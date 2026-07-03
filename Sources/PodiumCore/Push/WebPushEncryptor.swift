// WebPushEncryptor.swift — RFC 8291 ("Message Encryption for Web Push")
// aes128gcm content encoding, built directly on swift-crypto (ECDH P-256 +
// HKDF-SHA256 + AES-128-GCM). Ports the `aes128gcm` path of the `http_ece`
// npm package (the encryption engine underneath `web-push`, used by
// lib/push.js) — see ece.js `webpushSecret`, `deriveKeyAndNonce`,
// `encryptRecord`, `writeHeader`, `encrypt`.
//
// Wire layout of the returned `Data` (RFC 8188 §2 header + RFC 8291 body):
//
//     salt(16) | rs(4, big-endian) | idlen(1) | keyid(idlen=65, sender's
//     uncompressed ECDH public key) | record_0 | record_1 | ...
//
// Each record is AES-128-GCM-sealed plaintext with a single delimiter byte
// appended before sealing (0x02 for the last record, 0x01 otherwise) —
// RFC 8188's padding scheme — followed by the 16-byte GCM tag. Records
// after the first are only produced when the payload doesn't fit in one
// `recordSize - overhead` chunk; push notification payloads are tiny JSON
// blobs, so callers hit the single-record path in practice, but the
// multi-record loop is implemented for correctness with larger payloads.
//
// Key derivation (RFC 8291 §3.4, ece.js `webpushSecret` + `deriveKeyAndNonce`):
//   1. ecdh_secret  = ECDH(as_private, ua_public)
//   2. context      = "WebPush: info\0" || ua_public(65) || as_public(65)
//   3. ikm           = HKDF-SHA256(salt=auth_secret, ikm=ecdh_secret, info=context, L=32)
//   4. prk           = HKDF-extract(salt=salt16, ikm=ikm)
//   5. cek           = HKDF-expand(prk, info="Content-Encoding: aes128gcm\0", L=16)
//   6. nonce_base    = HKDF-expand(prk, info="Content-Encoding: nonce\0", L=12)
//   7. nonce_i       = nonce_base XOR big-endian-48-bit(counter) in its last 6 bytes

import Crypto
import Foundation

public enum WebPushEncryptionError: Error, Equatable {
    case invalidUserPublicKey
    case invalidUserAuthSecret
    case emptyRecord
}

public enum WebPushEncryptor {
    private static let tagByteCount = 16
    private static let paddingDelimiterByteCount = 1
    // Public: referenced from a public function's default argument value,
    // which Swift requires to be at least as accessible as the function.
    public static let defaultRecordSize = 4096

    /// Encrypts `payload` for delivery to a Web Push subscription, per
    /// RFC 8291. `userPublicKeyBase64URL`/`userAuthBase64URL` are the
    /// subscription's `p256dh`/`auth` values exactly as stored (base64url,
    /// no padding).
    ///
    /// - Parameters:
    ///   - senderKey: the application server's ephemeral ECDH key pair.
    ///     Callers normally omit this (a fresh key is generated per
    ///     message, as RFC 8291 requires); tests pass a fixed key to
    ///     reproduce the RFC's worked example.
    ///   - salt: the 16-byte record salt. Callers normally omit this (a
    ///     fresh random salt is generated per message); tests pass the
    ///     RFC's fixed salt.
    public static func encrypt(
        payload: Data,
        userPublicKeyBase64URL: String,
        userAuthBase64URL: String,
        recordSize: Int = defaultRecordSize,
        senderKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        salt: Data = randomSalt()
    ) throws -> Data {
        guard let userPublicKeyRaw = Base64URL.decode(userPublicKeyBase64URL), userPublicKeyRaw.count == 65,
              let userPublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: userPublicKeyRaw)
        else {
            throw WebPushEncryptionError.invalidUserPublicKey
        }
        guard let authSecret = Base64URL.decode(userAuthBase64URL), authSecret.count >= 16 else {
            throw WebPushEncryptionError.invalidUserAuthSecret
        }
        precondition(salt.count == 16, "salt must be 16 bytes")

        let senderPublicRaw = senderKey.publicKey.x963Representation
        let sharedSecret = try senderKey.sharedSecretFromKeyAgreement(with: userPublicKey)

        let context = webPushInfo(userPublicKey: userPublicKeyRaw, senderPublicKey: senderPublicRaw)
        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: context,
            outputByteCount: 32
        )

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16
        )
        let nonceBase = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12
        )
        let nonceBaseBytes = nonceBase.withUnsafeBytes { Data($0) }

        var header = Data()
        header.append(salt)
        header.append(bigEndianUInt32(UInt32(recordSize)))
        header.append(UInt8(senderPublicRaw.count))
        header.append(senderPublicRaw)

        let overhead = paddingDelimiterByteCount + tagByteCount
        let capacity = recordSize - overhead
        precondition(capacity > 0, "recordSize too small")

        var body = Data()
        var start = payload.startIndex
        var counter: UInt64 = 0
        repeat {
            let end = payload.index(start, offsetBy: capacity, limitedBy: payload.endIndex) ?? payload.endIndex
            let isLast = end >= payload.endIndex
            var chunk = Data(payload[start..<end])
            chunk.append(isLast ? 0x02 : 0x01)

            let nonce = try AES.GCM.Nonce(data: generateNonce(base: nonceBaseBytes, counter: counter))
            let sealed = try AES.GCM.seal(chunk, using: cek, nonce: nonce)
            body.append(sealed.ciphertext)
            body.append(sealed.tag)

            start = end
            counter += 1
        } while start < payload.endIndex

        // An entirely empty payload still produces exactly one (empty +
        // delimiter) record — the `repeat`/`while` above already guarantees
        // that since `payload.startIndex == payload.endIndex` runs the body
        // once before the loop condition is checked.

        return header + body
    }

    /// `"WebPush: info\0" || ua_public(65) || as_public(65)` — RFC 8291 §3.4.
    static func webPushInfo(userPublicKey: Data, senderPublicKey: Data) -> Data {
        var info = Data("WebPush: info\0".utf8)
        info.append(userPublicKey)
        info.append(senderPublicKey)
        return info
    }

    /// `nonce_base XOR counter` in the nonce's last 6 bytes (48-bit
    /// big-endian), per RFC 8188 §2. For `counter == 0` this is simply
    /// `nonce_base` unchanged.
    static func generateNonce(base: Data, counter: UInt64) -> Data {
        var nonce = [UInt8](base)
        let length = nonce.count
        for i in 0..<6 {
            let shift = 8 * (5 - i)
            let counterByte = UInt8(truncatingIfNeeded: counter >> UInt64(shift))
            nonce[length - 6 + i] ^= counterByte
        }
        return Data(nonce)
    }

    static func bigEndianUInt32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}
