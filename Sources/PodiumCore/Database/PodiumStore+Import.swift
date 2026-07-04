// PodiumStore+Import.swift — every raw SQL query `LegacyImporter` (port of
// scripts/import-history.js) and the P3.2 background services (periodic
// stale-session sweep, compaction scan, watchdog, stuck-agent check) need
// beyond what PodiumStore.swift already exposes. Kept in its own file per
// the P3.2 task's concurrency fence — PodiumStore.swift itself is owned by
// an earlier task and must not be touched.
//
// Two categories of new query here:
//   1. Historical-timestamp writers (setSessionStartEnd/setAgentStartEnd/…):
//      PodiumStore.insertSession/insertAgent/insertEvent always stamp "now"
//      (correct for live hook ingestion), but the importer must write the
//      REAL historical timestamps recovered from JSONL — exactly like
//      import-history.js's separate `UPDATE ... SET started_at = ?, ended_at
//      = ?` follow-up statements after each `stmts.insertX.run(...)`.
//   2. Idempotency/dedup lookups (eventSummaryExists, liveSubagentIdBy…):
//      port of the `stmts.getAgent.get(id)` / raw `db.prepare(...).get(...)`
//      existence checks sprinkled through import-history.js so re-running an
//      import never duplicates rows.

import CSQLite
import Foundation

extension PodiumStore {
    // MARK: - Historical-timestamp writers

    /// `UPDATE sessions SET started_at = ?, ended_at = ? WHERE id = ?` —
    /// unconditional (NOT `COALESCE`), matching import-history.js's raw
    /// follow-up statement after `stmts.insertSession.run(...)`.
    @discardableResult
    public func setSessionStartEnd(id: String, startedAt: String?, endedAt: String?) throws -> Int {
        try db.run(
            "UPDATE sessions SET started_at = ?, ended_at = ? WHERE id = ?",
            [SQLiteValue(startedAt), SQLiteValue(endedAt), .text(id)]
        )
    }

    /// `UPDATE sessions SET ended_at = ? WHERE id = ?` — used by the
    /// existing-session backfill path once the caller has already decided
    /// (in Swift) that the JSONL's `endedAt` is genuinely newer.
    @discardableResult
    public func setSessionEndedAt(id: String, endedAt: String) throws -> Int {
        try db.run("UPDATE sessions SET ended_at = ? WHERE id = ?", [.text(endedAt), .text(id)])
    }

    /// `UPDATE agents SET started_at = ?, ended_at = ? WHERE id = ?` — the
    /// 2-column variant import-history.js uses for the main agent and team
    /// subagents right after `stmts.insertAgent.run(...)`.
    @discardableResult
    public func setAgentStartEnd(id: String, startedAt: String?, endedAt: String?) throws -> Int {
        try db.run(
            "UPDATE agents SET started_at = ?, ended_at = ? WHERE id = ?",
            [SQLiteValue(startedAt), SQLiteValue(endedAt), .text(id)]
        )
    }

    /// `UPDATE agents SET started_at = ?, ended_at = ?, updated_at = ? WHERE
    /// id = ?` — the 3-column variant used for compaction agents, Agent-tool
    /// subagents, and JSONL-imported subagents.
    @discardableResult
    public func setAgentStartEndUpdated(id: String, startedAt: String, endedAt: String, updatedAt: String) throws -> Int {
        try db.run(
            "UPDATE agents SET started_at = ?, ended_at = ?, updated_at = ? WHERE id = ?",
            [.text(startedAt), .text(endedAt), .text(updatedAt), .text(id)]
        )
    }

    /// Insert an event with an EXPLICIT historical `created_at` rather than
    /// `strftime('now')` — the importer's core primitive, since every
    /// backfilled event must land at the real moment it happened (message
    /// timestamp, tool-use timestamp, compaction timestamp, …), not at
    /// import time. Port of import-history.js's raw 7-arg
    /// `insertEvent.run(session_id, agent_id, event_type, tool_name,
    /// summary, data, created_at)`.
    @discardableResult
    public func insertEventAt(
        sessionId: String, agentId: String?, eventType: String, toolName: String?,
        summary: String?, data: String?, createdAt: String
    ) throws -> Int64 {
        try db.sync { handle in
            let stmt = try SQLiteStatement(
                db: handle,
                sql: """
                INSERT INTO events (session_id, agent_id, event_type, tool_name, summary, data, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            try stmt.bind([
                .text(sessionId), SQLiteValue(agentId), .text(eventType),
                SQLiteValue(toolName), SQLiteValue(summary), SQLiteValue(data), .text(createdAt),
            ])
            _ = try stmt.step()
            return sqlite3_last_insert_rowid(handle)
        }
    }

    // MARK: - Idempotency / dedup lookups

    /// Per-event-type "high water mark" for a session — the newest
    /// `created_at` already stored for each `event_type`. Port of
    /// import-history.js's `cutoffRows` query (lines 912–918): any JSONL
    /// entry whose timestamp is strictly greater than this cutoff is
    /// unambiguously new and safe to insert on a re-import.
    public func eventTypeCutoffs(sessionId: String) throws -> [String: String] {
        let rows = try db.query(
            "SELECT event_type, MAX(created_at) AS m FROM events WHERE session_id = ? GROUP BY event_type",
            [.text(sessionId)]
        ) { row in (row.stringValue("event_type"), row.string("m")) }
        var result: [String: String] = [:]
        for (type, max) in rows {
            if let max { result[type] = max }
        }
        return result
    }

    /// `SELECT 1 FROM events WHERE session_id = ? AND event_type = ? AND
    /// summary = ? LIMIT 1` — dedup check for `importApiErrors`.
    public func eventSummaryExists(sessionId: String, eventType: String, summary: String) throws -> Bool {
        try db.queryOne(
            "SELECT 1 FROM events WHERE session_id = ? AND event_type = ? AND summary = ? LIMIT 1",
            [.text(sessionId), .text(eventType), .text(summary)]
        ) { _ in true } ?? false
    }

    /// `SELECT 1 FROM events WHERE agent_id = ? AND event_type = ? AND data
    /// LIKE ? LIMIT 1` — dedup check for per-tool-call subagent JSONL
    /// events (`importSubagentFromJsonl`'s `eventExists` prepared statement).
    public func eventDataLikeExists(agentId: String, eventType: String, dataLike likePattern: String) throws -> Bool {
        try db.queryOne(
            "SELECT 1 FROM events WHERE agent_id = ? AND event_type = ? AND data LIKE ? LIMIT 1",
            [.text(agentId), .text(eventType), .text(likePattern)]
        ) { _ in true } ?? false
    }

    /// `SELECT 1 FROM events WHERE session_id = ? AND agent_id = ? AND
    /// event_type = 'PreToolUse' AND tool_name = 'Agent' AND data LIKE ?
    /// LIMIT 1` — dedup check for the "subagent spawned (from JSONL)"
    /// marker event under the main agent.
    public func spawnEventExists(sessionId: String, agentId: String, dataLike likePattern: String) throws -> Bool {
        try db.queryOne(
            """
            SELECT 1 FROM events
             WHERE session_id = ? AND agent_id = ? AND event_type = 'PreToolUse'
               AND tool_name = 'Agent' AND data LIKE ? LIMIT 1
            """,
            [.text(sessionId), .text(agentId), .text(likePattern)]
        ) { _ in true } ?? false
    }

    /// Primary `findLiveSubagentForJsonl` match: a live subagent (created by
    /// the PreToolUse "Agent" hook) whose stored `spawn_tool_use_id` matches
    /// the JSONL-derived subagent's own tool_use id — a reliable 1:1 link
    /// even when several same-typed subagents run concurrently.
    public func liveSubagentIdBySpawnToolUseId(sessionId: String, excludeIdPrefix: String, toolUseId: String) throws -> String? {
        try db.queryOne(
            """
            SELECT id FROM agents
             WHERE session_id = ?
               AND type = 'subagent'
               AND id NOT LIKE ?
               AND metadata LIKE ?
             LIMIT 1
            """,
            [
                .text(sessionId), .text("\(excludeIdPrefix)%"),
                .text("%\"spawn_tool_use_id\":\"\(toolUseId)\"%"),
            ]
        ) { $0.stringValue("id") }
    }

    /// Fallback `findLiveSubagentForJsonl` match: timing + subagent-type
    /// heuristic for older agent records that predate `spawn_tool_use_id`
    /// storage (also matches a `NULL` `subagent_type` against
    /// `"general-purpose"`, since the harness defaults to that).
    public func liveSubagentIdByTiming(
        sessionId: String, subagentType: String, excludeIdPrefix: String, startedAt: String, toleranceSeconds: Int
    ) throws -> String? {
        try db.queryOne(
            """
            SELECT id FROM agents
             WHERE session_id = ?
               AND type = 'subagent'
               AND (subagent_type = ? OR (subagent_type IS NULL AND ? = 'general-purpose'))
               AND id NOT LIKE ?
               AND ABS(CAST(strftime('%s', started_at) AS INTEGER) -
                       CAST(strftime('%s', ?) AS INTEGER)) <= ?
             ORDER BY ABS(CAST(strftime('%s', started_at) AS INTEGER) -
                          CAST(strftime('%s', ?) AS INTEGER)) ASC
             LIMIT 1
            """,
            [
                .text(sessionId), .text(subagentType), .text(subagentType), .text("\(excludeIdPrefix)%"),
                .text(startedAt), .integer(Int64(toleranceSeconds)), .text(startedAt),
            ]
        ) { $0.stringValue("id") }
    }

    // MARK: - F1: import-time file skip cache

    /// One row of `import_file_cache` — the (mtime, size) fingerprint
    /// recorded the last time `LegacyImporter` actually parsed this file.
    public struct ImportFileCacheEntry: Sendable, Equatable {
        public let mtimeMs: Double
        public let size: Int64
    }

    /// Batch fetch so `importFromDirectory`/`backfillCompactions` do ONE
    /// query for the whole corpus instead of one per file — the file-level
    /// skip check itself must stay cheap even when nothing changed.
    public func importFileCacheEntries(paths: [String]) throws -> [String: ImportFileCacheEntry] {
        guard !paths.isEmpty else { return [:] }
        let placeholders = paths.map { _ in "?" }.joined(separator: ",")
        let rows = try db.query(
            "SELECT path, mtime_ms, size FROM import_file_cache WHERE path IN (\(placeholders))",
            paths.map { .text($0) }
        ) { row in
            (row.stringValue("path"), ImportFileCacheEntry(mtimeMs: row.doubleValue("mtime_ms"), size: Int64(row.intValue("size"))))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Records that `path` was fully parsed/imported at this (mtime, size) —
    /// called only after a file's import succeeded (no thrown error), so a
    /// failed parse/import is retried on every subsequent run rather than
    /// silently cached as "done".
    @discardableResult
    public func upsertImportFileCache(path: String, mtimeMs: Double, size: Int64) throws -> Int {
        try db.run(
            """
            INSERT INTO import_file_cache (path, mtime_ms, size, imported_at)
            VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            ON CONFLICT(path) DO UPDATE SET
              mtime_ms = excluded.mtime_ms, size = excluded.size, imported_at = excluded.imported_at
            """,
            [.text(path), .double(mtimeMs), .integer(size)]
        )
    }

    // MARK: - F1: batched import transactions

    /// Opens a plain `BEGIN` as its own top-level `db.exec` call — NOT
    /// `Database.transaction(_:)`, for the same reentrancy reason documented
    /// in `PodiumStore+Ingest.swift`: every `PodiumStore` method re-enters
    /// `Database.sync` (a serial `DispatchQueue.sync`), which deadlocks if
    /// called from inside another `sync` closure. Plain top-level
    /// `BEGIN`/`COMMIT` calls let each store method in between stay its own
    /// serialized hop on the same queue while still sharing one SQLite
    /// transaction. Callers MUST keep the window between `beginImportBatch`
    /// and `commitImportBatch` short (see `LegacyImporter.ImportBatch`) —
    /// the DB queue is shared with live hook ingestion, and any write that
    /// gets interleaved onto the queue while a batch is open becomes part of
    /// THAT transaction (and would be rolled back with it on failure).
    public func beginImportBatch() throws { try db.exec("BEGIN;") }

    public func commitImportBatch() throws { try db.exec("COMMIT;") }

    /// Best-effort rollback; ignores a "no transaction active" error so
    /// callers can call this unconditionally in a cleanup path.
    public func rollbackImportBatch() { try? db.exec("ROLLBACK;") }

    // MARK: - Periodic sweep (stale sessions + compaction scan)

    /// Batch-completes every non-terminal agent belonging to the given
    /// (already-determined-stale) session ids in one statement — port of
    /// index.js's sweep batch UPDATE (avoids an N+1 query per stale
    /// session).
    @discardableResult
    public func completeNonTerminalAgents(sessionIds: [String], endedAt: String, updatedAt: String) throws -> Int {
        guard !sessionIds.isEmpty else { return 0 }
        let placeholders = sessionIds.map { _ in "?" }.joined(separator: ",")
        var params: [SQLiteValue] = [.text(endedAt), .text(updatedAt)]
        params.append(contentsOf: sessionIds.map { .text($0) })
        return try db.run(
            """
            UPDATE agents SET status = 'completed', ended_at = COALESCE(ended_at, ?), updated_at = ?
             WHERE session_id IN (\(placeholders)) AND status NOT IN ('completed', 'error')
            """,
            params
        )
    }

    /// One row of `activeSessionTranscriptPaths()`.
    public struct ActiveSessionTranscript: Sendable, Equatable {
        public let sessionId: String
        public let transcriptPath: String
    }

    /// Sessions eligible for the sweep's compaction scan: active (or
    /// error-but-still-running), with a known transcript path — port of
    /// index.js's `active` query (lines 372–376).
    public func activeSessionTranscriptPaths() throws -> [ActiveSessionTranscript] {
        try db.query(
            """
            SELECT id AS session_id, transcript_path AS tp
              FROM sessions
             WHERE (status = 'active' OR (status = 'error' AND ended_at IS NULL))
               AND transcript_path IS NOT NULL
             ORDER BY updated_at DESC
            """,
            []
        ) { row in ActiveSessionTranscript(sessionId: row.stringValue("session_id"), transcriptPath: row.stringValue("tp")) }
    }

    // MARK: - Watchdog (API-error detection for stalled active sessions)

    /// One candidate session for the watchdog check.
    public struct WatchdogCandidate: Sendable, Equatable {
        public let id: String
        public let cwd: String?
        /// Raw JSON `data` blob of the most recent lifecycle event, if any —
        /// used to recover `transcript_path` (hooks.js lines 1069–1074).
        public let lastEventData: String?
    }

    /// Active sessions whose `updated_at` is older than `cutoff` — port of
    /// hooks.js's `watchdogCheck` query (lines 1069–1080; `last_event` is
    /// selected in Node but never read afterward, so it's omitted here).
    public func watchdogCandidates(cutoff: String) throws -> [WatchdogCandidate] {
        try db.query(
            """
            SELECT s.id, s.cwd,
                   (SELECT e.data FROM events e WHERE e.session_id = s.id
                    AND e.event_type IN ('SessionStart','UserPromptSubmit','PreToolUse','Stop','Notification')
                    ORDER BY e.created_at DESC LIMIT 1) as last_data
              FROM sessions s
             WHERE s.status = 'active' AND s.updated_at < ?
            """,
            [.text(cutoff)]
        ) { row in WatchdogCandidate(id: row.stringValue("id"), cwd: row.string("cwd"), lastEventData: row.string("last_data")) }
    }

    /// Count of `APIError` events already recorded for a session — used to
    /// decide whether the watchdog found anything genuinely new.
    public func apiErrorEventCount(sessionId: String) throws -> Int {
        try db.queryOne(
            "SELECT COUNT(*) as cnt FROM events WHERE session_id = ? AND event_type = 'APIError'",
            [.text(sessionId)]
        ) { $0.intValue("cnt") } ?? 0
    }

    /// Every `APIError` summary already recorded for a session, for
    /// dedup — port of hooks.js's `existingSummaries` batch fetch.
    public func apiErrorSummaries(sessionId: String) throws -> Set<String> {
        Set(try db.query(
            "SELECT summary FROM events WHERE session_id = ? AND event_type = 'APIError'",
            [.text(sessionId)]
        ) { $0.stringValue("summary") })
    }

    // MARK: - Stuck-agent check

    /// One candidate session for the stuck-agent check.
    public struct StuckCandidate: Sendable, Equatable {
        public let id: String
        public let updatedAt: String
    }

    /// Active sessions whose `updated_at` is older than `cutoff` — port of
    /// hooks.js's `stuckAgentCheck` query (lines 1188–1194).
    public func stuckSessionCandidates(cutoff: String) throws -> [StuckCandidate] {
        try db.query(
            "SELECT id, updated_at FROM sessions WHERE status = 'active' AND updated_at < ? AND updated_at != ''",
            [.text(cutoff)]
        ) { row in StuckCandidate(id: row.stringValue("id"), updatedAt: row.stringValue("updated_at")) }
    }
}
