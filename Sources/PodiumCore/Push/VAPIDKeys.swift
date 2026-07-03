// VAPIDKeys.swift — port of lib/push.js's `loadOrCreateVapidKeys` (lines
// 17–25). Generates (or loads) the P-256 key pair VAPID auth is signed
// with, persisted to `vapid-keys.json` in the data dir.
//
// FORMAT COMPATIBILITY: the file shape is EXACTLY the one the `web-push`
// npm library (`generateVAPIDKeys()`) writes and that the live plugin-era
// file at `~/.claude/podium/data/vapid-keys.json` already contains:
//
//     { "publicKey": "<base64url, 65-byte uncompressed P-256 point>",
//       "privateKey": "<base64url, 32-byte raw scalar>" }
//
// Loading that exact file must keep working so existing (if any) real
// subscriptions stay valid after migrating off the Node plugin — hence a
// dedicated plain `JSONEncoder`/`JSONDecoder` here (NOT `PodiumJSON`, whose
// `.convertFromSnakeCase`/`.convertToSnakeCase` are irrelevant to these two
// camelCase-only keys but would be an easy copy-paste footgun to reuse for
// a file whose shape is a hard external contract, not our own wire format).
//
// swift-crypto's `P256.KeyAgreement.PrivateKey`/`PublicKey` always produce
// fixed-length raw/x963 representations (32 / 65 bytes) — unlike Node's
// `crypto.createECDH`, which can occasionally return a short-by-a-byte
// buffer that web-push's `generateVAPIDKeys` has to manually zero-pad (see
// the comment in vapid-helper.js). No equivalent padding step is needed
// here.

import Crypto
import Foundation

/// A VAPID key pair, base64url-encoded exactly as `vapid-keys.json` stores
/// it and as the wire format (`GET /api/push/vapid-public-key`) exposes the
/// public half.
public struct VAPIDKeyPair: Codable, Equatable, Sendable {
    public let publicKey: String
    public let privateKey: String

    public init(publicKey: String, privateKey: String) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

public enum VAPIDKeyError: Error, Equatable {
    case invalidStoredFile
    case invalidPublicKey
    case invalidPrivateKey
}

public enum VAPIDKeyStore {
    /// Plain (non-snake_case) coder for the on-disk key file — see file
    /// header for why this must NOT be `PodiumJSON`.
    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    /// Generates a fresh P-256 VAPID key pair.
    public static func generate() -> VAPIDKeyPair {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return VAPIDKeyPair(
            publicKey: Base64URL.encode(privateKey.publicKey.x963Representation),
            privateKey: Base64URL.encode(privateKey.rawRepresentation)
        )
    }

    /// Loads `vapid-keys.json` at `path` if present, otherwise generates a
    /// new pair and persists it (creating the parent directory as needed) —
    /// the exact `loadOrCreateVapidKeys` behavior.
    @discardableResult
    public static func loadOrCreate(path: URL) throws -> VAPIDKeyPair {
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            do {
                return try decoder.decode(VAPIDKeyPair.self, from: data)
            } catch {
                throw VAPIDKeyError.invalidStoredFile
            }
        }
        let keys = generate()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(keys)
        try data.write(to: path, options: .atomic)
        return keys
    }

    /// Decodes the raw 65-byte uncompressed P-256 public key point.
    public static func publicKeyAgreementKey(from pair: VAPIDKeyPair) throws -> P256.KeyAgreement.PublicKey {
        guard let raw = Base64URL.decode(pair.publicKey) else { throw VAPIDKeyError.invalidPublicKey }
        return try P256.KeyAgreement.PublicKey(x963Representation: raw)
    }

    /// Decodes the raw 32-byte private scalar as a `P256.Signing.PrivateKey`
    /// — used for the ES256 VAPID JWT signature (`VAPIDJWT`).
    public static func signingPrivateKey(from pair: VAPIDKeyPair) throws -> P256.Signing.PrivateKey {
        guard let raw = Base64URL.decode(pair.privateKey) else { throw VAPIDKeyError.invalidPrivateKey }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: raw)
        } catch {
            throw VAPIDKeyError.invalidPrivateKey
        }
    }
}
