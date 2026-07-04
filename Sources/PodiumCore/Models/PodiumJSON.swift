import Foundation

/// Shared JSON coding infrastructure for all PodiumCore wire types.
///
/// Wire format parity with the Node dashboard server (dashboard/server/*):
/// all JSON keys are snake_case, and all timestamps are ISO8601 strings with
/// millisecond precision and a trailing "Z" — the same shape SQLite produces
/// via `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')`. Example: `2024-01-01T00:00:00.000Z`.
///
/// Models store timestamp fields as `String` (not `Date`) so a round-trip
/// through decode → encode reproduces the exact original text (including any
/// oddities already sitting in an existing dashboard.db). Computed `Date`
/// accessors are provided on top for convenience.
public enum PodiumJSON {
    /// Encoder producing snake_case keys. Does NOT touch date formatting —
    /// models encode their own timestamp fields as plain strings.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// Decoder accepting snake_case keys. Does NOT touch date formatting —
    /// models decode their own timestamp fields as plain strings.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Parses and formats the Podium wire timestamp format:
/// `2024-01-01T00:00:00.000Z` (milliseconds, always UTC/"Z").
///
/// Accepts both fractional-second and non-fractional ISO8601 strings on
/// decode (older rows / hand-written fixtures may omit the milliseconds),
/// but always **emits** the millisecond form to match
/// `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')` exactly.
public enum PodiumDate {
    /// Formatter for `2024-01-01T00:00:00.000Z` (fractional seconds).
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formatter for `2024-01-01T00:00:00Z` (no fractional seconds).
    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses a wire timestamp string, trying the fractional-second format
    /// first, then falling back to whole seconds. Returns `nil` if neither
    /// parses (e.g. malformed data) so callers can decide how to handle it.
    public static func parse(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        return wholeSecondFormatter.date(from: string)
    }

    /// Formats a `Date` as `2024-01-01T00:00:00.000Z` — the canonical wire
    /// format this app always emits, matching the SQLite strftime format.
    public static func format(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// Convenience: the current instant formatted as a wire timestamp.
    public static func now() -> String {
        format(Date())
    }
}

/// A JSON value with no fixed shape — used for the loosely-typed hook event
/// payloads (Claude Code hook JSON) and the `data` column on `events`, which
/// stores arbitrary JSON as TEXT. Round-trips through Codable exactly,
/// preserving key order is NOT guaranteed (Foundation JSON semantics), but
/// value fidelity is.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience accessor for object values, `nil` for any other case.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for string values, `nil` for any other case.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// Type-erased `Encodable` box for the `PodiumJSON.encoder` camelCase
/// footgun: `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` transforms
/// EVERY resolved `CodingKey.stringValue` uniformly, with no way to exempt
/// individual keys — not even via a `CodingKeys` enum with an explicit
/// camelCase raw value (that raw string is itself a `CodingKey.stringValue`
/// and gets re-transformed just the same, e.g. `claudeHome` → `claude_home`).
/// `Dictionary<String, _>` is the one documented exception: its keys are
/// written straight through with no `CodingKey` resolution step at all, so
/// they survive `.convertToSnakeCase` verbatim — confirmed empirically, and
/// true at any nesting depth (inside arrays, optionals, other structs).
///
/// So: for a wire type whose top-level field names must stay literal
/// camelCase (a handful of cc-config responses mirror the Node API's own
/// camelCase object literals — see `CcConfig.swift`/`CcMutate.swift`), give
/// it a custom `encode(to:)` that builds a `[String: AnyEncodable]` with the
/// literal key strings and writes that as a single-value container, instead
/// of letting the compiler synthesize the normal keyed encode. Leave
/// `init(from:)` to synthesize as usual — decoding is unaffected, since
/// `PodiumJSON.decoder`'s `.convertFromSnakeCase` only rewrites keys that
/// actually contain an underscore and passes an already-camelCase key
/// through unchanged.
public struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    public init<T: Encodable>(_ wrapped: T) {
        self.encodeClosure = wrapped.encode
    }

    public func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

/// A raw-string-preserving enum wrapper: decodes any string into `.known`
/// when it matches a case of `Known`, otherwise `.unknown(rawString)`. This
/// is how status columns stay lenient — an old/foreign dashboard.db with an
/// unexpected status value must never crash decoding.
public enum LenientRawValue<Known: RawRepresentable & Codable & Equatable & Sendable>: Codable, Equatable, Sendable
where Known.RawValue == String {
    case known(Known)
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .known(let value): return value.rawValue
        case .unknown(let value): return value
        }
    }

    /// The known case, or `nil` if this wraps an unrecognized raw string.
    public var knownValue: Known? {
        if case .known(let value) = self { return value }
        return nil
    }

    public init(_ known: Known) {
        self = .known(known)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let known = Known(rawValue: raw) {
            self = .known(known)
        } else {
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
