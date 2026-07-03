// PodiumStore+Ingest.swift — SQL helpers specific to hook ingestion
// (dashboard/server/routes/hooks.js) that don't belong in the general
// PodiumStore surface: one-shot conditional updates (github_pr_url,
// agents.task), compaction-agent timestamp stamping, and the two dedup
// existence checks hooks.js runs before inserting APIError/TurnDuration
// events. Kept in its own file (per the P2.3 concurrency fence) rather than
// touching PodiumStore.swift, which another task owns concurrently.
//
// NOTE ON TRANSACTIONS: `IngestEngine` wraps a full hook-event's worth of
// these calls in `db.exec("BEGIN")` / `db.exec("COMMIT")` rather than
// `Database.transaction(_:)`, because that helper hands the body a raw
// `OpaquePointer` and `PodiumStore`'s own methods each re-enter
// `Database.sync` (a private serial `DispatchQueue.sync`) — calling them
// from inside another `sync` closure on the same queue deadlocks. Plain
// `BEGIN`/`COMMIT` as their own top-level `db.exec(...)` calls avoids the
// nesting entirely: each statement, including every PodiumStore method call
// in between, is its own serialized hop on the same serial queue, so no
// other caller can interleave a write mid-transaction.

import CSQLite
import Foundation

extension PodiumStore {
    /// hooks.js lines 457–463: persist the first-seen GitHub PR URL sniffed
    /// from Bash output, but only if the column isn't already set.
    @discardableResult
    public func setGithubPrUrlIfUnset(sessionId: String, url: String) throws -> Int {
        try db.run(
            "UPDATE sessions SET github_pr_url = ? WHERE id = ? AND github_pr_url IS NULL",
            [.text(url), .text(sessionId)]
        )
    }

    /// hooks.js lines 698–703: set the main agent's `task` from the first
    /// user prompt, but only while it's still unset (keep the *first* prompt
    /// across the session's lifetime, not the latest).
    @discardableResult
    public func setMainAgentTaskIfUnset(sessionId: String, task: String) throws -> Int {
        try db.run(
            """
            UPDATE agents SET task = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE session_id = ? AND type = 'main' AND (task IS NULL OR task = '')
            """,
            [.text(task), .text(sessionId)]
        )
    }

    /// hooks.js lines 820–822: a compaction agent's lifecycle is
    /// instantaneous — stamp `started_at`/`updated_at` to the same
    /// transcript timestamp as `ended_at` (already set by `insertAgent`'s
    /// default) so duration is exactly 0 rather than
    /// `(ingestion wall clock) → (transcript time in the past)`, which would
    /// produce an impossible negative duration.
    @discardableResult
    public func stampCompactionTimestamps(agentId: String, timestamp: String) throws -> Int {
        try db.run(
            "UPDATE agents SET started_at = ?, ended_at = ?, updated_at = ? WHERE id = ?",
            [.text(timestamp), .text(timestamp), .text(timestamp), .text(agentId)]
        )
    }

    /// hooks.js lines 880–886: dedup guard before inserting an `APIError`
    /// event — same session + exact summary text already recorded.
    public func hasExistingAPIError(sessionId: String, summary: String) throws -> Bool {
        try db.queryOne(
            "SELECT 1 as found FROM events WHERE session_id = ? AND event_type = 'APIError' AND summary = ? LIMIT 1",
            [.text(sessionId), .text(summary)]
        ) { $0.intValue("found") } != nil
    }

    /// hooks.js lines 930–935: dedup guard before inserting a `TurnDuration`
    /// event — same session + exact `created_at` timestamp already recorded.
    public func hasExistingTurnDuration(sessionId: String, createdAt: String) throws -> Bool {
        try db.queryOne(
            "SELECT 1 as found FROM events WHERE session_id = ? AND event_type = 'TurnDuration' AND created_at = ? LIMIT 1",
            [.text(sessionId), .text(createdAt)]
        ) { $0.intValue("found") } != nil
    }
}
