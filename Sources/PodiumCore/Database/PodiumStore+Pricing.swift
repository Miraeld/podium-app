// PodiumStore+Pricing.swift — query methods backing P3.3 (pricing + settings
// routers). Kept as its own file per the P3.3 concurrency fence (parallel
// P3.2/P4.1 agents are mid-edit on PodiumStore.swift / other files; this file
// is exclusively owned by P3.3).
//
// Covers:
//   - global + per-session cost aggregation feeding CostCalculator
//     (routes/pricing.js `GET /cost`, `GET /cost/:sessionId`)
//   - DB/table diagnostics for `GET /api/settings/info` (routes/settings.js
//     `getDbSize`, `getTableCounts`, pragma reads, `load_stats`)
//   - destructive/maintenance operations: clear-data, reset-pricing, cleanup
//     (routes/settings.js `POST /clear-data|/reset-pricing|/cleanup`)
//   - full-DB export row dumps (routes/settings.js `GET /export`)
//
// `mapSession`/`mapAgent` on `PodiumStore` are `private` to PodiumStore.swift
// (not `internal`, unlike `mapEvent`/`mapTokenUsage`), so the export queries
// below re-derive the same row → model mapping locally rather than touching
// that file (explicitly out of scope for this task).

import CSQLite
import Foundation

extension PodiumStore {
    // MARK: - Cost aggregation (routes/pricing.js `GET /cost`)

    /// `SELECT model, SUM(...) ... FROM token_usage GROUP BY model` — global
    /// per-model totals with baselines folded in, feeding
    /// `CostCalculator.calculate` for the `breakdown`/`total_cost` fields.
    public func globalTokenTotalsByModel() throws -> [CostTokenRow] {
        try db.query(
            """
            SELECT model,
              SUM(input_tokens + baseline_input) as input_tokens,
              SUM(output_tokens + baseline_output) as output_tokens,
              SUM(cache_read_tokens + baseline_cache_read) as cache_read_tokens,
              SUM(cache_write_tokens + baseline_cache_write) as cache_write_tokens
            FROM token_usage
            GROUP BY model
            """,
            []
        ) { row in
            CostTokenRow(
                model: row.string("model") ?? "unknown",
                inputTokens: row.intValue("input_tokens"),
                outputTokens: row.intValue("output_tokens"),
                cacheReadTokens: row.intValue("cache_read_tokens"),
                cacheWriteTokens: row.intValue("cache_write_tokens")
            )
        }
    }

    /// `SELECT DATE(s.started_at, ?) as date, tu.model, SUM(...) ... GROUP BY
    /// 1, tu.model` — per-day-per-model rows for `daily_costs`, bucketed by
    /// the session's `started_at` shifted by `tzModifier` (same modifier
    /// convention as `AnalyticsRouter`/`stats.js`: `"${-offsetMin} minutes"`
    /// or the literal `"+0 minutes"` fallback).
    public func dailyTokenTotalsByModel(tzModifier: String) throws -> [DailyCostTokenRow] {
        try db.query(
            """
            SELECT
              DATE(s.started_at, ?) as date,
              tu.model as model,
              SUM(tu.input_tokens + tu.baseline_input) as input_tokens,
              SUM(tu.output_tokens + tu.baseline_output) as output_tokens,
              SUM(tu.cache_read_tokens + tu.baseline_cache_read) as cache_read_tokens,
              SUM(tu.cache_write_tokens + tu.baseline_cache_write) as cache_write_tokens
            FROM token_usage tu
            JOIN sessions s ON s.id = tu.session_id
            GROUP BY 1, tu.model
            """,
            [.text(tzModifier)]
        ) { row in
            DailyCostTokenRow(
                date: row.stringValue("date"),
                row: CostTokenRow(
                    model: row.string("model") ?? "unknown",
                    inputTokens: row.intValue("input_tokens"),
                    outputTokens: row.intValue("output_tokens"),
                    cacheReadTokens: row.intValue("cache_read_tokens"),
                    cacheWriteTokens: row.intValue("cache_write_tokens")
                )
            )
        }
    }

    /// `SELECT DATE(started_at, ?) as date FROM sessions WHERE id = ?` — the
    /// single day a session's cost is attributed to for `GET
    /// /cost/:sessionId`'s one-entry `daily_costs` array. `nil` when the
    /// session doesn't exist (Node: `started` is `undefined`, `daily_costs`
    /// comes back `[]`).
    public func sessionStartDate(id: String, tzModifier: String) throws -> String? {
        try db.queryOne(
            "SELECT DATE(started_at, ?) as date FROM sessions WHERE id = ?",
            [.text(tzModifier), .text(id)]
        ) { $0.string("date") } ?? nil
    }

    // MARK: - DB/table diagnostics (routes/settings.js `GET /info`)

    /// `getTableCounts()`: row counts for `sessions`/`agents`/`events`/
    /// `model_pricing`, plus `token_usage`'s count as the number of
    /// *distinct sessions* with token rows (matches Node's `COUNT(DISTINCT
    /// session_id)`, not a raw row count).
    public func settingsTableCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in ["sessions", "agents", "events", "model_pricing"] {
            counts[table] = try db.queryOne("SELECT COUNT(*) as c FROM \(table)", []) { $0.intValue("c") } ?? 0
        }
        counts["token_usage"] = try db.queryOne(
            "SELECT COUNT(DISTINCT session_id) as c FROM token_usage", []
        ) { $0.intValue("c") } ?? 0
        return counts
    }

    /// The 6 pragmas surfaced in `SettingsInfoResponse.DbInfo.Pragmas`.
    public func readDbPragmas() throws -> SettingsInfoResponse.DbInfo.Pragmas {
        let journalMode = try db.queryOne("PRAGMA journal_mode", []) { $0.stringValue("journal_mode") } ?? "unknown"
        let synchronous = try db.queryOne("PRAGMA synchronous", []) { $0.intValue("synchronous") } ?? 0
        let autoVacuum = try db.queryOne("PRAGMA auto_vacuum", []) { $0.intValue("auto_vacuum") } ?? 0
        let encoding = try db.queryOne("PRAGMA encoding", []) { $0.stringValue("encoding") } ?? "unknown"
        let foreignKeys = try db.queryOne("PRAGMA foreign_keys", []) { $0.intValue("foreign_keys") } ?? 0
        let busyTimeout = try db.queryOne("PRAGMA busy_timeout", []) { $0.intValue("busy_timeout") } ?? 0
        return SettingsInfoResponse.DbInfo.Pragmas(
            journalMode: journalMode,
            synchronous: synchronous,
            autoVacuum: autoVacuum,
            encoding: encoding,
            foreignKeys: foreignKeys,
            busyTimeout: busyTimeout
        )
    }

    /// `getCount(ms)`: number of `events` rows created after `now - minutesAgo`.
    public func eventCount(sinceMinutesAgo minutesAgo: Int) throws -> Int {
        let cutoff = PodiumDate.format(Date().addingTimeInterval(-Double(minutesAgo) * 60))
        return try db.queryOne(
            "SELECT COUNT(*) as c FROM events WHERE created_at > ?", [.text(cutoff)]
        ) { $0.intValue("c") } ?? 0
    }

    // MARK: - Destructive/maintenance operations

    /// `POST /clear-data`: wipes `token_usage`/`events`/`agents`/`sessions`
    /// (pricing untouched) with foreign keys disabled around the batch,
    /// exactly like Node. Returns the pre-clear table counts for the
    /// response's `cleared` field.
    @discardableResult
    public func clearAllSessionData() throws -> [String: Int] {
        let counts = try settingsTableCounts()
        try db.exec("PRAGMA foreign_keys = OFF;")
        try db.run("DELETE FROM token_usage")
        try db.run("DELETE FROM events")
        try db.run("DELETE FROM agents")
        try db.run("DELETE FROM sessions")
        try db.exec("PRAGMA foreign_keys = ON;")
        return counts
    }

    /// `POST /reset-pricing`: replaces every `model_pricing` row with
    /// `Schema.defaultPricing` (`INSERT OR IGNORE`, matching Node's seed
    /// helper), returning the resulting list.
    @discardableResult
    public func resetPricingToDefaults() throws -> [ModelPricing] {
        try db.run("DELETE FROM model_pricing")
        for (pattern, name, input, output, cacheRead, cacheWrite) in Schema.defaultPricing {
            try db.run(
                """
                INSERT OR IGNORE INTO model_pricing
                  (model_pattern, display_name, input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(pattern), .text(name), .double(input), .double(output), .double(cacheRead), .double(cacheWrite)]
            )
        }
        return try listPricing()
    }

    /// `POST /cleanup` result — mirrors settings.js's `result` object.
    public struct CleanupResult: Equatable, Sendable {
        public var abandoned: Int
        public var purgedSessions: Int
        public var purgedEvents: Int
        public var purgedAgents: Int
    }

    /// `POST /cleanup`: two independent, optional operations —
    ///   1. `abandonHours`: any `active` session whose `started_at` is older
    ///      than the cutoff AND has no `events` newer than the cutoff is
    ///      marked `abandoned` (`ended_at` = now), and its lingering
    ///      `waiting`/`working` agents are marked `completed`.
    ///   2. `purgeDays`: hard-deletes `completed`/`error`/`abandoned`
    ///      sessions (never `active`) older than the cutoff, plus their
    ///      `events`/`agents`/`token_usage` rows — deleted explicitly (not
    ///      left to FK cascade) so the response can report exact counts,
    ///      matching settings.js's manual delete-then-count sequence.
    public func cleanup(abandonHours: Double?, purgeDays: Double?) throws -> CleanupResult {
        var result = CleanupResult(abandoned: 0, purgedSessions: 0, purgedEvents: 0, purgedAgents: 0)

        if let abandonHours, abandonHours > 0 {
            let cutoff = PodiumDate.format(Date().addingTimeInterval(-abandonHours * 3600))
            let staleIds = try db.query(
                """
                SELECT s.id FROM sessions s
                WHERE s.status = 'active'
                  AND s.started_at < ?
                  AND NOT EXISTS (
                    SELECT 1 FROM events e WHERE e.session_id = s.id AND e.created_at > ?
                  )
                """,
                [.text(cutoff), .text(cutoff)]
            ) { $0.stringValue("id") }

            for id in staleIds {
                try db.run(
                    "UPDATE sessions SET status = 'abandoned', ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
                    [.text(id)]
                )
                try db.run(
                    """
                    UPDATE agents SET status = 'completed', ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                    WHERE session_id = ? AND status IN ('waiting','working')
                    """,
                    [.text(id)]
                )
            }
            result.abandoned = staleIds.count
        }

        if let purgeDays, purgeDays > 0 {
            let cutoff = PodiumDate.format(Date().addingTimeInterval(-purgeDays * 86400))
            let toDelete = try db.query(
                "SELECT id FROM sessions WHERE status IN ('completed','error','abandoned') AND started_at < ?",
                [.text(cutoff)]
            ) { $0.stringValue("id") }

            if !toDelete.isEmpty {
                let placeholders = toDelete.map { _ in "?" }.joined(separator: ",")
                let params = toDelete.map { SQLiteValue.text($0) }
                result.purgedEvents = try db.run("DELETE FROM events WHERE session_id IN (\(placeholders))", params)
                result.purgedAgents = try db.run("DELETE FROM agents WHERE session_id IN (\(placeholders))", params)
                try db.run("DELETE FROM token_usage WHERE session_id IN (\(placeholders))", params)
                try db.run("DELETE FROM sessions WHERE id IN (\(placeholders))", params)
                result.purgedSessions = toDelete.count
            }
        }

        return result
    }

    // MARK: - Export (routes/settings.js `GET /export`)

    /// `SELECT * FROM sessions ORDER BY started_at DESC` — re-derives the
    /// same row mapping as `PodiumStore.mapSession` (private to
    /// PodiumStore.swift) locally; a bare `SELECT *` has no `agent_count`/
    /// `last_activity` columns so those decode to `nil`, matching Node's raw
    /// table dump exactly (those fields only exist in the hand-built list
    /// query's `SELECT`, not the `sessions` table itself).
    public func exportSessions() throws -> [Session] {
        try db.query("SELECT * FROM sessions ORDER BY started_at DESC", []) { row in
            Session(
                id: row.stringValue("id"),
                name: row.string("name"),
                status: SessionStatus(rawValue: row.stringValue("status")) ?? .active,
                cwd: row.string("cwd"),
                model: row.string("model"),
                startedAt: row.stringValue("started_at"),
                endedAt: row.string("ended_at"),
                metadata: row.string("metadata"),
                awaitingInputSince: row.string("awaiting_input_since"),
                transcriptPath: row.string("transcript_path"),
                githubPrUrl: row.string("github_pr_url"),
                updatedAt: row.string("updated_at")
            )
        }
    }

    /// `SELECT * FROM agents ORDER BY started_at DESC` (no session filter).
    public func exportAgents() throws -> [Agent] {
        try db.query("SELECT * FROM agents ORDER BY started_at DESC", []) { row in
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
    }

    /// `SELECT * FROM events ORDER BY created_at DESC` (no session filter;
    /// reuses the `internal` `mapEvent` shared with `PodiumStore+Filters`).
    public func exportEvents() throws -> [DashboardEvent] {
        try db.query("SELECT * FROM events ORDER BY created_at DESC", [], mapEvent)
    }
}

/// One (date, per-model token row) pair feeding `CostCalculator.dailyCosts`
/// — kept in PodiumCore/Database rather than Pricing/ since it's produced by
/// a store query, but consumed purely as data by `CostCalculator`.
public struct DailyCostTokenRow: Equatable, Sendable {
    public let date: String
    public let row: CostTokenRow

    public init(date: String, row: CostTokenRow) {
        self.date = date
        self.row = row
    }
}
