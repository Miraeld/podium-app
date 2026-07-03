// Base64URL.swift — unpadded, URL-safe base64 (RFC 4648 §5), the encoding
// every Web Push value uses on the wire and on disk (VAPID keys, p256dh,
// auth, JWT segments, ciphertext bodies). Foundation's `Data` base64 APIs
// only speak standard base64 with padding, so this is a thin translation
// layer, not a reimplementation of the alphabet.

import Foundation

public enum Base64URL {
    /// Encodes `data` as unpadded, URL-safe base64 — e.g. what
    /// `Buffer.toString('base64url')` produces in Node.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Decodes URL-safe base64 with or without padding — e.g. what
    /// `Buffer.from(str, 'base64url')` accepts in Node.
    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
