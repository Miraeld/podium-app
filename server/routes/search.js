/**
 * @file Express router for full-text search across sessions and events.
 * GET /api/search?q=<query>&limit=20&offset=0
 *
 * Ported from the plugin-era reference server
 * (dashboard/server/routes/search.js) per ROADMAP N3 — upstream
 * (hoangsonww/Claude-Code-Agent-Monitor) has no search route at all
 * (docs/N2-GAP.md). Searches sessions by name/cwd and events by
 * summary/tool_name/data using SQLite LIKE queries. Returns up to
 * `limit` sessions + `limit` events (default/max 20 each), combined and
 * sorted by recency. Shape matches `client/src/pages/Search.tsx`'s
 * `SearchResponse`/`SearchResult` types exactly.
 */

const { Router } = require("express");
const { db, stmts } = require("../db");

const router = Router();

const MAX_PER_TYPE = 20;
const HIGHLIGHT_WINDOW = 100; // chars of context around the match

/**
 * Extract a ~HIGHLIGHT_WINDOW-char snippet around the first occurrence of
 * `query` (case-insensitive) in `text`, with the match itself wrapped in
 * `<mark>` tags — the client's `Highlight` component
 * (`client/src/pages/Search.tsx`) splits on `<mark>…</mark>` to render the
 * emphasized span, never using `dangerouslySetInnerHTML`. Returns null if no
 * match found.
 * @param {string|null} text
 * @param {string} query
 * @returns {string|null}
 */
function buildHighlight(text, query) {
  if (!text || !query) return null;
  const lower = text.toLowerCase();
  const idx = lower.indexOf(query.toLowerCase());
  if (idx === -1) return null;
  const start = Math.max(0, idx - Math.floor(HIGHLIGHT_WINDOW / 2));
  const end = Math.min(text.length, idx + query.length + Math.floor(HIGHLIGHT_WINDOW / 2));
  const before = text.slice(start, idx);
  const match = text.slice(idx, idx + query.length);
  const after = text.slice(idx + query.length, end);
  let snippet = `${before}<mark>${match}</mark>${after}`;
  if (start > 0) snippet = "…" + snippet;
  if (end < text.length) snippet = snippet + "…";
  return snippet;
}

// GET /api/search?q=<query>&limit=20&offset=0
router.get("/", (req, res) => {
  const q = typeof req.query.q === "string" ? req.query.q.trim() : "";
  if (!q) {
    return res.json({ results: [], total: 0 });
  }

  const limit = Math.min(parseInt(req.query.limit, 10) || MAX_PER_TYPE, MAX_PER_TYPE);
  const offset = Math.max(0, parseInt(req.query.offset, 10) || 0);
  const pattern = `%${q}%`;

  // ── Session search ──────────────────────────────────────────────────────
  const sessionRows = db
    .prepare(
      `SELECT s.id, s.name, s.cwd, s.status, s.started_at, s.updated_at
       FROM sessions s
       WHERE s.name LIKE ? OR s.cwd LIKE ?
       ORDER BY s.updated_at DESC
       LIMIT ? OFFSET ?`
    )
    .all(pattern, pattern, limit, offset);

  const sessionCountRow = db
    .prepare(`SELECT COUNT(*) as c FROM sessions WHERE name LIKE ? OR cwd LIKE ?`)
    .get(pattern, pattern);
  const sessionTotal = sessionCountRow ? sessionCountRow.c : 0;

  // Fetch costs for matched sessions in bulk (harmless extra field on the
  // wire — the client's SessionSearchResult type doesn't require it, but it
  // doesn't hurt to include for a future UI).
  let sessionCosts = {};
  if (sessionRows.length > 0) {
    const ids = sessionRows.map((r) => r.id);
    const placeholders = ids.map(() => "?").join(",");
    const tokenRows = db
      .prepare(
        `SELECT session_id, model,
           input_tokens + baseline_input as input_tokens,
           output_tokens + baseline_output as output_tokens,
           cache_read_tokens + baseline_cache_read as cache_read_tokens,
           cache_write_tokens + baseline_cache_write as cache_write_tokens
         FROM token_usage WHERE session_id IN (${placeholders})`
      )
      .all(...ids);
    const rules = stmts.listPricing.all();
    const bySession = {};
    for (const t of tokenRows) {
      if (!bySession[t.session_id]) bySession[t.session_id] = [];
      bySession[t.session_id].push(t);
    }
    for (const [sid, tokens] of Object.entries(bySession)) {
      let cost = 0;
      for (const t of tokens) {
        const rule = rules.find(
          (r) =>
            t.model && t.model.toLowerCase().startsWith(r.model_pattern.replace(/%$/, "").toLowerCase())
        );
        if (!rule) continue;
        cost +=
          (t.input_tokens / 1_000_000) * rule.input_per_mtok +
          (t.output_tokens / 1_000_000) * rule.output_per_mtok +
          (t.cache_read_tokens / 1_000_000) * rule.cache_read_per_mtok +
          (t.cache_write_tokens / 1_000_000) * rule.cache_write_per_mtok;
      }
      sessionCosts[sid] = cost;
    }
  }

  const sessionResults = sessionRows.map((s) => ({
    type: "session",
    session_id: s.id,
    session_name: s.name,
    cwd: s.cwd,
    status: s.status,
    cost: sessionCosts[s.id] || 0,
    started_at: s.started_at,
    highlight: buildHighlight(s.name, q) || buildHighlight(s.cwd, q) || s.name || s.cwd,
    _sort_key: s.updated_at || s.started_at || "",
  }));

  // ── Event search ────────────────────────────────────────────────────────
  const eventRows = db
    .prepare(
      `SELECT e.id, e.session_id, e.event_type, e.tool_name, e.summary, e.created_at,
              s.name as session_name
       FROM events e
       LEFT JOIN sessions s ON s.id = e.session_id
       WHERE e.summary LIKE ? OR e.tool_name LIKE ? OR e.data LIKE ?
       ORDER BY e.created_at DESC
       LIMIT ? OFFSET ?`
    )
    .all(pattern, pattern, pattern, limit, offset);

  const eventCountRow = db
    .prepare(`SELECT COUNT(*) as c FROM events WHERE summary LIKE ? OR tool_name LIKE ? OR data LIKE ?`)
    .get(pattern, pattern, pattern);
  const eventTotal = eventCountRow ? eventCountRow.c : 0;

  const eventResults = eventRows.map((e) => ({
    type: "event",
    session_id: e.session_id,
    session_name: e.session_name,
    event_id: e.id,
    event_type: e.event_type,
    tool_name: e.tool_name,
    summary: e.summary,
    created_at: e.created_at,
    _sort_key: e.created_at || "",
  }));

  // ── Combine and sort by recency ─────────────────────────────────────────
  const combined = [...sessionResults, ...eventResults];
  combined.sort((a, b) => {
    if (a._sort_key > b._sort_key) return -1;
    if (a._sort_key < b._sort_key) return 1;
    return 0;
  });

  for (const r of combined) {
    delete r._sort_key;
  }

  const total = sessionTotal + eventTotal;

  res.json({ results: combined, total });
});

module.exports = router;
