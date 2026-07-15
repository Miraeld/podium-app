/**
 * @file Shared session export/import-bundle logic. ROADMAP N3 — MISSING per
 * docs/N2-GAP.md (upstream hoangsonww/Claude-Code-Agent-Monitor has no
 * export.js router at all); ported/adapted from the plugin-era reference
 * server (dashboard/server/routes/export.js, READ-ONLY reference) and
 * Sources/PodiumServer/Routes/ExportRouter.swift. Backs GET
 * /api/export/session/:id and POST /api/import/session.
 *
 * Columns are read dynamically via PRAGMA table_info and intersected with
 * the bundle's keys before every INSERT — this server's schema has grown
 * several columns beyond the plugin-era reference (workflow_run_id/
 * workflow_phase on agents; speed/inference_geo/service_tier pricing
 * dimensions and compaction baselines on token_usage) and a hand-written
 * column list would either silently drop them on export or reject the
 * whole row on import. It also means an older bundle (missing a
 * since-added column) imports cleanly — the column just falls back to its
 * table default.
 */

const { db } = require("../db");

const EXPORT_VERSION = "1.0";

function tableColumns(table) {
  return db
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .map((r) => r.name);
}

/**
 * Build the exportable bundle for one session, or `null` if the session
 * doesn't exist.
 */
function buildBundle(sessionId) {
  const session = db.prepare("SELECT * FROM sessions WHERE id = ?").get(sessionId);
  if (!session) return null;

  const agents = db
    .prepare("SELECT * FROM agents WHERE session_id = ? ORDER BY started_at ASC")
    .all(sessionId);
  const events = db
    .prepare("SELECT * FROM events WHERE session_id = ? ORDER BY created_at ASC")
    .all(sessionId);
  const tokenUsage = db.prepare("SELECT * FROM token_usage WHERE session_id = ?").all(sessionId);

  return {
    podium_export_version: EXPORT_VERSION,
    exported_at: new Date().toISOString(),
    session,
    agents,
    events,
    token_usage: tokenUsage,
  };
}

/**
 * Insert `row` into `table` using only the keys both `row` and the live
 * schema agree on (unrecognized keys from a bundle produced by a newer/older
 * schema are silently dropped rather than failing the whole import).
 */
function insertRow(table, row, { orReplace = false } = {}) {
  const cols = tableColumns(table);
  const keys = Object.keys(row).filter((k) => cols.includes(k));
  if (keys.length === 0) return;
  const placeholders = keys.map(() => "?").join(", ");
  const verb = orReplace ? "INSERT OR REPLACE" : "INSERT OR IGNORE";
  const values = keys.map((k) => {
    const v = row[k];
    // `data`/`metadata` columns are stored as JSON strings; a re-exported
    // bundle may carry them as already-parsed objects — stringify anything
    // that isn't already string/number/null so the INSERT doesn't choke on
    // an object bound param.
    if (v !== null && typeof v === "object") return JSON.stringify(v);
    return v;
  });
  db.prepare(`${verb} INTO ${table} (${keys.join(", ")}) VALUES (${placeholders})`).run(...values);
}

/**
 * Import a previously-exported bundle (the shape `buildBundle` produces).
 * Runs in a single transaction so a partial failure never leaves a
 * half-imported session. Throws `Error`s carrying `.status`/`.code` on
 * malformed input — route handlers translate those into the error envelope.
 */
function importBundle(bundle) {
  if (!bundle || typeof bundle !== "object") {
    const err = new Error("Request body must be a JSON object");
    err.code = "INVALID_INPUT";
    err.status = 400;
    throw err;
  }
  if (bundle.podium_export_version !== EXPORT_VERSION) {
    const err = new Error(`Only podium_export_version "${EXPORT_VERSION}" is supported`);
    err.code = "UNSUPPORTED_VERSION";
    err.status = 400;
    throw err;
  }
  const { session, agents = [], events = [], token_usage: tokenUsage = [] } = bundle;
  if (!session || !session.id) {
    const err = new Error("bundle.session.id is required");
    err.code = "INVALID_INPUT";
    err.status = 400;
    throw err;
  }

  const run = db.transaction(() => {
    insertRow("sessions", session);
    for (const agent of agents) {
      insertRow("agents", { ...agent, session_id: agent.session_id ?? session.id });
    }
    for (const event of events) {
      insertRow("events", { ...event, session_id: event.session_id ?? session.id });
    }
    for (const t of tokenUsage) {
      insertRow("token_usage", { ...t, session_id: t.session_id ?? session.id }, { orReplace: true });
    }
  });
  run();

  return { ok: true, session_id: session.id };
}

module.exports = { EXPORT_VERSION, buildBundle, importBundle };
