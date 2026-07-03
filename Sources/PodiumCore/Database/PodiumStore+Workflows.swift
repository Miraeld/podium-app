// PodiumStore+Workflows.swift — port of dashboard/server/routes/workflows.js's
// data-fetching functions (lines 91–761) as PodiumStore query methods
// returning plain row/aggregate structs. Kept separate from PodiumStore.swift
// per the P3.4 concurrency fence (own file, no contention with other tasks).
//
// SQL here mirrors the Node handlers 1:1, including the `sessionIdFilter` /
// `statusClause` dynamic-WHERE helpers (workflows.js lines 96–108) — ported
// as `WorkflowStatusFilter` below. Node's `${sf.clause.replace("session_id",
// "<alias>.session_id")}` string surgery (used when a query joins multiple
// tables) is replaced with an explicit `alias:` parameter since Swift SQL is
// written per-query rather than templated.

import CSQLite
import Foundation

extension PodiumStore {
    /// Port of workflows.js's `statusClause`/`sessionIdFilter` helpers: an
    /// optional session-status filter ("active"/"completed"/"error"/
    /// "abandoned"), applied either directly against `sessions.status` (when
    /// the query already joins `sessions s`) or via a `session_id IN (...)`
    /// subquery (when the query only touches `agents`/`events`/`token_usage`).
    public struct WorkflowStatusFilter: Sendable {
        public let status: String?

        public init(status: String?) {
            // workflows.js: `req.query.status || null` — "all" and "" behave
            // identically to "no filter" (statusClause/sessionIdFilter both
            // special-case `!statusFilter || statusFilter === "all"`).
            if let status, !status.isEmpty, status != "all" {
                self.status = status
            } else {
                self.status = nil
            }
        }

        /// `statusClause(statusFilter, alias)` — appended directly to a query
        /// that already has `<alias> s` (or the given alias) in its FROM/JOIN.
        func statusClause(alias: String = "s") -> (sql: String, params: [SQLiteValue]) {
            guard let status else { return ("", []) }
            return (" AND \(alias).status = ?", [.text(status)])
        }

        /// `sessionIdFilter(statusFilter)` — for queries against `agents`/
        /// `events`/`token_usage` that reference `session_id` (optionally
        /// qualified by `column`, e.g. `"a1.session_id"`) directly.
        func sessionIdFilter(column: String = "session_id") -> (sql: String, params: [SQLiteValue]) {
            guard let status else { return ("", []) }
            return (" AND \(column) IN (SELECT id FROM sessions WHERE status = ?)", [.text(status)])
        }
    }

    // MARK: - durationSec (workflows.js lines 12–16)

    /// `durationSec(s)`: `started_at` → `ended_at ?? now`, in seconds, floored
    /// at 0. `startedAt` absent → 0 (mirrors `if (!s.started_at) return 0`).
    static func durationSec(startedAt: String?, endedAt: String?) -> Double {
        guard let startedAt, let start = PodiumDate.parse(startedAt) else { return 0 }
        let end = endedAt.flatMap(PodiumDate.parse) ?? Date()
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - getWorkflowStats (workflows.js lines 110–196)

    public struct WorkflowStatsRow: Sendable {
        public let totalSessions: Int
        public let totalAgents: Int
        public let totalSubagents: Int
        public let completedAgents: Int
        public let errorAgents: Int
        public let depthRows: [(sessionId: String, maxDepth: Int)]
        public let finishedSessionDurations: [(startedAt: String?, endedAt: String?)]
        public let totalCompactions: Int
        public let topFlow: (source: String, target: String, count: Int)?
    }

    public func workflowStats(filter: WorkflowStatusFilter) throws -> WorkflowStatsRow {
        let sf = filter.sessionIdFilter()
        let ss = filter.statusClause()

        let totalSessions = try db.queryOne(
            "SELECT COUNT(*) as c FROM sessions s WHERE 1=1\(ss.sql)", ss.params
        ) { $0.intValue("c") } ?? 0

        let totalAgents = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE 1=1\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        let totalSubagents = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE type = 'subagent'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        let completedAgents = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE status = 'completed'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        let errorAgents = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE status = 'error'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        let depthRows = try db.query(
            """
            WITH RECURSIVE agent_depth AS (
              SELECT id, session_id, parent_agent_id, 0 as depth FROM agents WHERE parent_agent_id IS NULL
              UNION ALL
              SELECT a.id, a.session_id, a.parent_agent_id, ad.depth + 1
              FROM agents a JOIN agent_depth ad ON a.parent_agent_id = ad.id
            )
            SELECT session_id, MAX(depth) as max_depth FROM agent_depth
            WHERE 1=1\(sf.sql)
            GROUP BY session_id
            """,
            sf.params
        ) { row in (row.stringValue("session_id"), row.intValue("max_depth")) }

        let sessionDurations = try db.query(
            "SELECT started_at, ended_at FROM sessions s WHERE ended_at IS NOT NULL\(ss.sql)", ss.params
        ) { row in (row.string("started_at"), row.string("ended_at")) }

        let totalCompactions = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE subagent_type = 'compaction'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        // topFlow (workflows.js lines 170–182): sessionIdFilter clause
        // rewritten to qualify `e1.session_id` instead of the bare column.
        let sfE1 = filter.sessionIdFilter(column: "e1.session_id")
        let topFlow = try db.queryOne(
            """
            SELECT e1.tool_name as source, e2.tool_name as target, COUNT(*) as c
             FROM events e1
             JOIN events e2 ON e2.session_id = e1.session_id AND e2.id = (
               SELECT MIN(e3.id) FROM events e3
               WHERE e3.session_id = e1.session_id AND e3.id > e1.id AND e3.tool_name IS NOT NULL
             )
             WHERE e1.tool_name IS NOT NULL AND e2.tool_name IS NOT NULL\(sfE1.sql)
             GROUP BY e1.tool_name, e2.tool_name
             ORDER BY c DESC LIMIT 1
            """,
            sfE1.params
        ) { row in (row.stringValue("source"), row.stringValue("target"), row.intValue("c")) }

        return WorkflowStatsRow(
            totalSessions: totalSessions,
            totalAgents: totalAgents,
            totalSubagents: totalSubagents,
            completedAgents: completedAgents,
            errorAgents: errorAgents,
            depthRows: depthRows,
            finishedSessionDurations: sessionDurations,
            totalCompactions: totalCompactions,
            topFlow: topFlow
        )
    }

    // MARK: - getOrchestrationData (workflows.js lines 198–266)

    public struct OrchestrationRow: Sendable {
        public let sessionCount: Int
        public let mainCount: Int
        public let subagentTypes: [(subagentType: String, count: Int, completed: Int, errors: Int)]
        public let edges: [(source: String, target: String, weight: Int)]
        public let outcomes: [(status: String, count: Int)]
        public let compactionsBySession: [(sessionId: String, count: Int)]
    }

    public func orchestrationData(filter: WorkflowStatusFilter) throws -> OrchestrationRow {
        let sf = filter.sessionIdFilter()
        let ss = filter.statusClause()

        let sessionCount = try db.queryOne(
            "SELECT COUNT(*) as c FROM sessions s WHERE 1=1\(ss.sql)", ss.params
        ) { $0.intValue("c") } ?? 0

        let mainCount = try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE type = 'main'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0

        let subagentTypes = try db.query(
            """
            SELECT subagent_type, COUNT(*) as count,
              SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
              SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as errors
             FROM agents WHERE type = 'subagent' AND subagent_type IS NOT NULL\(sf.sql)
             GROUP BY subagent_type ORDER BY count DESC
            """,
            sf.params
        ) { row in (row.stringValue("subagent_type"), row.intValue("count"), row.intValue("completed"), row.intValue("errors")) }

        let sfA = filter.sessionIdFilter(column: "a.session_id")
        let edges = try db.query(
            """
            SELECT
              COALESCE(p.subagent_type, 'main') as source,
              a.subagent_type as target,
              COUNT(*) as weight
             FROM agents a
             LEFT JOIN agents p ON a.parent_agent_id = p.id
             WHERE a.type = 'subagent' AND a.subagent_type IS NOT NULL\(sfA.sql)
             GROUP BY source, target
             ORDER BY weight DESC
            """,
            sfA.params
        ) { row in (row.stringValue("source"), row.stringValue("target"), row.intValue("weight")) }

        let outcomes = try db.query(
            """
            SELECT status, COUNT(*) as count FROM agents
             WHERE status IN ('completed', 'error')\(sf.sql)
             GROUP BY status
            """,
            sf.params
        ) { row in (row.stringValue("status"), row.intValue("count")) }

        let compactions = try db.query(
            """
            SELECT session_id, COUNT(*) as count
             FROM agents WHERE subagent_type = 'compaction'\(sf.sql)
             GROUP BY session_id
            """,
            sf.params
        ) { row in (row.stringValue("session_id"), row.intValue("count")) }

        return OrchestrationRow(
            sessionCount: sessionCount,
            mainCount: mainCount,
            subagentTypes: subagentTypes,
            edges: edges,
            outcomes: outcomes,
            compactionsBySession: compactions
        )
    }

    // MARK: - getToolFlowData (workflows.js lines 268–297)

    public func toolFlowTransitions(filter: WorkflowStatusFilter) throws -> [(source: String, target: String, value: Int)] {
        let sfE1 = filter.sessionIdFilter(column: "e1.session_id")
        return try db.query(
            """
            SELECT e1.tool_name as source, e2.tool_name as target, COUNT(*) as value
             FROM events e1
             JOIN events e2 ON e2.session_id = e1.session_id AND e2.id = (
               SELECT MIN(e3.id) FROM events e3
               WHERE e3.session_id = e1.session_id AND e3.id > e1.id AND e3.tool_name IS NOT NULL
             )
             WHERE e1.tool_name IS NOT NULL AND e2.tool_name IS NOT NULL\(sfE1.sql)
             GROUP BY e1.tool_name, e2.tool_name
             ORDER BY value DESC
             LIMIT 50
            """,
            sfE1.params
        ) { row in (row.stringValue("source"), row.stringValue("target"), row.intValue("value")) }
    }

    public func toolFlowCounts(filter: WorkflowStatusFilter) throws -> [(toolName: String, count: Int)] {
        let sf = filter.sessionIdFilter()
        return try db.query(
            """
            SELECT tool_name, COUNT(*) as count FROM events
             WHERE tool_name IS NOT NULL\(sf.sql)
             GROUP BY tool_name ORDER BY count DESC LIMIT 15
            """,
            sf.params
        ) { row in (row.stringValue("tool_name"), row.intValue("count")) }
    }

    // MARK: - getSubagentEffectiveness (workflows.js lines 299–363)

    public struct SubagentEffectivenessRow: Sendable {
        public let subagentType: String
        public let total: Int
        public let completed: Int
        public let errors: Int
        public let sessions: Int
        public let avgDuration: Double?
        /// 7-slot [Mon..Sun] counts, already remapped from SQLite's %w
        /// (0=Sun) — see `sessionAgentEffectivenessTrend`.
        public let trend: [Int]
    }

    /// `types` query (workflows.js lines 302–316): top 12 subagent types by
    /// total count, with completed/errors/distinct-session counts.
    public func subagentEffectivenessTypes(filter: WorkflowStatusFilter) throws -> [(subagentType: String, total: Int, completed: Int, errors: Int, sessions: Int)] {
        let sfA = filter.sessionIdFilter(column: "a.session_id")
        return try db.query(
            """
            SELECT
              a.subagent_type,
              COUNT(*) as total,
              SUM(CASE WHEN a.status = 'completed' THEN 1 ELSE 0 END) as completed,
              SUM(CASE WHEN a.status = 'error' THEN 1 ELSE 0 END) as errors,
              COUNT(DISTINCT a.session_id) as sessions
             FROM agents a
             WHERE a.type = 'subagent' AND a.subagent_type IS NOT NULL\(sfA.sql)
             GROUP BY a.subagent_type
             ORDER BY total DESC
             LIMIT 12
            """,
            sfA.params
        ) { row in
            (row.stringValue("subagent_type"), row.intValue("total"), row.intValue("completed"), row.intValue("errors"), row.intValue("sessions"))
        }
    }

    /// Average duration for one subagent type (workflows.js lines 321–330).
    /// Uses `julianday` diff in days * 86400 → seconds, `NULL` when
    /// `ended_at IS NULL` for that row (excluded from the AVG, matching SQL's
    /// NULL-skipping aggregate semantics).
    public func subagentEffectivenessAvgDuration(subagentType: String, filter: WorkflowStatusFilter) throws -> Double? {
        let sf = filter.sessionIdFilter()
        return try db.queryOne(
            """
            SELECT AVG(
              CASE WHEN ended_at IS NOT NULL THEN
                (julianday(ended_at) - julianday(started_at)) * 86400
              ELSE NULL END
            ) as avg_duration
            FROM agents WHERE subagent_type = ? AND type = 'subagent'\(sf.sql)
            """,
            [.text(subagentType)] + sf.params
        ) { $0.double("avg_duration") } ?? nil
    }

    /// Weekly trend (workflows.js lines 335–348): count per day-of-week over
    /// the last 56 days, remapped from SQLite's `%w` (0=Sun..6=Sat) to a
    /// Mon-first 7-slot array via `(dow + 6) % 7`.
    public func subagentEffectivenessTrend(subagentType: String, filter: WorkflowStatusFilter) throws -> [Int] {
        let sf = filter.sessionIdFilter()
        let rows = try db.query(
            """
            SELECT CAST(strftime('%w', started_at) AS INTEGER) as dow, COUNT(*) as count
             FROM agents WHERE subagent_type = ? AND type = 'subagent'
               AND started_at >= date('now', '-56 days')\(sf.sql)
             GROUP BY dow ORDER BY dow ASC
            """,
            [.text(subagentType)] + sf.params
        ) { row in (row.intValue("dow"), row.intValue("count")) }

        var trendByDay = [Int](repeating: 0, count: 7)
        for (dow, count) in rows {
            let idx = (dow + 6) % 7 // Sun(0)->6, Mon(1)->0, Tue(2)->1, ...
            trendByDay[idx] = count
        }
        return trendByDay
    }

    // MARK: - getWorkflowPatterns (workflows.js lines 365–434)

    /// Ordered subagent_type sequence per session (workflows.js lines
    /// 369–382): sessions with >= 2 subagents, sequence joined with "→".
    public func workflowPatternSequences(filter: WorkflowStatusFilter) throws -> [(sessionId: String, sequence: String)] {
        let sf = filter.sessionIdFilter()
        // GROUP_CONCAT has no guaranteed ordering unless the input rows are
        // pre-sorted (SQLite concatenates in the order rows arrive from the
        // subquery) — the subquery's `ORDER BY session_id, started_at ASC`
        // establishes that order, matching db.js/better-sqlite3 exactly.
        return try db.query(
            """
            SELECT session_id, GROUP_CONCAT(subagent_type, '→') as sequence
             FROM (
               SELECT session_id, subagent_type
               FROM agents
               WHERE type = 'subagent' AND subagent_type IS NOT NULL\(sf.sql)
               ORDER BY session_id, started_at ASC
             )
             GROUP BY session_id
             HAVING COUNT(*) >= 2
            """,
            sf.params
        ) { row in (row.stringValue("session_id"), row.stringValue("sequence")) }
    }

    public func totalSessionsCount(filter: WorkflowStatusFilter) throws -> Int {
        let ss = filter.statusClause()
        return try db.queryOne("SELECT COUNT(*) as c FROM sessions s WHERE 1=1\(ss.sql)", ss.params) { $0.intValue("c") } ?? 0
    }

    /// Sessions with zero subagents (workflows.js lines 422–427).
    public func soloSessionCount(filter: WorkflowStatusFilter) throws -> Int {
        let ss = filter.statusClause()
        return try db.queryOne(
            """
            SELECT COUNT(*) as c FROM sessions s
             WHERE NOT EXISTS (SELECT 1 FROM agents a WHERE a.session_id = s.id AND a.type = 'subagent')\(ss.sql)
            """,
            ss.params
        ) { $0.intValue("c") } ?? 0
    }

    // MARK: - getModelDelegation (workflows.js lines 436–474)

    public func modelDelegationMainModels(filter: WorkflowStatusFilter) throws -> [(model: String, agentCount: Int, sessionCount: Int)] {
        let ss = filter.statusClause()
        return try db.query(
            """
            SELECT s.model, COUNT(DISTINCT a.id) as agent_count, COUNT(DISTINCT s.id) as session_count
             FROM agents a JOIN sessions s ON a.session_id = s.id
             WHERE a.type = 'main' AND s.model IS NOT NULL\(ss.sql)
             GROUP BY s.model ORDER BY agent_count DESC
            """,
            ss.params
        ) { row in (row.stringValue("model"), row.intValue("agent_count"), row.intValue("session_count")) }
    }

    public func modelDelegationSubagentModels(filter: WorkflowStatusFilter) throws -> [(model: String, agentCount: Int)] {
        let ss = filter.statusClause()
        return try db.query(
            """
            SELECT s.model, COUNT(a.id) as agent_count
             FROM agents a JOIN sessions s ON a.session_id = s.id
             WHERE a.type = 'subagent' AND s.model IS NOT NULL\(ss.sql)
             GROUP BY s.model ORDER BY agent_count DESC
            """,
            ss.params
        ) { row in (row.stringValue("model"), row.intValue("agent_count")) }
    }

    public func modelDelegationTokensByModel(filter: WorkflowStatusFilter) throws -> [(model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int)] {
        let sfToken = filter.sessionIdFilter()
        return try db.query(
            """
            SELECT model,
              SUM(input_tokens + baseline_input) as input_tokens,
              SUM(output_tokens + baseline_output) as output_tokens,
              SUM(cache_read_tokens + baseline_cache_read) as cache_read_tokens,
              SUM(cache_write_tokens + baseline_cache_write) as cache_write_tokens
             FROM token_usage WHERE 1=1\(sfToken.sql)
             GROUP BY model ORDER BY (input_tokens + output_tokens) DESC
            """,
            sfToken.params
        ) { row in
            (row.stringValue("model"), row.intValue("input_tokens"), row.intValue("output_tokens"), row.intValue("cache_read_tokens"), row.intValue("cache_write_tokens"))
        }
    }

    // MARK: - getErrorPropagation (workflows.js lines 476–564)

    public func errorsByDepth(filter: WorkflowStatusFilter) throws -> [(depth: Int, count: Int)] {
        let sf = filter.sessionIdFilter()
        return try db.query(
            """
            WITH RECURSIVE agent_depth AS (
              SELECT id, session_id, subagent_type, status, 0 as depth
              FROM agents WHERE parent_agent_id IS NULL
              UNION ALL
              SELECT a.id, a.session_id, a.subagent_type, a.status, ad.depth + 1
              FROM agents a JOIN agent_depth ad ON a.parent_agent_id = ad.id
            )
            SELECT depth, COUNT(*) as count FROM agent_depth
            WHERE status = 'error'\(sf.sql)
            GROUP BY depth ORDER BY depth ASC
            """,
            sf.params
        ) { row in (row.intValue("depth"), row.intValue("count")) }
    }

    /// Sessions whose status is 'error' but whose main agent isn't flagged
    /// error (workflows.js lines 499–507) — folded into depth 0 by the
    /// router (see `WorkflowsRouter.getErrorPropagation`).
    public func sessionErrorsNotInAgents(filter: WorkflowStatusFilter) throws -> Int {
        let ss = filter.statusClause()
        return try db.queryOne(
            """
            SELECT COUNT(*) as c FROM sessions s
             WHERE s.status = 'error'\(ss.sql)
               AND NOT EXISTS (
                 SELECT 1 FROM agents a WHERE a.session_id = s.id AND a.status = 'error'
               )
            """,
            ss.params
        ) { $0.intValue("c") } ?? 0
    }

    public func errorPropagationByType(filter: WorkflowStatusFilter) throws -> [(subagentType: String, count: Int)] {
        let sf = filter.sessionIdFilter()
        return try db.query(
            """
            SELECT subagent_type, COUNT(*) as count
             FROM agents WHERE status = 'error' AND subagent_type IS NOT NULL\(sf.sql)
             GROUP BY subagent_type ORDER BY count DESC LIMIT 5
            """,
            sf.params
        ) { row in (row.stringValue("subagent_type"), row.intValue("count")) }
    }

    public func errorPropagationEventErrors(filter: WorkflowStatusFilter) throws -> [(summary: String, count: Int)] {
        let sfE = filter.sessionIdFilter(column: "e.session_id")
        return try db.query(
            """
            SELECT e.summary, COUNT(*) as count
             FROM events e
             WHERE ((e.event_type = 'Stop' AND e.summary LIKE 'Error in%')
                OR e.event_type = 'APIError')\(sfE.sql)
             GROUP BY e.summary ORDER BY count DESC LIMIT 10
            """,
            sfE.params
        ) { row in (row.stringValue("summary"), row.intValue("count")) }
    }

    /// `sessionsWithErrors` (workflows.js lines 539–551): UNION of
    /// (session-level error status) ∪ (any agent error) ∪ (any error event),
    /// counted distinct. Ported as three separate `sessionIdFilter()`
    /// applications matching each UNION branch's parameter binding order
    /// exactly (`...ss.params, ...sf.params, ...sf.params` in the original).
    public func sessionsWithErrorsCount(filter: WorkflowStatusFilter) throws -> Int {
        let ss = filter.statusClause()
        let sf = filter.sessionIdFilter()
        return try db.queryOne(
            """
            SELECT COUNT(DISTINCT id) as c FROM (
              SELECT id FROM sessions s WHERE s.status = 'error'\(ss.sql)
              UNION
              SELECT DISTINCT session_id as id FROM agents WHERE status = 'error'\(sf.sql)
              UNION
              SELECT DISTINCT session_id as id FROM events
              WHERE ((event_type = 'Stop' AND summary LIKE 'Error in%')
                 OR event_type = 'APIError')\(sf.sql)
            )
            """,
            ss.params + sf.params + sf.params
        ) { $0.intValue("c") } ?? 0
    }

    // MARK: - getConcurrencyData (workflows.js lines 566–616)

    public struct ConcurrencyAgentRow: Sendable {
        public let name: String
        public let status: String
        public let startedAt: String?
        public let endedAt: String?
        public let sessionStart: String?
        public let sessionEnd: String?
    }

    /// Raw lanes (workflows.js lines 571–583): agents in sessions that have
    /// ended, up to 2000 rows, ordered by `a.started_at ASC`. Aggregation
    /// into `typeAgg`/`aggregateLanes` happens in the router (pure Swift, no
    /// SQL needed for that part — port lines 585–615 there).
    public func concurrencyLaneAgents(filter: WorkflowStatusFilter) throws -> [(type: String, subagentType: String?, name: String, status: String, startedAt: String?, endedAt: String?, sessionStart: String?, sessionEnd: String?)] {
        let ss = filter.statusClause()
        return try db.query(
            """
            SELECT
              a.id, a.name, a.type, a.subagent_type, a.status,
              a.started_at, a.ended_at, a.session_id,
              s.started_at as session_start, s.ended_at as session_end
             FROM agents a
             JOIN sessions s ON a.session_id = s.id
             WHERE s.ended_at IS NOT NULL\(ss.sql)
             ORDER BY a.started_at ASC
             LIMIT 2000
            """,
            ss.params
        ) { row in
            (
                row.stringValue("type"), row.string("subagent_type"), row.stringValue("name"), row.stringValue("status"),
                row.string("started_at"), row.string("ended_at"), row.string("session_start"), row.string("session_end")
            )
        }
    }

    // MARK: - getSessionComplexity (workflows.js lines 618–660)

    public func sessionComplexityRows(filter: WorkflowStatusFilter) throws -> [(id: String, name: String?, status: String, startedAt: String?, endedAt: String?, agentCount: Int, subagentCount: Int, model: String?)] {
        let ss = filter.statusClause()
        return try db.query(
            """
            SELECT
              s.id, s.name, s.status, s.started_at, s.ended_at, s.model,
              COUNT(a.id) as agent_count,
              SUM(CASE WHEN a.type = 'subagent' THEN 1 ELSE 0 END) as subagent_count
             FROM sessions s
             LEFT JOIN agents a ON a.session_id = s.id
             WHERE 1=1\(ss.sql)
             GROUP BY s.id
             ORDER BY s.started_at DESC
             LIMIT 200
            """,
            ss.params
        ) { row in
            (
                row.stringValue("id"), row.string("name"), row.stringValue("status"),
                row.string("started_at"), row.string("ended_at"),
                row.intValue("agent_count"), row.intValue("subagent_count"), row.string("model")
            )
        }
    }

    /// Total token count for one session (workflows.js lines 639–645).
    public func sessionTotalTokens(sessionId: String) throws -> Int {
        try db.queryOne(
            """
            SELECT SUM(input_tokens + baseline_input + output_tokens + baseline_output +
                        cache_read_tokens + baseline_cache_read + cache_write_tokens + baseline_cache_write) as total
             FROM token_usage WHERE session_id = ?
            """,
            [.text(sessionId)]
        ) { $0.intValue("total") } ?? 0
    }

    // MARK: - getCompactionImpact (workflows.js lines 662–706)

    public func compactionTotalCount(filter: WorkflowStatusFilter) throws -> Int {
        let sf = filter.sessionIdFilter()
        return try db.queryOne(
            "SELECT COUNT(*) as c FROM agents WHERE subagent_type = 'compaction'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0
    }

    public func compactionTokensRecovered(filter: WorkflowStatusFilter) throws -> Int {
        let sf = filter.sessionIdFilter()
        return try db.queryOne(
            """
            SELECT SUM(baseline_input + baseline_output + baseline_cache_read + baseline_cache_write) as total
             FROM token_usage WHERE 1=1\(sf.sql)
            """,
            sf.params
        ) { $0.intValue("total") } ?? 0
    }

    public func compactionPerSession(filter: WorkflowStatusFilter) throws -> [(sessionId: String, compactions: Int)] {
        let sf = filter.sessionIdFilter()
        return try db.query(
            """
            SELECT session_id, COUNT(*) as compactions
             FROM agents WHERE subagent_type = 'compaction'\(sf.sql)
             GROUP BY session_id ORDER BY compactions DESC LIMIT 50
            """,
            sf.params
        ) { row in (row.stringValue("session_id"), row.intValue("compactions")) }
    }

    public func compactionSessionsWithCompactionsCount(filter: WorkflowStatusFilter) throws -> Int {
        let sf = filter.sessionIdFilter()
        return try db.queryOne(
            "SELECT COUNT(DISTINCT session_id) as c FROM agents WHERE subagent_type = 'compaction'\(sf.sql)", sf.params
        ) { $0.intValue("c") } ?? 0
    }

    // MARK: - getAgentCooccurrence (workflows.js lines 708–732)

    public func agentCooccurrencePairs(filter: WorkflowStatusFilter) throws -> [(source: String, target: String, weight: Int)] {
        let sfA1 = filter.sessionIdFilter(column: "a1.session_id")
        return try db.query(
            """
            SELECT a1.subagent_type as source, a2.subagent_type as target,
                   COUNT(*) as weight
             FROM agents a1
             JOIN agents a2 ON a1.session_id = a2.session_id
               AND a1.started_at < a2.started_at
               AND a1.id != a2.id
             WHERE a1.type = 'subagent' AND a2.type = 'subagent'
               AND a1.subagent_type IS NOT NULL AND a2.subagent_type IS NOT NULL
               AND a1.subagent_type != 'compaction' AND a2.subagent_type != 'compaction'\(sfA1.sql)
             GROUP BY a1.subagent_type, a2.subagent_type
             HAVING weight >= 2
             ORDER BY weight DESC
             LIMIT 40
            """,
            sfA1.params
        ) { row in (row.stringValue("source"), row.stringValue("target"), row.intValue("weight")) }
    }

    // MARK: - GET /session/:id support (workflows.js lines 42–85, 734–759)

    /// All events for a session ordered `created_at ASC, id ASC` — distinct
    /// from `listEventsBySession` (P1.1/P2.2), which orders DESC for the
    /// sessions-detail feed. workflows.js line 50–52 uses ASC explicitly for
    /// the drill-in timeline.
    public func listEventsBySessionAscending(sessionId: String) throws -> [DashboardEvent] {
        try db.query(
            "SELECT * FROM events WHERE session_id = ? ORDER BY created_at ASC, id ASC",
            [.text(sessionId)],
            mapEvent
        )
    }
}
