// PodiumStore+Runs.swift — port of lib/dashboard-runs.js: persistence for
// runs spawned via `POST /api/run`. `RunSpawner` (Sources/PodiumCore/Runs/)
// mirrors every spawn/status transition into the `dashboard_runs` table
// (schema + indexes already exist from P1.1 — see Schema.swift) so the Run
// page can show full history and resume any past run after the in-memory
// handle is reaped (5 min after exit).
//
// Kept in its own file (not PodiumStore.swift) per the P4.1 concurrency
// fence — this task must never edit PodiumStore.swift directly.
//
// NOTE ON WIRE FORMAT: `DashboardRun` rows are genuinely snake_case on the
// wire (they mirror raw SQL column names, like every other DB-backed model)
// — this is the ONE type in the `/api/run` family that's fine to encode
// with `PodiumJSON.encoder`. See RunSpawner.swift's header comment for the
// contrasting camelCase live-handle family, and RunRouter.swift's
// `DashboardRunWire` for the one exception (`isLive`, added post-query).

import CSQLite
import Foundation

extension PodiumStore {
    private func mapDashboardRun(_ row: SQLiteRow) -> DashboardRun {
        DashboardRun(
            id: row.stringValue("id"),
            sessionId: row.string("session_id"),
            mode: RunMode(rawValue: row.stringValue("mode")) ?? .conversation,
            cwd: row.stringValue("cwd"),
            model: row.string("model"),
            permissionMode: row.string("permission_mode"),
            effort: row.string("effort"),
            resumeSessionId: row.string("resume_session_id"),
            promptPreview: row.string("prompt_preview"),
            status: RunStatus(rawValue: row.stringValue("status")) ?? .abandoned,
            exitCode: row.int("exit_code"),
            startedAt: row.stringValue("started_at"),
            endedAt: row.string("ended_at")
        )
    }

    /// Insert (or fully replace) a `dashboard_runs` row at spawn time.
    /// Idempotent on `id` — mirrors dashboard-runs.js's `INSERT OR REPLACE`.
    @discardableResult
    public func recordDashboardRun(
        id: String, sessionId: String?, mode: RunMode, cwd: String, model: String?,
        permissionMode: String?, effort: String?, resumeSessionId: String?, promptPreview: String?,
        status: RunStatus, exitCode: Int?, startedAt: String, endedAt: String?
    ) throws -> Int {
        try db.run(
            """
            INSERT OR REPLACE INTO dashboard_runs (
              id, session_id, mode, cwd, model, permission_mode, effort,
              resume_session_id, prompt_preview, status, exit_code, started_at, ended_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), SQLiteValue(sessionId), .text(mode.rawValue), .text(cwd), SQLiteValue(model),
                SQLiteValue(permissionMode), SQLiteValue(effort), SQLiteValue(resumeSessionId),
                SQLiteValue(promptPreview), .text(status.rawValue), SQLiteValue(exitCode),
                .text(startedAt), SQLiteValue(endedAt),
            ]
        )
    }

    /// Partial update — `nil` arguments leave the existing column untouched
    /// (COALESCE), matching dashboard-runs.js's `patchRun`.
    @discardableResult
    public func patchDashboardRun(id: String, sessionId: String? = nil, status: RunStatus? = nil, exitCode: Int? = nil, endedAt: String? = nil) throws -> Int {
        try db.run(
            """
            UPDATE dashboard_runs
            SET session_id = COALESCE(?, session_id),
                status = COALESCE(?, status),
                exit_code = COALESCE(?, exit_code),
                ended_at = COALESCE(?, ended_at)
            WHERE id = ?
            """,
            [SQLiteValue(sessionId), SQLiteValue(status?.rawValue), SQLiteValue(exitCode), SQLiteValue(endedAt), .text(id)]
        )
    }

    /// `GET /api/run/history` backing query — most recent first, capped
    /// `[1, 500]` (dashboard-runs.js's `listRuns`).
    public func listDashboardRuns(limit: Int) throws -> [DashboardRun] {
        let safeLimit = max(1, min(500, limit))
        return try db.query(
            """
            SELECT id, session_id, mode, cwd, model, permission_mode, effort,
                   resume_session_id, prompt_preview, status, exit_code, started_at, ended_at
            FROM dashboard_runs ORDER BY started_at DESC LIMIT ?
            """,
            [.integer(Int64(safeLimit))],
            mapDashboardRun
        )
    }

    public func getDashboardRun(id: String) throws -> DashboardRun? {
        try db.queryOne(
            """
            SELECT id, session_id, mode, cwd, model, permission_mode, effort,
                   resume_session_id, prompt_preview, status, exit_code, started_at, ended_at
            FROM dashboard_runs WHERE id = ?
            """,
            [.text(id)],
            mapDashboardRun
        )
    }

    /// Boot-time orphan reconciliation (dashboard-runs.js's
    /// `reconcileOrphans`): any row still `running`/`spawning` from a
    /// previous process is a orphan — the in-memory handle map was just
    /// wiped by the restart. Returns the number of rows updated.
    @discardableResult
    public func reconcileOrphanRuns() throws -> Int {
        try db.run(
            """
            UPDATE dashboard_runs
            SET status = 'abandoned',
                ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            WHERE status IN ('running', 'spawning')
            """
        )
    }

    /// Distinct recent session cwds, most-recently-active first — backs the
    /// `"recent"` entries of `GET /api/run/cwds` (routes/run.js).
    public func recentSessionCwds(limit: Int = 30) throws -> [String] {
        try db.query(
            """
            SELECT cwd, MAX(started_at) AS last_at FROM sessions
            WHERE cwd IS NOT NULL AND cwd <> ''
            GROUP BY cwd ORDER BY last_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        ) { row in row.stringValue("cwd") }
    }
}
