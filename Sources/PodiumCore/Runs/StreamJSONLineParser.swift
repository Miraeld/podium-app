// StreamJSONLineParser.swift — port of lib/stream-json-parser.js.
//
// Newline-delimited JSON line buffer for parsing `claude --output-format
// stream-json` output. Reassembles arbitrarily chunked stdout into discrete
// JSON envelopes (one per line). Robust to partial writes; malformed lines
// are reported as `.failure` but never thrown — a single garbage line must
// never take down the run.
//
// Unlike the Node version (which takes `onObject`/`onError` callbacks fired
// synchronously during `push`), this returns the parsed results as an array
// so `RunSpawner` (an actor) can process them with `await` in between
// (broadcasting, persistence) without needing an async-capable callback.

import Foundation

public struct StreamJSONParseError: Error, Equatable, Sendable {
    public let message: String
    public let raw: String
}

public struct StreamJSONLineParser: Sendable {
    private var buffer: String = ""

    public init() {}

    /// Appends `chunk` to the internal buffer and extracts every complete
    /// (`\n`-terminated) line, in order. Blank lines are silently skipped
    /// (matches the Node parser's `if (!line) continue`).
    public mutating func push(_ chunk: String) -> [Result<JSONValue, StreamJSONParseError>] {
        buffer += chunk
        var results: [Result<JSONValue, StreamJSONParseError>] = []
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newlineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard !line.isEmpty else { continue }
            results.append(Self.parse(line))
        }
        return results
    }

    /// Flushes any trailing partial line still in the buffer (e.g. the
    /// process exited without a final newline). Matches the Node parser's
    /// `flush()`, called once on child `exit`.
    public mutating func flush() -> Result<JSONValue, StreamJSONParseError>? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !tail.isEmpty else { return nil }
        return Self.parse(tail)
    }

    private static func parse(_ line: String) -> Result<JSONValue, StreamJSONParseError> {
        guard let data = line.data(using: .utf8) else {
            return .failure(StreamJSONParseError(message: "invalid utf8", raw: line))
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return .success(value)
        } catch {
            return .failure(StreamJSONParseError(message: "\(error)", raw: line))
        }
    }
}
