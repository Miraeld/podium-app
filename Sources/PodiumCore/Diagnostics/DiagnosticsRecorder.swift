// DiagnosticsRecorder.swift — P4.4: the actual gap `ServerRuntimeInfo`
// (P3.3) doesn't fill. Tracks hook ingestion health (last-event timestamp +
// a latency sample) and feeds `LogRingBuffer` with a rolling log of recent
// hook activity, so `GET /api/diagnostics` can answer "is the hook→server
// pipeline actually working?" at a glance.
//
// Instrumentation point: `HooksRouterMount` (Routes/HooksRouter.swift)
// calls `DiagnosticsRecorder.shared.recordHookEvent(...)` right after
// `IngestEngine.process(...)` returns — i.e. AFTER the engine's internal
// transaction has committed and broadcasts have been computed, never
// reaching into `IngestEngine`'s own COMMIT/notifier-ordering logic (that
// file is explicitly off-limits this task; see IngestEngine.swift's own
// doc comment on why notifier events are queued until COMMIT succeeds).
// This keeps instrumentation purely additive: a single call at the HTTP
// router layer, no changes to ingestion semantics.
//
// Latency definition (documented per the task brief's "use your judgment"
// clause): `recordHookEvent` is called synchronously right after
// `engine.process` returns, so the elapsed wall-clock time across that call
// **is** the observable "hook processing latency" — the time the ingestion
// engine spent parsing the payload, running its DB transaction, and
// preparing broadcasts, from the router's point of view. This is a truer
// signal than "time since last event was received" (which would only
// detect a dead pipeline, not a slow one) and doesn't require touching
// IngestEngine's internals: the router already brackets the call with
// `Date()` on either side.
public actor DiagnosticsRecorder {
    public static let shared = DiagnosticsRecorder()

    public let log: LogRingBuffer

    /// Timestamp (wire format) of the most recent successfully-processed
    /// hook event, or `nil` if none have been recorded yet this process.
    public private(set) var lastEventAt: String?
    /// Latency (seconds) of the most recently processed hook event —
    /// wall-clock time the router spent inside `IngestEngine.process`.
    public private(set) var lastLatencySeconds: Double?
    /// Rolling average latency over the last `latencyWindowSize` samples —
    /// smooths out one-off outliers (e.g. a cold-start compile-cache miss)
    /// for a more representative "is this healthy" signal than the single
    /// latest sample.
    public private(set) var averageLatencySeconds: Double?
    /// Total hook events processed since process start (monotonic counter,
    /// resets on restart — same lifetime as `ServerRuntimeInfo`).
    public private(set) var totalEventsProcessed: Int = 0
    /// Total hook events that failed to parse/process (router-level
    /// rejections — missing session_id, bad JSON, etc.). Tracked
    /// separately from `totalEventsProcessed` so the panel can surface an
    /// error rate.
    public private(set) var totalEventsFailed: Int = 0

    private var recentLatencies: [Double] = []
    private let latencyWindowSize = 20

    public init(log: LogRingBuffer = LogRingBuffer()) {
        self.log = log
    }

    /// Records one successfully-processed hook event. Called from
    /// `HooksRouterMount` after `IngestEngine.process` returns with at
    /// least one broadcast.
    public func recordHookEvent(hookType: String, sessionId: String, latencySeconds: Double) {
        let now = PodiumDate.now()
        lastEventAt = now
        lastLatencySeconds = latencySeconds
        totalEventsProcessed += 1

        recentLatencies.append(latencySeconds)
        if recentLatencies.count > latencyWindowSize {
            recentLatencies.removeFirst(recentLatencies.count - latencyWindowSize)
        }
        averageLatencySeconds = recentLatencies.reduce(0, +) / Double(recentLatencies.count)

        let ms = String(format: "%.2fms", latencySeconds * 1000)
        Task { await log.append(level: "info", message: "hook event processed: \(hookType) (session \(sessionId), \(ms))") }
    }

    /// Records a hook payload the router rejected before it ever reached
    /// the ingestion engine (bad JSON, missing `hook_type`/`data`, or the
    /// engine no-op'd on a missing `session_id`). Kept distinct from
    /// `recordHookEvent` so a client's malformed request doesn't masquerade
    /// as healthy ingestion.
    public func recordHookFailure(reason: String) {
        totalEventsFailed += 1
        Task { await log.append(level: "error", message: "hook event rejected: \(reason)") }
    }

    /// Snapshot used by `DiagnosticsRouter` to build the HTTP response.
    public struct HookHealth: Sendable {
        public let lastEventAt: String?
        public let lastLatencySeconds: Double?
        public let averageLatencySeconds: Double?
        public let totalEventsProcessed: Int
        public let totalEventsFailed: Int
    }

    public func hookHealth() -> HookHealth {
        HookHealth(
            lastEventAt: lastEventAt,
            lastLatencySeconds: lastLatencySeconds,
            averageLatencySeconds: averageLatencySeconds,
            totalEventsProcessed: totalEventsProcessed,
            totalEventsFailed: totalEventsFailed
        )
    }

    /// Recent log entries, newest first.
    public func recentLog(limit: Int = 100) async -> [LogEntry] {
        await log.snapshot(limit: limit)
    }

    /// Test-only reset so `DiagnosticsRecorder.shared`'s process-lifetime
    /// state doesn't leak between XCTest cases that share the singleton.
    public func resetForTesting() async {
        lastEventAt = nil
        lastLatencySeconds = nil
        averageLatencySeconds = nil
        totalEventsProcessed = 0
        totalEventsFailed = 0
        recentLatencies.removeAll()
        await log.clear()
    }
}
