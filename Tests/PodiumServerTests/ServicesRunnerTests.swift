import XCTest
import PodiumCore
@testable import PodiumServer

/// Coverage for the P3.2 background services: the periodic stale-session
/// sweep (abandon + broadcast), the compaction scan, the API-error
/// watchdog, and the stuck-agent check. Drives a single tick of each
/// service directly against a seeded `PodiumStore` rather than waiting on
/// the real interval loop.
final class ServicesRunnerTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var broadcaster: Broadcaster!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("podium-services-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
        broadcaster = Broadcaster()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func context() -> ServerContext {
        ServerContext(store: store, broadcaster: broadcaster, runSpawner: RunSpawner(store: store, broadcaster: broadcaster))
    }

    /// Seeds an old, stale-looking `updated_at` directly (bypassing the
    /// `strftime('now')` default every `PodiumStore` write helper uses) so
    /// the sweep's staleness window actually triggers in a fast unit test.
    private func backdateSessionUpdatedAt(id: String, minutesAgo: Int) throws {
        try store.db.run("UPDATE sessions SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-\(minutesAgo) minutes') WHERE id = ?", [.text(id)])
    }

    // MARK: - StaleSessionSweepService

    func testSweepAbandonsStaleSessionAndCompletesItsAgents() async throws {
        try store.insertSession(id: "s1", name: "Stale", status: .active, cwd: "/tmp", model: "claude-sonnet-4-5", metadata: nil)
        try store.insertAgent(id: "s1-main", sessionId: "s1", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try backdateSessionUpdatedAt(id: "s1", minutesAgo: 200) // past the 180-minute default threshold

        try store.insertSession(id: "s2", name: "Fresh", status: .active, cwd: "/tmp", model: "claude-sonnet-4-5", metadata: nil)
        try store.insertAgent(id: "s2-main", sessionId: "s2", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)

        let service = StaleSessionSweepService()
        try await service.sweepStaleSessions(context: context(), staleMinutes: 180)

        let stale = try XCTUnwrap(store.getSession(id: "s1"))
        XCTAssertEqual(stale.status.knownValue, .abandoned)
        let staleAgent = try XCTUnwrap(store.getAgent(id: "s1-main"))
        XCTAssertEqual(staleAgent.status.knownValue, .completed)
        XCTAssertNotNil(staleAgent.endedAt)

        // The fresh session must be untouched.
        let fresh = try XCTUnwrap(store.getSession(id: "s2"))
        XCTAssertEqual(fresh.status.knownValue, .active)
        let freshAgent = try XCTUnwrap(store.getAgent(id: "s2-main"))
        XCTAssertEqual(freshAgent.status.knownValue, .working)
    }

    func testSweepScansActiveSessionsForNewCompactions() async throws {
        let transcriptPath = tempDir.appendingPathComponent("session.jsonl")
        try #"{"timestamp":"2024-01-01T00:00:00.000Z","isCompactSummary":true,"uuid":"scan-uuid-1"}"#.write(to: transcriptPath, atomically: true, encoding: .utf8)

        try store.insertSession(id: "s3", name: "Active", status: .active, cwd: "/tmp", model: "claude-sonnet-4-5", metadata: nil)
        try store.setSessionTranscriptPath(id: "s3", transcriptPath: transcriptPath.path)
        try store.insertAgent(id: "s3-main", sessionId: "s3", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)

        let service = StaleSessionSweepService()
        try await service.scanActiveSessionsForCompactions(context: context())

        let compactAgent = try XCTUnwrap(store.getAgent(id: "s3-compact-scan-uuid-1"))
        XCTAssertEqual(compactAgent.subagentType, "compaction")
        let events = try store.listEventsBySession(sessionId: "s3")
        XCTAssertTrue(events.contains { $0.eventType == "Compaction" })
    }

    // MARK: - StuckAgentCheckService

    func testStuckAgentCheckAlertsOnceThenClearsWhenUpdatedAtMoves() async throws {
        try store.insertSession(id: "s4", name: "Stuck", status: .active, cwd: "/tmp", model: "claude-sonnet-4-5", metadata: nil)
        try backdateSessionUpdatedAt(id: "s4", minutesAgo: 10) // past the 5-minute stuck threshold

        let service = StuckAgentCheckService()
        var alerted: [String: String] = [:]
        try await service.tick(context: context(), alertedAt: &alerted)
        XCTAssertEqual(alerted.count, 1, "first tick over threshold should alert")

        // Same updated_at snapshot — must NOT alert again.
        try await service.tick(context: context(), alertedAt: &alerted)
        XCTAssertEqual(alerted.count, 1)

        // The session gets a fresh event (updated_at moves forward, past
        // the stuck cutoff) — the alert must clear on the next tick.
        try store.touchSession(id: "s4")
        try await service.tick(context: context(), alertedAt: &alerted)
        XCTAssertTrue(alerted.isEmpty, "a session no longer stuck must drop out of the alert map")
    }

    // MARK: - WatchdogService

    func testWatchdogRecordsNewApiErrorAndFlipsSessionToError() async throws {
        let transcriptPath = tempDir.appendingPathComponent("watchdog.jsonl")
        try #"{"timestamp":"2024-01-01T00:00:00.000Z","message":{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}}"#.write(to: transcriptPath, atomically: true, encoding: .utf8)

        try store.insertSession(id: "s5", name: "Erroring", status: .active, cwd: "/tmp", model: "claude-sonnet-4-5", metadata: nil)
        try store.insertEvent(sessionId: "s5", agentId: nil, eventType: "SessionStart", toolName: nil, summary: nil, data: #"{"transcript_path":"\#(transcriptPath.path)"}"#)
        try store.insertAgent(id: "s5-main", sessionId: "s5", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try backdateSessionUpdatedAt(id: "s5", minutesAgo: 1) // just needs to be older than the 10s watchdog threshold

        let service = WatchdogService()
        try await service.tick(context: context())

        let events = try store.listEventsBySession(sessionId: "s5")
        XCTAssertTrue(events.contains { $0.eventType == "APIError" && ($0.summary ?? "").contains("Rate limited") })

        let session = try XCTUnwrap(store.getSession(id: "s5"))
        XCTAssertEqual(session.status.knownValue, .error)
        let agent = try XCTUnwrap(store.getAgent(id: "s5-main"))
        XCTAssertEqual(agent.status.knownValue, .error)

        // A second tick with no NEW errors in the transcript must not
        // duplicate the event or re-broadcast.
        try await service.tick(context: context())
        let eventsAfterSecondTick = try store.listEventsBySession(sessionId: "s5")
        XCTAssertEqual(eventsAfterSecondTick.count, events.count)
    }

    // MARK: - LegacyImportService (marker-file gating)

    func testLegacyImportServiceWritesMarkerAndSkipsOnSecondRun() async throws {
        let claudeHomeDir = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeHomeDir, withIntermediateDirectories: true)
        let originalClaudeEnv = ClaudeHome.environment
        let originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": claudeHomeDir.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDir.path]
        ClaudeHome.resetOverrideCacheForTesting()
        defer {
            ClaudeHome.environment = originalClaudeEnv
            PodiumPaths.environment = originalPathsEnv
            ClaudeHome.resetOverrideCacheForTesting()
        }

        let markerPath = tempDir.appendingPathComponent(".legacy-import.done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath.path))

        let service = LegacyImportService()
        try await service.run(context: context())
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath.path), "marker must be written after a successful import")

        // Second run must be a fast no-op (marker present) — nothing to
        // assert on behavior beyond "doesn't throw", but this documents the
        // guard exists and is exercised.
        try await service.run(context: context())
    }
}
