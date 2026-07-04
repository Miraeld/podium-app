// DiagnosticsResponse.swift — wire shape for `GET /api/diagnostics` (P4.4).
//
// No Node reference exists for this endpoint (it's new to the Swift app),
// so field names are chosen for consistency with the rest of the snake_case
// API rather than ported from anywhere. Reuses `ServerRuntimeInfo` (P3.3)
// for process/platform/memory rather than duplicating it — see
// `SettingsInfoResponse.ServerRuntimeInfo` for the sibling shape already
// exposed via `GET /api/settings/info`.

import Foundation

public struct DiagnosticsResponse: Codable, Equatable, Sendable {
    public var server: ServerInfo
    public var hooks: HookHealth
    public var log: [LogEntry]

    public init(server: ServerInfo, hooks: HookHealth, log: [LogEntry]) {
        self.server = server
        self.hooks = hooks
        self.log = log
    }

    /// Process/platform/memory snapshot — deliberately the same shape as
    /// `SettingsInfoResponse.ServerRuntimeInfo` (P3.3) so a client already
    /// rendering that panel can reuse the same fields here; kept as its own
    /// type (not shared directly) since the two endpoints are allowed to
    /// diverge independently without breaking each other.
    public struct ServerInfo: Codable, Equatable, Sendable {
        public var uptimeSeconds: Double
        public var platform: String
        public var arch: String
        public var cpuCount: Int
        public var loadAverages: [Double]
        public var residentMemoryBytes: Double
        public var totalMemoryBytes: Double

        public init(
            uptimeSeconds: Double,
            platform: String,
            arch: String,
            cpuCount: Int,
            loadAverages: [Double],
            residentMemoryBytes: Double,
            totalMemoryBytes: Double
        ) {
            self.uptimeSeconds = uptimeSeconds
            self.platform = platform
            self.arch = arch
            self.cpuCount = cpuCount
            self.loadAverages = loadAverages
            self.residentMemoryBytes = residentMemoryBytes
            self.totalMemoryBytes = totalMemoryBytes
        }
    }

    /// Hook ingestion pipeline health — the actual gap this task fills.
    /// `status` is a simple derived traffic light so a native/web client
    /// doesn't need to reimplement the "is this stale?" threshold logic:
    /// - `"ok"`: at least one event processed, most recent one within
    ///   `staleAfterSeconds`.
    /// - `"stale"`: at least one event ever processed, but the most recent
    ///   one is older than `staleAfterSeconds` (pipeline may have gone
    ///   quiet — could be normal if Claude Code just isn't running).
    /// - `"unknown"`: no hook event has been processed since this server
    ///   process started (fresh install, or hooks never fired yet).
    public struct HookHealth: Codable, Equatable, Sendable {
        public var status: String
        public var lastEventAt: String?
        public var lastLatencySeconds: Double?
        public var averageLatencySeconds: Double?
        public var totalEventsProcessed: Int
        public var totalEventsFailed: Int

        public init(
            status: String,
            lastEventAt: String?,
            lastLatencySeconds: Double?,
            averageLatencySeconds: Double?,
            totalEventsProcessed: Int,
            totalEventsFailed: Int
        ) {
            self.status = status
            self.lastEventAt = lastEventAt
            self.lastLatencySeconds = lastLatencySeconds
            self.averageLatencySeconds = averageLatencySeconds
            self.totalEventsProcessed = totalEventsProcessed
            self.totalEventsFailed = totalEventsFailed
        }

        /// Threshold (seconds) past which a last-known-good hook event is
        /// considered stale rather than healthy. 15 minutes: long enough to
        /// tolerate normal gaps between Claude Code sessions, short enough
        /// to flag a genuinely broken pipeline within one sitting.
        public static let staleAfterSeconds: Double = 15 * 60

        /// Derives `status` from a `lastEventAt` wire timestamp and "now".
        public static func deriveStatus(lastEventAt: String?, now: Date = Date()) -> String {
            guard let lastEventAt, let parsed = PodiumDate.parse(lastEventAt) else { return "unknown" }
            return now.timeIntervalSince(parsed) <= staleAfterSeconds ? "ok" : "stale"
        }
    }
}
