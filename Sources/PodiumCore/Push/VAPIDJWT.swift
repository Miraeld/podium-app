// VAPIDJWT.swift — port of web-push's vapid-helper.js `getVapidHeaders`
// (ES256-signed JWT, aes128gcm branch only — this app never speaks the
// legacy `aesgcm` encoding, so the `Crypto-Key`/`p256ecdsa=` header pair
// that branch adds is intentionally not implemented).
//
// JWT shape (RFC 8292 VAPID + RFC 7519 JWT):
//   header:  {"typ":"JWT","alg":"ES256"}
//   payload: {"aud":<push-service-origin>,"exp":<unix-seconds>,"sub":<subject>}
//   signature: raw ECDSA P-256 (r || s, 64 bytes) over "header.payload",
//              base64url — NOT the DER form `P256.Signing.ECDSASignature`
//              would produce via `derRepresentation`; `rawRepresentation`
//              is the compact JWS form both `jws` (Node) and every push
//              service's JWT verifier expect.
//
// Final header value: `vapid t=<jwt>, k=<publicKey>` (aes128gcm only).

import Crypto
import Foundation

public enum VAPIDError: Error, Equatable {
    case invalidAudience
    case invalidSubject
}

public enum VAPID {
    /// Default VAPID JWT lifetime — 12 hours, matching web-push's
    /// `DEFAULT_EXPIRATION_SECONDS`.
    public static let defaultExpirationSeconds: TimeInterval = 12 * 60 * 60

    /// Builds the `Authorization: vapid t=..., k=...` header value for a
    /// push request to `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: the subscription's push-service endpoint URL; only its
    ///     scheme+host(+port) is used as the JWT `aud` claim, matching
    ///     Node's `url.parse(endpoint)` → `protocol + "//" + host`.
    ///   - subject: an `https:` or `mailto:` URI identifying the sender
    ///     (VAPID `sub` claim).
    ///   - keys: the VAPID key pair; `keys.privateKey` signs the JWT.
    ///   - expiration: absolute expiry; defaults to now + 12h.
    public static func authorizationHeader(
        endpoint: String,
        subject: String,
        keys: VAPIDKeyPair,
        expiration: Date = Date().addingTimeInterval(VAPID.defaultExpirationSeconds)
    ) throws -> String {
        let audience = try self.audience(forEndpoint: endpoint)
        let privateKey = try VAPIDKeyStore.signingPrivateKey(from: keys)

        let header = JWTHeader(typ: "JWT", alg: "ES256")
        let payload = JWTPayload(aud: audience, exp: Int(expiration.timeIntervalSince1970), sub: subject)

        let encoder = JSONEncoder()
        let headerSegment = Base64URL.encode(try encoder.encode(header))
        let payloadSegment = Base64URL.encode(try encoder.encode(payload))
        let signingInput = "\(headerSegment).\(payloadSegment)"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let signatureSegment = Base64URL.encode(signature.rawRepresentation)

        let jwt = "\(signingInput).\(signatureSegment)"
        return "vapid t=\(jwt), k=\(keys.publicKey)"
    }

    /// `protocol://host[:port]` of `endpoint` — the VAPID `aud` claim.
    static func audience(forEndpoint endpoint: String) throws -> String {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty
        else {
            throw VAPIDError.invalidAudience
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    struct JWTHeader: Encodable {
        let typ: String
        let alg: String
    }

    struct JWTPayload: Encodable {
        let aud: String
        let exp: Int
        let sub: String
    }
}
