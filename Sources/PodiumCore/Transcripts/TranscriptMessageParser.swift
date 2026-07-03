// TranscriptMessageParser.swift — port of the `parseMessage`/pagination logic
// inside dashboard/server/routes/sessions.js's `GET /:id/transcript` handler
// (lines 491–761): turns raw JSONL entries into the `TranscriptMessage` shape
// the React conversation viewer consumes, with four pagination modes
// (`after`, `before`, `offset`, default-latest-N).
//
// DEVIATION: sessions.js streams the file line-by-line with early
// termination for efficiency. This port reads the whole file into memory via
// `String(contentsOf:)` and iterates its lines — simpler, and the JSONL files
// this endpoint serves are individual session transcripts (tens of MB at
// most), not the multi-GB logs `TranscriptCache` guards against. Pagination
// semantics (which lines are returned, `has_more`, `first_line`/`last_line`)
// are ported exactly.

import Foundation

public enum TranscriptMessageParser {
    private static let contentTruncateLen = 10240

    /// Reads `path` and returns a page of parsed messages per the query mode
    /// (mirrors sessions.js `GET /:id/transcript`). Never throws — any read
    /// or parse failure yields the same empty-result shape Node returns from
    /// its `catch` block.
    public static func page(
        path: String,
        agentId: String?,
        limit: Int,
        after: Int?,
        before: Int?,
        offset: Int
    ) -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return TranscriptResult(messages: [], total: 0, hasMore: false, lastLine: 0, firstLine: 0)
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return TranscriptResult(messages: [], total: 0, hasMore: false, lastLine: 0, firstLine: 0)
        }

        // Split on "\n" only, matching Node's readline (which treats a lone
        // "\r\n" as one line break too — strip a trailing CR per line below).
        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var lineNum = 0
        var total = 0
        var hasMore = false
        var messages: [(line: Int, message: TranscriptMessage)] = []

        func decode(_ rawLine: Substring) -> JSONValue? {
            var line = rawLine
            if line.hasSuffix("\r") { line = line.dropLast() }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }

        if let after {
            var foundStart = false
            for rawLine in rawLines {
                lineNum += 1
                guard let entry = decode(rawLine) else { continue }
                let type = entry.string("type")
                guard type == "user" || type == "assistant" else { continue }
                if !foundStart {
                    if lineNum <= after { continue }
                    foundStart = true
                }
                guard let message = parseMessage(entry, line: lineNum) else { continue }
                total += 1
                messages.append((lineNum, message))
                if messages.count >= limit {
                    hasMore = true
                    break
                }
            }
        } else if let before {
            for rawLine in rawLines {
                lineNum += 1
                guard let entry = decode(rawLine) else { continue }
                let type = entry.string("type")
                guard type == "user" || type == "assistant" else { continue }
                if lineNum >= before { break }
                guard let message = parseMessage(entry, line: lineNum) else { continue }
                total += 1
                messages.append((lineNum, message))
                if messages.count > limit { messages.removeFirst() }
            }
            if total > limit { hasMore = true }
        } else if offset > 0 {
            var skipped = 0
            for rawLine in rawLines {
                lineNum += 1
                guard let entry = decode(rawLine) else { continue }
                let type = entry.string("type")
                guard type == "user" || type == "assistant" else { continue }
                guard let message = parseMessage(entry, line: lineNum) else { continue }
                total += 1
                if skipped < offset {
                    skipped += 1
                    continue
                }
                messages.append((lineNum, message))
                if messages.count >= limit {
                    hasMore = true
                    break
                }
            }
        } else {
            for rawLine in rawLines {
                lineNum += 1
                guard let entry = decode(rawLine) else { continue }
                let type = entry.string("type")
                guard type == "user" || type == "assistant" else { continue }
                guard let message = parseMessage(entry, line: lineNum) else { continue }
                total += 1
                messages.append((lineNum, message))
                if messages.count > limit { messages.removeFirst() }
            }
            hasMore = total > limit
        }

        let lastLine = messages.last?.line ?? 0
        let firstLine = messages.first?.line ?? 0
        return TranscriptResult(
            messages: messages.map(\.message), total: total, hasMore: hasMore, lastLine: lastLine, firstLine: firstLine
        )
    }

    /// `parseMessage(entry, num)` — returns `nil` when the entry has no
    /// displayable content (mirrors Node returning `null`).
    static func parseMessage(_ entry: JSONValue, line: Int) -> TranscriptMessage? {
        let entryType = entry.string("type") ?? ""
        let msg = entryType == "assistant" ? (entry["message"] ?? .object([:])) : .object([:])
        var content: [TranscriptContent] = []

        if entryType == "user" {
            let msgContent = entry["message"]?["content"]
            if let text = msgContent?.asString {
                content.append(TranscriptContent(type: "text", text: truncate(text, contentTruncateLen)))
            } else if let blocks = msgContent?.asArray {
                for block in blocks {
                    let blockType = block.string("type")
                    if blockType == "text", let text = block.nonEmptyString("text") {
                        content.append(TranscriptContent(type: "text", text: truncate(text, contentTruncateLen)))
                    } else if blockType == "tool_result" {
                        // `typeof block.content === "string" ? block.content
                        // : JSON.stringify(block.content || "")` — a missing/
                        // null content encodes as the JSON string `""`, not
                        // a bare empty string.
                        let rawContent = block["content"]
                        let output: String
                        if let string = rawContent?.asString {
                            output = string
                        } else {
                            let toEncode: JSONValue = (rawContent == nil || rawContent == .null) ? .string("") : rawContent!
                            output = (try? String(data: JSONEncoder().encode(toEncode), encoding: .utf8)) ?? "\"\""
                        }
                        content.append(TranscriptContent(
                            type: "tool_result", id: block.string("tool_use_id"),
                            output: truncate(output, contentTruncateLen), isError: block["is_error"]?.asBool ?? false
                        ))
                    }
                }
            } else if msgContent == nil || msgContent == .null {
                return nil
            }
        } else {
            let msgContent = msg["content"]?.asArray ?? []
            for block in msgContent {
                let blockType = block.string("type")
                if blockType == "text", let text = block.nonEmptyString("text") {
                    content.append(TranscriptContent(type: "text", text: truncate(text, contentTruncateLen)))
                } else if blockType == "thinking", let thinking = block.nonEmptyString("thinking") {
                    content.append(TranscriptContent(type: "thinking", text: truncate(thinking, contentTruncateLen)))
                } else if blockType == "tool_use" {
                    content.append(TranscriptContent(
                        type: "tool_use", name: block.nonEmptyString("name") ?? "unknown", id: block.string("id"),
                        input: truncateInput(block["input"], contentTruncateLen)
                    ))
                }
            }
        }

        guard !content.isEmpty else { return nil }

        var message = TranscriptMessage(
            type: entryType,
            timestamp: coerceTimestamp(entry["timestamp"]),
            content: content
        )

        if entryType == "assistant" {
            message.model = msg.nonEmptyString("model")
            if let usage = msg["usage"] {
                message.usage = TranscriptMessage.Usage(
                    inputTokens: usage["input_tokens"]?.asInt ?? 0,
                    outputTokens: usage["output_tokens"]?.asInt ?? 0,
                    cacheReadInputTokens: usage["cache_read_input_tokens"]?.asInt ?? 0,
                    cacheCreationInputTokens: usage["cache_creation_input_tokens"]?.asInt ?? 0
                )
            }
        }

        return message
    }

    private static func coerceTimestamp(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .number(let ms):
            return PodiumDate.format(Date(timeIntervalSince1970: ms / 1000))
        case .string(let string):
            return string
        default:
            return nil
        }
    }

    private static func truncate(_ string: String, _ maxLen: Int) -> String {
        guard string.count > maxLen else { return string }
        return String(string.prefix(maxLen)) + "[truncated]"
    }

    /// `truncateObj` — truncates a tool_use `input` object when its
    /// serialized JSON exceeds `maxLen`, replacing it with
    /// `{"_truncated": "<preview>"}` (matches `TranscriptContent.truncatedPreview`).
    private static func truncateInput(_ value: JSONValue?, _ maxLen: Int) -> JSONValue? {
        guard let value, value != .null else { return value }
        guard let json = try? JSONEncoder().encode(value), let jsonString = String(data: json, encoding: .utf8) else {
            return value
        }
        guard jsonString.count > maxLen else { return value }
        return .object(["_truncated": .string(truncate(jsonString, maxLen))])
    }
}
