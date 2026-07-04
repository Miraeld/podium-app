// PodiumStore+SessionBundle.swift — SQL for the per-SESSION export/import
// bundle (port of dashboard/server/routes/export.js), as distinct from
// `PodiumStore+Pricing.swift`'s `exportSessions()`/`exportAgents()`/etc,
// which back the FULL-DB dump at `GET /api/settings/export` (a completely
// different feature — see `Routes/SettingsRouter.swift`'s doc comment and
// this task's own report for the confirmed distinction against the Node
// reference).
//
// Kept in its own file (not touching PodiumStore.swift, another task's
// fence) per the same P4.3/P3.2 convention `PodiumStore+Import.swift`
// established: new raw SQL a dependent task needs goes in a `PodiumStore+X`
// extension file.

import CSQLite
import Foundation

extension PodiumStore {
    // MARK: - Export (routes/export.js `GET /session/:id`)

    /// `SELECT * FROM agents WHERE session_id = ? ORDER BY started_at ASC`
    /// (export.js line 30 — ASCENDING, unlike `listAgentsBySession`'s
    /// `DESC`, since export.js orders chronologically for the bundle).
    public func exportAgentsBySessionAscending(sessionId: String) throws -> [Agent] {
        try db.query(
            "SELECT * FROM agents WHERE session_id = ? ORDER BY started_at ASC",
            [.text(sessionId)]
        ) { row in
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

    /// `SELECT * FROM events WHERE session_id = ? ORDER BY created_at ASC`
    /// (export.js line 34).
    public func exportEventsBySessionAscending(sessionId: String) throws -> [DashboardEvent] {
        try db.query(
            "SELECT * FROM events WHERE session_id = ? ORDER BY created_at ASC",
            [.text(sessionId)],
            mapEvent
        )
    }

    /// `SELECT * FROM token_usage WHERE session_id = ?` (export.js line 38) —
    /// raw current + baseline columns, NOT `getTokensBySession`'s
    /// pre-folded projection (that shape is for cost math, this one is for
    /// a byte-for-byte re-importable bundle).
    public func exportTokenUsageBySession(sessionId: String) throws -> [TokenUsage] {
        try db.query("SELECT * FROM token_usage WHERE session_id = ?", [.text(sessionId)]) { row in
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
    }

    // MARK: - Import (routes/export.js `POST /session`)
    //
    // IMPORTANT: every helper below takes the transaction's raw `handle`
    // and binds/steps a `SQLiteStatement` directly against it — it must
    // NOT call `db.run`/`db.query`/etc. `Database.sync` is a serial
    // `DispatchQueue.sync`, and `db.transaction { handle in ... }` already
    // runs its closure ON that queue (see `Database.transaction`'s own doc
    // comment: "body receives the raw handle so it can prepare/run further
    // statements without re-entering `sync` (which would deadlock)").
    // Calling `db.run` from inside here would recursively `sync` onto a
    // queue already draining synchronously — libdispatch traps that
    // (`SIGTRAP`) rather than hanging silently. `importSessionBundle` is
    // the only public entry point; these row-level helpers are private.

    /// `INSERT OR IGNORE INTO sessions (<dynamic column list>) VALUES (...)`
    /// — export.js builds the column list dynamically from the bundle's
    /// `session` object so an older export (missing a newer column like
    /// `github_pr_url`) still imports. This port takes the already-decoded
    /// `Session` model instead of a raw dynamic column set — every column
    /// the current schema has is always written (any that didn't exist in
    /// an older bundle simply decode to `nil`/defaults on the `Session`
    /// model already, so the net effect is the same: a missing column in
    /// the source JSON never blocks the import).
    private func importSessionRow(_ session: Session, handle: OpaquePointer) throws {
        let stmt = try SQLiteStatement(
            db: handle,
            sql: """
            INSERT OR IGNORE INTO sessions
              (id, name, status, cwd, model, started_at, ended_at, metadata,
               awaiting_input_since, transcript_path, github_pr_url, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try stmt.bind([
            .text(session.id), SQLiteValue(session.name), .text(session.status.rawValue),
            SQLiteValue(session.cwd), SQLiteValue(session.model), .text(session.startedAt),
            SQLiteValue(session.endedAt), SQLiteValue(session.metadata),
            SQLiteValue(session.awaitingInputSince), SQLiteValue(session.transcriptPath),
            SQLiteValue(session.githubPrUrl), SQLiteValue(session.updatedAt ?? ""),
        ])
        _ = try stmt.step()
    }

    /// `INSERT OR IGNORE INTO agents (...)` — export.js lines 94–117,
    /// defaulting `type`/`status` the same way (`"main"`/`"completed"`) when
    /// the bundle's agent object omits them (shouldn't happen from our own
    /// exporter, but an externally-hand-edited bundle might).
    private func importAgentRow(_ agent: Agent, fallbackSessionId: String, handle: OpaquePointer) throws {
        let stmt = try SQLiteStatement(
            db: handle,
            sql: """
            INSERT OR IGNORE INTO agents
              (id, session_id, name, type, subagent_type, status, task, current_tool,
               started_at, ended_at, parent_agent_id, metadata, updated_at, awaiting_input_since)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try stmt.bind([
            .text(agent.id), .text(agent.sessionId.isEmpty ? fallbackSessionId : agent.sessionId),
            .text(agent.name), .text(agent.type.rawValue), SQLiteValue(agent.subagentType),
            .text(agent.status.rawValue), SQLiteValue(agent.task), SQLiteValue(agent.currentTool),
            .text(agent.startedAt), SQLiteValue(agent.endedAt), SQLiteValue(agent.parentAgentId),
            SQLiteValue(agent.metadata), .text(agent.updatedAt), SQLiteValue(agent.awaitingInputSince),
        ])
        _ = try stmt.step()
    }

    /// `INSERT OR IGNORE INTO events (...)` — export.js lines 120–143.
    /// `id` is included explicitly (unlike live ingestion's
    /// autoincrement-only `insertEvent`) so re-importing the same bundle
    /// twice is idempotent via `OR IGNORE` on the primary key, matching
    /// Node's behavior exactly.
    private func importEventRow(_ event: DashboardEvent, fallbackSessionId: String, handle: OpaquePointer) throws {
        let stmt = try SQLiteStatement(
            db: handle,
            sql: """
            INSERT OR IGNORE INTO events
              (id, session_id, agent_id, event_type, tool_name, summary, data, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try stmt.bind([
            event.id.map { SQLiteValue.integer(Int64($0)) } ?? .null,
            .text(event.sessionId.isEmpty ? fallbackSessionId : event.sessionId),
            SQLiteValue(event.agentId), .text(event.eventType), SQLiteValue(event.toolName),
            SQLiteValue(event.summary), SQLiteValue(event.data), .text(event.createdAt),
        ])
        _ = try stmt.step()
    }

    /// `INSERT OR REPLACE INTO token_usage (...)` — export.js lines 146–165
    /// (upsert semantics, unlike sessions/agents/events' `OR IGNORE`,
    /// matching Node exactly: a re-import always wins for token counts).
    private func importTokenUsageRow(_ usage: TokenUsage, fallbackSessionId: String, handle: OpaquePointer) throws {
        let stmt = try SQLiteStatement(
            db: handle,
            sql: """
            INSERT OR REPLACE INTO token_usage
              (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
               baseline_input, baseline_output, baseline_cache_read, baseline_cache_write)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try stmt.bind([
            .text(usage.sessionId.isEmpty ? fallbackSessionId : usage.sessionId), .text(usage.model),
            .integer(Int64(usage.inputTokens)), .integer(Int64(usage.outputTokens)),
            .integer(Int64(usage.cacheReadTokens)), .integer(Int64(usage.cacheWriteTokens)),
            .integer(Int64(usage.baselineInput)), .integer(Int64(usage.baselineOutput)),
            .integer(Int64(usage.baselineCacheRead)), .integer(Int64(usage.baselineCacheWrite)),
        ])
        _ = try stmt.step()
    }

    /// Runs the full session-bundle import in one transaction (export.js's
    /// `db.transaction(...)` wrapper) — all-or-nothing so a partial failure
    /// never leaves half-imported rows.
    public func importSessionBundle(_ bundle: SessionExportBundle) throws {
        try db.transaction { handle in
            try self.importSessionRow(bundle.session, handle: handle)
            for agent in bundle.agents { try self.importAgentRow(agent, fallbackSessionId: bundle.session.id, handle: handle) }
            for event in bundle.events { try self.importEventRow(event, fallbackSessionId: bundle.session.id, handle: handle) }
            for usage in bundle.tokenUsage { try self.importTokenUsageRow(usage, fallbackSessionId: bundle.session.id, handle: handle) }
        }
    }
}
