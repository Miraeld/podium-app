// IngestSeams.swift — dependency-injection seams IngestEngine consumes but
// does not implement. Both ship a no-op default here so P2.3 is fully
// functional (and testable) standalone; later tasks provide real
// implementations without touching IngestEngine's call sites.

import Foundation

// MARK: - Notifier (P4.2 seam)

/// The kinds of push notifications hooks.js's ingestion path can trigger.
/// hooks.js itself doesn't call a push-notification helper directly today
/// (that lives in the Node server's `lib/push.js`, wired from session-end /
/// error transitions) — this seam exists so P4.2 can hang its VAPID web-push
/// implementation off the same state-machine transitions the plan calls out
/// (session end, session error, agent_stuck, cost_spike) without IngestEngine
/// depending on swift-crypto or the push subscriptions table.
public enum NotifierEvent: Sendable, Equatable {
    case sessionCompleted(sessionId: String, sessionName: String?)
    case sessionError(sessionId: String, sessionName: String?)
    case agentStuck(sessionId: String, minutesStuck: Int)
    case costSpike(sessionId: String, cost: Double)
}

/// Injected push-notification trigger point. `IngestEngine` calls this on
/// every transition that Node's push layer cares about; the no-op default
/// makes P2.3 fully functional without P4.2. Fire-and-forget by contract —
/// implementations must not block or throw into the ingest path.
public protocol Notifier: Sendable {
    func notify(_ event: NotifierEvent) async
}

/// No-op `Notifier` — the default until P4.2 lands a real implementation.
public struct NoOpNotifier: Notifier {
    public init() {}
    public func notify(_ event: NotifierEvent) async {}
}

// MARK: - TranscriptTokenSource (P3.1 seam)

/// One model's token counters as extracted from a transcript JSONL, in the
/// shape `IngestEngine` feeds straight into `PodiumStore.replaceTokenUsage`.
/// Mirrors transcript-cache.js's `tokensByModel[model]` entries
/// (`{ input, output, cacheRead, cacheWrite }`).
public struct TranscriptTokens: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// One compaction marker found in a transcript (transcript-cache.js
/// `compaction.entries[]`: `{ uuid, timestamp }`).
public struct TranscriptCompactionEntry: Sendable, Equatable {
    public var uuid: String?
    public var timestamp: String?

    public init(uuid: String?, timestamp: String?) {
        self.uuid = uuid
        self.timestamp = timestamp
    }
}

/// One API error found in a transcript (transcript-cache.js `errors[]`).
public struct TranscriptAPIError: Sendable, Equatable {
    public var type: String
    public var message: String
    public var timestamp: String?
    /// Raw JSON blob stored verbatim in `events.data` (parity with hooks.js
    /// `JSON.stringify(apiErr)`).
    public var raw: JSONValue

    public init(type: String, message: String, timestamp: String?, raw: JSONValue) {
        self.type = type
        self.message = message
        self.timestamp = timestamp
        self.raw = raw
    }
}

/// One turn-duration system message found in a transcript
/// (transcript-cache.js `turnDurations[]`).
public struct TranscriptTurnDuration: Sendable, Equatable {
    public var timestamp: String?
    public var durationMs: Int

    public init(timestamp: String?, durationMs: Int) {
        self.timestamp = timestamp
        self.durationMs = durationMs
    }
}

/// Everything `IngestEngine` extracts from a transcript path on each hook
/// event that carries one — the Swift analogue of transcript-cache.js's
/// `extract()` return shape (`{ tokensByModel, compaction, errors,
/// turnDurations, thinkingBlockCount, usageExtras, latestModel }`).
/// `usageExtras`/thinking-block metadata are intentionally omitted from this
/// seam (P3.1's concern) — IngestEngine's session-metadata enrichment step is
/// a documented deviation until P3.1 lands (see IngestEngine doc comment).
public struct TranscriptExtractResult: Sendable, Equatable {
    public var tokensByModel: [String: TranscriptTokens]
    public var compactionEntries: [TranscriptCompactionEntry]
    public var errors: [TranscriptAPIError]
    public var turnDurations: [TranscriptTurnDuration]
    public var latestModel: String?

    public init(
        tokensByModel: [String: TranscriptTokens] = [:],
        compactionEntries: [TranscriptCompactionEntry] = [],
        errors: [TranscriptAPIError] = [],
        turnDurations: [TranscriptTurnDuration] = [],
        latestModel: String? = nil
    ) {
        self.tokensByModel = tokensByModel
        self.compactionEntries = compactionEntries
        self.errors = errors
        self.turnDurations = turnDurations
        self.latestModel = latestModel
    }

    public var isEmpty: Bool {
        tokensByModel.isEmpty && compactionEntries.isEmpty && errors.isEmpty
            && turnDurations.isEmpty && latestModel == nil
    }
}

/// Injected transcript-token source. `IngestEngine` calls `extract(path:)` on
/// every hook event whose payload carries a `transcript_path`, exactly where
/// hooks.js calls `transcriptCache.extract(data.transcript_path)`. The no-op
/// default (`nil` result, i.e. "nothing extracted") makes P2.3 fully
/// functional and testable before P3.1's real JSONL parser lands — every
/// engine test that needs token/compaction behavior injects a
/// `StubTranscriptTokenSource` (see IngestEngineTests) rather than touching
/// disk.
public protocol TranscriptTokenSource: Sendable {
    /// Returns the extracted result for `path`, or `nil` if the file is
    /// missing/unreadable/empty — mirrors transcript-cache.js's `extract()`
    /// returning `null`.
    func extract(path: String) -> TranscriptExtractResult?

    /// Evicts any cached state for `path` — called on SessionEnd, mirroring
    /// `transcriptCache.invalidate(data.transcript_path)`.
    func invalidate(path: String)
}

/// No-op `TranscriptTokenSource` — the default until P3.1 lands a real JSONL
/// parser with mtime/size-based caching.
public struct NoOpTranscriptTokenSource: TranscriptTokenSource {
    public init() {}
    public func extract(path: String) -> TranscriptExtractResult? { nil }
    public func invalidate(path: String) {}
}
