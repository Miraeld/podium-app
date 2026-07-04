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

/// JS `field || null` — collapses an empty string to `nil` before a value
/// reaches a store method that uses SQL `COALESCE(?, existing)` for
/// "unchanged" semantics. Node's create/patch handlers (agents.js,
/// sessions.js) apply this to plain string body fields (name/task/cwd/
/// model/subagent_type/parent_agent_id/ended_at) before calling into
/// better-sqlite3 — without it, an explicit `""` in a PATCH body would
/// overwrite an existing column instead of leaving it untouched. Only apply
/// to fields Node actually treats this way; `status`/`type` use a
/// `field || "default"` pattern (handled separately) and `metadata` is
/// conditionally JSON-stringified.
func collapseEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
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
        guard let raw = queryValue(name), let parsed = jsParseInt(raw) else { return fallback }
        return Swift.min(Swift.max(parsed, min), max)
    }

    /// Same as `queryInt`, but returns `nil` on missing/unparseable input
    /// instead of falling back — for params that gate optional behavior
    /// (e.g. `after`/`before` line numbers).
    func queryIntOrNil(_ name: String) -> Int? {
        guard let raw = queryValue(name) else { return nil }
        return jsParseInt(raw)
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

/// JS `parseInt(raw, 10)`-compatible leading-integer parser: strips leading
/// whitespace, an optional `+`/`-` sign, then consumes a leading run of
/// ASCII digits — trailing non-digit garbage is ignored (`"50abc"` → `50`),
/// same as Node's `parseInt`. Returns `nil` if no digits are found at all
/// (Node's `NaN` case), matching `Int(raw)`'s failure behavior for those
/// call sites. Swift's `Int.init(_:)` is used throughout `RequestDecoding`
/// instead, which is strict and rejects all of the above — this is the
/// lenient replacement.
func jsParseInt(_ raw: String) -> Int? {
    var chars = Substring(raw)
    // Strip leading whitespace (JS parseInt trims whitespace, matching
    // `String.prototype.trim`'s whitespace set closely enough for query
    // params — ASCII space/tab/newline cover realistic inputs).
    while let first = chars.first, first.isWhitespace {
        chars.removeFirst()
    }

    var sign = 1
    if let first = chars.first, first == "+" || first == "-" {
        if first == "-" { sign = -1 }
        chars.removeFirst()
    }

    var digits = ""
    while let first = chars.first, first.isASCII, first.isNumber {
        digits.append(first)
        chars.removeFirst()
    }

    guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
    return sign * magnitude
}
