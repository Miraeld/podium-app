import Foundation

/// One content block within a transcript message — `text`, `tool_use`,
/// `tool_result`, or `thinking` (dashboard/server/lib/transcript-cache.js).
/// Matches client/src/lib/types.ts `TranscriptContent`.
public struct TranscriptContent: Codable, Equatable, Sendable {
    public var type: String
    public var text: String?
    public var name: String?
    public var id: String?
    /// A tool_use's input JSON object. When the server truncates a huge
    /// input for payload size, this decodes as `{"_truncated": "<preview>"}`
    /// instead — surfaced via `truncatedPreview` below.
    public var input: JSONValue?
    public var output: String?
    public var isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, name, id, input, output
        case isError = "is_error"
    }

    public init(
        type: String,
        text: String? = nil,
        name: String? = nil,
        id: String? = nil,
        input: JSONValue? = nil,
        output: String? = nil,
        isError: Bool? = nil
    ) {
        self.type = type
        self.text = text
        self.name = name
        self.id = id
        self.input = input
        self.output = output
        self.isError = isError
    }

    /// If `input` is a truncation marker (`{"_truncated": "..."}`, written by
    /// `lib/transcript-cache.js`'s `truncate` helper for oversized tool
    /// inputs), returns the preview string; `nil` otherwise.
    public var truncatedPreview: String? {
        guard case .object(let dict)? = input else { return nil }
        guard case .string(let preview)? = dict["_truncated"] else { return nil }
        return preview
    }
}

/// A single JSONL entry from a Claude Code transcript — a `user` or
/// `assistant` turn. Matches client/src/lib/types.ts `TranscriptMessage`.
public struct TranscriptMessage: Codable, Equatable, Sendable {
    public var type: String
    public var timestamp: String?
    public var content: [TranscriptContent]
    public var model: String?
    public var usage: Usage?

    public init(
        type: String,
        timestamp: String? = nil,
        content: [TranscriptContent],
        model: String? = nil,
        usage: Usage? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.content = content
        self.model = model
        self.usage = usage
    }

    public var timestampDate: Date? { timestamp.flatMap(PodiumDate.parse) }

    /// Per-message token usage, as recorded directly on the transcript
    /// entry by Claude Code. Field names are the raw Anthropic Messages API
    /// usage keys (`cache_read_input_tokens`, `cache_creation_input_tokens`)
    /// — NOT the DB's `cache_read_tokens`/`cache_write_tokens` naming.
    ///
    /// IMPORTANT: `PodiumJSON.decoder`/`.encoder` already apply
    /// `.convertFromSnakeCase`/`.convertToSnakeCase` globally, which convert
    /// the wire key to camelCase *before* matching against `CodingKeys` raw
    /// values — so `CodingKeys` here must use the camelCase Swift property
    /// names (the implicit default), NOT the original snake_case wire
    /// strings, or decoding silently fails to find every key. Explicit
    /// snake_case `CodingKeys` are only correct for types decoded with a
    /// plain (non-converting) `JSONDecoder`.
    public struct Usage: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadInputTokens: Int?
        public var cacheCreationInputTokens: Int?

        public init(
            inputTokens: Int,
            outputTokens: Int,
            cacheReadInputTokens: Int? = nil,
            cacheCreationInputTokens: Int? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
        }
    }
}

/// `GET /api/sessions/:id/transcript` response — a page of parsed messages
/// with cursor pagination. Matches client/src/lib/types.ts `TranscriptResult`.
public struct TranscriptResult: Codable, Equatable, Sendable {
    public var messages: [TranscriptMessage]
    public var total: Int
    public var hasMore: Bool
    public var lastLine: Int
    public var firstLine: Int

    public init(messages: [TranscriptMessage], total: Int, hasMore: Bool, lastLine: Int, firstLine: Int) {
        self.messages = messages
        self.total = total
        self.hasMore = hasMore
        self.lastLine = lastLine
        self.firstLine = firstLine
    }
}

/// One entry in `GET /api/sessions/:id/transcripts` — a JSONL file
/// associated with the session (main transcript, a subagent sidechain, or a
/// compaction snapshot). Matches client/src/lib/types.ts `TranscriptInfo`.
public struct TranscriptInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var subagentType: String?
    public var hasTranscript: Bool
    public var dbAgentId: String?

    public init(
        id: String,
        name: String,
        type: String,
        subagentType: String? = nil,
        hasTranscript: Bool,
        dbAgentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.subagentType = subagentType
        self.hasTranscript = hasTranscript
        self.dbAgentId = dbAgentId
    }
}

/// `GET /api/sessions/:id/transcripts` response envelope.
public struct TranscriptListResult: Codable, Equatable, Sendable {
    public var transcripts: [TranscriptInfo]

    public init(transcripts: [TranscriptInfo]) {
        self.transcripts = transcripts
    }
}
