// RequestDecoding.swift — shared request-body/query helpers for the P2.2
// read routers. Kept here (not in JSONResponse.swift) since it's specific to
// *decoding* incoming requests rather than *encoding* outgoing responses.
//
// IMPORTANT: bodies are decoded with `PodiumJSON.decoder` (snake_case), NOT
// Hummingbird's `request.decode(as:context:)` convenience, which uses
// `RequestContext`'s default `Encoder`/`Decoder` (camelCase) and would
// silently fail to populate snake_case request fields like `session_id`.

import Foundation
import Hummingbird
import HummingbirdCore
import PodiumCore

/// 1 MB JSON body cap — parity with the Node app's `express.json({ limit:
/// "1mb" })` (plan §2.1 / index.js app assembly).
let jsonBodyLimit = 1 * 1024 * 1024

extension Request {
    /// Collects the full body (up to `jsonBodyLimit`) and decodes it as
    /// `T` using `PodiumJSON.decoder` (snake_case keys). Empty bodies decode
    /// as if `{}` were sent, matching Express's `req.body` defaulting to
    /// `{}` for a bodyless POST/PATCH.
    mutating func decodeJSONBody<T: Decodable>(as type: T.Type = T.self) async throws -> T {
        let buffer = try await self.collectBody(upTo: jsonBodyLimit)
        let data = buffer.readableBytesView.isEmpty ? Data("{}".utf8) : Data(buffer.readableBytesView)
        return try PodiumJSON.decoder.decode(T.self, from: data)
    }
}

extension URI {
    /// Raw string query parameter lookup (percent-decoded by `URI` itself).
    func queryValue(_ name: String) -> String? {
        guard let value = queryParameters[name[...]] else { return nil }
        let string = String(value)
        return string.isEmpty ? nil : string
    }

    /// `parseInt(req.query.X) || fallback` — clamps to `[min, max]`, and
    /// falls back on missing/unparseable input (mirrors `Number.isNaN`
    /// guards used throughout the Node routers).
    func queryInt(_ name: String, fallback: Int, min: Int = Int.min, max: Int = Int.max) -> Int {
        guard let raw = queryValue(name), let parsed = Int(raw) else { return fallback }
        return Swift.min(Swift.max(parsed, min), max)
    }

    /// Same as `queryInt`, but returns `nil` on missing/unparseable input
    /// instead of falling back — for params that gate optional behavior
    /// (e.g. `after`/`before` line numbers).
    func queryIntOrNil(_ name: String) -> Int? {
        guard let raw = queryValue(name) else { return nil }
        return Int(raw)
    }

    /// Comma-separated list query param → non-empty trimmed components, or
    /// `nil` if absent/empty — mirrors events.js `parseCsv`.
    func queryCSV(_ name: String) -> [String]? {
        guard let raw = queryValue(name) else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// `req.query.X` trimmed, `nil` if absent/blank — mirrors the repeated
    /// `typeof req.query.q === "string" ? req.query.q.trim() : ""` pattern.
    func queryTrimmed(_ name: String) -> String? {
        guard let raw = queryValue(name) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses a date query param into a wire-format ISO8601 string, or
    /// `nil` if absent/unparseable — mirrors events.js `parseDate` (accepts
    /// anything `new Date(value)` can parse, re-emits as `toISOString()`).
    func queryDate(_ name: String) -> String? {
        guard let raw = queryValue(name) else { return nil }
        guard let date = PodiumDate.parse(raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        return PodiumDate.format(date)
    }
}
