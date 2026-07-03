import XCTest
@testable import PodiumCore

final class DatabaseTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-db-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func dbPath(_ name: String = "dashboard.db") -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func openFreshStore(_ name: String = "dashboard.db") throws -> PodiumStore {
        try PodiumStore(path: dbPath(name))
    }

    // MARK: - Fresh DB

    func testFreshDatabaseCreatesSchemaAndSeedsPricing() throws {
        let store = try openFreshStore()

        let pricing = try store.listPricing()
        XCTAssertEqual(pricing.count, Schema.defaultPricing.count)
        XCTAssertTrue(pricing.contains { $0.modelPattern == "claude-opus-4-5%" })

        // Basic sanity: tables exist and are queryable.
        XCTAssertEqual(try store.countEvents(), 0)
        XCTAssertEqual(try store.listSessions(limit: 10, offset: 0).count, 0)
    }

    func testTopUpAddsOnlyMissingPatternsAndPreservesUserEdits() throws {
        let path = dbPath()
        do {
            let store = try PodiumStore(path: path)
            // User edits an existing default pricing row.
            try store.upsertPricing(PricingPutRequest(
                modelPattern: "claude-opus-4-5%",
                displayName: "My Custom Opus",
                inputPerMtok: 999,
                outputPerMtok: 999,
                cacheReadPerMtok: 999,
                cacheWritePerMtok: 999
            ))
            // Remove one default row entirely to simulate "missing pattern".
            try store.deletePricing(pattern: "claude-3-opus%")
            store.db.close()
        }

        // Reopen — top-up should re-add the deleted pattern but must NOT
        // clobber the user's edited row.
        let store2 = try PodiumStore(path: path)
        let edited = try store2.getPricing(pattern: "claude-opus-4-5%")
        XCTAssertEqual(edited?.displayName, "My Custom Opus")
        XCTAssertEqual(edited?.inputPerMtok, 999)

        let readded = try store2.getPricing(pattern: "claude-3-opus%")
        XCTAssertNotNil(readded)
        XCTAssertEqual(readded?.displayName, "Claude Opus 3")
    }

    // MARK: - Migration from an old-schema DB

    /// Builds a pre-migration dashboard.db by hand: old CREATE TABLE
    /// statements without the columns/constraints later migrations add
    /// (token_usage with no `model` column, agents with the legacy
    /// idle/connected CHECK constraint), then runs `Schema.migrate` and
    /// asserts the data survives and transforms correctly.
    func testMigrationFromOldSchemaTransformsDataCorrectly() throws {
        let path = dbPath()
        let db = try Database(path: path)

        // Old-style sessions/agents/events tables (pre updated_at,
        // pre awaiting_input_since, pre transcript_path, pre github_pr_url).
        try db.exec("""
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              name TEXT,
              status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed','error','abandoned')),
              cwd TEXT,
              model TEXT,
              started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
              ended_at TEXT,
              metadata TEXT
            );
            CREATE TABLE agents (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              name TEXT NOT NULL,
              type TEXT NOT NULL DEFAULT 'main' CHECK(type IN ('main','subagent')),
              subagent_type TEXT,
              status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle','connected','working','waiting','completed','error')),
              task TEXT,
              current_tool TEXT,
              started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
              ended_at TEXT,
              parent_agent_id TEXT,
              metadata TEXT,
              FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
              FOREIGN KEY (parent_agent_id) REFERENCES agents(id) ON DELETE SET NULL
            );
            CREATE TABLE events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              agent_id TEXT,
              event_type TEXT NOT NULL,
              tool_name TEXT,
              summary TEXT,
              data TEXT,
              created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE TABLE token_usage (
              session_id TEXT NOT NULL,
              input_tokens INTEGER NOT NULL DEFAULT 0,
              output_tokens INTEGER NOT NULL DEFAULT 0,
              cache_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_write_tokens INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (session_id)
            );
            CREATE TABLE model_pricing (
              model_pattern TEXT PRIMARY KEY,
              display_name TEXT NOT NULL,
              input_per_mtok REAL NOT NULL DEFAULT 0,
              output_per_mtok REAL NOT NULL DEFAULT 0,
              cache_read_per_mtok REAL NOT NULL DEFAULT 0,
              cache_write_per_mtok REAL NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            """)

        // Seed data using the OLD schema shapes.
        try db.exec("""
            INSERT INTO sessions (id, name, status, cwd, model, started_at)
              VALUES ('sess-1', 'Old Session', 'active', '/tmp/proj', 'claude-sonnet-4-5', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
            """)
        try db.exec("""
            INSERT INTO agents (id, session_id, name, type, status, started_at)
              VALUES ('agent-idle', 'sess-1', 'Idle Agent', 'main', 'idle', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
            """)
        try db.exec("""
            INSERT INTO agents (id, session_id, name, type, status, started_at)
              VALUES ('agent-connected', 'sess-1', 'Connected Agent', 'subagent', 'connected', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
            """)
        try db.exec("""
            INSERT INTO token_usage (session_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
              VALUES ('sess-1', 100, 200, 10, 20);
            """)
        db.close()

        // Reopen with a fresh Database handle and run the full migration
        // chain, exactly like app startup would.
        let db2 = try Database(path: path)
        try Schema.migrate(db2)
        let store = PodiumStore(db: db2)

        // token_usage now has a `model` column, backfilled from sessions.model.
        let tokenRows = try store.getTokensBySession(sessionId: "sess-1")
        XCTAssertEqual(tokenRows.count, 1)
        XCTAssertEqual(tokenRows.first?.model, "claude-sonnet-4-5")
        XCTAssertEqual(tokenRows.first?.inputTokens, 100)

        // sessions/agents now have updated_at populated.
        let session = try store.getSession(id: "sess-1")
        XCTAssertNotNil(session?.updatedAt)
        XCTAssertFalse(session!.updatedAt!.isEmpty)

        // agents status CHECK constraint rebuilt: idle -> waiting, connected -> working.
        let idleAgent = try store.getAgent(id: "agent-idle")
        XCTAssertEqual(idleAgent?.status.knownValue, .waiting)
        let connectedAgent = try store.getAgent(id: "agent-connected")
        XCTAssertEqual(connectedAgent?.status.knownValue, .working)

        // New agents table enforces the 4-status CHECK constraint now —
        // inserting a legacy status should fail.
        XCTAssertThrowsError(
            try db2.exec("INSERT INTO agents (id, session_id, name, status) VALUES ('bad', 'sess-1', 'Bad', 'idle');")
        )

        // Pricing seeded on top of the pre-existing (empty) model_pricing table.
        XCTAssertEqual(try store.listPricing().count, Schema.defaultPricing.count)
    }

    // MARK: - replaceTokenUsage baseline behavior (compaction)

    func testReplaceTokenUsageAccumulatesBaselineOnCountDrop() throws {
        let store = try openFreshStore()
        try store.insertSession(id: "sess-1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        // Initial high counts.
        try store.replaceTokenUsage(
            sessionId: "sess-1", model: "claude-sonnet-4-5",
            inputTokens: 1000, outputTokens: 2000, cacheReadTokens: 100, cacheWriteTokens: 50
        )

        var rows = try store.getTokensBySession(sessionId: "sess-1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 1000)
        XCTAssertEqual(rows[0].outputTokens, 2000)

        // Compaction: transcript rewritten, counts drop below the prior
        // stored values — the drop must be folded into baseline_*, and the
        // *effective* (current+baseline) total returned by
        // getTokensBySession must equal the pre-compaction total.
        try store.replaceTokenUsage(
            sessionId: "sess-1", model: "claude-sonnet-4-5",
            inputTokens: 50, outputTokens: 80, cacheReadTokens: 5, cacheWriteTokens: 2
        )

        rows = try store.getTokensBySession(sessionId: "sess-1")
        XCTAssertEqual(rows.count, 1)
        // Effective totals = new current + baseline(which absorbed the old current).
        XCTAssertEqual(rows[0].inputTokens, 1000 + 50)
        XCTAssertEqual(rows[0].outputTokens, 2000 + 80)
        XCTAssertEqual(rows[0].cacheReadTokens, 100 + 5)
        XCTAssertEqual(rows[0].cacheWriteTokens, 50 + 2)

        // A subsequent increase (no further compaction) should NOT add more
        // to the baseline — it just replaces current tokens outright.
        try store.replaceTokenUsage(
            sessionId: "sess-1", model: "claude-sonnet-4-5",
            inputTokens: 120, outputTokens: 90, cacheReadTokens: 6, cacheWriteTokens: 3
        )
        rows = try store.getTokensBySession(sessionId: "sess-1")
        XCTAssertEqual(rows[0].inputTokens, 1000 + 120)
        XCTAssertEqual(rows[0].outputTokens, 2000 + 90)

        // getTokenTotals (global) reflects the same effective sum.
        let totals = try store.getTokenTotals()
        XCTAssertEqual(totals.totalInput, 1000 + 120)
        XCTAssertEqual(totals.totalOutput, 2000 + 90)
    }

    func testUpsertTokenUsageIsAdditive() throws {
        let store = try openFreshStore()
        try store.insertSession(id: "sess-1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        try store.upsertTokenUsage(sessionId: "sess-1", model: "claude-sonnet-4-5", inputTokens: 10, outputTokens: 20, cacheReadTokens: 1, cacheWriteTokens: 2)
        try store.upsertTokenUsage(sessionId: "sess-1", model: "claude-sonnet-4-5", inputTokens: 5, outputTokens: 5, cacheReadTokens: 1, cacheWriteTokens: 1)

        let rows = try store.getTokensBySession(sessionId: "sess-1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].inputTokens, 15)
        XCTAssertEqual(rows[0].outputTokens, 25)
    }

    // MARK: - findDeepestWorkingAgent

    func testFindDeepestWorkingAgentReturnsDeepestInThreeLevelTree() throws {
        let store = try openFreshStore()
        try store.insertSession(id: "sess-1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        // main (depth 0) -> subagent A (depth 1, working) -> subagent B (depth 2, working)
        // Also a sibling subagent C (depth 1, completed) to make sure status filtering works.
        try store.insertAgent(id: "main", sessionId: "sess-1", name: "main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertAgent(id: "sub-a", sessionId: "sess-1", name: "sub-a", type: .subagent, subagentType: "explore", status: .working, task: nil, parentAgentId: "main", metadata: nil)
        try store.insertAgent(id: "sub-c", sessionId: "sess-1", name: "sub-c", type: .subagent, subagentType: "explore", status: .completed, task: nil, parentAgentId: "main", metadata: nil)
        try store.insertAgent(id: "sub-b", sessionId: "sess-1", name: "sub-b", type: .subagent, subagentType: "explore", status: .working, task: nil, parentAgentId: "sub-a", metadata: nil)

        let deepest = try store.findDeepestWorkingAgent(sessionId: "sess-1")
        XCTAssertEqual(deepest?.id, "sub-b")
        XCTAssertEqual(deepest?.depth, 2)
    }

    func testFindDeepestWorkingAgentReturnsNilWhenNoneWorking() throws {
        let store = try openFreshStore()
        try store.insertSession(id: "sess-1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "main", sessionId: "sess-1", name: "main", type: .main, subagentType: nil, status: .completed, task: nil, parentAgentId: nil, metadata: nil)

        let deepest = try store.findDeepestWorkingAgent(sessionId: "sess-1")
        XCTAssertNil(deepest)
    }

    // MARK: - findStaleSessions

    func testFindStaleSessionsIncludesErrorWithNullEndedAt() throws {
        let store = try openFreshStore()

        // A session in 'error' status with ended_at NULL and an old
        // updated_at should be considered stale (the "error but running"
        // branch — covered by the partial index too).
        try store.insertSession(id: "err-sess", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)
        // Backdate updated_at directly (bypassing touchSession's "now").
        try store.db.exec("UPDATE sessions SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 minutes') WHERE id = 'err-sess';")

        // A completed session should never show up regardless of age.
        try store.insertSession(id: "completed-sess", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        try store.db.exec("UPDATE sessions SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 minutes') WHERE id = 'completed-sess';")

        // A fresh active session should not be stale yet (updated just now).
        try store.insertSession(id: "fresh-sess", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        let stale = try store.findStaleSessions(excludingId: "unrelated", minutes: 10)
        XCTAssertTrue(stale.contains("err-sess"))
        XCTAssertFalse(stale.contains("completed-sess"))
        XCTAssertFalse(stale.contains("fresh-sess"))
    }

    func testFindStaleSessionsExcludesGivenId() throws {
        let store = try openFreshStore()
        try store.insertSession(id: "sess-1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.db.exec("UPDATE sessions SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 minutes') WHERE id = 'sess-1';")

        let stale = try store.findStaleSessions(excludingId: "sess-1", minutes: 10)
        XCTAssertFalse(stale.contains("sess-1"))
    }

    // MARK: - Startup cleanup: stale active session -> completed

    func testStartupCleanupCompletesStaleActiveSessionWithNoRecentEvents() throws {
        let path = dbPath()
        let db = try Database(path: path)
        try Schema.migrate(db)
        let store = PodiumStore(db: db)

        try store.insertSession(id: "stale-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        // Backdate started_at to over an hour ago, with no recent events.
        try db.exec("UPDATE sessions SET started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 hours') WHERE id = 'stale-active';")

        // A second session that's active but recent — must NOT be touched.
        try store.insertSession(id: "recent-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        // Re-run migrate (idempotent) to trigger the startup cleanup again,
        // simulating a fresh app boot against this now-stale DB.
        try Schema.migrate(db)

        let staleSession = try store.getSession(id: "stale-active")
        XCTAssertEqual(staleSession?.status.knownValue, .completed)
        XCTAssertNotNil(staleSession?.endedAt)

        let recentSession = try store.getSession(id: "recent-active")
        XCTAssertEqual(recentSession?.status.knownValue, .active)
    }

    func testStartupCleanupCompletesOrphanAgentsOnFinishedSessions() throws {
        let path = dbPath()
        let db = try Database(path: path)
        try Schema.migrate(db)
        let store = PodiumStore(db: db)

        try store.insertSession(id: "sess-1", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "orphan", sessionId: "sess-1", name: "orphan", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)

        try Schema.migrate(db)

        let agent = try store.getAgent(id: "orphan")
        XCTAssertEqual(agent?.status.knownValue, .completed)
        XCTAssertNotNil(agent?.endedAt)
    }

    // MARK: - DB path resolution

    func testDatabasePathHonorsExplicitDashboardDbPath() {
        let originalEnv = PodiumPaths.environment
        defer { PodiumPaths.environment = originalEnv }

        let explicitPath = tempDir.appendingPathComponent("custom/dashboard.db").path
        PodiumPaths.environment = ["DASHBOARD_DB_PATH": explicitPath]

        XCTAssertEqual(PodiumPaths.databasePath(), explicitPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (explicitPath as NSString).deletingLastPathComponent))
    }

    func testDatabasePathHonorsDashboardDataDir() {
        let originalEnv = PodiumPaths.environment
        defer { PodiumPaths.environment = originalEnv }

        let dataDir = tempDir.appendingPathComponent("data-dir").path
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": dataDir]

        XCTAssertEqual(PodiumPaths.databasePath(), dataDir + "/dashboard.db")
    }
}
