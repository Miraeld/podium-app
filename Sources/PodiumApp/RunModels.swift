#if os(macOS)
import Foundation

// MARK: - RunHandle

struct RunHandle: Identifiable, Decodable {
    let id: String
    let pid: Int?
    let mode: String
    let cwd: String
    let model: String?
    let permissionMode: String
    let effort: String?
    let prompt: String
    let status: String          // "spawning" | "running" | "completed" | "error" | "killed"
    let startedAt: Double       // epoch milliseconds
    let endedAt: Double?        // epoch ms or null
    let exitCode: Int?
    let sessionId: String?
    let envelopeCount: Int
    let stdoutTail: String?
    let stderrTail: String?
    let envelopes: [RunEnvelope]?

    var startedDate: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    var endedDate: Date? { endedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    var isActive: Bool {
        status == "spawning" || status == "running"
    }
}

// MARK: - RunListResponse

struct RunListResponse: Decodable {
    let items: [RunHandle]
    let maxConcurrent: Int?
    let activeCount: Int?
}

// MARK: - RunEnvelope

/// A normalized display segment derived from one parsed envelope line.
enum RunSegment {
    case system(String)
    case text(String)
    case toolUse(name: String, input: String)
    case toolResult(text: String, isError: Bool)
    case result(String)
}

struct RunEnvelope: Identifiable {
    let id: UUID
    let segments: [RunSegment]
}

extension RunEnvelope: Decodable {
    init(from decoder: Decoder) throws {
        self.id = UUID()

        let container = try decoder.container(keyedBy: TopKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""

        var segments: [RunSegment] = []

        switch type {
        case "system":
            let subtype = (try? container.decode(String.self, forKey: .subtype)) ?? ""
            let model = try? container.decode(String.self, forKey: .model)
            let cwd = try? container.decode(String.self, forKey: .cwd)
            var parts: [String] = ["[system:\(subtype)]"]
            if let m = model { parts.append("model: \(m)") }
            if let c = cwd { parts.append("cwd: \(c)") }
            segments.append(.system(parts.joined(separator: " · ")))

        case "assistant":
            if let message = try? container.decode(MessageWrapper.self, forKey: .message) {
                for block in message.content {
                    switch block {
                    case .text(let t):
                        if !t.isEmpty { segments.append(.text(t)) }
                    case .toolUse(let name, let input):
                        segments.append(.toolUse(name: name, input: input))
                    }
                }
            }

        case "user":
            if let message = try? container.decode(UserMessageWrapper.self, forKey: .message) {
                for block in message.content {
                    switch block {
                    case .toolResult(let text, let isError):
                        segments.append(.toolResult(text: text, isError: isError))
                    }
                }
            }

        case "result":
            let subtype = (try? container.decode(String.self, forKey: .subtype)) ?? ""
            let result = (try? container.decode(String.self, forKey: .result)) ?? ""
            let label = result.isEmpty ? "[\(subtype)]" : result
            segments.append(.result(label))

        default:
            break
        }

        self.segments = segments
    }

    private enum TopKeys: String, CodingKey {
        case type, subtype, message, model, cwd, result
    }

    // MARK: - Assistant message blocks

    private enum AssistantBlock {
        case text(String)
        case toolUse(name: String, input: String)
    }

    private struct MessageWrapper: Decodable {
        let content: [AssistantBlock]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: MessageKeys.self)
            var arr: [AssistantBlock] = []
            if var blocks = try? container.nestedUnkeyedContainer(forKey: .content) {
                while !blocks.isAtEnd {
                    if let block = try? blocks.decode(RawBlock.self) {
                        switch block.type {
                        case "text":
                            arr.append(.text(block.text ?? ""))
                        case "tool_use":
                            let inputStr = block.input.map { jsonString($0) } ?? "{}"
                            arr.append(.toolUse(name: block.name ?? "(unknown)", input: inputStr))
                        default:
                            break
                        }
                    } else {
                        // skip undecodable block
                        _ = try? blocks.decode(SkipValue.self)
                    }
                }
            }
            self.content = arr
        }

        private enum MessageKeys: String, CodingKey { case content }

        private struct RawBlock: Decodable {
            let type: String
            let text: String?
            let name: String?
            let input: [String: JSONValue]?
        }
    }

    // MARK: - User message blocks

    private enum UserBlock {
        case toolResult(text: String, isError: Bool)
    }

    private struct UserMessageWrapper: Decodable {
        let content: [UserBlock]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: MessageKeys.self)
            var arr: [UserBlock] = []
            if var blocks = try? container.nestedUnkeyedContainer(forKey: .content) {
                while !blocks.isAtEnd {
                    if let block = try? blocks.decode(RawUserBlock.self) {
                        if block.type == "tool_result" {
                            let isError = block.isError ?? false
                            let text: String
                            switch block.content {
                            case .string(let s): text = s
                            case .array(let parts): text = parts.joined(separator: "\n")
                            case .none: text = ""
                            }
                            arr.append(.toolResult(text: text, isError: isError))
                        }
                    } else {
                        _ = try? blocks.decode(SkipValue.self)
                    }
                }
            }
            self.content = arr
        }

        private enum MessageKeys: String, CodingKey { case content }

        private struct RawUserBlock: Decodable {
            let type: String
            let isError: Bool?
            let content: ToolResultContent?

            enum CodingKeys: String, CodingKey {
                case type, isError = "is_error", content
            }
        }
    }
}

// MARK: - ToolResultContent (string or array)

private enum ToolResultContent: Decodable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? c.decode([ContentPart].self) {
            self = .array(arr.compactMap { $0.text })
            return
        }
        self = .string("")
    }

    private struct ContentPart: Decodable {
        let type: String?
        let text: String?
    }
}

// MARK: - JSONValue (for arbitrary tool input objects)

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        self = .null
    }

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0 { return "\(Int(n))" }
            return "\(n)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[\(a.map(\.displayString).joined(separator: ", "))]"
        case .object(let o):
            let pairs = o.map { "\($0.key): \($0.value.displayString)" }.joined(separator: ", ")
            return "{\(pairs)}"
        }
    }
}

// MARK: - WebSocket message wrappers

struct RunStreamMessage: Decodable {
    let data: Payload
    struct Payload: Decodable {
        let id: String
        let envelope: RunEnvelope
    }
}

struct RunStatusMessage: Decodable {
    let data: Payload
    struct Payload: Decodable {
        let id: String
        let status: String
    }
}

/// Acknowledges a message sent to a conversation-mode run via
/// `POST /api/run/:id/message`. Matches `PodiumCore.RunInputAckPayload`
/// (camelCase wire format — same `/api/run` family exception as the rest
/// of this file).
struct RunInputAckMessage: Decodable {
    let data: Payload
    struct Payload: Decodable {
        let id: String
        let messageId: String
        let at: Double
    }
}

// MARK: - Helpers

private func jsonString(_ dict: [String: JSONValue]) -> String {
    let pairs = dict.map { "\($0.key): \($0.value.displayString)" }.joined(separator: ", ")
    return "{ \(pairs) }"
}

/// Used to skip undecoded values in unkeyed containers.
private struct SkipValue: Decodable {}

#endif
