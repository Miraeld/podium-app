// PodiumStore+Filters.swift — dynamic-WHERE query helpers backing the P2.2
// read routers (routes/sessions.js list+facets, routes/agents.js list,
// routes/events.js list+facets+full, routes/search.js). Kept separate from
// PodiumStore.swift (the P1.1 statement port) so the two files don't
// contend on the same lines while both are actively edited.
//
// All SQL here mirrors the referenced Node route handler's query building
// 1:1 — see the doc comment on each method for the exact source lines.

import CSQLite
import Foundation

extension PodiumStore {
    // MARK: - Sessions: dynamic WHERE list + facets

    /// One row of `listSessionsFiltered`, exposing `cost` in addition to the
    /// plain `Session` fields (rows.js attaches `row.cost` after the SQL
    /// query runs — see sessions.js lines 114–167).
    public struct SessionFilter: Sendable {
        public var q: String?
        public var status: String?
        public var cwd: String?
        public var sortBy: String
        public var sortDesc: Bool

        public init(q: String? = nil, status: String? = nil, cwd: String? = nil, sortBy: String = "time", sortDesc: Bool = true) {
            self.q = q
            self.status = status
            self.cwd = cwd
            self.sortBy = sortBy
            self.sortDesc = sortDesc
        }

        /// Builds the shared `WHERE` clause + params used by both the count
        /// query and the row query (sessions.js lines 52–75).
        fileprivate func whereClause() -> (sql: String, params: [SQLiteValue]) {
            var clauses: [String] = []
            var params: [SQLiteValue] = []

            if let q, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                let like = "%\(trimmed)%"
                clauses.append("(s.id LIKE ? OR s.name LIKE ? OR s.cwd LIKE ?)")
                params.append(contentsOf: [.text(like), .text(like), .text(like)])
            }
            if let status, !status.isEmpty {
                if status == "active" {
                    clauses.append("(s.status = 'active' OR (s.status = 'error' AND s.ended_at IS NULL))")
                } else {
                    clauses.append("s.status = ?")
                    params.append(.text(status))
                }
            }
            if let cwd, !cwd.isEmpty {
                clauses.append("s.cwd = ?")
                params.append(.text(cwd))
            }

            let sql = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            return (sql, params)
        }
    }

    /// Total count matching `filter` (sessions.js line 76 —
    /// `SELECT COUNT(*) as c FROM sessions s ${whereSql}`).
    public func countSessions(matching filter: SessionFilter) throws -> Int {
        let (whereSql, params) = filter.whereClause()
        return try db.queryOne("SELECT COUNT(*) as c FROM sessions s \(whereSql)", params) {
            $0.intValue("c")
        } ?? 0
    }

    /// Result of `listSessionsFiltered`: a `Session` with `cost` populated
    /// (sessions.js attaches `row.cost = calculateCost(...)` post-query for
    /// every branch — line-sort ("price") and SQL-sort ("time"/"duration")
    /// paths both compute it the same way, they just differ in *when* the
    /// LIMIT/OFFSET window is applied relative to the sort).
    ///
    /// Sort semantics (sessions.js lines 80–168):
    /// - `sort_by=price`: cost must be computed for **every** matching row
    ///   before sorting, since the DB can't sort by an app-computed value —
    ///   load all matching rows, compute cost, sort in Swift, then page.
    /// - `sort_by=time` (default): `ORDER BY s.updated_at {ASC|DESC}` in SQL,
    ///   LIMIT/OFFSET in SQL, cost computed only for the page.
    /// - `sort_by=duration`: `ORDER BY julianday(COALESCE(ended_at, now)) -
    ///   julianday(started_at)` in SQL, same LIMIT/OFFSET-then-cost pattern.
    public func listSessionsFiltered(matching filter: SessionFilter, limit: Int, offset: Int) throws -> [Session] {
        let (whereSql, whereParams) = filter.whereClause()

        let baseRowsSQL = """
        SELECT s.*, COUNT(a.id) as agent_count, s.updated_at as last_activity
        FROM sessions s LEFT JOIN agents a ON a.session_id = s.id
        \(whereSql)
        GROUP BY s.id
        """

        var rows: [Session]

        if filter.sortBy == "price" {
            let allRows = try db.query(baseRowsSQL, whereParams, mapSessionRow)
            guard !allRows.isEmpty else { return [] }

            let rules = try listPricing()
            let ids = allRows.map(\.id)
            let tokensBySession = try tokensBySessionChunked(ids: ids)

            var withCost: [(session: Session, cost: Double)] = allRows.map { session in
                let tokens = tokensBySession[session.id] ?? []
                let cost = tokens.isEmpty ? 0 : CostCalculator.totalCost(tokenRows: tokens, pricingRules: rules)
                return (session, cost)
            }
            withCost.sort { filter.sortDesc ? $0.cost > $1.cost : $0.cost < $1.cost }

            let page = withCost.dropFirst(offset).prefix(limit)
            rows = page.map { pair in
                var s = pair.session
                s.cost = pair.cost
                return s
            }
        } else {
            let orderSQL: String
            switch filter.sortBy {
            case "duration":
                orderSQL = "(julianday(COALESCE(s.ended_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))) - julianday(s.started_at)) \(filter.sortDesc ? "DESC" : "ASC")"
            default: // "time" and any unrecognized value fall back to updated_at, matching Node's default
                orderSQL = "s.updated_at \(filter.sortDesc ? "DESC" : "ASC")"
            }

            var params = whereParams
            params.append(.integer(Int64(limit)))
            params.append(.integer(Int64(offset)))
            let pageRows = try db.query(
                "\(baseRowsSQL) ORDER BY \(orderSQL) LIMIT ? OFFSET ?",
                params,
                mapSessionRow
            )

            if pageRows.isEmpty {
                rows = []
            } else {
                let rules = try listPricing()
                let ids = pageRows.map(\.id)
                let tokensBySession = try tokensBySessionChunked(ids: ids)
                rows = pageRows.map { session in
                    var s = session
                    let tokens = tokensBySession[session.id] ?? []
                    s.cost = tokens.isEmpty ? 0 : CostCalculator.totalCost(tokenRows: tokens, pricingRules: rules)
                    return s
                }
            }
        }

        return rows
    }

    /// `SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd != ''
    /// ORDER BY cwd` (sessions.js lines 173–178).
    public func sessionCwdFacets() throws -> [String] {
        try db.query(
            "SELECT DISTINCT cwd FROM sessions WHERE cwd IS NOT NULL AND cwd != '' ORDER BY cwd",
            []
        ) { $0.stringValue("cwd") }
    }

    /// Per-session token rows (already baseline-folded), grouped by
    /// `session_id`, chunked at 900 IDs per query to stay under SQLite's
    /// default `SQLITE_MAX_VARIABLE_NUMBER` — mirrors sessions.js's manual
    /// `for (i += 900)` chunking (lines 93–118) exactly, generalized for
    /// both the paged (limit/offset) and price-sort (all rows) call sites.
    private func tokensBySessionChunked(ids: [String]) throws -> [String: [CostTokenRow]] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: [CostTokenRow]] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 900, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let params = chunk.map { SQLiteValue.text($0) }
            let rows = try db.query(
                """
                SELECT session_id, model,
                  input_tokens + baseline_input as input_tokens,
                  output_tokens + baseline_output as output_tokens,
                  cache_read_tokens + baseline_cache_read as cache_read_tokens,
                  cache_write_tokens + baseline_cache_write as cache_write_tokens
                FROM token_usage WHERE session_id IN (\(placeholders))
                """,
                params
            ) { row -> (String, CostTokenRow) in
                let sessionId = row.stringValue("session_id")
                return (sessionId, CostTokenRow(
                    model: row.string("model") ?? "unknown",
                    inputTokens: row.intValue("input_tokens"),
                    outputTokens: row.intValue("output_tokens"),
                    cacheReadTokens: row.intValue("cache_read_tokens"),
                    cacheWriteTokens: row.intValue("cache_write_tokens")
                ))
            }
            for (sessionId, tokenRow) in rows {
                result[sessionId, default: []].append(tokenRow)
            }
            start += 900
        }
        return result
    }

    /// Row mapper shared with `mapSession` in PodiumStore.swift, duplicated
    /// here (rather than made internal there) to avoid touching that file's
    /// `private` access level while both files are under active development
    /// — same field list, `agent_count`/`last_activity` columns included.
    fileprivate func mapSessionRow(_ row: SQLiteRow) -> Session {
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

    // MARK: - Events: dynamic WHERE list + facets + full

    public struct EventFilter: Sendable {
        public var eventType: [String]?
        public var toolName: [String]?
        public var agentId: [String]?
        public var sessionId: [String]?
        public var q: String?
        /// ISO8601 lower bound (inclusive), already normalized by the caller
        /// (mirrors events.js `parseDate` — invalid strings become `nil`).
        public var from: String?
        /// ISO8601 upper bound (inclusive).
        public var to: String?

        public init(
            eventType: [String]? = nil, toolName: [String]? = nil, agentId: [String]? = nil,
            sessionId: [String]? = nil, q: String? = nil, from: String? = nil, to: String? = nil
        ) {
            self.eventType = eventType
            self.toolName = toolName
            self.agentId = agentId
            self.sessionId = sessionId
            self.q = q
            self.from = from
            self.to = to
        }

        /// Port of events.js `buildWhere` (lines 43–76).
        fileprivate func whereClause() -> (sql: String, params: [SQLiteValue]) {
            var clauses: [String] = []
            var params: [SQLiteValue] = []

            func inClause(_ field: String, _ values: [String]) {
                clauses.append("\(field) IN (\(values.map { _ in "?" }.joined(separator: ",")))")
                params.append(contentsOf: values.map { .text($0) })
            }

            if let eventType, !eventType.isEmpty { inClause("event_type", eventType) }
            if let toolName, !toolName.isEmpty { inClause("tool_name", toolName) }
            if let agentId, !agentId.isEmpty { inClause("agent_id", agentId) }
            if let sessionId, !sessionId.isEmpty { inClause("session_id", sessionId) }

            if let q, !q.isEmpty {
                let like = "%\(q)%"
                clauses.append("(summary LIKE ? OR tool_name LIKE ? OR data LIKE ?)")
                params.append(contentsOf: [.text(like), .text(like), .text(like)])
            }
            if let from {
                clauses.append("created_at >= ?")
                params.append(.text(from))
            }
            if let to {
                clauses.append("created_at <= ?")
                params.append(.text(to))
            }

            let sql = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            return (sql, params)
        }
    }

    /// events.js list handler (lines 79–102): filtered rows, newest first.
    public func listEventsFiltered(matching filter: EventFilter, limit: Int, offset: Int) throws -> [DashboardEvent] {
        let (whereSql, whereParams) = filter.whereClause()
        var params = whereParams
        params.append(.integer(Int64(limit)))
        params.append(.integer(Int64(offset)))
        return try db.query(
            "SELECT * FROM events \(whereSql) ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
            params,
            mapEventRow
        )
    }

    /// events.js count query paired with `listEventsFiltered` (line 96/99).
    public func countEventsFiltered(matching filter: EventFilter) throws -> Int {
        let (whereSql, params) = filter.whereClause()
        return try db.queryOne("SELECT COUNT(*) as count FROM events \(whereSql)", params) {
            $0.intValue("count")
        } ?? 0
    }

    /// `GET /api/events/:id/full` (events.js lines 107–125) — a single event
    /// row by integer id, `data` left as the raw TEXT column; the router
    /// layer is responsible for attempting `JSON.parse` on it, mirroring
    /// Node's try/catch-and-leave-as-string behavior.
    public func getEventFull(id: Int) throws -> DashboardEvent? {
        try db.queryOne("SELECT * FROM events WHERE id = ?", [.integer(Int64(id))], mapEventRow)
    }

    /// events.js facets handler (lines 128–142).
    public func eventFacets() throws -> (eventTypes: [String], toolNames: [String]) {
        let eventTypes = try db.query(
            "SELECT DISTINCT event_type FROM events WHERE event_type IS NOT NULL ORDER BY event_type",
            []
        ) { $0.stringValue("event_type") }
        let toolNames = try db.query(
            "SELECT DISTINCT tool_name FROM events WHERE tool_name IS NOT NULL ORDER BY tool_name",
            []
        ) { $0.stringValue("tool_name") }
        return (eventTypes, toolNames)
    }

    fileprivate func mapEventRow(_ row: SQLiteRow) -> DashboardEvent {
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

    // MARK: - Search

    /// search.js session search (lines 50–65): name/cwd LIKE match, newest
    /// `updated_at` first.
    public struct SessionSearchRow: Sendable {
        public let id: String
        public let name: String?
        public let cwd: String?
        public let status: String
        public let startedAt: String
        public let updatedAt: String?
    }

    public func searchSessions(query: String, limit: Int, offset: Int) throws -> (rows: [SessionSearchRow], total: Int) {
        let pattern = "%\(query)%"
        let rows = try db.query(
            """
            SELECT s.id, s.name, s.cwd, s.status, s.started_at, s.updated_at
            FROM sessions s
            WHERE s.name LIKE ? OR s.cwd LIKE ?
            ORDER BY s.updated_at DESC
            LIMIT ? OFFSET ?
            """,
            [.text(pattern), .text(pattern), .integer(Int64(limit)), .integer(Int64(offset))]
        ) { row in
            SessionSearchRow(
                id: row.stringValue("id"),
                name: row.string("name"),
                cwd: row.string("cwd"),
                status: row.stringValue("status"),
                startedAt: row.stringValue("started_at"),
                updatedAt: row.string("updated_at")
            )
        }
        let total = try db.queryOne(
            "SELECT COUNT(*) as c FROM sessions WHERE name LIKE ? OR cwd LIKE ?",
            [.text(pattern), .text(pattern)]
        ) { $0.intValue("c") } ?? 0
        return (rows, total)
    }

    /// search.js event search (lines 123–141): summary/tool_name/data LIKE
    /// match, joined to the owning session's name, newest `created_at` first.
    public struct EventSearchRow: Sendable {
        public let id: Int
        public let sessionId: String
        public let sessionName: String?
        public let eventType: String
        public let toolName: String?
        public let summary: String?
        public let createdAt: String
    }

    public func searchEvents(query: String, limit: Int, offset: Int) throws -> (rows: [EventSearchRow], total: Int) {
        let pattern = "%\(query)%"
        let rows = try db.query(
            """
            SELECT e.id, e.session_id, e.event_type, e.tool_name, e.summary, e.created_at,
                   s.name as session_name
            FROM events e
            LEFT JOIN sessions s ON s.id = e.session_id
            WHERE e.summary LIKE ? OR e.tool_name LIKE ? OR e.data LIKE ?
            ORDER BY e.created_at DESC
            LIMIT ? OFFSET ?
            """,
            [.text(pattern), .text(pattern), .text(pattern), .integer(Int64(limit)), .integer(Int64(offset))]
        ) { row in
            EventSearchRow(
                id: row.intValue("id"),
                sessionId: row.stringValue("session_id"),
                sessionName: row.string("session_name"),
                eventType: row.stringValue("event_type"),
                toolName: row.string("tool_name"),
                summary: row.string("summary"),
                createdAt: row.stringValue("created_at")
            )
        }
        let total = try db.queryOne(
            "SELECT COUNT(*) as c FROM events WHERE summary LIKE ? OR tool_name LIKE ? OR data LIKE ?",
            [.text(pattern), .text(pattern), .text(pattern)]
        ) { $0.intValue("c") } ?? 0
        return (rows, total)
    }

    /// Bulk per-session cost for search session hits (search.js lines 68–104):
    /// tokens for the given ids, grouped, cost computed per session.
    public func costsForSessions(ids: [String]) throws -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        let tokensBySession = try tokensBySessionChunked(ids: ids)
        guard !tokensBySession.isEmpty else { return [:] }
        let rules = try listPricing()
        var result: [String: Double] = [:]
        for (sessionId, tokens) in tokensBySession {
            result[sessionId] = CostCalculator.totalCost(tokenRows: tokens, pricingRules: rules)
        }
        return result
    }
}
