// Schema.swift — port of dashboard/server/db.js lines 49–442: CREATE TABLE
// statements, indexes, DEFAULT_PRICING seed + top-up, every migration in
// order, and the three startup cleanup statements.
//
// This file MUST be able to open a real dashboard.db produced by the Node
// app without data loss — every migration here mirrors the Node one
// statement-for-statement (including the try/catch "does this column exist"
// probe pattern, translated to Swift as "does this query throw").

import Foundation

public enum Schema {
    // MARK: - Table creation (db.js lines 49–156)

    static let createTablesSQL = """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      name TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed','error','abandoned')),
      cwd TEXT,
      model TEXT,
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      ended_at TEXT,
      metadata TEXT
    );

    CREATE TABLE IF NOT EXISTS agents (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'main' CHECK(type IN ('main','subagent')),
      subagent_type TEXT,
      status TEXT NOT NULL DEFAULT 'waiting' CHECK(status IN ('working','waiting','completed','error')),
      task TEXT,
      current_tool TEXT,
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      ended_at TEXT,
      parent_agent_id TEXT,
      metadata TEXT,
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
      FOREIGN KEY (parent_agent_id) REFERENCES agents(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      agent_id TEXT,
      event_type TEXT NOT NULL,
      tool_name TEXT,
      summary TEXT,
      data TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
      FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS token_usage (
      session_id TEXT NOT NULL,
      model TEXT NOT NULL DEFAULT 'unknown',
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (session_id, model),
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS model_pricing (
      model_pattern TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      input_per_mtok REAL NOT NULL DEFAULT 0,
      output_per_mtok REAL NOT NULL DEFAULT 0,
      cache_read_per_mtok REAL NOT NULL DEFAULT 0,
      cache_write_per_mtok REAL NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS push_subscriptions (
      endpoint TEXT PRIMARY KEY,
      p256dh TEXT NOT NULL,
      auth TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS dashboard_runs (
      id TEXT PRIMARY KEY,
      session_id TEXT,
      mode TEXT NOT NULL,
      cwd TEXT NOT NULL,
      model TEXT,
      permission_mode TEXT,
      effort TEXT,
      resume_session_id TEXT,
      prompt_preview TEXT,
      status TEXT NOT NULL,
      exit_code INTEGER,
      started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      ended_at TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_agents_session ON agents(session_id);
    CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
    CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
    CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
    CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
    CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at DESC);

    CREATE INDEX IF NOT EXISTS idx_events_session_type ON events(session_id, event_type);
    CREATE INDEX IF NOT EXISTS idx_agents_session_type ON agents(session_id, type);
    CREATE INDEX IF NOT EXISTS idx_dashboard_runs_started ON dashboard_runs(started_at DESC);
    CREATE INDEX IF NOT EXISTS idx_dashboard_runs_session ON dashboard_runs(session_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_error_active ON sessions(ended_at) WHERE status='error' AND ended_at IS NULL;
    """

    // MARK: - Default pricing (db.js lines 161–181)

    /// (pattern, displayName, inputPerMtok, outputPerMtok, cacheReadPerMtok, cacheWritePerMtok)
    public static let defaultPricing: [(String, String, Double, Double, Double, Double)] = [
        ("claude-opus-4-8%", "Claude Opus 4.8", 5, 25, 0.5, 6.25),
        ("claude-opus-4-7%", "Claude Opus 4.7", 5, 25, 0.5, 6.25),
        ("claude-opus-4-6%", "Claude Opus 4.6", 5, 25, 0.5, 6.25),
        ("claude-opus-4-5%", "Claude Opus 4.5", 5, 25, 0.5, 6.25),
        ("claude-opus-4-1%", "Claude Opus 4.1", 15, 75, 1.5, 18.75),
        ("claude-opus-4-2%", "Claude Opus 4", 15, 75, 1.5, 18.75),
        ("claude-sonnet-4-6%", "Claude Sonnet 4.6", 3, 15, 0.3, 3.75),
        ("claude-sonnet-4-5%", "Claude Sonnet 4.5", 3, 15, 0.3, 3.75),
        ("claude-sonnet-4-2%", "Claude Sonnet 4", 3, 15, 0.3, 3.75),
        ("claude-3-7-sonnet%", "Claude Sonnet 3.7", 3, 15, 0.3, 3.75),
        ("claude-3-5-sonnet%", "Claude Sonnet 3.5", 3, 15, 0.3, 3.75),
        ("claude-haiku-4-5%", "Claude Haiku 4.5", 1, 5, 0.1, 1.25),
        ("claude-3-5-haiku%", "Claude Haiku 3.5", 0.8, 4, 0.08, 1),
        ("claude-3-haiku%", "Claude Haiku 3", 0.25, 1.25, 0.03, 0.3),
        ("claude-3-opus%", "Claude Opus 3", 15, 75, 1.5, 18.75),
    ]

    // MARK: - Entry point

    /// Runs table creation, pricing seed/top-up, every migration (in order),
    /// and the startup cleanups. Safe to call every time the app starts —
    /// every step is idempotent, exactly like db.js's module-load-time script.
    public static func migrate(_ db: Database) throws {
        try db.exec(createTablesSQL)
        try topUpDefaultPricing(db)
        try migrateTokenUsageModelColumn(db)
        try migrateUpdatedAtColumns(db)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_sessions_status_updated ON sessions(status, updated_at DESC);")
        try migrateAwaitingInputSinceColumns(db)
        try migrateTranscriptPathColumn(db)
        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_sessions_active_tp
            ON sessions(status, transcript_path)
            WHERE status='active' AND transcript_path IS NOT NULL;
            """)
        try migrateGithubPrUrlColumn(db)
        try migrateAgentsStatusCheckConstraint(db)
        try migrateTokenUsageBaselineColumns(db)
        try startupCleanupStaleActiveSessions(db)
        try startupCleanupOrphanAgents(db)
        try startupRepairCompactionAgentTimestamps(db)
    }

    /// Returns `true` if `SELECT <column> FROM <table> LIMIT 1` succeeds —
    /// the Swift analogue of db.js's `try { db.prepare(...).get() } catch {}`
    /// "does this column exist" probe.
    private static func columnExists(_ db: Database, table: String, column: String) -> Bool {
        (try? db.exec("SELECT \(column) FROM \(table) LIMIT 1")) != nil
    }

    // MARK: - Pricing top-up (db.js lines 183–203)

    private static func topUpDefaultPricing(_ db: Database) throws {
        let existing = Set(try db.query("SELECT model_pattern FROM model_pricing", []) { row in
            row.stringValue("model_pattern")
        })
        try db.transaction { handle in
            for (pattern, name, input, output, cacheRead, cacheWrite) in defaultPricing {
                guard !existing.contains(pattern) else { continue }
                let stmt = try SQLiteStatement(
                    db: handle,
                    sql: """
                    INSERT OR IGNORE INTO model_pricing
                      (model_pattern, display_name, input_per_mtok, output_per_mtok, cache_read_per_mtok, cache_write_per_mtok)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """
                )
                try stmt.bind([
                    .text(pattern), .text(name),
                    .double(input), .double(output), .double(cacheRead), .double(cacheWrite),
                ])
                _ = try stmt.step()
            }
        }
    }

    // MARK: - Migrate: token_usage model column (db.js lines 205–235)

    private static func migrateTokenUsageModelColumn(_ db: Database) throws {
        guard !columnExists(db, table: "token_usage", column: "model") else { return }

        try db.exec("PRAGMA foreign_keys = OFF;")
        try db.exec("ALTER TABLE token_usage RENAME TO token_usage_old;")
        try db.exec("""
            CREATE TABLE token_usage (
              session_id TEXT NOT NULL,
              model TEXT NOT NULL DEFAULT 'unknown',
              input_tokens INTEGER NOT NULL DEFAULT 0,
              output_tokens INTEGER NOT NULL DEFAULT 0,
              cache_read_tokens INTEGER NOT NULL DEFAULT 0,
              cache_write_tokens INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (session_id, model),
              FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );
            """)
        try db.exec("""
            INSERT INTO token_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
              SELECT tu.session_id, COALESCE(s.model, 'unknown'), tu.input_tokens, tu.output_tokens, tu.cache_read_tokens, tu.cache_write_tokens
              FROM token_usage_old tu LEFT JOIN sessions s ON s.id = tu.session_id;
            """)
        try db.exec("DROP TABLE token_usage_old;")
        try db.exec("PRAGMA foreign_keys = ON;")
    }

    // MARK: - Migrate: updated_at columns (db.js lines 237–249)

    private static func migrateUpdatedAtColumns(_ db: Database) throws {
        if !columnExists(db, table: "sessions", column: "updated_at") {
            try db.exec("ALTER TABLE sessions ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';")
            try db.exec("UPDATE sessions SET updated_at = COALESCE(ended_at, started_at);")
        }
        if !columnExists(db, table: "agents", column: "updated_at") {
            try db.exec("ALTER TABLE agents ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';")
            try db.exec("UPDATE agents SET updated_at = COALESCE(ended_at, started_at);")
        }
    }

    // MARK: - Migrate: awaiting_input_since columns (db.js lines 256–272)

    private static func migrateAwaitingInputSinceColumns(_ db: Database) throws {
        if !columnExists(db, table: "sessions", column: "awaiting_input_since") {
            try db.exec("ALTER TABLE sessions ADD COLUMN awaiting_input_since TEXT;")
        }
        if !columnExists(db, table: "agents", column: "awaiting_input_since") {
            try db.exec("ALTER TABLE agents ADD COLUMN awaiting_input_since TEXT;")
        }
    }

    // MARK: - Migrate: transcript_path + backfill (db.js lines 274–302)

    private static func migrateTranscriptPathColumn(_ db: Database) throws {
        guard !columnExists(db, table: "sessions", column: "transcript_path") else { return }

        try db.exec("ALTER TABLE sessions ADD COLUMN transcript_path TEXT;")
        try db.exec("""
            UPDATE sessions SET transcript_path = (
              SELECT json_extract(e.data, '$.transcript_path')
              FROM events e
              WHERE e.session_id = sessions.id
                AND json_valid(e.data) = 1
                AND json_extract(e.data, '$.transcript_path') IS NOT NULL
              LIMIT 1
            ) WHERE transcript_path IS NULL;
            """)
    }

    // MARK: - Migrate: github_pr_url (db.js lines 312–320)

    private static func migrateGithubPrUrlColumn(_ db: Database) throws {
        guard !columnExists(db, table: "sessions", column: "github_pr_url") else { return }
        try db.exec("ALTER TABLE sessions ADD COLUMN github_pr_url TEXT;")
    }

    // MARK: - Migrate: agents status CHECK rebuild (db.js lines 322–377)

    private static func migrateAgentsStatusCheckConstraint(_ db: Database) throws {
        let sql: String? = try db.queryOne(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='agents'",
            []
        ) { row in row.stringValue("sql") }

        guard let tableSQL = sql, tableSQL.contains("'idle'") else { return }

        try db.exec("PRAGMA foreign_keys = OFF;")
        try db.exec("BEGIN;")
        do {
            try db.exec("""
                CREATE TABLE agents_new (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  name TEXT NOT NULL,
                  type TEXT NOT NULL DEFAULT 'main' CHECK(type IN ('main','subagent')),
                  subagent_type TEXT,
                  status TEXT NOT NULL DEFAULT 'waiting' CHECK(status IN ('working','waiting','completed','error')),
                  task TEXT,
                  current_tool TEXT,
                  started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                  ended_at TEXT,
                  parent_agent_id TEXT,
                  metadata TEXT,
                  updated_at TEXT NOT NULL DEFAULT '',
                  awaiting_input_since TEXT,
                  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                  FOREIGN KEY (parent_agent_id) REFERENCES agents(id) ON DELETE SET NULL
                );
                """)
            try db.exec("""
                INSERT INTO agents_new SELECT
                  id, session_id, name, type, subagent_type,
                  CASE status
                    WHEN 'idle' THEN 'waiting'
                    WHEN 'connected' THEN 'working'
                    ELSE status
                  END,
                  task, current_tool, started_at, ended_at, parent_agent_id, metadata,
                  updated_at, awaiting_input_since
                FROM agents;
                """)
            try db.exec("DROP TABLE agents;")
            try db.exec("ALTER TABLE agents_new RENAME TO agents;")
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            try? db.exec("PRAGMA foreign_keys = ON;")
            throw error
        }
        try db.exec("PRAGMA foreign_keys = ON;")

        try db.exec("""
            CREATE INDEX IF NOT EXISTS idx_agents_session ON agents(session_id);
            CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
            CREATE INDEX IF NOT EXISTS idx_agents_parent ON agents(parent_agent_id);
            """)
    }

    // MARK: - Migrate: token_usage baseline columns (db.js lines 379–394)

    private static func migrateTokenUsageBaselineColumns(_ db: Database) throws {
        guard !columnExists(db, table: "token_usage", column: "baseline_input") else { return }
        try db.exec("ALTER TABLE token_usage ADD COLUMN baseline_input INTEGER NOT NULL DEFAULT 0;")
        try db.exec("ALTER TABLE token_usage ADD COLUMN baseline_output INTEGER NOT NULL DEFAULT 0;")
        try db.exec("ALTER TABLE token_usage ADD COLUMN baseline_cache_read INTEGER NOT NULL DEFAULT 0;")
        try db.exec("ALTER TABLE token_usage ADD COLUMN baseline_cache_write INTEGER NOT NULL DEFAULT 0;")
    }

    // MARK: - Startup cleanups (db.js lines 396–442)

    private static func startupCleanupStaleActiveSessions(_ db: Database) throws {
        try db.exec("""
            UPDATE sessions SET
              status = 'completed',
              ended_at = COALESCE(ended_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            WHERE status = 'active'
              AND started_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 hour')
              AND NOT EXISTS (
                SELECT 1 FROM events e
                WHERE e.session_id = sessions.id
                  AND e.created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 hour')
              );
            """)
    }

    private static func startupCleanupOrphanAgents(_ db: Database) throws {
        try db.exec("""
            UPDATE agents SET
              status = 'completed',
              ended_at = COALESCE(ended_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            WHERE status IN ('working', 'waiting')
              AND session_id IN (SELECT id FROM sessions WHERE status IN ('completed', 'error', 'abandoned'));
            """)
    }

    private static func startupRepairCompactionAgentTimestamps(_ db: Database) throws {
        try db.exec("""
            UPDATE agents SET
              started_at = ended_at,
              updated_at = ended_at
            WHERE subagent_type = 'compaction'
              AND ended_at IS NOT NULL
              AND julianday(ended_at) < julianday(started_at);
            """)
    }
}
