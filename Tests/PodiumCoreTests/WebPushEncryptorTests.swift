import XCTest
import Crypto
@testable import PodiumCore

/// Byte-exact coverage of `WebPushEncryptor` against RFC 8291 §5's worked
/// example — the "meaty part" of P4.2 (plan §6, task P4.2 acceptance bar:
/// "RFC 8291 test vectors MUST pass").
///
/// All fixture values below are transcribed verbatim from
/// https://www.rfc-editor.org/rfc/rfc8291#section-5 ("Push Message
/// Encryption Example").
final class WebPushEncryptorTests: XCTestCase {
    // MARK: - RFC 8291 §5 fixtures

    /// The application server's (sender's) ephemeral ECDH key pair.
    /// Private: `yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw` (as85, raw
    /// scalar). RFC 8291 gives the raw private key as a base64url string in
    /// the `as_private` line of the example.
    private static let asPrivateBase64URL = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"

    /// The user agent's (receiver's) public key (`ua_public`), the
    /// subscription's `p256dh` value — 65-byte uncompressed point, base64url.
    private static let uaPublicBase64URL =
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"

    /// The subscription's `auth` secret.
    private static let authSecretBase64URL = "BTBZMqHH6r4Tts7J_aSIgg"

    /// The 16-byte record salt RFC 8291 uses for this example.
    private static let saltBase64URL = "DGv6ra1nlYgDCS1FRnbzlw"

    /// Plaintext payload the RFC encrypts: ASCII "When I grow up, I want to
    /// be a watermelon".
    private static let plaintext = "When I grow up, I want to be a watermelon"

    /// Expected aes128gcm ciphertext body — the exact HTTP POST body from
    /// RFC 8291 §5's worked example (three lines in the RFC, concatenated
    /// here into one base64url string): header (salt|rs|idlen|keyid) +
    /// single encrypted record.
    private static let expectedCiphertextBase64URL =
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

    /// The application server's ephemeral public key, as embedded in the
    /// ciphertext header (`keyid`) — used to independently reconstruct the
    /// fixed sender key pair for the test.
    private static let asPublicBase64URL =
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"

    private static func fixedSenderKey() throws -> P256.KeyAgreement.PrivateKey {
        guard let raw = Base64URL.decode(asPrivateBase64URL) else {
            XCTFail("failed to decode as_private fixture")
            throw WebPushEncryptionError.invalidUserPublicKey
        }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    private static func fixedSalt() throws -> Data {
        guard let salt = Base64URL.decode(saltBase64URL), salt.count == 16 else {
            XCTFail("failed to decode salt fixture")
            throw WebPushEncryptionError.invalidUserPublicKey
        }
        return salt
    }

    // MARK: - RFC 8291 §5 worked example

    func testRFC8291WorkedExampleProducesByteExactCiphertext() throws {
        let senderKey = try Self.fixedSenderKey()
        let salt = try Self.fixedSalt()

        // Sanity check: the fixed sender key's public half must match the
        // `keyid` embedded in the RFC's expected output, or the fixture
        // transcription above is wrong.
        let senderPublicRaw = senderKey.publicKey.x963Representation
        let expectedSenderPublic = Base64URL.decode(Self.asPublicBase64URL)
        XCTAssertEqual(senderPublicRaw, expectedSenderPublic, "fixed sender key doesn't match RFC 8291 as_public")

        let ciphertext = try WebPushEncryptor.encrypt(
            payload: Data(Self.plaintext.utf8),
            userPublicKeyBase64URL: Self.uaPublicBase64URL,
            userAuthBase64URL: Self.authSecretBase64URL,
            senderKey: senderKey,
            salt: salt
        )

        guard let expected = Base64URL.decode(Self.expectedCiphertextBase64URL) else {
            XCTFail("failed to decode expected ciphertext fixture")
            return
        }
        XCTAssertEqual(ciphertext, expected, "ciphertext does not byte-exact match RFC 8291 §5's worked example")
    }

    func testRFC8291HeaderLayoutMatchesSaltRecordSizeAndKeyId() throws {
        let senderKey = try Self.fixedSenderKey()
        let salt = try Self.fixedSalt()

        let ciphertext = try WebPushEncryptor.encrypt(
            payload: Data(Self.plaintext.utf8),
            userPublicKeyBase64URL: Self.uaPublicBase64URL,
            userAuthBase64URL: Self.authSecretBase64URL,
            senderKey: senderKey,
            salt: salt
        )

        // salt(16) | rs(4, BE) | idlen(1) | keyid(65)
        XCTAssertEqual(ciphertext.prefix(16), salt)
        let rsBytes = ciphertext.subdata(in: 16..<20)
        let rs = rsBytes.reduce(0) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(rs, UInt32(WebPushEncryptor.defaultRecordSize))
        XCTAssertEqual(ciphertext[ciphertext.startIndex + 20], 65)
        let keyId = ciphertext.subdata(in: 21..<86)
        XCTAssertEqual(keyId, senderKey.publicKey.x963Representation)
    }

    // MARK: - Round trip via the receiver-side derivation (sanity, not RFC-pinned)

    /// Decrypts our own output using the same key material, independently
    /// walking the aes128gcm layout — guards against a future refactor
    /// silently changing record framing while still matching the one fixed
    /// RFC vector above (which only exercises a single record).
    func testEncryptedPayloadDecryptsBackToPlaintextWithReceiverDerivation() throws {
        let senderKey = P256.KeyAgreement.PrivateKey()
        let receiverKey = P256.KeyAgreement.PrivateKey()
        let authSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let salt = WebPushEncryptor.randomSalt()

        let userPublicKeyBase64URL = Base64URL.encode(receiverKey.publicKey.x963Representation)
        let authBase64URL = Base64URL.encode(authSecret)

        let plaintext = "hello from podium"
        let ciphertext = try WebPushEncryptor.encrypt(
            payload: Data(plaintext.utf8),
            userPublicKeyBase64URL: userPublicKeyBase64URL,
            userAuthBase64URL: authBase64URL,
            senderKey: senderKey,
            salt: salt
        )

        let decrypted = try Self.decrypt(
            ciphertext: ciphertext,
            receiverPrivateKey: receiverKey,
            authSecret: authSecret
        )
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), plaintext)
    }

    /// Minimal receiver-side aes128gcm decoder, independent of
    /// `WebPushEncryptor`'s internals — mirrors RFC 8291 §3.4/RFC 8188 §2
    /// key derivation from the *receiver's* point of view (ECDH with the
    /// sender's embedded public key instead of the user's).
    private static func decrypt(ciphertext: Data, receiverPrivateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let salt = ciphertext.subdata(in: ciphertext.startIndex..<(ciphertext.startIndex + 16))
        let idLen = Int(ciphertext[ciphertext.startIndex + 20])
        let keyIdStart = ciphertext.startIndex + 21
        let senderPublicRaw = ciphertext.subdata(in: keyIdStart..<(keyIdStart + idLen))
        let bodyStart = keyIdStart + idLen

        let senderPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicRaw)
        let sharedSecret = try receiverPrivateKey.sharedSecretFromKeyAgreement(with: senderPublicKey)

        var context = Data("WebPush: info\0".utf8)
        context.append(receiverPrivateKey.publicKey.x963Representation)
        context.append(senderPublicRaw)

        let ikm = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: authSecret, sharedInfo: context, outputByteCount: 32)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonceBase = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let nonceBaseBytes = nonceBase.withUnsafeBytes { Data($0) }

        let sealedBody = ciphertext.subdata(in: bodyStart..<ciphertext.endIndex)
        let tagSize = 16
        let ciphertextPart = sealedBody.subdata(in: sealedBody.startIndex..<(sealedBody.endIndex - tagSize))
        let tag = sealedBody.subdata(in: (sealedBody.endIndex - tagSize)..<sealedBody.endIndex)

        let nonceBytes = [UInt8](nonceBaseBytes) // counter 0 -> unchanged
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextPart, tag: tag)
        var opened = try AES.GCM.open(sealedBox, using: cek)
        // Strip the trailing padding delimiter byte (0x02 = last record).
        XCTAssertEqual(opened.removeLast(), 0x02)
        return opened
    }
}
