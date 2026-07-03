// JSONValue+Hooks.swift — convenience accessors used throughout IngestEngine
// to read loosely-typed Claude Code hook payloads without hand-rolling
// `if case .object(...)` boilerplate at every call site. Mirrors the loose
// duck-typing hooks.js does on `data.<field>` (a plain JS object) — every
// accessor here is nil-safe and never throws, matching the "garbage payloads
// must never crash the ingestion pipeline" requirement.

import Foundation

extension JSONValue {
    /// Subscript into an `.object` value; `nil` for any other case or a
    /// missing key. Mirrors `data.foo` on a JS object (undefined, not throw).
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// String field access, matching JS's `typeof data.foo === 'string' ? data.foo : undefined`
    /// pattern used throughout hooks.js.
    public var asString: String? {
        stringValue
    }

    /// Number field access as `Double`.
    public var asDouble: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Number field access as `Int` (truncating), matching `parseInt`-style
    /// usage sites in hooks.js where fractional hook payload numbers would be
    /// unexpected but shouldn't crash.
    public var asInt: Int? {
        asDouble.map { Int($0) }
    }

    /// Bool field access.
    public var asBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Array field access.
    public var asArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Convenience: string field at `key`, `nil` if absent, not a string, or
    /// an empty string — mirrors hooks.js's frequent
    /// `typeof data.transcript_path === 'string' && data.transcript_path` guard.
    public func nonEmptyString(_ key: String) -> String? {
        guard let value = self[key]?.asString, !value.isEmpty else { return nil }
        return value
    }

    /// Convenience: string field at `key`, empty string included (unlike
    /// `nonEmptyString`) — for fields where "" is a meaningful distinct value
    /// from "absent".
    public func string(_ key: String) -> String? {
        self[key]?.asString
    }

    /// Builds a `JSONValue.object` from raw Foundation types (as produced by
    /// `JSONSerialization`), used by `HooksRouter` to convert the decoded
    /// request body into `JSONValue` for the engine, and by tests to build
    /// fixtures ergonomically.
    public static func from(_ any: Any?) -> JSONValue {
        switch any {
        case nil, is NSNull:
            return .null
        case let v as String:
            return .string(v)
        case let v as Bool:
            // NOTE: must check Bool before NSNumber — on Darwin, NSNumber(bool:)
            // bridges to Bool and would otherwise be misread as a number.
            return .bool(v)
        case let v as Int:
            return .number(Double(v))
        case let v as Double:
            return .number(v)
        case let v as NSNumber:
            // CFBoolean bridges to NSNumber too; guard defensively.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                return .bool(v.boolValue)
            }
            return .number(v.doubleValue)
        case let v as [Any?]:
            return .array(v.map { JSONValue.from($0) })
        case let v as [String: Any?]:
            var result: [String: JSONValue] = [:]
            for (key, value) in v { result[key] = JSONValue.from(value) }
            return .object(result)
        default:
            return .null
        }
    }

    /// Round-trips this value back to plain Foundation types
    /// (String/NSNumber/Bool/Array/Dictionary/NSNull) suitable for
    /// `JSONSerialization` — the inverse of `from(_:)`. Used when composing
    /// the `data` blob stored on `events.data`, where hooks.js sometimes
    /// mutates the plain JS object before `JSON.stringify`-ing it (e.g.
    /// `data.bash_parsed = {...}`).
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map { $0.foundationValue }
        case .object(let value):
            var result: [String: Any] = [:]
            for (key, val) in value { result[key] = val.foundationValue }
            return result
        }
    }

    /// Returns a new `.object` value with `key` set to `value`, preserving
    /// all other keys — used to build the mutated `data` blob (hooks.js
    /// mutates `data` in place; JSONValue is a value type, so callers use
    /// this to produce the updated copy) without allocating a mutable dict
    /// at every call site.
    public func settingObject(_ key: String, to value: JSONValue) -> JSONValue {
        var dict = objectValue ?? [:]
        dict[key] = value
        return .object(dict)
    }
}
