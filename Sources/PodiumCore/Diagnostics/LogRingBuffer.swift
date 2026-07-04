// LogRingBuffer.swift — bounded in-memory circular buffer of recent
// diagnostic log lines, backing the "rolling log of recent activity" part
// of P4.4's `GET /api/diagnostics`.
//
// Deliberately NOT a persistent log store (plan says "a simple actor-backed
// circular buffer is fine, a few hundred entries is plenty, don't build a
// persistent log store"): entries live only in process memory and are lost
// on restart, same lifetime as `ServerRuntimeInfo.processStartDate`.

import Foundation

/// One recorded line of diagnostic activity — a hook event, an ingestion
/// outcome, or any other lightweight note worth surfacing in the
/// diagnostics panel's "recent activity" list.
public struct LogEntry: Codable, Equatable, Sendable {
    /// Wire-format timestamp (`PodiumDate.now()` shape) of when this entry
    /// was recorded.
    public let timestamp: String
    /// Coarse severity for UI color-coding — kept as a plain string (not an
    /// enum) so the ring buffer never fails to record a line just because
    /// some future caller invents a new level.
    public let level: String
    /// Free-text message, e.g. "hook event processed: PostToolUse (session
    /// abc123, 4.2ms)".
    public let message: String

    public init(timestamp: String = PodiumDate.now(), level: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// Thread-safe bounded circular buffer of `LogEntry` values. Actor-isolated
/// so concurrent recorders (hook ingestion, future instrumentation points)
/// can append without a lock, and `snapshot()` always returns a consistent
/// copy.
public actor LogRingBuffer {
    private var entries: [LogEntry] = []
    private let capacity: Int

    /// "A few hundred entries is plenty" per the task brief.
    public static let defaultCapacity = 300

    public init(capacity: Int = LogRingBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Appends a new entry, evicting the oldest one once `capacity` is
    /// exceeded (FIFO — oldest entries drop first).
    public func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Convenience overload matching `DiagnosticsRecorder`'s call sites.
    public func append(level: String, message: String) {
        append(LogEntry(level: level, message: message))
    }

    /// Most recent entries first (newest-first — the natural order for a
    /// "recent activity" list), optionally capped to `limit`.
    ///
    /// Defensive guard: `Sequence.prefix(_:)` traps fatally on a negative
    /// count. Callers are expected to clamp their own input (see
    /// `DiagnosticsRouter`), but this is a public actor method reachable
    /// from any future call site, so a non-positive `limit` degrades to "no
    /// entries" here too rather than crashing the process.
    public func snapshot(limit: Int? = nil) -> [LogEntry] {
        let newestFirst = entries.reversed()
        guard let limit else { return Array(newestFirst) }
        guard limit > 0 else { return [] }
        return Array(newestFirst.prefix(limit))
    }

    public func clear() {
        entries.removeAll()
    }
}
