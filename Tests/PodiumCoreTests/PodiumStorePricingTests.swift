import XCTest
@testable import PodiumCore

/// Coverage for `PodiumStore+Pricing.swift` (P3.3): global/per-session cost
/// aggregation, settings diagnostics, and the destructive maintenance ops
/// (`clear-data`, `reset-pricing`, `cleanup`) backing `SettingsRouter`.
final class PodiumStorePricingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-pricing-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openStore(_ name: String = "dashboard.db") throws -> PodiumStore {
        try PodiumStore(path: tempDir.appendingPathComponent(name).path)
    }

    /// Backdates a session's `started_at`/`updated_at` directly via SQL —
    /// `insertSession` always stamps "now", so cleanup/cost-by-date tests
    /// need a raw override to simulate old data.
    private func backdateSession(_ store: PodiumStore, id: String, startedAt: String) throws {
        try store.db.run("UPDATE sessions SET started_at = ? WHERE id = ?", [.text(startedAt), .text(id)])
    }

    private func backdateEvent(_ store: PodiumStore, id: Int64, createdAt: String) throws {
        try store.db.run("UPDATE events SET created_at = ? WHERE id = ?", [.text(createdAt), .integer(id)])
    }

    // MARK: - Global + per-session cost aggregation

    func testGlobalTokenTotalsByModelFoldsBaselinesIn() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheWriteTokens: 5)
        // A compaction event folds prior counts into baseline_* via replaceTokenUsage.
        try store.replaceTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 10, outputTokens: 5, cacheReadTokens: 1, cacheWriteTokens: 1)

        let totals = try store.globalTokenTotalsByModel()
        XCTAssertEqual(totals.count, 1)
        // current (post-replace) + baseline (pre-replace, since new < old): 10 + 100 = 110
        XCTAssertEqual(totals[0].inputTokens, 110)
        XCTAssertEqual(totals[0].outputTokens, 55)
        XCTAssertEqual(totals[0].cacheReadTokens, 11)
        XCTAssertEqual(totals[0].cacheWriteTokens, 6)
    }

    func testSessionStartDateReturnsNilForMissingSession() throws {
        let store = try openStore()
        let date = try store.sessionStartDate(id: "does-not-exist", tzModifier: "+0 minutes")
        XCTAssertNil(date)
    }

    func testSessionStartDateReturnsSessionsDay() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try backdateSession(store, id: "s1", startedAt: "2026-03-15T10:00:00.000Z")

        let date = try store.sessionStartDate(id: "s1", tzModifier: "+0 minutes")
        XCTAssertEqual(date, "2026-03-15")
    }

    // MARK: - Settings diagnostics

    func testSettingsTableCountsCountsDistinctSessionsForTokenUsage() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: "a1", eventType: "tool_use", toolName: "Read", summary: nil, data: nil)
        // Two rows, same session — token_usage count is DISTINCT session_id, so this contributes 1, not 2.
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-haiku-4-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)

        let counts = try store.settingsTableCounts()
        XCTAssertEqual(counts["sessions"], 1)
        XCTAssertEqual(counts["agents"], 1)
        XCTAssertEqual(counts["events"], 1)
        XCTAssertEqual(counts["model_pricing"], Schema.defaultPricing.count)
        XCTAssertEqual(counts["token_usage"], 1)
    }

    func testReadDbPragmasReturnsExpectedDefaults() throws {
        let store = try openStore()
        let pragmas = try store.readDbPragmas()
        XCTAssertEqual(pragmas.journalMode.lowercased(), "wal")
        XCTAssertEqual(pragmas.foreignKeys, 1)
    }

    func testEventCountSinceMinutesAgoExcludesOlderEvents() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        let recentId = try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "tool_use", toolName: nil, summary: nil, data: nil)
        let oldId = try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "tool_use", toolName: nil, summary: nil, data: nil)
        try backdateEvent(store, id: oldId, createdAt: "2020-01-01T00:00:00.000Z")
        _ = recentId

        let count = try store.eventCount(sinceMinutesAgo: 5)
        XCTAssertEqual(count, 1)
    }

    // MARK: - clear-data

    func testClearAllSessionDataWipesEverythingButPricing() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: "a1", eventType: "tool_use", toolName: nil, summary: nil, data: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)

        let clearedCounts = try store.clearAllSessionData()
        XCTAssertEqual(clearedCounts["sessions"], 1)

        XCTAssertEqual(try store.settingsTableCounts()["sessions"], 0)
        XCTAssertEqual(try store.settingsTableCounts()["agents"], 0)
        XCTAssertEqual(try store.settingsTableCounts()["events"], 0)
        XCTAssertEqual(try store.settingsTableCounts()["token_usage"], 0)
        // Pricing survives clear-data.
        XCTAssertEqual(try store.listPricing().count, Schema.defaultPricing.count)
    }

    // MARK: - reset-pricing

    func testResetPricingToDefaultsDiscardsUserEditsAndRestoresDefaults() throws {
        let store = try openStore()
        try store.upsertPricing(PricingPutRequest(modelPattern: "claude-opus-4-5%", displayName: "Edited", inputPerMtok: 999, outputPerMtok: 999, cacheReadPerMtok: 999, cacheWritePerMtok: 999))
        try store.upsertPricing(PricingPutRequest(modelPattern: "custom-model%", displayName: "Custom", inputPerMtok: 1, outputPerMtok: 1, cacheReadPerMtok: 1, cacheWritePerMtok: 1))

        let restored = try store.resetPricingToDefaults()

        XCTAssertEqual(restored.count, Schema.defaultPricing.count)
        XCTAssertNil(restored.first { $0.modelPattern == "custom-model%" })
        let opus = restored.first { $0.modelPattern == "claude-opus-4-5%" }
        XCTAssertEqual(opus?.displayName, "Claude Opus 4.5")
        XCTAssertEqual(opus?.inputPerMtok, 5)
    }

    // MARK: - cleanup: abandon-hours

    func testCleanupAbandonsStaleActiveSessionsWithNoRecentEvents() throws {
        let store = try openStore()
        try store.insertSession(id: "stale", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try backdateSession(store, id: "stale", startedAt: "2020-01-01T00:00:00.000Z")
        try store.insertAgent(id: "a1", sessionId: "stale", name: "main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)

        try store.insertSession(id: "fresh", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        let result = try store.cleanup(abandonHours: 1, purgeDays: nil)

        XCTAssertEqual(result.abandoned, 1)
        XCTAssertEqual(try store.getSession(id: "stale")?.status.knownValue, .abandoned)
        XCTAssertNotNil(try store.getSession(id: "stale")?.endedAt)
        XCTAssertEqual(try store.getAgent(id: "a1")?.status.knownValue, .completed)
        // The fresh session (started_at = now) is untouched.
        XCTAssertEqual(try store.getSession(id: "fresh")?.status.knownValue, .active)
    }

    /// A stale-looking session that actually has a recent event must NOT be
    /// abandoned — mirrors settings.js's `NOT EXISTS (... e.created_at > ?)`
    /// guard.
    func testCleanupDoesNotAbandonStaleSessionWithRecentActivity() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try backdateSession(store, id: "s1", startedAt: "2020-01-01T00:00:00.000Z")
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "tool_use", toolName: nil, summary: nil, data: nil) // created_at = now

        let result = try store.cleanup(abandonHours: 1, purgeDays: nil)

        XCTAssertEqual(result.abandoned, 0)
        XCTAssertEqual(try store.getSession(id: "s1")?.status.knownValue, .active)
    }

    // MARK: - cleanup: purge-days cascade

    /// Purge must cascade-delete events/agents/token_usage for purged
    /// sessions and report exact counts — the core "cleanup deletes
    /// cascade" requirement.
    func testCleanupPurgeCascadesEventsAgentsAndTokenUsage() throws {
        let store = try openStore()
        try store.insertSession(id: "old-completed", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        try backdateSession(store, id: "old-completed", startedAt: "2020-01-01T00:00:00.000Z")
        try store.insertAgent(id: "a1", sessionId: "old-completed", name: "main", type: .main, subagentType: nil, status: .completed, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertAgent(id: "a2", sessionId: "old-completed", name: "sub", type: .subagent, subagentType: "explore", status: .completed, task: nil, parentAgentId: "a1", metadata: nil)
        try store.insertEvent(sessionId: "old-completed", agentId: "a1", eventType: "tool_use", toolName: nil, summary: nil, data: nil)
        try store.insertEvent(sessionId: "old-completed", agentId: "a2", eventType: "tool_use", toolName: nil, summary: nil, data: nil)
        try store.upsertTokenUsage(sessionId: "old-completed", model: "claude-opus-4-5", inputTokens: 5, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)

        // A recent, still-active session must never be purged even if it
        // otherwise looks old (guard: status IN (completed,error,abandoned)).
        try store.insertSession(id: "old-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try backdateSession(store, id: "old-active", startedAt: "2020-01-01T00:00:00.000Z")

        // A recent completed session must not be purged (younger than cutoff).
        try store.insertSession(id: "recent-completed", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)

        let result = try store.cleanup(abandonHours: nil, purgeDays: 30)

        XCTAssertEqual(result.purgedSessions, 1)
        XCTAssertEqual(result.purgedEvents, 2)
        XCTAssertEqual(result.purgedAgents, 2)

        XCTAssertNil(try store.getSession(id: "old-completed"))
        XCTAssertNil(try store.getAgent(id: "a1"))
        XCTAssertNil(try store.getAgent(id: "a2"))
        XCTAssertEqual(try store.getTokensBySession(sessionId: "old-completed").count, 0)

        // Untouched sessions survive.
        XCTAssertNotNil(try store.getSession(id: "old-active"))
        XCTAssertNotNil(try store.getSession(id: "recent-completed"))
    }

    func testCleanupWithNoQualifyingSessionsReturnsAllZeros() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        let result = try store.cleanup(abandonHours: 1, purgeDays: 30)

        XCTAssertEqual(result.abandoned, 0)
        XCTAssertEqual(result.purgedSessions, 0)
        XCTAssertEqual(result.purgedEvents, 0)
        XCTAssertEqual(result.purgedAgents, 0)
    }

    // MARK: - Export

    func testExportRowDumpsMatchInsertedData() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: "My Session", status: .active, cwd: "/tmp", model: "claude-opus-4-5", metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: "a1", eventType: "tool_use", toolName: "Read", summary: "read a file", data: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0)

        let sessions = try store.exportSessions()
        let agents = try store.exportAgents()
        let events = try store.exportEvents()
        let tokenUsage = try store.exportTokenUsage()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "s1")
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, "a1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].toolName, "Read")
        XCTAssertEqual(tokenUsage.count, 1)
        XCTAssertEqual(tokenUsage[0].inputTokens, 100)
        XCTAssertEqual(tokenUsage[0].sessionId, "s1")
    }
}
