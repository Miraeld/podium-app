// ServicesRunner — scaffold for the background services index.js starts
// after the HTTP server begins listening (index.js lines 211–398):
// one-time legacy import, the periodic stale-session/compaction sweep, the
// cc-config filesystem watcher, and the update scheduler.
//
// This task (P2.1) only wired the scaffold with no-op placeholders.
// P3.2 (this pass) fills in `legacyImport` and `periodicSweep` with real
// `BackgroundService`s (below), plus two more index.js/hooks.js timers that
// didn't have a placeholder slot yet — `watchdog` (API-error detection for
// stalled active sessions, hooks.js lines 1060–1176) and `stuckAgentCheck`
// (hooks.js lines 1180–1208). `ccWatcher`/`updateScheduler` remain P4.3's
// no-ops.
//
// Deviation from hooks.js's `stuckAgentAlertsSet`: rather than a shared
// mutable `Set<String>` cleared from inside `IngestEngine`'s event
// processing (which would require a new engine seam), `StuckAgentCheckService`
// dedups on a local `[sessionId: lastAlertedUpdatedAt]` snapshot — a session
// is re-alerted only once its `updated_at` has moved past the value it was
// last alerted at. Self-clearing (any new event changes `updated_at`), same
// externally-observable behavior, no IngestEngine coupling needed.

import Foundation
import PodiumCore

/// One pluggable background service. Conforming types should be cheap to
/// construct and do their real work inside `run()`, which is expected to
/// run for the lifetime of the process (a long-lived loop) or return quickly
/// after doing one-shot work (e.g. the legacy import).
public protocol BackgroundService: Sendable {
    /// Short identifier used in log lines (`"[services] <name> failed: ..."`).
    var name: String { get }

    /// Perform the service's work. For one-shot services this should return
    /// once done; for recurring services it should run until `Task` cancellation
    /// (checked via `Task.isCancelled` / `Task.checkCancellation()`) and return
    /// then. Throwing is treated as non-fatal — `ServicesRunner` logs and moves on.
    func run(context: ServerContext) async throws
}

/// No-op placeholder used for the four services this task scaffolds but does
/// not implement: legacyImport, periodicSweep, ccWatcher, updateScheduler.
/// Dependent tasks replace the placeholder with a real `BackgroundService`
/// conformance and swap it into `ServicesRunner.defaultServices`.
public struct NoOpService: BackgroundService {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public func run(context: ServerContext) async throws {
        // Intentionally empty — see the four `PodiumServer.Services.*` cases
        // below and the task references in STANDALONE_PLAN.md §5 (P2.3/P3.2/P4.3).
    }
}

/// Named placeholders for the four services index.js starts post-listen,
/// plus two more (`watchdog`, `stuckAgentCheck`) added by P3.2 for the two
/// additional hooks.js timers that had no scaffolded slot. Kept as static
/// factories (rather than bare `NoOpService(name:)` calls at every call
/// site) so a dependent task can `grep` for exactly one spot to replace per
/// service.
public enum PlaceholderServices {
    /// One-time legacy import from `~/.claude/projects/**`, guarded by the
    /// `.legacy-import.done` marker file — P3.2.
    public static var legacyImport: any BackgroundService { LegacyImportService() }

    /// Periodic stale-session sweep + compaction scan of active sessions —
    /// P3.2 (coordinates with P2.3's IngestEngine for the compaction-token
    /// seam via `TranscriptCache.shared`, same cache P3.1 wired into
    /// `HooksRouter`, no duplicate reads).
    public static var periodicSweep: any BackgroundService { StaleSessionSweepService() }

    /// API-error watchdog for active sessions whose transcript shows an
    /// error but never fired a Stop/Notification hook — P3.2 (hooks.js
    /// lines 1060–1176).
    public static var watchdog: any BackgroundService { WatchdogService() }

    /// `agent_stuck` broadcast for active sessions idle past the stuck
    /// threshold — P3.2 (hooks.js lines 1180–1208).
    public static var stuckAgentCheck: any BackgroundService { StuckAgentCheckService() }

    /// `~/.claude` config filesystem watcher -> `cc_config_changed` broadcast — P4.3.
    public static var ccWatcher: any BackgroundService { NoOpService(name: "ccWatcher") }

    /// Upstream version-check scheduler -> `update_status` broadcast — P4.3.
    public static var updateScheduler: any BackgroundService { NoOpService(name: "updateScheduler") }
}

/// Starts and supervises a fixed set of `BackgroundService`s as independent
/// tasks once the HTTP server is listening. Mirrors `startBackgroundServices()`
/// in index.js: fire-and-forget, a failure in one service is logged and never
/// brings down the server or the other services.
public actor ServicesRunner {
    public static func defaultServices() -> [any BackgroundService] {
        [
            PlaceholderServices.legacyImport,
            PlaceholderServices.periodicSweep,
            PlaceholderServices.watchdog,
            PlaceholderServices.stuckAgentCheck,
            PlaceholderServices.ccWatcher,
            PlaceholderServices.updateScheduler,
        ]
    }

    private var tasks: [Task<Void, Never>] = []

    public init() {}

    /// Start every service as its own detached-from-caller `Task`. Safe to
    /// call once; call `stopAll()` before calling `start` again.
    public func start(services: [any BackgroundService] = ServicesRunner.defaultServices(), context: ServerContext) {
        for service in services {
            let task = Task {
                do {
                    try await service.run(context: context)
                } catch {
                    FileHandle.standardError.write(
                        Data("[services] \(service.name) failed: \(error)\n".utf8)
                    )
                }
            }
            tasks.append(task)
        }
    }

    /// Cancel every running service task (called on graceful shutdown).
    public func stopAll() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }
}

// MARK: - legacyImport (index.js `autoImportLegacySessions`, one-shot)

/// One-time legacy-session backfill, guarded by a `.legacy-import.done`
/// marker file next to the database. Fire-and-forget and non-fatal by
/// design — a failure here must never block the server from serving live
/// traffic; the marker is written only after `importAllSessions` +
/// `backfillCompactions` both succeed, so a crash mid-import retries on the
/// next start instead of being skipped forever (matches index.js's
/// `.then(() => fs.writeFileSync(markerPath, ...))` placement exactly).
public struct LegacyImportService: BackgroundService {
    public let name = "legacyImport"
    public init() {}

    public func run(context: ServerContext) async throws {
        let markerURL = PodiumPaths.dataDir().appendingPathComponent(".legacy-import.done", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { return }

        try LegacyImporter.importAllSessions(store: context.store)
        try LegacyImporter.backfillCompactions(store: context.store)

        try? "\(PodiumDate.now())\n".write(to: markerURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - periodicSweep (index.js's `setInterval`, lines 300–398)

/// Periodic maintenance sweep: (1) abandons sessions that slipped through
/// event-based detection (`DASHBOARD_STALE_MINUTES`, default 180) and
/// completes their non-terminal agents in a single batch update; (2)
/// re-scans every ACTIVE session's transcript for new compaction markers
/// (`/compact` fires no hook, so this periodic scan is the only path that
/// picks those up without waiting for the next real hook event).
///
/// Sweep interval: 1/4 of the stale threshold, clamped to [60s, 5 min] —
/// same formula as index.js.
public struct StaleSessionSweepService: BackgroundService {
    public let name = "periodicSweep"
    public init() {}

    public func run(context: ServerContext) async throws {
        let staleMinutes = Self.staleMinutes()
        let intervalNanoseconds = Self.sweepIntervalNanoseconds(staleMinutes: staleMinutes)

        while !Task.isCancelled {
            do {
                try await sweepStaleSessions(context: context, staleMinutes: staleMinutes)
                try await scanActiveSessionsForCompactions(context: context)
            } catch {
                FileHandle.standardError.write(Data("[services] periodicSweep tick failed: \(error)\n".utf8))
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    static func staleMinutes() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["DASHBOARD_STALE_MINUTES"], let parsed = Int(raw), parsed > 0 else {
            return 180
        }
        return parsed
    }

    static func sweepIntervalNanoseconds(staleMinutes: Int) -> UInt64 {
        let quarterMs = Double(staleMinutes) * 60_000 / 4
        let clampedMs = min(300_000, max(60_000, quarterMs))
        return UInt64(clampedMs) * 1_000_000
    }

    /// Step 1: abandon stale sessions + batch-complete their agents.
    func sweepStaleSessions(context: ServerContext, staleMinutes: Int) async throws {
        let store = context.store
        let staleIds = try store.findStaleSessions(excludingId: "__periodic__", minutes: staleMinutes)
        guard !staleIds.isEmpty else { return }

        let now = PodiumDate.now()
        try store.completeNonTerminalAgents(sessionIds: staleIds, endedAt: now, updatedAt: now)

        for sessionId in staleIds {
            try store.updateSession(id: sessionId, status: .abandoned, endedAt: now)
            if let session = try store.getSession(id: sessionId) {
                await context.broadcaster.broadcast(type: "session_updated", data: session)
                if let transcriptPath = session.transcriptPath {
                    TranscriptCache.shared.invalidate(path: transcriptPath)
                }
            }
        }

        // Broadcast every now-completed agent per stale session (mirrors
        // index.js broadcasting every agent whose status reads 'completed'
        // post-sweep, not just the ones this batch actually flipped).
        for sessionId in staleIds {
            let agents = try store.listAgentsBySession(sessionId: sessionId)
            for agent in agents where agent.status.knownValue == .completed {
                await context.broadcaster.broadcast(type: "agent_updated", data: agent)
            }
        }
    }

    /// Step 2: scan every active session's transcript for new compaction
    /// markers via the SAME `TranscriptCache` the hook-ingestion path uses
    /// (P3.1's entry point — no duplicate reads).
    func scanActiveSessionsForCompactions(context: ServerContext) async throws {
        let store = context.store
        let activeSessions = try store.activeSessionTranscriptPaths()
        for row in activeSessions {
            let compactions = TranscriptCache.shared.extractCompactions(path: row.transcriptPath)
            guard !compactions.isEmpty else { continue }
            let mainAgentId = "\(row.sessionId)-main"
            let created: Int
            do {
                created = try LegacyImporter.importCompactions(store: store, sessionId: row.sessionId, mainAgentId: mainAgentId, compactions: compactions)
            } catch {
                FileHandle.standardError.write(Data("[SWEEP] Compaction scan failed for session \(row.sessionId): \(error)\n".utf8))
                continue
            }
            guard created > 0, let uuid = compactions.last?.uuid else { continue }
            let compactAgentId = "\(row.sessionId)-compact-\(uuid)"
            if let agent = try store.getAgent(id: compactAgentId) {
                await context.broadcaster.broadcast(type: "agent_created", data: agent)
            }
        }
    }
}

// MARK: - watchdog (hooks.js lines 1060–1176)

/// Detects API errors (401, rate limits, invalid_request, …) in active
/// sessions that never fired a Stop/Notification hook — the Claude CLI
/// leaves the session sitting there with the error only visible in the
/// transcript. Runs every 15s against sessions idle for >10s.
public struct WatchdogService: BackgroundService {
    public let name = "watchdog"
    public init() {}

    private static let intervalNanoseconds: UInt64 = 15_000_000_000
    private static let staleThresholdSeconds = 10

    public func run(context: ServerContext) async throws {
        while !Task.isCancelled {
            do {
                try await tick(context: context)
            } catch {
                FileHandle.standardError.write(Data("[services] watchdog tick failed: \(error)\n".utf8))
            }
            try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
        }
    }

    func tick(context: ServerContext) async throws {
        let store = context.store
        let cutoff = PodiumDate.format(Date().addingTimeInterval(-Double(Self.staleThresholdSeconds)))
        let candidates = try store.watchdogCandidates(cutoff: cutoff)

        for candidate in candidates {
            guard let transcriptPath = resolveTranscriptPath(candidate) else { continue }
            guard let result = TranscriptCache.shared.extract(path: transcriptPath), !result.errors.isEmpty else { continue }

            let existingCount = try store.apiErrorEventCount(sessionId: candidate.id)
            guard existingCount < result.errors.count else { continue }

            let existingSummaries = try store.apiErrorSummaries(sessionId: candidate.id)
            let mainAgent = try store.listAgentsBySession(sessionId: candidate.id).first { $0.type.knownValue == .main }

            let mainAgentId: String? = mainAgent?.id
            let mainAgentIdJSON: JSONValue = mainAgentId.map(JSONValue.string) ?? .null

            var recordedNew = false
            for apiError in result.errors {
                let summary = "\(apiError.type): \(apiError.message)"
                guard !existingSummaries.contains(summary) else { continue }
                let dataJSON = (try? PodiumJSON.encoder.encode(apiError.raw)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try store.insertEvent(sessionId: candidate.id, agentId: mainAgentId, eventType: "APIError", toolName: nil, summary: summary, data: dataJSON)
                await context.broadcaster.broadcast(type: "new_event", data: JSONValue.object([
                    "session_id": .string(candidate.id), "agent_id": mainAgentIdJSON,
                    "event_type": .string("APIError"), "tool_name": .null, "summary": .string(summary),
                    "created_at": .string(apiError.timestamp ?? PodiumDate.now()),
                ]))
                recordedNew = true
            }

            guard recordedNew else { continue }

            if let session = try store.getSession(id: candidate.id), session.status.knownValue != .error {
                try store.updateSession(id: candidate.id, status: .error)
            }
            if let updated = try store.getSession(id: candidate.id) {
                await context.broadcaster.broadcast(type: "session_updated", data: updated)
            }
            if let mainAgent, mainAgent.status.knownValue != .completed, mainAgent.status.knownValue != .error {
                try store.updateAgent(id: mainAgent.id, status: .error)
                try store.clearAgentAwaitingInput(id: mainAgent.id)
                if let updatedAgent = try store.getAgent(id: mainAgent.id) {
                    await context.broadcaster.broadcast(type: "agent_updated", data: updatedAgent)
                }
            }
        }
    }

    /// Recovers the transcript path from the most recent lifecycle event's
    /// `data.transcript_path`, falling back to Claude Code's standard path
    /// layout derived from `cwd` — port of hooks.js's `watchdogCheck` path
    /// resolution (lines 1083–1091).
    private func resolveTranscriptPath(_ candidate: PodiumStore.WatchdogCandidate) -> String? {
        if let lastData = candidate.lastEventData,
           let jsonData = lastData.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: jsonData),
           let transcriptPath = decoded.nonEmptyString("transcript_path") {
            return transcriptPath
        }
        return ClaudeHome.transcriptPath(sessionId: candidate.id, cwd: candidate.cwd)
    }
}

// MARK: - stuckAgentCheck (hooks.js lines 1180–1208)

/// Broadcasts `agent_stuck` once per "staleness window" for active sessions
/// whose `updated_at` hasn't moved in >5 minutes. See the file header for
/// the dedup-strategy deviation from hooks.js's `stuckAgentAlertsSet`.
public struct StuckAgentCheckService: BackgroundService {
    public let name = "stuckAgentCheck"
    public init() {}

    private static let intervalNanoseconds: UInt64 = 60_000_000_000
    private static let thresholdMinutes = 5

    public func run(context: ServerContext) async throws {
        var alertedAt: [String: String] = [:]
        while !Task.isCancelled {
            do {
                try await tick(context: context, alertedAt: &alertedAt)
            } catch {
                FileHandle.standardError.write(Data("[services] stuckAgentCheck tick failed: \(error)\n".utf8))
            }
            try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
        }
    }

    func tick(context: ServerContext, alertedAt: inout [String: String]) async throws {
        let cutoff = PodiumDate.format(Date().addingTimeInterval(-Double(Self.thresholdMinutes * 60)))
        let candidates = try context.store.stuckSessionCandidates(cutoff: cutoff)
        let candidateIds = Set(candidates.map(\.id))

        // Drop alert memory for sessions no longer in the stuck set (either
        // they got a new event — updated_at moved past the cutoff — or
        // they're no longer active).
        alertedAt = alertedAt.filter { candidateIds.contains($0.key) }

        for candidate in candidates {
            guard alertedAt[candidate.id] != candidate.updatedAt else { continue }
            alertedAt[candidate.id] = candidate.updatedAt

            guard let updatedDate = PodiumDate.parse(candidate.updatedAt) else { continue }
            let minutesStuck = Int(Date().timeIntervalSince(updatedDate) / 60)
            await context.broadcaster.broadcast(type: "agent_stuck", data: JSONValue.object([
                "session_id": .string(candidate.id), "minutes_stuck": .number(Double(minutesStuck)),
            ]))
        }
    }
}
