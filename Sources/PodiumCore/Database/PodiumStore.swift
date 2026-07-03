// PodiumStore.swift — port of the `stmts` map in dashboard/server/db.js
// (lines 444–734) as typed methods returning PodiumCore model structs. Keeps
// exact SQL semantics: COALESCE-based partial updates, awaiting-input
// set/clear (clear only when non-null), the findDeepestWorkingAgent
// recursive CTE, upsertTokenUsage (additive) vs replaceTokenUsage (baseline
// CASE logic), pricing LIKE matching, and every aggregate query.

import CSQLite
import Foundation

public final class PodiumStore {
    public let db: Database

    public init(db: Database) {
        self.db = db
    }

    /// Opens (or creates) the database at the resolved path and runs the
    /// full migration chain — the one-stop constructor most callers want.
    public convenience init(path: String = PodiumPaths.databasePath()) throws {
        let db = try Database(path: path)
        try Schema.migrate(db)
        self.init(db: db)
    }

    // MARK: - Row mapping

    private func mapSession(_ row: SQLiteRow) -> Session {
        Session(
            id: row.stringValue("id"),
            name: row.string("name"),
            status: SessionStatus(rawValue: row.stringValue("status")) ?? .active,
            cwd: row.string("cwd"),
            model: row.string("model"),
            startedAt: row.stringValue("started_at"),
            endedAt: row.string("ended_at"),
            metadata: row.string("metadata"),
            agentCount: row.int("agent_count"),
            lastActivity: row.string("last_activity"),
            awaitingInputSince: row.string("awaiting_input_since"),
            transcriptPath: row.string("transcript_path"),
            githubPrUrl: row.string("github_pr_url"),
            updatedAt: row.string("updated_at")
        )
    }

    private func mapAgent(_ row: SQLiteRow) -> Agent {
        Agent(
            id: row.stringValue("id"),
            sessionId: row.stringValue("session_id"),
            name: row.stringValue("name"),
            type: AgentType(rawValue: row.stringValue("type")) ?? .main,
            subagentType: row.string("subagent_type"),
            status: AgentStatus(rawValue: row.stringValue("status")) ?? .waiting,
            task: row.string("task"),
            currentTool: row.string("current_tool"),
            startedAt: row.stringValue("started_at"),
            endedAt: row.string("ended_at"),
            updatedAt: row.stringValue("updated_at"),
            parentAgentId: row.string("parent_agent_id"),
            metadata: row.string("metadata"),
            awaitingInputSince: row.string("awaiting_input_since")
        )
    }

    private func mapEvent(_ row: SQLiteRow) -> DashboardEvent {
        DashboardEvent(
            id: row.int("id"),
            sessionId: row.stringValue("session_id"),
            agentId: row.string("agent_id"),
            eventType: row.stringValue("event_type"),
            toolName: row.string("tool_name"),
            summary: row.string("summary"),
            data: row.string("data"),
            createdAt: row.stringValue("created_at")
        )
    }

    private func mapTokenUsage(_ row: SQLiteRow) -> TokenUsage {
        TokenUsage(
            sessionId: row.stringValue("session_id"),
            model: row.string("model") ?? "unknown",
            inputTokens: row.intValue("input_tokens"),
            outputTokens: row.intValue("output_tokens"),
            cacheReadTokens: row.intValue("cache_read_tokens"),
            cacheWriteTokens: row.intValue("cache_write_tokens"),
            baselineInput: row.intValue("baseline_input"),
            baselineOutput: row.intValue("baseline_output"),
            baselineCacheRead: row.intValue("baseline_cache_read"),
            baselineCacheWrite: row.intValue("baseline_cache_write")
        )
    }

    private func mapPricing(_ row: SQLiteRow) -> ModelPricing {
        ModelPricing(
            modelPattern: row.stringValue("model_pattern"),
            displayName: row.stringValue("display_name"),
            inputPerMtok: row.doubleValue("input_per_mtok"),
            outputPerMtok: row.doubleValue("output_per_mtok"),
            cacheReadPerMtok: row.doubleValue("cache_read_per_mtok"),
            cacheWritePerMtok: row.doubleValue("cache_write_per_mtok"),
            updatedAt: row.stringValue("updated_at")
        )
    }

    // MARK: - Sessions

    public func getSession(id: String) throws -> Session? {
        try db.queryOne("SELECT * FROM sessions WHERE id = ?", [.text(id)], mapSession)
    }

    /// listSessions: agent_count + last_activity (db.js `listSessions`).
    public func listSessions(limit: Int, offset: Int) throws -> [Session] {
        try db.query(
            """
            SELECT s.*, COUNT(a.id) as agent_count, s.updated_at as last_activity
            FROM sessions s LEFT JOIN agents a ON a.session_id = s.id
            GROUP BY s.id ORDER BY s.updated_at DESC LIMIT ? OFFSET ?
            """,
            [.integer(Int64(limit)), .integer(Int64(offset))],
            mapSession
        )
    }

    @discardableResult
    public func insertSession(id: String, name: String?, status: SessionStatus, cwd: String?, model: String?, metadata: String?) throws -> Int {
        try db.run(
            """
            INSERT INTO sessions (id, name, status, cwd, model, started_at, updated_at, metadata)
            VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?)
            """,
            [.text(id), SQLiteValue(name), .text(status.rawValue), SQLiteValue(cwd), SQLiteValue(model), SQLiteValue(metadata)]
        )
    }

    @discardableResult
    public func updateSession(id: String, name: String? = nil, status: SessionStatus? = nil, endedAt: String? = nil, metadata: String? = nil) throws -> Int {
        try db.run(
            """
            UPDATE sessions SET name = COALESCE(?, name), status = COALESCE(?, status), ended_at = COALESCE(?, ended_at),
              metadata = COALESCE(?, metadata), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?
            """,
            [SQLiteValue(name), SQLiteValue(status?.rawValue), SQLiteValue(endedAt), SQLiteValue(metadata), .text(id)]
        )
    }

    @discardableResult
    public func reactivateSession(id: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET status = 'active', ended_at = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            [.text(id)]
        )
    }

    @discardableResult
    public func updateSessionModel(id: String, model: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET model = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND COALESCE(model, '') != ?",
            [.text(model), .text(id), .text(model)]
        )
    }

    @discardableResult
    public func setSessionTranscriptPath(id: String, transcriptPath: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET transcript_path = ? WHERE id = ? AND (transcript_path IS NULL OR transcript_path = '')",
            [.text(transcriptPath), .text(id)]
        )
    }

    // MARK: - Agents

    public func getAgent(id: String) throws -> Agent? {
        try db.queryOne("SELECT * FROM agents WHERE id = ?", [.text(id)], mapAgent)
    }

    public func listAgents(limit: Int, offset: Int) throws -> [Agent] {
        try db.query(
            "SELECT * FROM agents ORDER BY started_at DESC LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))],
            mapAgent
        )
    }

    public func listAgentsBySession(sessionId: String) throws -> [Agent] {
        try db.query(
            "SELECT * FROM agents WHERE session_id = ? ORDER BY started_at DESC",
            [.text(sessionId)],
            mapAgent
        )
    }

    public func listAgentsByStatus(status: AgentStatus, limit: Int, offset: Int) throws -> [Agent] {
        try db.query(
            "SELECT * FROM agents WHERE status = ? ORDER BY started_at DESC LIMIT ? OFFSET ?",
            [.text(status.rawValue), .integer(Int64(limit)), .integer(Int64(offset))],
            mapAgent
        )
    }

    @discardableResult
    public func insertAgent(
        id: String, sessionId: String, name: String, type: AgentType, subagentType: String?,
        status: AgentStatus, task: String?, parentAgentId: String?, metadata: String?
    ) throws -> Int {
        try db.run(
            """
            INSERT INTO agents (id, session_id, name, type, subagent_type, status, task, started_at, updated_at, parent_agent_id, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?, ?)
            """,
            [
                .text(id), .text(sessionId), .text(name), .text(type.rawValue), SQLiteValue(subagentType),
                .text(status.rawValue), SQLiteValue(task), SQLiteValue(parentAgentId), SQLiteValue(metadata),
            ]
        )
    }

    @discardableResult
    public func updateAgent(
        id: String, name: String? = nil, status: AgentStatus? = nil, task: String? = nil,
        currentTool: String? = nil, endedAt: String? = nil, metadata: String? = nil
    ) throws -> Int {
        try db.run(
            """
            UPDATE agents SET name = COALESCE(?, name), status = COALESCE(?, status), task = COALESCE(?, task),
              current_tool = ?, ended_at = COALESCE(?, ended_at), metadata = COALESCE(?, metadata),
              updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?
            """,
            [
                SQLiteValue(name), SQLiteValue(status?.rawValue), SQLiteValue(task),
                SQLiteValue(currentTool), SQLiteValue(endedAt), SQLiteValue(metadata), .text(id),
            ]
        )
    }

    @discardableResult
    public func reactivateAgent(id: String) throws -> Int {
        try db.run(
            "UPDATE agents SET status = 'working', ended_at = NULL, current_tool = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            [.text(id)]
        )
    }

    // MARK: - Awaiting input

    @discardableResult
    public func setSessionAwaitingInput(id: String, since: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET awaiting_input_since = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            [.text(since), .text(id)]
        )
    }

    @discardableResult
    public func clearSessionAwaitingInput(id: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET awaiting_input_since = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND awaiting_input_since IS NOT NULL",
            [.text(id)]
        )
    }

    @discardableResult
    public func setAgentAwaitingInput(id: String, since: String) throws -> Int {
        try db.run(
            "UPDATE agents SET awaiting_input_since = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            [.text(since), .text(id)]
        )
    }

    @discardableResult
    public func clearAgentAwaitingInput(id: String) throws -> Int {
        try db.run(
            "UPDATE agents SET awaiting_input_since = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND awaiting_input_since IS NOT NULL",
            [.text(id)]
        )
    }

    @discardableResult
    public func clearSessionAgentsAwaitingInput(sessionId: String) throws -> Int {
        try db.run(
            "UPDATE agents SET awaiting_input_since = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE session_id = ? AND awaiting_input_since IS NOT NULL",
            [.text(sessionId)]
        )
    }

    /// Result row of `findDeepestWorkingAgent`: agent id + its depth in the tree.
    public struct DeepestAgent: Equatable, Sendable {
        public let id: String
        public let depth: Int
    }

    /// Recursive-CTE port of db.js `findDeepestWorkingAgent` — finds the
    /// deepest currently-working subagent in a session, most-recently-started
    /// wins ties at the same depth.
    public func findDeepestWorkingAgent(sessionId: String) throws -> DeepestAgent? {
        try db.queryOne(
            """
            WITH RECURSIVE agent_depth AS (
              SELECT id, parent_agent_id, 0 as depth
              FROM agents
              WHERE session_id = ? AND parent_agent_id IS NULL
              UNION ALL
              SELECT a.id, a.parent_agent_id, ad.depth + 1
              FROM agents a
              JOIN agent_depth ad ON a.parent_agent_id = ad.id
              WHERE a.session_id = ?
            )
            SELECT ad.id, ad.depth
            FROM agent_depth ad
            JOIN agents a ON a.id = ad.id
            WHERE a.status = 'working' AND a.type = 'subagent'
            ORDER BY ad.depth DESC, a.started_at DESC
            LIMIT 1
            """,
            [.text(sessionId), .text(sessionId)]
        ) { row in
            DeepestAgent(id: row.stringValue("id"), depth: row.intValue("depth"))
        }
    }

    // MARK: - Touch / stale

    @discardableResult
    public func touchSession(id: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            [.text(id)]
        )
    }

    /// findStaleSessions: active OR (error AND ended_at IS NULL), excluding
    /// `excludingId`, whose `updated_at` is older than `minutes` minutes.
    public func findStaleSessions(excludingId: String, minutes: Int) throws -> [String] {
        try db.query(
            """
            SELECT id FROM sessions
             WHERE (status = 'active' OR (status = 'error' AND ended_at IS NULL)) AND id != ?
               AND updated_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || ? || ' minutes')
            """,
            [.text(excludingId), .text(String(minutes))]
        ) { row in row.stringValue("id") }
    }

    // MARK: - Events

    @discardableResult
    public func insertEvent(sessionId: String, agentId: String?, eventType: String, toolName: String?, summary: String?, data: String?) throws -> Int64 {
        try db.sync { handle in
            let stmt = try SQLiteStatement(
                db: handle,
                sql: """
                INSERT INTO events (session_id, agent_id, event_type, tool_name, summary, data, created_at)
                VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                """
            )
            try stmt.bind([
                .text(sessionId), SQLiteValue(agentId), .text(eventType),
                SQLiteValue(toolName), SQLiteValue(summary), SQLiteValue(data),
            ])
            _ = try stmt.step()
            return sqlite3_last_insert_rowid(handle)
        }
    }

    public func listEvents(limit: Int, offset: Int) throws -> [DashboardEvent] {
        try db.query(
            "SELECT * FROM events ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))],
            mapEvent
        )
    }

    public func listEventsBySession(sessionId: String) throws -> [DashboardEvent] {
        try db.query(
            "SELECT * FROM events WHERE session_id = ? ORDER BY created_at DESC, id DESC",
            [.text(sessionId)],
            mapEvent
        )
    }

    public func countEvents() throws -> Int {
        try db.queryOne("SELECT COUNT(*) as count FROM events", []) { $0.intValue("count") } ?? 0
    }

    public func countEventsSince(_ isoTimestamp: String) throws -> Int {
        try db.queryOne("SELECT COUNT(*) as count FROM events WHERE created_at >= ?", [.text(isoTimestamp)]) {
            $0.intValue("count")
        } ?? 0
    }

    /// countEventsToday: accepts a tz modifier (e.g. "-420 minutes") to
    /// compute local midnight in UTC.
    public func countEventsToday(tzModifier: String) throws -> Int {
        try db.queryOne(
            "SELECT COUNT(*) as count FROM events WHERE created_at >= datetime('now', ?, 'start of day', ?)",
            [.text(tzModifier), .text(tzModifier)]
        ) { $0.intValue("count") } ?? 0
    }

    // MARK: - Stats

    public struct GlobalStats: Equatable, Sendable {
        public let totalSessions: Int
        public let activeSessions: Int
        public let activeAgents: Int
        public let totalAgents: Int
        public let totalEvents: Int
    }

    public func stats() throws -> GlobalStats {
        try db.queryOne(
            """
            SELECT
              (SELECT COUNT(*) FROM sessions) as total_sessions,
              (SELECT COUNT(*) FROM sessions WHERE status = 'active' OR (status = 'error' AND ended_at IS NULL)) as active_sessions,
              (SELECT COUNT(*) FROM agents WHERE status IN ('working', 'waiting')) as active_agents,
              (SELECT COUNT(*) FROM agents) as total_agents,
              (SELECT COUNT(*) FROM events) as total_events
            """,
            []
        ) { row in
            GlobalStats(
                totalSessions: row.intValue("total_sessions"),
                activeSessions: row.intValue("active_sessions"),
                activeAgents: row.intValue("active_agents"),
                totalAgents: row.intValue("total_agents"),
                totalEvents: row.intValue("total_events")
            )
        } ?? GlobalStats(totalSessions: 0, activeSessions: 0, activeAgents: 0, totalAgents: 0, totalEvents: 0)
    }

    public func agentStatusCounts() throws -> [String: Int] {
        let rows = try db.query("SELECT status, COUNT(*) as count FROM agents GROUP BY status", []) { row in
            (row.stringValue("status"), row.intValue("count"))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    public func sessionStatusCounts() throws -> [String: Int] {
        let rows = try db.query("SELECT status, COUNT(*) as count FROM sessions GROUP BY status", []) { row in
            (row.stringValue("status"), row.intValue("count"))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    // MARK: - Token usage

    /// upsertTokenUsage: additive — adds to existing counters on conflict.
    @discardableResult
    public func upsertTokenUsage(sessionId: String, model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) throws -> Int {
        try db.run(
            """
            INSERT INTO token_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, model) DO UPDATE SET
              input_tokens = input_tokens + excluded.input_tokens,
              output_tokens = output_tokens + excluded.output_tokens,
              cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
              cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens
            """,
            [
                .text(sessionId), .text(model), .integer(Int64(inputTokens)), .integer(Int64(outputTokens)),
                .integer(Int64(cacheReadTokens)), .integer(Int64(cacheWriteTokens)),
            ]
        )
    }

    /// replaceTokenUsage: replaces the current counters, but if the new
    /// value for any counter is LOWER than what's stored (compaction rewrote
    /// the transcript and lost history), the difference is folded into the
    /// corresponding baseline_* column so the effective total never regresses.
    @discardableResult
    public func replaceTokenUsage(sessionId: String, model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) throws -> Int {
        try db.run(
            """
            INSERT INTO token_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                                     baseline_input, baseline_output, baseline_cache_read, baseline_cache_write)
            VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 0)
            ON CONFLICT(session_id, model) DO UPDATE SET
              baseline_input = CASE WHEN excluded.input_tokens < input_tokens
                THEN baseline_input + input_tokens ELSE baseline_input END,
              baseline_output = CASE WHEN excluded.output_tokens < output_tokens
                THEN baseline_output + output_tokens ELSE baseline_output END,
              baseline_cache_read = CASE WHEN excluded.cache_read_tokens < cache_read_tokens
                THEN baseline_cache_read + cache_read_tokens ELSE baseline_cache_read END,
              baseline_cache_write = CASE WHEN excluded.cache_write_tokens < cache_write_tokens
                THEN baseline_cache_write + cache_write_tokens ELSE baseline_cache_write END,
              input_tokens = excluded.input_tokens,
              output_tokens = excluded.output_tokens,
              cache_read_tokens = excluded.cache_read_tokens,
              cache_write_tokens = excluded.cache_write_tokens
            """,
            [
                .text(sessionId), .text(model), .integer(Int64(inputTokens)), .integer(Int64(outputTokens)),
                .integer(Int64(cacheReadTokens)), .integer(Int64(cacheWriteTokens)),
            ]
        )
    }

    public struct TokenTotals: Equatable, Sendable {
        public let totalInput: Int
        public let totalOutput: Int
        public let totalCacheRead: Int
        public let totalCacheWrite: Int
    }

    public func getTokenTotals() throws -> TokenTotals {
        try db.queryOne(
            """
            SELECT
              COALESCE(SUM(input_tokens + baseline_input), 0) as total_input,
              COALESCE(SUM(output_tokens + baseline_output), 0) as total_output,
              COALESCE(SUM(cache_read_tokens + baseline_cache_read), 0) as total_cache_read,
              COALESCE(SUM(cache_write_tokens + baseline_cache_write), 0) as total_cache_write
            FROM token_usage
            """,
            []
        ) { row in
            TokenTotals(
                totalInput: row.intValue("total_input"),
                totalOutput: row.intValue("total_output"),
                totalCacheRead: row.intValue("total_cache_read"),
                totalCacheWrite: row.intValue("total_cache_write")
            )
        } ?? TokenTotals(totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0)
    }

    /// getTokensBySession: per-model rows with baselines already folded into
    /// the returned current values (current + baseline), matching the SQL's
    /// column aliasing exactly. NOTE: the returned `TokenUsage.baseline*`
    /// fields are zero because the SQL already added them into the
    /// current-token fields — mirrors the Node query shape 1:1.
    public func getTokensBySession(sessionId: String) throws -> [TokenUsage] {
        try db.query(
            """
            SELECT model,
              input_tokens + baseline_input as input_tokens,
              output_tokens + baseline_output as output_tokens,
              cache_read_tokens + baseline_cache_read as cache_read_tokens,
              cache_write_tokens + baseline_cache_write as cache_write_tokens
            FROM token_usage WHERE session_id = ?
            """,
            [.text(sessionId)]
        ) { row in
            TokenUsage(
                sessionId: sessionId,
                model: row.string("model") ?? "unknown",
                inputTokens: row.intValue("input_tokens"),
                outputTokens: row.intValue("output_tokens"),
                cacheReadTokens: row.intValue("cache_read_tokens"),
                cacheWriteTokens: row.intValue("cache_write_tokens")
            )
        }
    }

    // MARK: - Model pricing

    public func listPricing() throws -> [ModelPricing] {
        try db.query("SELECT * FROM model_pricing ORDER BY display_name ASC", [], mapPricing)
    }

    public func getPricing(pattern: String) throws -> ModelPricing? {
        try db.queryOne("SELECT * FROM model_pricing WHERE model_pattern = ?", [.text(pattern)], mapPricing)
    }

    @discardableResult
    public func upsertPricing(_ pricing: PricingPutRequest) throws -> Int {
        try db.run(
            """
            INSERT INTO model_pricing (model_pattern, display_name, input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            ON CONFLICT(model_pattern) DO UPDATE SET
              display_name = excluded.display_name,
              input_per_mtok = excluded.input_per_mtok,
              output_per_mtok = excluded.output_per_mtok,
              cache_read_per_mtok = excluded.cache_read_per_mtok,
              cache_write_per_mtok = excluded.cache_write_per_mtok,
              updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            """,
            [
                .text(pricing.modelPattern), .text(pricing.displayName),
                .double(pricing.inputPerMtok), .double(pricing.outputPerMtok),
                .double(pricing.cacheReadPerMtok), .double(pricing.cacheWritePerMtok),
            ]
        )
    }

    @discardableResult
    public func deletePricing(pattern: String) throws -> Int {
        try db.run("DELETE FROM model_pricing WHERE model_pattern = ?", [.text(pattern)])
    }

    /// matchPricing: `? LIKE REPLACE(model_pattern, '%', '%')` — a no-op
    /// REPLACE in the original SQL (kept for parity; it does not alter the
    /// pattern), so this is effectively `<model> LIKE <model_pattern>`,
    /// first row wins (no explicit ORDER BY — matches db.js semantics
    /// exactly, whatever order SQLite returns rows for the table scan).
    public func matchPricing(model: String) throws -> ModelPricing? {
        try db.queryOne(
            "SELECT * FROM model_pricing WHERE ? LIKE REPLACE(model_pattern, '%', '%') LIMIT 1",
            [.text(model)],
            mapPricing
        )
    }

    // MARK: - Aggregates (global)

    public func toolUsageCounts() throws -> [(toolName: String, count: Int)] {
        try db.query(
            """
            SELECT tool_name, COUNT(*) as count
            FROM events
            WHERE tool_name IS NOT NULL
            GROUP BY tool_name
            ORDER BY count DESC
            LIMIT 20
            """,
            []
        ) { row in (row.stringValue("tool_name"), row.intValue("count")) }
    }

    public func dailyEventCounts(tzModifier: String) throws -> [(date: String, count: Int)] {
        try db.query(
            """
            SELECT DATE(created_at, ?) as date, COUNT(*) as count
            FROM events
            WHERE created_at >= DATE('now', '-365 days')
            GROUP BY 1
            ORDER BY date ASC
            """,
            [.text(tzModifier)]
        ) { row in (row.stringValue("date"), row.intValue("count")) }
    }

    public func dailySessionCounts(tzModifier: String) throws -> [(date: String, count: Int)] {
        try db.query(
            """
            SELECT DATE(started_at, ?) as date, COUNT(*) as count
            FROM sessions
            WHERE started_at >= DATE('now', '-365 days')
            GROUP BY 1
            ORDER BY date ASC
            """,
            [.text(tzModifier)]
        ) { row in (row.stringValue("date"), row.intValue("count")) }
    }

    public func agentTypeDistribution() throws -> [(subagentType: String, count: Int)] {
        try db.query(
            """
            SELECT subagent_type, COUNT(*) as count
            FROM agents
            WHERE type = 'subagent' AND subagent_type IS NOT NULL
            GROUP BY subagent_type
            ORDER BY count DESC
            """,
            []
        ) { row in (row.stringValue("subagent_type"), row.intValue("count")) }
    }

    public func totalSubagentCount() throws -> Int {
        try db.queryOne("SELECT COUNT(*) as count FROM agents WHERE type = 'subagent'", []) {
            $0.intValue("count")
        } ?? 0
    }

    public func eventTypeCounts() throws -> [(eventType: String, count: Int)] {
        try db.query(
            "SELECT event_type, COUNT(*) as count FROM events GROUP BY event_type ORDER BY count DESC",
            []
        ) { row in (row.stringValue("event_type"), row.intValue("count")) }
    }

    public func avgEventsPerSession() throws -> Double {
        try db.queryOne(
            """
            SELECT ROUND(CAST(COUNT(*) AS REAL) / MAX(1, (SELECT COUNT(*) FROM sessions)), 1) as avg
            FROM events
            """,
            []
        ) { $0.doubleValue("avg") } ?? 0
    }

    // MARK: - Per-session aggregates

    public func sessionEventCount(sessionId: String) throws -> Int {
        try db.queryOne("SELECT COUNT(*) as count FROM events WHERE session_id = ?", [.text(sessionId)]) {
            $0.intValue("count")
        } ?? 0
    }

    public func sessionEventTypeCounts(sessionId: String) throws -> [(eventType: String, count: Int)] {
        try db.query(
            """
            SELECT event_type, COUNT(*) as count
            FROM events
            WHERE session_id = ?
            GROUP BY event_type
            ORDER BY count DESC
            """,
            [.text(sessionId)]
        ) { row in (row.stringValue("event_type"), row.intValue("count")) }
    }

    public func sessionToolUsageCounts(sessionId: String) throws -> [(toolName: String, count: Int)] {
        try db.query(
            """
            SELECT tool_name, COUNT(*) as count
            FROM events
            WHERE session_id = ? AND tool_name IS NOT NULL
            GROUP BY tool_name
            ORDER BY count DESC
            LIMIT 15
            """,
            [.text(sessionId)]
        ) { row in (row.stringValue("tool_name"), row.intValue("count")) }
    }

    public func sessionErrorCount(sessionId: String) throws -> Int {
        try db.queryOne(
            """
            SELECT COUNT(*) as count
            FROM events
            WHERE session_id = ?
              AND (
                LOWER(event_type) LIKE '%error%'
                OR LOWER(event_type) LIKE '%failed%'
                OR LOWER(summary) LIKE 'error%'
                OR LOWER(summary) LIKE 'failed%'
              )
            """,
            [.text(sessionId)]
        ) { $0.intValue("count") } ?? 0
    }

    public struct EventTimeRange: Equatable, Sendable {
        public let firstAt: String?
        public let lastAt: String?
    }

    public func sessionEventTimeRange(sessionId: String) throws -> EventTimeRange {
        try db.queryOne(
            "SELECT MIN(created_at) as first_at, MAX(created_at) as last_at FROM events WHERE session_id = ?",
            [.text(sessionId)]
        ) { row in
            EventTimeRange(firstAt: row.string("first_at"), lastAt: row.string("last_at"))
        } ?? EventTimeRange(firstAt: nil, lastAt: nil)
    }

    public func sessionAgentTypeCounts(sessionId: String) throws -> [(subagentType: String, count: Int)] {
        try db.query(
            """
            SELECT
              COALESCE(subagent_type, 'unknown') as subagent_type,
              COUNT(*) as count
            FROM agents
            WHERE session_id = ? AND type = 'subagent'
            GROUP BY COALESCE(subagent_type, 'unknown')
            ORDER BY count DESC
            """,
            [.text(sessionId)]
        ) { row in (row.stringValue("subagent_type"), row.intValue("count")) }
    }

    public func sessionAgentStatusCounts(sessionId: String) throws -> [(status: String, count: Int)] {
        try db.query(
            "SELECT status, COUNT(*) as count FROM agents WHERE session_id = ? GROUP BY status",
            [.text(sessionId)]
        ) { row in (row.stringValue("status"), row.intValue("count")) }
    }

    public func sessionTokenTotals(sessionId: String) throws -> TokenTotals {
        try db.queryOne(
            """
            SELECT
              COALESCE(SUM(input_tokens + baseline_input), 0) as input_tokens,
              COALESCE(SUM(output_tokens + baseline_output), 0) as output_tokens,
              COALESCE(SUM(cache_read_tokens + baseline_cache_read), 0) as cache_read_tokens,
              COALESCE(SUM(cache_write_tokens + baseline_cache_write), 0) as cache_write_tokens
            FROM token_usage
            WHERE session_id = ?
            """,
            [.text(sessionId)]
        ) { row in
            TokenTotals(
                totalInput: row.intValue("input_tokens"),
                totalOutput: row.intValue("output_tokens"),
                totalCacheRead: row.intValue("cache_read_tokens"),
                totalCacheWrite: row.intValue("cache_write_tokens")
            )
        } ?? TokenTotals(totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0)
    }
}
