# Podium Standalone — Master Plan & Task Tracker

> **Goal:** Turn PodiumSwiftApp into a fully standalone macOS + Linux application with
> **every feature of Podium** (the Claude Code plugin), with **zero dependency on the
> plugin or Node.js at runtime**.
>
> This file is the single source of truth across runs. Each task has a status, and a
> complete, self-contained prompt for a Sonnet dev agent. **Update the status + Run Log
> after every task completes.**

- **This repo:** `/Users/gaelrobin/Desktop/PodiumSwiftApp` (branch `develop`)
- **Reference source (read-only):** `/Users/gaelrobin/Desktop/Work/Claude/podium`
- **Plan author:** Claude Fable 5 — 2026-07-03

---

## 0. Resuming this project in a fresh session (any account, any model)

This file is self-sufficient — no conversation history or memory files needed.
An orchestrator picking this up cold should:

1. Read §1 (architecture), §4 (working agreements — binding), §5 (task board),
   §6b (product decisions), §7 (run log, bottom-up for the latest state).
2. **Reconcile 🟦 tasks first.** 🟦 means an agent was dispatched; if your session
   just started, that agent is dead. Its partial work IS committed (this repo has
   an auto-commit hook — check `git log --oneline -20` for `Auto-commit:` entries
   naming the task's files) but possibly unfinished. Verify with `swift build &&
   swift test`: if green and the task's deliverables look complete, mark ✅ with a
   run-log note "completed by earlier session, verified"; otherwise re-dispatch
   the task's prompt from §6 *plus* one line telling the dev to first audit
   existing partial work in its owned paths and continue, not restart.
3. Dispatch the next unblocked ⬜ task(s): spawn `general-purpose` agents on
   model `sonnet`, prompt = §6.0 shared preamble + the task prompt, verbatim.
   Parallel agents share the checkout — always give each an explicit
   "YOU OWN / DO NOT TOUCH" path fence (see the P2.2/P2.3 prompts for the
   pattern) and never let two agents own the same file.
4. After every completion: flip the board, append to the run log (result +
   hand-off notes for dependent tasks), commit this file.
   **Two orchestrator sessions in parallel:** the board is the lock. Before
   dispatching, set the task to 🟦 with your session tag (e.g. 🟦@A / 🟦@B) and
   commit+push this file immediately; only dispatch tasks whose path fences don't
   overlap another session's 🟦 tasks. Pull before every board edit.
5. Hardening gates between phases (working agreement #8): run a code review over
   the phase's diff + a contract sanity check against the React client before
   opening the next phase.

State that lives OUTSIDE this file (same machine only): auto-memory in
`~/.claude/projects/-Users-gaelrobin-Desktop-PodiumSwiftApp/memory/` (product
principles are duplicated here in §4/§6b, so losing memory loses nothing
critical); the vendored web client in `WebClient/dist`; CI in
`.github/workflows/ci.yml`.

---

## 1. Architecture (decided with Gaël, 2026-07-03)

**One Swift package, four products:**

| Target | Platforms | Role |
|---|---|---|
| `PodiumCore` (lib) | macOS + Linux | Models, SQLite store (schema + migrations), pricing, hook-event ingestion logic, transcript/JSONL parsing, analytics queries, ~/.claude discovery, hook installer. **No UI, no Apple-only APIs.** |
| `PodiumServer` (lib) | macOS + Linux | Hummingbird 2 HTTP server: full REST API (parity with Node server), WebSocket broadcast hub, static serving of the bundled React dashboard. |
| `podium-server` (exe) | macOS + Linux | Headless daemon CLI. On Linux this **is** the app: it serves the glassmorphism web dashboard in the browser. |
| `podium-hook` (exe) | macOS + Linux | Tiny native replacement for `hook.mjs`: reads hook JSON on stdin, POSTs to `/api/hooks/event`, hard 1.5 s deadline. Installed to `~/.claude/podium/`. |
| `PodiumApp` (exe) | macOS only | The native SwiftUI glassmorphism app. Embeds `PodiumServer` **in-process** (no separate daemon needed on macOS). |

**Key decisions:**

1. **Swift runs great on Linux** — only SwiftUI doesn't. So Core + Server + CLI are
   cross-platform; SwiftUI is the macOS premium experience.
2. **Glassmorphism on both platforms:** native materials on macOS (SwiftUI app);
   the existing React dashboard (already glass-styled, black/gold Podium brand) served
   by the Swift server for Linux/browser use. The web client is **vendored as built
   assets** — reused, not rewritten.
3. **Standalone ingestion:** the app/daemon installs its own hooks into
   `~/.claude/settings.json` (global), pointing at the native `podium-hook` binary.
   No plugin, no Node. Plus one-time legacy import + periodic JSONL sweeps for
   compaction events (same as Node server).
4. **SQLite:** thin custom wrapper over the system C API (`CSQLite` system-library
   target). No third-party ORM — deterministic Linux support, zero deps.
5. **HTTP/WS:** Hummingbird 2.x + hummingbird-websocket (SwiftNIO, first-class Linux).
6. **DB compatibility:** identical schema/paths semantics to Node
   (`DASHBOARD_DB_PATH` / `DASHBOARD_DATA_DIR` env, WAL mode) so an existing
   `dashboard.db` from the plugin opens unchanged in the Swift app.
7. **Scope: everything, phased.** Core observability first; run-spawner, web-push,
   import/export come later; nothing dropped.

---

## 2. Feature inventory (from audit of Podium v1.4.0)

### 2.1 Database schema (dashboard/server/db.js — must be ported 1:1)

Tables: `sessions` (id, name, status[active|completed|error|abandoned], cwd, model,
started_at, ended_at, metadata, updated_at, awaiting_input_since, transcript_path,
github_pr_url) · `agents` (id, session_id, name, type[main|subagent], subagent_type,
status[working|waiting|completed|error], task, current_tool, started_at, ended_at,
parent_agent_id, metadata, updated_at, awaiting_input_since) · `events` (id, session_id,
agent_id, event_type, tool_name, summary, data, created_at) · `token_usage` (session_id,
model, input/output/cache_read/cache_write tokens + 4 baseline_* columns for compaction) ·
`model_pricing` (model_pattern PK, display_name, 4 per-mtok rates, updated_at) ·
`push_subscriptions` (endpoint PK, p256dh, auth) · `dashboard_runs` (id, session_id, mode,
cwd, model, permission_mode, effort, resume_session_id, prompt_preview, status, exit_code,
started_at, ended_at). Plus ~12 indexes (incl. partial indexes), default-pricing seed +
top-up, all migrations, and 3 startup-cleanup statements. See db.js lines 49–442.

### 2.2 REST API surface (all must exist in Swift)

| Router | Endpoints |
|---|---|
| health | GET /api/health · GET /api/openapi.json · /api/docs (swagger UI — serve openapi.json + static swagger, or redoc) |
| sessions | GET / · GET /facets · GET /:id · GET /:id/stats · POST / · PATCH /:id · GET /:id/transcripts · GET /:id/transcript |
| agents | GET / · GET /:id · POST / · PATCH /:id |
| events | GET / · GET /:id/full · GET /facets |
| stats | GET / |
| hooks | POST /event  ← **the ingestion heart (hooks.js, 1 212 lines)** |
| analytics | GET / |
| pricing | GET / · PUT / · DELETE /:pattern · GET /cost · GET /cost/:sessionId |
| settings | GET /info · POST /clear-data · POST /reimport · POST /reinstall-hooks · POST /reset-pricing · GET /export · GET/PUT /claude-home · POST /cleanup |
| workflows | GET / · GET /session/:id |
| push | GET /vapid-public-key · POST /subscribe · DELETE /subscribe · POST /send |
| import | GET /guide · POST /rescan · POST /scan-path · POST /upload · POST /session (bundle) |
| export | GET /session/:id · POST /session |
| updates | GET /status · POST /check |
| cc-config | GET /overview /skills /agents /commands /output-styles /plugins /mcp /hooks /settings /memory /marketplaces /keybindings /statusline /hook-scripts /backups · GET/PUT/DELETE /file |
| run | GET / · GET /history · GET /cwds · GET /files · GET /binary · POST / · POST /:id/message · GET /:id · DELETE /:id |
| static | serve client dist with the exact cache policy of index.js lines 118–142 + SPA fallback |

### 2.3 WebSocket (`/ws`)

Envelope `{type, data, timestamp}`. Broadcast types: `session_created`,
`session_updated`, `agent_created`, `agent_updated`, `agent_stuck`, `new_event`,
`cc_config_changed`, `cost_spike`, `run_input_ack`, `run_status`, `run_stream`,
`update_status` (+ client sends nothing meaningful; server pushes only).

### 2.4 Background services (index.js lines 178–398)

- Auto-install hooks on startup (idempotent).
- One-time legacy import from `~/.claude/projects/**` (marker file `.legacy-import.done`).
- Periodic sweep every ≤5 min: abandon stale sessions (`DASHBOARD_STALE_MINUTES`,
  default 180), complete their agents, evict transcript cache, scan active sessions'
  JSONL for compaction entries (since `/compact` fires no hooks).
- Server info file `~/.claude/.agent-dashboard.json` (port + PID) written on start,
  removed on shutdown — this is how hooks discover the port. **Must be kept.**
- cc-watcher: FS-watch `~/.claude` config dirs → broadcast `cc_config_changed`.
- update-scheduler: version check (adapt: check GitHub releases of this repo).
- dashboard_runs orphan reconciliation on boot.

### 2.5 Ingestion semantics (hook.mjs + routes/hooks.js)

Hook events registered for: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, SubagentStart, SubagentStop, SessionEnd (+ server handles
Notification → awaiting_input). Hook POSTs raw Claude Code payload as
`{hook_type, data}`. Server (`hooks.js`) does the heavy lifting: ensureSession,
main-agent synthesis (`<session>-main`), subagent lifecycle via Agent tool_use
matching + `findDeepestWorkingAgent` recursive CTE, token usage parsing from
transcripts (replaceTokenUsage w/ compaction baselines), model updates, GitHub PR URL
detection in Bash output, awaiting-input stamping/clearing, WS broadcasts, push
notifications on session end/error, `agent_stuck` + `cost_spike` heuristics.

### 2.6 Web client (vendored)

React 18 + Vite + Tailwind, pages: Dashboard, Sessions, SessionDetail (conversation
transcript viewer), ActivityFeed, Analytics, Workflows (12 d3 visualizations incl.
OrchestrationDAG, sankey ModelDelegationFlow, ConcurrencyTimeline…), Search, Run,
KanbanBoard, ImportSession, CcConfig, Settings. i18n, dark/light themes, PWA
(sw.js + manifest), web-push subscribe.

### 2.7 Current PodiumSwiftApp state (the starting point)

Thin read-only macOS viewer: Dashboard/Sessions/SessionDetail/Analytics/Settings over
REST+WS. Missing: everything server-side, transcripts, workflows, search, run, import/
export, cc-config, push. Uses purple theme (to be re-branded black/gold per
`memory/podium-brand-palette.md`). Known annoyance: refresh spinner interrupts reading.

---

## 3. Target repo layout

```
PodiumSwiftApp/
├── Package.swift                     # multi-target, macOS 14+ / Linux
├── Sources/
│   ├── CSQLite/                      # system-library target (sqlite3)
│   ├── PodiumCore/
│   │   ├── Database/                 # SQLite wrapper, schema, migrations, statements
│   │   ├── Models/                   # Session, Agent, Event, TokenUsage, Pricing, Run…
│   │   ├── Ingest/                   # hook event processing (port of hooks.js)
│   │   ├── Transcripts/              # JSONL parser, transcript cache, compaction scan
│   │   ├── Discovery/                # ~/.claude discovery, legacy import, cc-config read
│   │   ├── Pricing/                  # cost computation
│   │   ├── Workflows/                # tree/swimlane/graph builders (port workflows.js)
│   │   ├── Runs/                     # run-spawner (Process + stream-json parser)
│   │   ├── Push/                     # VAPID web-push (swift-crypto)
│   │   └── Hooks/                    # settings.json hook installer/uninstaller
│   ├── PodiumServer/                 # Hummingbird app, routes/, websocket, static
│   ├── PodiumServerCLI/              # podium-server executable (daemon)
│   ├── PodiumHook/                   # podium-hook executable
│   └── PodiumApp/                    # SwiftUI macOS app (existing, upgraded)
├── WebClient/dist/                   # vendored built React dashboard (+ SYNC.md)
├── Tests/PodiumCoreTests/  Tests/PodiumServerTests/
├── scripts/build-linux.sh  scripts/package-macos.sh  run.sh
└── .github/workflows/ci.yml          # macOS + Linux (Swift 6 container) build+test
```

---

## 4. Working agreements (for every dev agent)

1. **Branch:** work directly on `develop` in this repo unless the task says otherwise.
   Commit at logical checkpoints with clear messages.
2. **Cross-platform rule:** `PodiumCore`, `PodiumServer`, `PodiumServerCLI`,
   `PodiumHook` must compile with **no** `import AppKit/SwiftUI` and no
   Darwin-only APIs (guard with `#if canImport(...)` when unavoidable). CI enforces.
3. **Behavioral parity beats elegance:** when porting Node code, match observable
   behavior (status transitions, JSON field names — the API uses **snake_case** JSON
   exactly like the Node server, timestamps `strftime('%Y-%m-%dT%H:%M:%fZ')` format).
   The React client must work against the Swift server without modification.
4. **Tests:** every ported module gets XCTest coverage of the tricky bits (migrations,
   ingestion state machine, pricing math, JSONL parsing). `swift test` must pass.
5. **Verify builds:** `swift build` (and `swift test`) before declaring done.
6. **Do not modify** `/Users/gaelrobin/Desktop/Work/Claude/podium` — read-only reference.
7. **Report:** finish with a summary of files touched, deviations from the task
   prompt, and anything the next task must know. The orchestrator updates this file.
8. **Quality over breadth (Gaël, 2026-07-03):** depth and polish beat feature
   count — nothing ships half-working. Prefer finishing fewer things completely
   (and saying so) over shallow coverage. A hardening gate (code review +
   contract check against the React client) runs at the end of each phase, not
   only at P6.2.

---

## 5. Phases & task board

Legend: ⬜ todo · 🟦 in progress · ✅ done · ⚠️ done with caveats (see Run Log)

| ID | Task | Depends on | Status |
|---|---|---|---|
| **P0.1** | Repo restructure: multi-target Package.swift, CSQLite, CI, vendor web client | — | ✅ |
| **P1.1** | SQLite wrapper + schema + migrations + prepared statements (port db.js) | P0.1 | ✅ |
| **P1.2** | Core models + JSON coding (snake_case parity) | P0.1 | ✅ |
| **P2.1** | Hummingbird server skeleton: health, WS hub, static client, server-info file | P1.1, P1.2 | ✅ |
| **P2.2** | Read API: sessions, agents, events, stats, analytics, search, facets | P2.1 | ✅ |
| **P2.3** | Hook ingestion engine (port hooks.js) + POST /api/hooks/event | P2.1 | ✅ |
| **P2.4** | podium-hook binary + hook installer (port hook.mjs + install.mjs) | P0.1 | ✅ |
| **P3.1** | Transcript engine: JSONL parser, cache, GET transcript endpoints, token reconcile | P2.2 | ✅ |
| **P3.2** | Legacy import + rescan/scan-path/upload + periodic sweeps | P3.1, P2.3 | ✅ |
| **P3.3** | Pricing + cost endpoints + settings router (info/clear/reimport/cleanup/export/claude-home) | P2.2 | ✅ |
| **P3.4** | Workflows API (port workflows.js: tree, swimLanes, patterns) | P2.2 | ✅ |
| **P4.1** | Run-spawner: spawn claude CLI, stream-json, run router, WS run_* messages | P2.1 | ✅ |
| **P4.2** | Web-push (VAPID via swift-crypto) + push router + notify-on-end | P2.1 | ✅ |
| **P4.3** | cc-config explorer + FS watcher + updates router + session export/import bundles | P2.2 | ✅ |
| **P4.4** | Diagnostics: /api/diagnostics (hook latency, last event, log ring buffer) + native panel + web note | P2.3 | ✅ |
| **P5.1** | macOS app: embed server in-process, lifecycle, single-instance, menu-bar status | P2.1–P2.4 | ✅ |
| **P5.2** | macOS app: brand re-theme (black/gold), fix refresh-spinner annoyance | P0.1 | ✅ |
| **P5.3** | macOS app: transcript viewer + search + session actions | P3.1 | ✅ |
| **P5.4** | macOS app: workflows graphs, analytics upgrade, run page, cc-config, import/export UI | P3.4, P4.1, P4.3 | ✅ |
| **P5.5** | First-run onboarding tour (macOS app; web dashboard gets a lighter variant) | P5.4 | ✅ |
| **P6.1** | Packaging: macOS .app/DMG script, Linux static-ish binary + systemd unit + install.sh | P5.1 | 🟦@F |
| **P6.2a** | Contract E2E: ContractTests harness + fixtures + contract-check.sh + manual browser walk of every web page vs Swift server | P2–P4 (server gated) | 🟦@P |
| **P6.2b** | Docs: README, MIGRATION, CLAUDE.md rewrite (needs P6.1's install story) | P6.1, P6.2a | ⬜ |
| **F1** | v1 polish: reimport/import perf on real-size corpora (backfillCompactions re-scan, snapshotTranscript copies) | P3.2 | ✅ |

**PO decisions (Fable 5, delegated by Gaël 2026-07-04 ~02:00, "full power"):**
1. After the Phase-3 gate, **P5.1 jumps the queue** (app embeds server = the
   zero-setup demo moment); P4.3/P4.4 trail behind it.
2. **Gaël's live data is untouchable while he sleeps**: the Docker container
   (port 4820) and ~/.claude/podium/data/ stay exactly as they are. The
   switchover of his real 420 MB DB to the Swift server happens only with him
   awake and watching, after P5.1 is verified against a COPY of that DB.
3. Overnight goal: completion agent → Phase-3 gate → P5.1 → (P4.3 ∥ P4.4),
   HANDOVER.md refreshed after every step so any-morning pickup is trivial.

Suggested run order / parallelism:
`P0.1` → (`P1.1` ∥ `P1.2` ∥ `P2.4`) → `P2.1` → (`P2.2` ∥ `P2.3`) →
(`P3.1` ∥ `P3.3` ∥ `P3.4` ∥ `P4.1` ∥ `P4.2` ∥ `P4.3` ∥ `P5.2`) → `P3.2` →
(`P5.1` → `P5.3` → `P5.4`) → `P6.1` → `P6.2`.

---

## 6. Dev prompts (Sonnet)

> Spawn each with `subagent_type: general-purpose`, `model: sonnet`. Paste the shared
> preamble + the task prompt. Every prompt is self-contained.

### 6.0 Shared preamble (prepend to every task)

```
You are a senior Swift engineer on the "Podium Standalone" project.

Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp (branch develop). Work here.
Read-only reference (the Node.js app you are porting):
/Users/gaelrobin/Desktop/Work/Claude/podium — NEVER modify it.

Read /Users/gaelrobin/Desktop/PodiumSwiftApp/STANDALONE_PLAN.md sections 1–4 first:
architecture, feature inventory, layout, and working agreements are defined there
and are binding. Key rules: PodiumCore/PodiumServer/CLI/Hook targets must compile
on Linux (no AppKit/SwiftUI/Darwin-only APIs); API JSON is snake_case matching the
Node server exactly; timestamps are ISO8601 with milliseconds + 'Z'
(SQLite strftime('%Y-%m-%dT%H:%M:%fZ') format); behavioral parity with the Node
code beats elegance. Run `swift build` and `swift test` before finishing.
Commit your work on develop with clear messages.
Finish by reporting: files created/changed, test results, deviations, and notes
for dependent tasks.
```

### P0.1 — Repo restructure + CI + vendor web client

```
TASK P0.1 — Restructure the package for the standalone architecture.

1. Rewrite Package.swift (swift-tools-version 5.10+):
   - platforms: [.macOS(.v14)]  (fix the current bogus "26.0"; Linux needs no entry)
   - Targets per STANDALONE_PLAN.md §3:
     * CSQLite: systemLibrary target wrapping sqlite3 (module.modulemap with
       `header "sqlite3.h"`, `link "sqlite3"`; providers: apt libsqlite3-dev / brew sqlite3)
     * PodiumCore (depends: CSQLite)
     * PodiumServer (depends: PodiumCore, hummingbird ~2.x, hummingbird-websocket)
     * PodiumServerCLI executable "podium-server" (depends: PodiumServer, swift-argument-parser)
     * PodiumHook executable "podium-hook" (Foundation only — keep dep-free)
     * PodiumApp executable (existing sources, unchanged behavior, macOS-only;
       add `.when(platforms: [.macOS])` style guards so `swift build` on Linux
       still succeeds for the other products — use platform-conditional target
       exclusion via #if os(macOS) wrapping in a small @main shim if needed;
       simplest accepted approach: wrap every PodiumApp source in #if os(macOS))
   - Add swift-crypto dependency (used later by push; fine to add now).
2. Move nothing in Sources/PodiumApp except what's needed to compile; create the
   new empty target directories with a placeholder.swift each so everything builds.
3. Vendor the web client: run `npm --prefix dashboard/client install && npm --prefix
   dashboard/client run build` inside a COPY of the client at
   /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client — if a dist/ already
   exists there and is fresh, just copy it. Copy the built dist/ into
   WebClient/dist/ in this repo. Add WebClient/SYNC.md documenting the exact
   rebuild+copy commands. Do NOT vendor node_modules or sources.
4. CI: .github/workflows/ci.yml with two jobs:
   - macos-latest: swift build && swift test
   - ubuntu (container swift:6.0 or swift:5.10): apt-get install libsqlite3-dev,
     then swift build --product podium-server --product podium-hook && swift test
5. Update run.sh so the existing macOS app flow still works.
6. Verify: swift build succeeds on macOS for all products; commit.

Note: PodiumApp currently reads Sources/PodiumApp/*.swift (10 files) — see repo
CLAUDE.md for the activation-policy constraints; do not break them.
```

### P1.1 — SQLite wrapper + schema + migrations + statements

```
TASK P1.1 — Port dashboard/server/db.js (736 lines) to PodiumCore/Database.

Reference: /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/db.js

1. Sources/PodiumCore/Database/SQLite.swift — minimal ergonomic wrapper over CSQLite:
   open/close, exec, prepared statements with bind/step/column accessors, transactions,
   WAL + foreign_keys + busy_timeout pragmas, thread-safety via a serial queue or an
   actor (choose one; the Node server is effectively single-threaded — a serial
   DispatchQueue-confined class `Database` is fine and Linux-safe).
2. Sources/PodiumCore/Database/Schema.swift — port EXACTLY:
   - CREATE TABLE statements (db.js lines 49–156) incl. CHECK constraints + indexes
   - DEFAULT_PRICING seed + startup top-up (lines 161–203)
   - every migration in order (token_usage model column, updated_at columns,
     awaiting_input_since, transcript_path + backfill w/ json_valid guard,
     github_pr_url, agents status CHECK rebuild for legacy 'idle'/'connected',
     token baseline columns) — lines 205–394
   - startup cleanups (stale actives → completed, orphan agents, compaction
     started_at repair) — lines 396–442
   These migrations MUST be able to open a real dashboard.db produced by the Node
   app without data loss (that is the whole point).
3. Sources/PodiumCore/Database/Statements.swift — port the `stmts` map (lines
   444–734) as methods on a `PodiumStore` type returning model values (models come
   from task P1.2; if P1.2 is not merged yet, define the structs yourself in
   Models/ following §2.1 of the plan and coordinate field names — snake_case JSON).
   Keep the exact SQL semantics including replaceTokenUsage baseline CASE logic and
   findDeepestWorkingAgent recursive CTE.
4. DB path resolution parity: env DASHBOARD_DB_PATH > DASHBOARD_DATA_DIR/dashboard.db
   > <default data dir>/dashboard.db. Default data dir for the Swift app:
   ~/Library/Application Support/Podium on macOS, $XDG_DATA_HOME/podium or
   ~/.local/share/podium on Linux. Expose as PodiumPaths.
5. Tests (Tests/PodiumCoreTests/DatabaseTests.swift):
   - fresh DB: schema creates, pricing seeded
   - migration: build an old-schema DB in the test (e.g. token_usage without model,
     agents with 'idle' status) and assert migrations transform it correctly
   - replaceTokenUsage baseline behavior when counts go down (compaction)
   - findDeepestWorkingAgent returns deepest working subagent
```

### P1.2 — Core models

```
TASK P1.2 — Define all domain models in Sources/PodiumCore/Models/.

References: plan §2.1/§2.2; Node route responses in
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/routes/*.js; the Swift
app's existing Sources/PodiumApp/Models.swift (client-side shapes to stay compatible
with); client-side types in
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client/src/lib/types.ts (this
is the most complete catalog of the wire format the React client expects).

1. Create Codable structs: Session, Agent, Event, EventFull, TokenUsage(+baselines),
   ModelPricing, Stats, SessionStats, Analytics, CostSummary, SessionCost,
   WorkflowSummary, WorkflowDetail (tree + swimLanes), PushSubscription,
   DashboardRun, RunEnvelope, ServerInfo, HealthResponse, plus request bodies
   (SessionCreate/Patch, AgentCreate/Patch, PricingPut, RunCreate…).
2. Wire format is snake_case: encode/decode with explicit CodingKeys or a shared
   JSONEncoder/Decoder pair (PodiumJSON.encoder/.decoder) using .convertToSnakeCase
   — but BE CAREFUL: keys like p256dh, cache_read_tokens, vapid keys must round-trip
   exactly; add tests for every model against literal JSON fixtures captured from
   the Node server's shapes (write fixtures by hand from types.ts, not by running
   the Node server).
3. Date handling: emit ISO8601 with milliseconds ("2024-01-01T00:00:00.000Z");
   accept both fractional and non-fractional on decode. Store as String in models
   where the DB stores TEXT (safer for parity), with computed Date accessors.
4. Status enums with raw String values (session: active/completed/error/abandoned;
   agent: working/waiting/completed/error; run: spawning/running/completed/error/
   killed/abandoned) — but decode unknown values leniently to a .unknown case or
   raw string so old DBs never crash the API.
5. Tests: fixture round-trips per model.
```

### P2.1 — Server skeleton

```
TASK P2.1 — Hummingbird server skeleton in Sources/PodiumServer + PodiumServerCLI.

References:
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/index.js (lines 58–159:
app assembly, static cache policy; 250–298: boot, shutdown, server-info)
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/websocket.js
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/lib/server-info.js

1. PodiumServerApp: builds a Hummingbird 2 application with:
   - CORS middleware (allow all — parity with `cors()`)
   - JSON body limit 1 MB
   - GET /api/health → {"status":"ok","timestamp":ISO}
   - WebSocket endpoint /ws using hummingbird-websocket: a Broadcaster actor with
     connect/disconnect tracking and `broadcast(type: String, data: some Encodable)`
     wrapping into {type, data, timestamp} envelopes. All later routers use this.
   - Static file middleware serving WebClient/dist with EXACT cache policy of
     index.js lines 118–142 (immutable for /assets/, no-cache for index.html/sw.js/
     manifest.json, 300 s for the rest) + SPA fallback to index.html for non-/api GETs.
     Resolve the dist dir: env PODIUM_WEB_DIST > bundled resource > ../WebClient/dist.
   - Router registry: a plug-in point where later tasks mount /api/sessions etc.
2. Port discovery file: on listen, write ~/.claude/.agent-dashboard.json in the
   MULTI-SERVER format hook.mjs reads (see hook.mjs lines 28–49): {"servers":
   [{"port":N,"pid":N}]} — merge with existing live entries, drop dead PIDs; remove
   own entry on shutdown. Port selection: env DASHBOARD_PORT default 4820; if taken,
   increment up to +20 (the Electron shell did a fallback; keep that behavior).
3. PodiumServerCLI (podium-server): swift-argument-parser CLI: `podium-server
   [--port] [--data-dir] [--no-hooks] [--open]`; graceful SIGINT/SIGTERM shutdown
   (close DB, remove server-info). Log startup line like the Node server.
4. Background-services scaffold: a ServicesRunner started post-listen with no-op
   placeholders for legacyImport/sweep/ccWatcher/updateScheduler (later tasks fill
   them) — structure now so tasks P2.3/P3.2/P4.3 have a home.
5. Tests: boot on a random port with a temp data dir; hit /api/health; open a WS
   client, call broadcast, assert envelope shape; static index.html served with
   no-cache header.
```

### P2.2 — Read API routers

```
TASK P2.2 — Port the read-side routers to PodiumServer/Routes/.

References (port faithfully, including query params, pagination, facets, and
response envelopes):
routes/sessions.js (775 l) — list w/ dynamic WHERE (status incl. the
  "error-but-running counts as active" rule, search, cwd, date range), facets,
  get, stats, POST, PATCH (name/status), the transcripts listing (defer
  /:id/transcript full content to P3.1 — return 501 for now with a TODO)
routes/agents.js, routes/events.js (list + /:id/full + facets),
routes/stats.js, routes/analytics.js (timezone-offset param handling!),
routes/search.js (174 l — cross-entity search)
All under /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/

1. Implement each router on the PodiumStore statements from P1.1 (add any missing
   dynamic-SQL helpers there — keep raw SQL in PodiumCore, HTTP mapping here).
2. Timezone handling parity: routes accept a tz-offset-minutes param and pass
   SQLite modifiers exactly like the Node code (see countEventsToday and
   dailyEventCounts usage in analytics.js).
3. Error contract parity: 404 {"error": "..."} etc. — mirror the Node responses.
4. POST /api/sessions and /api/agents + PATCH must broadcast session_created /
   session_updated / agent_created / agent_updated exactly like the Node routes.
5. Tests: seed a temp DB via PodiumStore, assert list filters, facets shape,
   analytics with a non-UTC offset, search returns each entity kind.
6. Contract check: pick 5 representative endpoints, and diff your JSON against
   the shapes in dashboard/client/src/lib/types.ts + api.ts. The React client is
   the acceptance judge.
```

### P2.3 — Hook ingestion engine

```
TASK P2.3 — Port routes/hooks.js (1 212 lines) — the heart of Podium — to
Sources/PodiumCore/Ingest/ + a thin POST /api/hooks/event route.

References:
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/routes/hooks.js (ALL of it)
/Users/gaelrobin/Desktop/Work/Claude/podium/hook.mjs (payload shapes posted)
/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/lib/transcript-cache.js
(token parsing — coordinate with P3.1; if its TranscriptCache isn't merged yet,
define the protocol and a stub, and note the seam in your report)

1. IngestEngine (PodiumCore): a type with `func process(hookType: String, data:
   JSONValue) -> [Broadcast]` where Broadcast = (type, payload). Port the full
   state machine: ensureSession (+ transcript_path stamping, model updates,
   reactivation), main-agent synthesis (id "<session>-main"), turn_start events,
   PreToolUse/PostToolUse incl. Agent-tool subagent creation and matching by
   tool_use_id, SubagentStart/Stop enrichment, findDeepestWorkingAgent fallback
   parenting, PostToolUseFailure, Notification → awaiting_input_since stamp and
   its clearing rules, SessionEnd (+ statuses), token usage via transcript parse
   with replaceTokenUsage baselines, GitHub PR URL sniffing from Bash output,
   agent_stuck and cost_spike heuristics, push-notification triggers (call an
   injected `Notifier` protocol; P4.2 implements it — provide a no-op default).
2. Route: POST /api/hooks/event — parse {hook_type, data} leniently (unknown
   fields fine, never 500 on garbage; the hook must never break Claude Code),
   run engine, emit broadcasts over the WS hub, return 200 fast.
3. Use a JSONValue enum (or similar) for the loosely-typed hook payloads — do not
   try to strongly type Claude Code's hook input.
4. Tests are the deliverable's soul: replay a scripted sequence of hook payloads
   (write fixtures modeled on hook.mjs's shapes) through the engine against a temp
   DB and assert: session created→active, main agent working, subagent tree built
   with correct parent, tool events recorded with summaries, awaiting-input set on
   Notification and cleared on next activity, SessionEnd completes agents, token
   baselines survive a simulated compaction (counts drop), broadcasts emitted in
   order.
```

### P2.4 — podium-hook + installer

```
TASK P2.4 — Native hook binary + settings.json installer.

References:
/Users/gaelrobin/Desktop/Work/Claude/podium/hook.mjs (302 l — port whole behavior)
/Users/gaelrobin/Desktop/Work/Claude/podium/install.mjs (184 l)

1. Sources/PodiumHook/main.swift (Foundation only, no deps):
   - read all stdin; parse JSON; ignore invalid silently (exit 0 — NEVER crash or
     block Claude Code)
   - port discovery: env CLAUDE_DASHBOARD_PORT else ~/.claude/.agent-dashboard.json
     (multi-server format, PID-liveness via kill(pid,0), EPERM counts as alive)
     else 4820
   - POST {hook_type, data:<raw payload>} to 127.0.0.1:<port>/api/hooks/event on
     every live port; 1 s request timeout; hard process deadline 1.5 s (exit(0)
     via DispatchQueue.global().asyncAfter or a timer thread)
   - use URLSession (FoundationNetworking on Linux — `#if canImport(FoundationNetworking)`)
2. Sources/PodiumCore/Hooks/HookInstaller.swift:
   - port install.mjs: install/uninstall/check against ~/.claude/settings.json
     (global default; project mode optional param)
   - events list identical (SessionStart…SessionEnd, 8 events), marker
     ".claude/podium/hook" (note: no .mjs), timeout: 2, command `"<home>/.claude/
     podium/podium-hook"`; ALSO remove/replace legacy node hook entries matching
     ".claude/podium/hook.mjs" and "plugins/cache/wp-media/podium" so we upgrade
     plugin users in place (keep detection markers from install.mjs)
   - copies the podium-hook binary to ~/.claude/podium/podium-hook (source: own
     bundle/executable dir — take path as parameter)
   - JSON-preserving edit: read settings.json, mutate only hooks arrays, pretty
     2-space output like Node
3. Tests: temp HOME fixture — install into empty/existing/legacy settings.json,
   check idempotency, uninstall removes all podium entries and nothing else.
   For the binary: unit-test port discovery + payload building as library code
   (put logic in PodiumCore/Hooks/HookClient.swift, main.swift stays 20 lines).
```

### P3.1 — Transcript engine

```
TASK P3.1 — Port transcript parsing: lib/transcript-cache.js (594 l),
lib/stream-json-parser.js, sessions.js transcript endpoints.

References under /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/:
lib/transcript-cache.js, routes/sessions.js lines 300–775 (GET /:id/transcripts,
GET /:id/transcript with cursor pagination), lib/claude-home.js (resolve ~/.claude,
honoring the configurable claude-home in settings — see routes/settings.js
claude-home endpoints).

1. PodiumCore/Transcripts/TranscriptCache: parse Claude Code JSONL transcripts
   (message entries, tool_use/tool_result, usage blocks per model, compaction
   markers), mtime+size-based cache invalidation, extractCompactions(),
   token-usage extraction feeding replaceTokenUsage (per-model, with the
   "counts went down → baseline" semantics).
2. Implement GET /api/sessions/:id/transcripts (list JSONL files for session) and
   GET /api/sessions/:id/transcript (parsed messages, cursor pagination — match
   the Node response shape exactly; check client/src/pages/SessionDetail.tsx +
   components/conversation/* for the consumed fields).
3. Wire the IngestEngine's transcript-token seam (P2.3 defined the protocol).
4. Tests: fixture JSONL files (hand-write small ones incl. a compaction, a
   subagent sidechain, multi-model usage) — assert parsed messages, token totals,
   compaction extraction, cache invalidation on file change.
```

### P3.2 — Legacy import + sweeps

```
TASK P3.2 — Port scripts/import-history.js + routes/import.js (435 l) + the
periodic maintenance sweep.

References under /Users/gaelrobin/Desktop/Work/Claude/podium/:
dashboard/scripts/import-history.js, dashboard/server/routes/import.js,
dashboard/server/index.js lines 161–209 (one-time import w/ marker) and 300–398
(sweep), dashboard/server/lib/cc-discovery.js (session discovery in ~/.claude).

1. PodiumCore/Discovery/LegacyImporter: importAllSessions (walk
   ~/.claude/projects/**.jsonl, reconstruct sessions/agents/events/token_usage,
   idempotent per-session dedup), backfillCompactions, importCompactions.
2. Routes: GET /api/import/guide, POST /rescan, POST /scan-path, POST /upload
   (multipart JSONL upload — Hummingbird multipart).
3. ServicesRunner: one-time legacy import guarded by .legacy-import.done marker
   (write only after success), periodic sweep (stale→abandoned w/
   DASHBOARD_STALE_MINUTES default 180, agent completion batch update, transcript
   cache eviction, compaction scan of active sessions) — port index.js faithfully
   including broadcast calls.
4. Tests: fixture ~/.claude tree → import produces expected rows twice-run-once-
   counted; sweep abandons a stale session and broadcasts.
```

### P3.3 — Pricing, cost & settings routers

```
TASK P3.3 — Port routes/pricing.js (168 l) and routes/settings.js (288 l).

1. Pricing: GET/PUT /api/pricing, DELETE /:pattern, GET /cost (global summary:
   per-model tokens × matched pricing w/ LIKE pattern matching — port matchPricing
   semantics), GET /cost/:sessionId. Put cost math in PodiumCore/Pricing/.
2. Settings: GET /info (server version, db path, db size, counts, hook status —
   adapt fields; check client/src/pages/Settings.tsx for what's displayed),
   POST /clear-data (wipe tables, keep pricing), POST /reimport, POST
   /reinstall-hooks (calls HookInstaller), POST /reset-pricing (DEFAULT_PRICING),
   GET /export (full DB export — stream a .db copy or JSON dump; match Node),
   GET/PUT /claude-home (configurable ~/.claude override, persisted in a config
   file in the data dir), POST /cleanup (delete sessions older than N days /
   by status — match Node params).
3. Tests: cost math against hand-computed fixtures incl. cache pricing and
   pattern matching precedence; cleanup deletes cascade.
```

### P3.4 — Workflows API

```
TASK P3.4 — Port routes/workflows.js (761 l) to PodiumCore/Workflows/ + router.

Reference: /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server/routes/workflows.js
Consumer: client/src/pages/Workflows.tsx + components/workflows/* (12 charts) —
these define the required response shape (tree, swimLanes, stats, patterns…).

1. GET /api/workflows — cross-session aggregates (patterns, complexity scatter,
   subagent effectiveness, delegation flows…). GET /api/workflows/session/:id —
   per-session tree + swimlanes + tool execution flow.
2. Pure functions in PodiumCore taking rows in, structs out; router is thin.
3. Tests: seed a session with a 3-level agent tree + tool events; assert tree
   nesting, swimlane ordering, duration math (incl. the negative-duration guard
   for compaction agents).
```

### P4.1 — Run-spawner

```
TASK P4.1 — Port lib/run-spawner.js (518 l), lib/dashboard-runs.js,
lib/stream-json-parser.js, routes/run.js (341 l).

1. PodiumCore/Runs/RunSpawner: spawn `claude` via Foundation.Process:
   headless mode (argv -p prompt, stdin closed) and conversation mode (stdin open,
   JSON envelopes per turn, --resume support); always `--output-format stream-json
   --verbose`; line-buffered stdout parser → envelopes; bounded replay log (500);
   status lifecycle spawning→running→completed/error/killed; reap after 5 min;
   concurrency cap RUN_MAX_CONCURRENT (default 10000); persistence to
   dashboard_runs + orphan reconciliation on boot.
2. Router: GET / (active), /history, /cwds (recent session cwds), /files (browse
   dir for the picker — mind path traversal: resolve+prefix check), /binary
   (locate claude binary: which + common paths), POST / (start), POST /:id/message,
   GET /:id (with replay), DELETE /:id (kill). Broadcast run_status / run_stream /
   run_input_ack.
3. Env for spawned procs: inherit, ensure hooks fire (they will — global hooks).
4. Tests: use /bin/cat or a tiny fixture script as a fake "claude" (inject binary
   path) to test envelope parsing, replay, kill, persistence. Do NOT spawn real
   claude in tests.
```

### P4.2 — Web-push

```
TASK P4.2 — Port lib/push.js + routes/push.js using swift-crypto.

1. PodiumCore/Push/: VAPID key gen/load (P-256, store vapid-keys.json in data dir,
   format-compatible with the Node file so existing keys keep working — check
   web-push's JSON shape), JWT ES256 signing for the Authorization header,
   aes128gcm payload encryption per RFC 8291 (implement with swift-crypto:
   ECDH over P-256 + HKDF + AES-128-GCM — this is the meaty part; write it as
   a clean WebPushEncryptor with test vectors from RFC 8291 §5).
2. Router: GET /vapid-public-key, POST/DELETE /subscribe, POST /send.
   Notifier implementation for the IngestEngine seam (P2.3): notify on session
   end/error like the Node server; prune 404/410 subscriptions.
3. On macOS, ALSO provide a NativeNotifier (UNUserNotificationCenter) behind
   #if os(macOS), used by the app when it hosts the server (P5.1 wires it).
   On Linux, provide a LinuxDesktopNotifier that shells out to notify-send when
   available (silently no-op otherwise) so the headless daemon gives the same
   "session ended / awaiting input" toasts as macOS — Linux parity is a product
   requirement (plan §6b).
4. Tests: RFC 8291 test vectors MUST pass; subscription CRUD; JWT header/claims
   shape.
```

### P4.3 — cc-config explorer, watcher, updates, export bundles

```
TASK P4.3 — Port routes/cc-config.js (181 l) + lib/cc-discovery.js (792 l) +
lib/cc-mutate.js + lib/cc-watcher.js + routes/updates.js + routes/export.js.

1. PodiumCore/Discovery/CcConfig: enumerate ~/.claude (honoring claude-home
   override): skills, agents, commands, output-styles, plugins, mcp servers,
   hooks, settings, memory (CLAUDE.md files), marketplaces, keybindings,
   statusline, hook-scripts; file read/write/delete with the backup mechanism
   cc-mutate.js implements (backups dir + list endpoint). Path-traversal guards:
   every file path must resolve inside claude-home.
2. Watcher: DispatchSource file watching on macOS; on Linux use a 2 s mtime-poll
   fallback (keep it simple, no inotify dep) → broadcast cc_config_changed.
3. Updates router: GET /status, POST /check — adapt to check GitHub releases of
   wp-media/podium AND this app's own repo; return the Node-compatible shape
   (client/src/components/UpdateNotifier.tsx is the consumer).
4. Export/import session bundles (routes/export.js): GET /api/export/session/:id
   (zip bundle: session JSON + events + transcript files) and POST /api/import/
   session / /api/export/session. Use ZIPFoundation (add dep) — works on Linux.
5. Tests: fixture claude-home tree; traversal attack returns 400; backup rotation;
   export→import round-trip on a seeded session.
```

### P5.1 — macOS app hosts the server

```
TASK P5.1 — Embed PodiumServer in the SwiftUI app.

1. On app launch: start PodiumServerApp in-process on 4820 (fallback +20),
   data dir ~/Library/Application Support/Podium, run HookInstaller (global),
   start background services. On quit: graceful shutdown (server-info cleanup).
2. Single-instance semantics: if a live Podium server already owns the port
   (check ~/.claude/.agent-dashboard.json + health ping), CONNECT instead of
   host — the app must keep working as a pure client (its current mode) so a
   Linux-style external daemon is also supported. Add a Settings toggle
   "Embedded server" (default on) + status row showing mode/port/db path.
3. AppState: point the existing API/WS clients at the embedded server via
   localhost as today — no shortcut in-process calls; keep the HTTP boundary.
4. Native notifications: wire P4.2's NativeNotifier through
   UNUserNotificationCenter with permission request on first launch.
5. Menu bar extra (MenuBarExtra): active agents count + total cost today +
   quick-open, per repo CLAUDE.md wishlist.
6. Verify with run.sh: app launches, hooks installed, a real claude session in a
   terminal appears live in the app with zero plugin/Node involvement.
```

### P5.2 — Brand re-theme + polish

```
TASK P5.2 — Re-theme the macOS app to the official Podium brand and fix the
refresh-spinner annoyance.

References: this repo's memory file
/Users/gaelrobin/.claude/projects/-Users-gaelrobin-Desktop-PodiumSwiftApp/memory/podium-brand-palette.md
(official black/gold dark + white/gold/blue light tokens, eye logo, AppIcon notes)
and the web client's Tailwind config + index.css for exact colors.

1. Theme.swift: replace purple palette with brand tokens; support dark AND light
   (remove hardcoded .preferredColorScheme(.dark), add a Settings appearance
   picker: system/dark/light). Keep glassmorphism (materials + gold accents).
2. Refresh UX: views must never blank to a spinner on periodic refresh — keep
   stale data visible, update in place (only show skeletons on first load).
   Root-cause: AppState refresh replaces arrays wholesale; make updates diffable/
   in-place and gate ProgressViews on `isInitialLoad`.
3. App icon: ensure install/run.sh path uses the brand AppIcon.icns (see memory
   note about install.sh hook).
4. Verify visually with run.sh (screenshots if possible).
```

### P5.3 — Native transcript viewer + search

```
TASK P5.3 — Native conversation transcript viewer + global search in the app.

References: server endpoints from P3.1/P2.2; web implementation for behavior:
client/src/components/conversation/* (message list, tool call blocks, markdown,
code blocks) and client/src/pages/Search.tsx.

1. SessionDetailView: new "Transcript" tab — paginated message list (cursor API),
   user/assistant bubbles, collapsible tool-call blocks with input/output,
   markdown rendering (AttributedString(markdown:)), code blocks with mono font,
   lazy loading, "jump to latest", live append via WS new_event nudge.
2. Global search: ⌘K search window/sheet hitting /api/search — grouped results
   (sessions/agents/events), Enter navigates to the session (reuse the deeplink
   focus mechanics in PodiumApp.swift).
3. Session actions: rename (PATCH), export bundle (GET /api/export/session/:id →
   NSSavePanel), delete/cleanup where the API allows.
4. Keep the glass design language; verify with run.sh.
```

### P5.4 — Native workflows, analytics+, run page, cc-config, import/export

```
TASK P5.4 — Bring the remaining web features native.

1. WorkflowsView: session picker + agent-hierarchy tree (OutlineGroup), swimlane
   timeline (custom Canvas), orchestration DAG (simplified force-less layered
   layout is fine — parity of information beats parity of pixels), stats cards.
   Consumer shapes: GET /api/workflows + /session/:id (see P3.4).
2. RunView: start headless/conversation runs (cwd picker via /api/run/cwds +
   /files, model/permission-mode/effort pickers), live stream via run_stream WS,
   input box for conversation mode, history list with resume, kill.
3. CcConfigView: sidebar sections (skills/agents/commands/mcp/hooks/settings/
   memory…), file viewer w/ syntax-ish mono display, edit+save (PUT /file w/
   backup), backups browser.
4. ImportExport: Import page (rescan, scan path, upload JSONL via file picker),
   Analytics upgrades to match web (daily charts w/ tz offset, cost spike info).
5. Sidebar gains: Workflows, Run, Config, Import sections; keep glass design.
```

### P5.5 — First-run onboarding tour

```
TASK P5.5 — First-run onboarding, in-app.

Product frame (plan §6b): this app must kill the "too complicated" objection —
the tour is the moment that either proves simplicity or destroys it. Curated,
glanceable, skippable. Target: a colleague who has never heard of Podium
understands what they're looking at in under a minute.

1. macOS app: on first launch (AppStorage flag), after the server is up and
   hooks are installed, show a glass-styled overlay tour (4–6 steps max):
   what Podium is (one sentence), the live dashboard, sessions & the detail
   view, notifications/awaiting-input, where Settings lives. Spotlight-style
   highlight on the real UI, not screenshots. Every step skippable; "Skip tour"
   always visible; re-runnable from Help menu → "Show tour".
2. If legacy import ran on this launch, the first step says "importing your
   history — N sessions found so far" with live count (poll /api/stats).
3. Keep copy short and human — no jargon, no walls of text (the "not bloated"
   rule applies to words too).
4. Web dashboard variant: do NOT rebuild the tour in React — add a dismissible
   first-visit welcome card on the Dashboard page pointing at the three main
   nav areas, stored in localStorage. (Check whether the client already has a
   Tip/UpdateNotifier pattern to reuse — client/src/components/Tip.tsx.)
   NOTE: this requires editing the vendored client — see WebClient/SYNC.md for
   the rebuild flow; keep the diff minimal and upstream-friendly.
5. Verify visually via run.sh in both light and dark; screenshots in the report.
```

### P6.1 — Packaging

```
TASK P6.1 — Distribution packaging.

1. scripts/package-macos.sh: release build, assemble PodiumApp.app (extend run.sh
   logic), embed podium-hook + WebClient/dist as Resources, codesign ad-hoc,
   create DMG (hdiutil).
2. scripts/build-linux.sh: swift build -c release --product podium-server
   --product podium-hook (document running inside swift:6 docker for portability),
   output tarball with binaries + WebClient/dist + install-linux.sh that copies to
   /usr/local/{bin,share/podium}, installs a systemd user unit
   (podium-server.service, WantedBy=default.target) and runs podium-server
   --install-hooks once.
3. Make PodiumServerCLI resolve WebClient dist relative to the installed layout
   (/usr/local/share/podium/web) in addition to dev paths.
4. Verify: macOS package launches on a clean user account path; Linux tarball
   builds in docker (docker run --rm -v $PWD:/src swift:6.0 ...) even if you can't
   run systemd here — lint the unit file.
```

### P6.2 — Contract E2E + docs

```
TASK P6.2 — Prove the React client runs unmodified on the Swift server + docs.

1. Contract test harness (Tests/PodiumServerTests/ContractTests.swift +
   scripts/contract-check.sh): boot podium-server on a temp dir, seed via
   /api/hooks/event with a realistic recorded hook sequence (fixtures), then curl
   every GET endpoint and validate against expectations extracted from
   client/src/lib/types.ts (hand-derived JSON schema-ish asserts are fine).
2. Manual E2E: serve WebClient/dist, open every page in a browser (use the
   preview/browser tooling if available) — Dashboard, Sessions, SessionDetail w/
   transcript, ActivityFeed, Analytics, Workflows, Search, Run, Kanban, Import,
   CcConfig, Settings — and fix (or file precisely) anything broken.
3. Docs: rewrite README.md (what it is, macOS app, Linux daemon, how ingestion
   works, migration from the plugin incl. "your existing dashboard.db just
   works"), MIGRATION.md, update CLAUDE.md for the new architecture.
4. Update STANDALONE_PLAN.md: mark done, list any residual gaps honestly.
```

---

## 6b. Backlog — reviewed with Gaël 2026-07-03

Product frame (binding for all UI/UX tasks): Podium will be advertised inside
GroupOne as a standalone product — **useful, easy to use, not info-bloated, sexy**.
Linux must get the macOS niceties wherever possible (see №2).

**The objection to kill (Gaël's manager, blocking the plugin today): "too
complicated."** The acceptance bar for P5.1 and P6.x is therefore: download →
open → your agents appear live. Zero manual steps — hooks self-install, history
self-imports, defaults are right. Any step that needs explaining in a README is
a defect against this goal, not a docs task.

1. **Pre-migration DB backup** — parked, low priority (single user today; still
   cheap insurance for Gaël's own plugin-era dashboard.db — revisit before first
   GroupOne distribution).
2. **Awaiting-input notification + ANSWER-FROM-POPUP** — approved, ambitious
   version: notification with a popup that can answer the prompt directly.
   Feasibility split (verified against Claude Code's interfaces):
   - Podium-spawned runs (P4.1): fully possible — stream-json control protocol
     carries permission request/response envelopes; wire the popup answer back
     via the run's stdin. First-class citizen in P4.1 + P5.x scope.
   - External terminal sessions: no clean remote-answer API; do notification +
     jump-to-terminal (focus the right window). Keystroke injection rejected
     (fragile).
   - Linux: daemon sends desktop notifications via notify-send/DBus; web-push +
     browser notification click-through opens the session in the web dashboard.
3. **Diagnostics panel** — APPROVED → scheduled as task P4.4 below.
4. ~~Cost budget alert~~ — dropped (team subscription; cost is not a pain point;
   keep cost UI de-emphasized per earlier feedback).
5. **Quick Look extension** — parked, revisit after P6.2.

Explicitly rejected: iOS companion, Raycast/Alfred, session-diff views.

## 7. Run log

| Date | Task | Agent | Result | Notes |
|---|---|---|---|---|
| 2026-07-03 | Plan authored | Fable 5 | ✅ | Audit of podium v1.4.0 + PodiumSwiftApp complete |
| 2026-07-03 | P0.1 Repo restructure | Sonnet 5 | ✅ | 5-product package (PodiumCore, PodiumServer, podium-server, podium-hook, PodiumApp) builds + tests green on macOS and Linux (swift:6.1 container). See notes below. |
| 2026-07-03 | P2.4 podium-hook + installer | Sonnet 5 | ✅ | HookClient (port discovery, PID liveness, multi-port POST), HookInstaller (install/uninstall/check, legacy plugin-entry upgrade, installBinary), 37 tests green, binary smoke-tested. Startup wiring deferred to P2.1/P5.1 by design. settings.json written with sorted keys (vs Node insertion order) — note for P6.2. |
| 2026-07-03 | P1.2 core models | Sonnet 5 | ✅ | 15 model files + PodiumJSON (snake_case, ms-ISO8601, JSONValue, lenient enums), 42 fixture tests (80/80 in target). **Footgun documented in PodiumJSON.swift: never mix explicit snake_case CodingKeys with .convertFromSnakeCase — silently decodes nil.** RunHandle (live, epoch-ms) vs DashboardRun (persisted, ISO TEXT) split is load-bearing for P4.1. All routers must use PodiumJSON.encoder/.decoder only. |
| 2026-07-03 | P5.2 re-theme + spinner fix | Sonnet 5 | ✅ | Brand theme was mostly pre-existing (Wave 6); added persisted appearance setting (system/dark/light, @AppStorage + Settings General tab), isInitialLoad/isAnalyticsInitialLoad spinner gating + in-place mergeSessions() (no more blanking on ⌘R), run.sh now bundles AppIcon.icns. **Human should eyeball light/dark contrast once via ./run.sh** (agent couldn't screenshot). P5.3/P5.4: use the isInitialLoad pattern, never isLoading-gated full-screen spinners. |

| 2026-07-03 | P1.1 database port | Sonnet 5 | ✅ | SQLite.swift (serial-queue Database), Schema.swift (full db.js schema/migrations/cleanups), PodiumStore.swift (all stmts as typed methods), PodiumPaths. 13 new tests, 94 total green. `PodiumStore(path:)` = one-stop constructor for P2.1. |
| 2026-07-03 | P5.2 visual verification + fix | Fable 5 | ✅ | Verified on-screen via computer use: General tab + theme picker work, dark mode good. Found & fixed light-mode bug: brand gold #FED23A illegible as text on light glass → new adaptive `Theme.accentText` (#947005 in light), applied to Live Feed + 4 other text usages. NOTE: /Applications/Podium.app (old install) can shadow the dev bundle when both run — check `ps` before UI-testing. |
| 2026-07-03 | P2.1 server skeleton | Sonnet 5 | ✅ | Hummingbird 2 app (`Sources/PodiumServer/`): CORS-allow-all, `/api/health`, `/ws` via `Broadcaster` actor (envelope-exact WSMessage), `StaticFileHandler` (hand-rolled, not `FileMiddleware`, to get Node's exact per-path Cache-Control policy), `RouterRegistry`/`RouterMount` plug-in point, `ServicesRunner` + 4 no-op `PlaceholderServices` for P2.3/P3.2/P4.3, `ServerInfoWriter` (new, PodiumCore/Discovery — multi-server `.agent-dashboard.json`, PID-liveness pruned, atomic rename), `PodiumServerLifecycle.run` (port fallback +20, server-info write/remove, background-services start, all keyed off Hummingbird's own `onServerRunning`/graceful-SIGINT-SIGTERM-via-ServiceGroup — no manual signal handling needed). `podium-server` CLI (swift-argument-parser: --port/--data-dir/--no-hooks/--web-dist) auto-installs hooks non-fatally via existing `HookInstaller`. 11 new tests (`PodiumServerAppTests`, `BroadcasterTests`) green on macOS; 7/7 green on Linux (swift:6.1 docker) with 1 WS test `#if`-skipped there (libcurl-backed `URLSessionWebSocketTask` on Linux Foundation doesn't support WS upgrades — a corelibs-foundation gap, not a server bug; envelope shape still covered by `BroadcasterTests` which is platform-agnostic). Manually smoke-tested the real `podium-server` binary end-to-end (health, static cache headers, server-info write + real-SIGTERM cleanup). Deleted `Sources/PodiumCore/placeholder.swift`, `Sources/PodiumServer/placeholder.swift`, and both `PlaceholderTests.swift` files. Deviations: `JSONResponse` wraps `PodiumJSON.encoder` for route responses since Hummingbird 2's default `RequestContext.Encoder` is a plain camelCase `JSONEncoder` with no snake_case hook — **P2.2+ routers must return `JSONResponse(...)` (or extend it), never a bare `Encodable`/`ResponseEncodable` conformance, or JSON keys will silently come out camelCase.** `PodiumStore` marked `@unchecked Sendable` (its `Database` already was) so it can live in the `Sendable` `ServerContext`/`PodiumServerApp` structs passed into router mounts. Notes for P2.2/P2.3: mount routers via `RouterMount.mount(on:context:)`, pull `store`/`broadcaster` off `ServerContext`, list every mount in `PodiumServerCLI/main.swift`'s `mounts:` array (currently empty). P4.3's cc-watcher/updates and P3.2's legacy-import/sweep just need to replace their `PlaceholderServices.*` case in `Sources/PodiumServer/Services/ServicesRunner.swift` with a real `BackgroundService`. |

| 2026-07-03 | P2.2 read routers | Sonnet 5 | ✅ | 6 routers + filters + CostCalculator, 171/171 tests. Fixed: countEventsToday tz double-bind, SearchResult model (flat results array per search.js), AgentPatchRequest missing fields. **Error contract correction: Node's real shape is {"error":{"code","message"}} (CodedErrorResponse) — the flat {"error":"…"} in plan §2.2/§6 prompts is wrong except where explicitly pinned. All future routers must use CodedErrorResponse.** Transcript endpoints 501-stubbed for P3.1 (incl. /transcripts listing — needs claude-home discovery). HooksRouterMount already wired in main.swift. |

| 2026-07-03 | P2.3 ingestion engine | Sonnet 5 | ✅ | Full hooks.js state machine in PodiumCore/Ingest/ + HooksRouter; 45 new tests (replay suite). Seams: TranscriptTokenSource (P3.1), Notifier (P4.2) — call sites wired + stub-tested. Deviations: BEGIN/COMMIT bracketing instead of Database.transaction (re-entrancy), broadcasts after COMMIT (safer than Node). TODOs owned elsewhere: scanAndImportSubagents (P3.1/P3.2), watchdog + stuck-agent periodic loops (P3.2 ServicesRunner). |
| 2026-07-03 | **Phase 2 gate** | Fable 5 | ✅ | 171/171 tests re-run by orchestrator. Live E2E smoke: booted real podium-server binary → POSTed SessionStart/PreToolUse → session+main agent+tool state correct via read API; **machine's real production hooks discovered the Swift server via .agent-dashboard.json and fed it live events unprompted**; garbage POST → clean 400 CodedErrorResponse; static dashboard served with exact cache headers; SIGTERM removed server-info entry + file. Full code-review gate deferred to end of phase 3 (will cover phases 2+3 together). |
| 2026-07-03 | Session handover + 🟦 reconcile | Fable 5 (new session) | ✅ | Old session hit its limit; P3.1/P3.4 agents died. P3.1: zero traces → clean re-dispatch. P3.4: partial work found uncommitted (WorkflowAggregator.swift, PodiumStore+Workflows.swift, small PodiumStore.swift diff) with 3 compile errors at the interruption point — orchestrator applied stopgap unwrap fixes (`?? 0`, `.int`→`.intValue`), auto-commit hook landed it as c909bcb, baseline re-verified 171/171 green. Both tasks re-dispatched ~21:35 CEST with path fences (P3.1 additionally owns HooksRouter.swift:25 seam wiring; P3.4 told to audit predecessor work + review the stopgaps). |
| 2026-07-04 | P3.3 pricing + settings | Sonnet 5 (2 agents, resumed) | ✅ | All pricing/cost/settings endpoints + 38 new tests; 303/303 green at e0aa2c0 (before P3.2's later WIP). **Real bug found+fixed: Hummingbird does NOT percent-decode path params** — DELETE /api/pricing/:pattern got literal `%25`, matched nothing, 404 (every model_pattern contains `%`); fixed with .removingPercentEncoding — **check any future router with encodable path params**. GET /info hook-status uses ClaudeHome.settingsPath() (override-aware), NOT HookInstaller's hardcoded default — Node parity. Heap fields = RSS proxy (no V8 heap in Swift), documented in ServerRuntimeInfo.swift (Diagnostics/ — P4.4 can build on it). ReimportRunner seam: protocol {run() async throws -> ReimportResult{imported,skipped,errors}}, threaded through ServerContext/PodiumServerApp as optional (nil → 503 NOT_IMPLEMENTED, tested); orchestrator wires P3.2's LegacyImporter adapter when it lands. JSONResponse gained extraHeaders (Content-Disposition for /export) — additive. Attribution of 4787b9c mystery files resolved: all P3.3's. CAVEAT: its report claimed PricingRouterMount was already in main.swift — false (fence respected, so neither mount was there); orchestrator added PricingRouterMount+SettingsRouterMount, build-verify pending P3.2's WIP settling. |
| 2026-07-04 | P4.1 run-spawner | Sonnet 5 (2 agents, resumed) | ✅ | Predecessor's port audited line-by-line vs run-spawner.js/routes/run.js — faithful; continued. Known WIP failure: the TEST was wrong (Node clamps limit into [1,500] BEFORE SQL, so limit=-5 → 1 row) — impl already matched. Closed gaps: injectable reap delay (+2 tests), run_input_ack broadcast assertion, RunRouterTests.swift from scratch (18 HTTP tests: same-origin guard, spawn→fetch→kill lifecycle, 429 concurrency, /files traversal + node_modules skip). 295/295 at commit 86e12cb. **P5.4 wire gotcha: live-handle family (GET /, GET /:id, POST / resp, WS run_*) is camelCase on the wire (Node parity); GET /history rows snake_case + spliced isLive — do NOT use PodiumJSON for the camelCase family (see RunRouter.swift header).** §6b №2: read side confirmed — unknown envelope types pass through verbatim to replay/stream; write-back half (control-response framing onto stdin) NOT built, needs sendInput extension when popup lands. **Auto-commit hook misattributes: commits sweep the whole dirty tree — use `git show <commit> -- <file>` for real authorship.** Diagnostics/ServerRuntimeInfo.swift + ReimportRunner.swift + JSONResponse/RouterRegistry diffs in 4787b9c are NOT P4.1's (likely P3.3's /info + seam work — confirm from its report). |
| 2026-07-04 | 🟦 reconcile #2 (session limit ~22:02) | Fable 5 | ✅ | All 3 lane agents died at the account session limit. P4.1: heavy partial work committed (Runs/ 4 files, PodiumStore+Runs, RunRouter, main.swift/PodiumServerApp/RouterRegistry edits, 3 test files; 1 failing WIP assertion PodiumStoreRunsTests:78). P3.3: pricing half done (CostCalculator ext, PodiumStore+Pricing, PricingRouter, HookInstaller edit; settings router + tests missing) — orchestrator stopgap: readDbPragmas() `.string/.int` → `.stringValue/.intValue`. P3.2: zero traces. Partial work committed as d3d8155; 243/244 green (the 1 failure is P4.1's own WIP test, left for it to resolve). All 3 re-dispatched ~00:35 CEST with resume-audit instructions + same fences. |
| 2026-07-03 | P3.1 transcript engine | Sonnet 5 | ✅ | ClaudeHome (override file > CLAUDE_HOME env > ~/.claude; setClaudeHome ready for P3.3), TranscriptCache (mtime+size invalidation, LRU 200, incremental-read-on-growth, stats() matches SettingsInfoResponse shape), TranscriptMessageParser (all 4 pagination modes), TranscriptCacheTokenSource wired in HooksRouter. 501 stubs gone. 37 new tests, 220/220 green (verified by orchestrator). Pagination cursors verified against ConversationView.tsx round-trip flow (fixed a trailing-newline off-by-one before locking cursor tests). Token-0 bug: write path closed + e2e-tested with the REAL token source; pure-legacy sessions still need P3.2. Deviation: full-range Data reads instead of Node's 4MiB chunking (no V8 ceiling in Swift). P3.2 entry points: TranscriptCache.invalidate/.clear/.shared.extractCompactions. Commits c223963 + da70539 + auto-commits. |
| 2026-07-03 | P3.4 workflows API | Sonnet 5 | ✅ | Predecessor's WorkflowAggregator/PodiumStore+Workflows audited line-by-line vs workflows.js — solid, continued not restarted; orchestrator's 3 stopgap fixes confirmed correct (SUM()-over-zero-rows returns SQL NULL → `intValue` coalesce matches Node's `|| 0`). Added WorkflowsRouter (GET /api/workflows, /session/:id; CodedErrorResponse 404), main.swift mount, 12 tests (8 aggregator unit + 4 HTTP vs seeded DB incl. negative-duration clamp). 183/183 green at completion. **Node parity quirk preserved, not fixed: 2–3-step tool sequences double-count in pattern mining (full-sequence + sliding-window passes collide on the same key).** For P5.4: response models = WorkflowSummary/WorkflowDetail in Models/Workflow.swift, match client types.ts WorkflowData/SessionDrillIn. Commits 7095054 + f894704. |
| 2026-07-04 | P3.2 audit + P4.2 tests + wiring debt (completion agent) | Sonnet 5 | ✅ | **P3.2 audit vs §6 prompt: everything already genuinely done, not just apparently done** — LegacyImporter (importAllSessions/backfillCompactions/importCompactions/scanAndImportSubagents, all 1165 lines), ImportRouter (guide/rescan/scan-path/upload incl. hand-rolled multipart parser, no new dep), ServicesRunner's 4 real services (legacyImport w/ `.legacy-import.done` marker written only post-success, periodicSweep w/ broadcasts, watchdog 15s API-error loop, stuckAgentCheck 60s loop — both P2.3-deferred loops present and tested), `scanAndImportSubagents` wired from HooksRouter post-SubagentStop (not deferred — better than the plan expected). 10 LegacyImporterTests + 12 ImportRouterTests + ServicesRunnerTests all pre-existing and passing. No gaps found; nothing needed fixing. **Wiring debt closed:** `ImportRouterMount`+`PushRouterMount` added to `PodiumServerCLI/main.swift`'s mounts array; `reimportRunner`/`pushService` params threaded through `PodiumServerLifecycle.makeApp`/`.run` (were previously dropped between `main.swift` and `PodiumServerApp`); `LegacyImporterReimportRunner` adapter (wraps `LegacyImporter.importAllSessions`+`backfillCompactions`) built and passed at the CLI call site — `POST /api/settings/reimport` no longer 503s. **P4.2 test suite written from zero** (acceptance bar: RFC 8291 vectors, VAPID round-trip, PushRouter HTTP, PushNotifier seam): `WebPushEncryptorTests` (byte-exact RFC 8291 §5 worked example via fixed sender key + fixed salt, header layout, independent receiver-side decrypt round trip); `VAPIDKeysTests` (P-256 validity, Node web-push `vapid-keys.json` camelCase round trip in temp dirs, malformed-file error, VAPID JWT header/payload/compact-signature shape); `PushRouterTests` (12 HTTP tests: vapid-public-key, subscribe upsert/validation, unsubscribe, send fan-out over 2 subscriptions with header assertions, 404/410 pruning, 5xx non-pruning, all via a `StubWebPushTransport` — zero real network calls); `PushNotifierTests` (7 tests: all 4 `NotifierEvent` cases fire with correct title/body incl. no-name fallback, payload shape decrypted end-to-end via a capturing transport + the subscription's own keys, matches `sw.js`'s `NotificationOptions` spread contract). 355/355 green (324 baseline + 31 new). **Real finding, not a bug:** `PushNotifier`'s additive `data.sessionId`/`url` click-through fields go through `PodiumJSON.encoder` (`.convertToSnakeCase`), so the wire key is `session_id` — harmless today since no client JS reads it yet (feature isn't wired into `push.ts`/`sw.js`), but flag before any future click-through UI work assumes camelCase. **Manually smoke-tested the real `podium-server` binary** (temp data dir, `--no-hooks`, random port): `/api/health`, `/api/import/guide`, `/api/push/vapid-public-key` all respond correctly; `POST /api/settings/reimport` against an isolated empty fixture (via `CLAUDE_HOME` override) returns `{ok:true,imported:0,skipped:0,errors:0}` in ~10ms confirming the wiring — but the SAME endpoint against the user's real `~/.claude/projects` (294 real files) pinned one core at 100% CPU for 2+ minutes without finishing; killed it, never touched real data beyond reads. **Flagged as a follow-up task (not fixed in this pass, out of scope for the wiring/test brief): `LegacyImporter`'s `backfillCompactions` re-scans every session's full JSONL on every call, and `snapshotTranscript` copies every file unconditionally per import — likely the source of real-corpus slowness; needs profiling against large real transcripts, not fixture-scale ones.** Commits: 82173c3, e6d3818, 1ce89fb, c313363 (tests) + d8f92a5 auto-commit (wiring). |

| 2026-07-04 | **Phase-3 hardening gate** | Sonnet 5 (orchestrator) + 3 review sub-agents | ⚠️ | 355/355 green re-verified (one flaky re-run failure not reproducible). Live-binary smoke test (temp dir, random port, `--no-hooks`) clean across sessions/agents/events/stats/analytics/search/transcripts/import/pricing/settings/workflows/run/push. **8 confirmed bugs found, 0 blockers, all fixable without redesign — dispatched as parallel fix tasks, NOT yet fixed as of this entry:** (1) `IngestEngine.swift` fires push-notifier `Task`s *before* `COMMIT` (SessionEnd ~L621, cost_spike ~L782) — a rolled-back transaction can still fire a real OS notification; fix: defer notifier events alongside broadcasts, fire only post-commit. (2) `TranscriptCache.swift` trims the parse array on every append instead of at the `parseTrimWatermark` (2× cap, computed but unused) — O(N) per line instead of amortized O(1) on long transcripts. (3) **`WorkflowsRouter.swift` top-level keys are wrong on the wire** — Node's `workflows.js` hand-builds `res.json({...toolFlow, modelDelegation, errorPropagation...})` / `{...toolTimeline, swimLanes...}` in **camelCase** (confirmed against the actual Node source, not just types.ts) while every other endpoint is snake_case; Swift's `JSONResponse` always applies `PodiumJSON.encoder`'s `.convertToSnakeCase` uniformly, so both `GET /api/workflows` and `GET /api/workflows/session/:id` currently emit `tool_flow`/`model_delegation`/`error_propagation`/`tool_timeline`/`swim_lanes` — the vendored React client reads the camelCase names, so today these fields render **silently blank/undefined**, not a crash. Root cause: Swift's `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` cannot be bypassed per-key even with explicit `CodingKeys` (transforms the resolved key string unconditionally) — needs either a route-local raw-fragment JSON assembler (encode each sub-object independently with `PodiumJSON.encoder`, splice under literal camelCase top-level keys) or an equivalent workaround; do NOT try to "fix" via CodingKeys alone, it won't work. (4) `RequestDecoding.swift` `queryInt`/`queryIntOrNil` use strict `Int(raw)` vs Node's lenient `parseInt(raw,10)` (accepts leading `+`, whitespace, trailing garbage) — systemic across every numeric query param, low real-world hit rate but genuine parity gap. (5) `SessionsRouter.swift` clamps `limit` to `min: 0` at two call sites (`GET /` ~L41, `GET /:id/transcript` ~L295) but Node's `Math.min(parseInt(...)||50, N)` has no lower clamp — negative `limit` should mean "unlimited" (SQLite `LIMIT -1` semantics) not zero rows. (6) `AgentsRouter.swift` ~L38 silently maps an unrecognized `?status=` value to `.waiting` instead of Node's behavior (query runs with the literal bogus string, matches nothing, returns `[]`) — real behavior divergence for typo'd/future status values. (7) Empty-string body fields (`name`/`status`/`task`/`cwd`/`model`/etc.) overwrite existing values via SQL `COALESCE(?, existing)` on PATCH instead of Node's `field || null` collapse-to-null-first pattern (`agents.js`/`sessions.js`) — sending `{"name":""}` wrongly blanks a column Node would have left untouched. (8) `SearchRouter.swift` routes cost calculation through the shared `CostCalculator` (regex, longest-pattern-first) but Node's `search.js:89-104` uses a **different**, search-endpoint-only algorithm (raw-order `startsWith` on trailing-`%`-stripped pattern) — can silently disagree with the cost shown everywhere else for the same session. **Minor, no action needed:** `usage_extras` metadata (service_tiers/speeds/inference_geos) never populated in LegacyImporter (cosmetic gap, no consumer yet); unsanitized path-join in `scanAndImportSubagents` matches Node's identical unguarded join (same local-only trust model, not a regression); `claude-sonnet-5%` has no pricing seed row (pre-existing Node staleness, not a Swift bug — costs 0 on both servers today). **Push crypto (RFC 8291/8292/8188), run-spawner/RunRouter, SQL-injection/path-traversal sweep across all routers, and broadcast-ordering: all verified clean, no findings.** None of the 8 bugs touch `Sources/PodiumApp`, `PodiumServerLifecycle`, or server embedding — **verdict: does not block P5.1**, dispatched to run in parallel via two fix-it agents fenced to non-overlapping paths (Ingest+Transcripts vs Routes+JSONResponse).

| 2026-07-04 | P5.1 embed server in-process | Sonnet 5 | ✅ | New `Sources/PodiumApp/EmbeddedServer.swift`: `EmbeddedServer.shared.resolveAndStart(configuredHost:configuredPort:)`, called from `AppState.start()` before building `PodiumAPI`/connecting WS. Single-instance check: health-GETs `preferredPort` (the app's configured/default port) unconditionally, plus any additional PID-verified-live entries from `~/.claude/.agent-dashboard.json` **only when that file exists** (its `[4820]` guess-fallback for a missing file is for hooks' best-effort POST semantics, not this decision) — if anything answers, connects as a pure client (zero changes to that path); otherwise hosts via `PodiumServerLifecycle.run` (chosen over `.makeApp`+manual `runService()` — `.run` already has the port-fallback-to-+20 loop, server-info write/remove, and services bookkeeping) in a detached background `Task`, polling health across the candidate port range to learn which port it actually bound before returning. `PushService` constructed explicitly with `NativeNotifier()` (task 4 — matches the default `PlatformNotifier.makeDefault()` already resolves to on macOS, but now explicit at the call site). `HookInstaller.install`/`installBinary` run non-fatally at hosting-start (same pattern as `PodiumServerCLI.installHooksNonFatal`); `run.sh` now also builds `podium-hook` and bundles it into `PodiumApp.app/Contents/Resources/` so `EmbeddedServer` has a binary to install (`Bundle.main.path(forResource:)` in the app bundle, sibling-of-executable in dev `.build` layout). Graceful shutdown: `AppDelegate.applicationWillTerminate` (fires for Cmd+Q / Quit menu — the app's `applicationShouldTerminateAfterLastWindowClosed` returns `true` but `MenuBarExtra` keeps the process alive on window-close alone, so this was the one reliable pre-exit hook) calls `EmbeddedServer.shared.shutdown()`, which cancels the background run `Task` and calls `ServerInfoWriter.remove()` directly (belt-and-suspenders alongside `.run`'s own `defer` cleanup, since `Task.cancel()` only requests cooperative cancellation and we don't want app quit blocked on Hummingbird's async shutdown). Settings: new "Embedded Server" section in `ConnectionTab` (`SettingsView.swift`) — `@AppStorage("podium_embedded_server_enabled")` toggle (default ON via `EmbeddedServer.embeddedServerEnabledKey`, restart-to-apply per spec) + a live mode/port/db-path status row reading `EmbeddedServer.shared.mode`. `Package.swift`: `PodiumApp` target now depends on `PodiumServer`+`PodiumCore` (was previously dependency-free). **377/377 tests green** (355 baseline + 22 that landed from the parallel Phase-3 fix-it agents during this session — none of my files caused failures; verified by re-running after their auto-commits settled). **Live-verified end-to-end, twice, both directions:** (1) real machine, real `./run.sh`: with Gaël's production Docker container live on 4820, the app correctly detected it via the unconditional health-check-of-preferred-port and connected as a pure client — confirmed via `lsof` (only an outbound `ESTABLISHED` connection to 4820, no listening socket opened by PodiumApp, no `.agent-dashboard.json` write) — **his real data was never touched, at no point did the app attempt to bind a port**. (2) isolated sandbox (`HOME`/`DASHBOARD_DATA_DIR` overrides, `-podium_port` NSUserDefaults CLI arg, unused high port, real `.app` bundle launched directly so `NSApplication`'s full lifecycle runs): embedded hosting engaged, hooks auto-installed into the sandboxed `~/.claude/settings.json` (8 entries, correct binary path), `.agent-dashboard.json` written with real port+PID; **piped real `SessionStart`/`PreToolUse` JSON payloads through the sandboxed `podium-hook` binary exactly as Claude Code would invoke it** — `GET /api/sessions` and `GET /api/agents` on the embedded server immediately showed the live session (status `active`, correct `cwd`/name) and synthesized main agent (`current_tool: "Bash"`) — this is the actual P5.1 acceptance bar, confirmed with zero Node/plugin involvement. Then quit via the real Podium menu → Quit item (AppKit's real termination path, not a bare SIGTERM to a raw executable, which does NOT run `applicationWillTerminate`): process exited, `.agent-dashboard.json` deleted entirely (the only entry was removed, so `ServerInfoWriter.persist([])` deletes the file per its own doc comment), health check on the dead port failed immediately. **Deviations from the brief:** none structural; one correction made mid-session — an earlier draft of the single-instance check additionally trusted `HookPortDiscovery.resolvePorts()`'s hardcoded `[4820]` fallback even when `.agent-dashboard.json` didn't exist, which would have been *too* eager to skip hosting on a machine where nothing is actually listening on 4820 (that fallback exists for hook POST best-effort semantics, not host-or-not decisions) — tightened to only trust that fallback list when the info file is actually present, while still always checking the app's own configured/preferred port unconditionally (which is what actually catches Gaël's containerized instance, since it doesn't write the discovery file). **Notes for P5.3/P5.4/future work:** `EmbeddedServer.shared.mode` is the one source of truth for "are we hosting" — `MenuBarView.swift` was left untouched per the brief (already shows session/agent counts + cost + Open/Quit, satisfies the menu-bar requirement) but could optionally surface `.mode` too if a future task wants port/mode visible from the menu bar without opening Settings. The `-podium_port`/`-podium_host` NSUserDefaults argument-domain trick used for manual testing is a handy pattern for any future agent needing to smoke-test multiple app instances side by side without touching the real `~/Library/Preferences` plist. `LegacyImporterReimportRunner` is duplicated (not shared) between `PodiumServerCLI/main.swift` and `EmbeddedServer.swift` since the CLI's copy is `internal` to its own target — if `ReimportResult`'s shape ever changes, update both.

| 2026-07-04 | Phase-3 hardening fixes (2 parallel agents) | Sonnet 5 | ✅ | All 8 confirmed gate bugs fixed and tested, 377/377 green (orchestrator re-verified after both landed). **fix-core** (Ingest+Transcripts fence): `IngestEngine.swift` now threads `pendingNotifications: inout [NotifierEvent]` through `processTransactionBody`/`handleSessionEnd`/`extractTranscriptSignals` exactly like the existing `broadcasts` pattern — notifier `Task`s only spawn after `COMMIT` succeeds in `process()`; added a test-only `testFailurePoint` hook to simulate a mid-transaction throw for the regression test (`SpyNotifier` actor added to IngestEngineTests, 3 new tests). `TranscriptCache.swift` split `trimIfNeeded` into an unconditional variant (still used in finalize/merge, matches Node's `_trimArray`) and a new `trimAtWatermarkIfNeeded` gated on `array.count >= parseTrimWatermark` (used at all 4 `consumeLine` call sites, matches Node's `_consumeLine` exactly) — added a test-only `watermarkTrimExecutionCount` counter to make the amortized-O(1) behavior directly observable in tests. **fix-routes** (Routes+JSONResponse fence): added `JSONResponse(fields:)`, a raw-fragment JSON assembler (encodes each sub-object independently via `PodiumJSON.encoder` then splices under literal top-level keys, sidestepping Swift's all-or-nothing `KeyEncodingStrategy`) — `WorkflowsRouter.swift`'s two handlers now emit real `toolFlow`/`modelDelegation`/`errorPropagation`/`toolTimeline`/`swimLanes` camelCase top-level keys, verified via `JSONSerialization`-based tests (not round-tripped Codable, so a regression would actually be caught). Added `jsParseInt`/`collapseEmpty` helpers in `RequestDecoding.swift` (JS-`parseInt` leniency + `field||null` collapse), wired into Sessions/Agents routers. Removed the `min: 0` limit clamp at both SessionsRouter call sites — but discovered or the price-sort branch in `PodiumStore+Filters.swift`, Node's `Array.slice(offset, offset+limit)` on a negative limit is a **different quirk** than SQL's negative-`LIMIT`-means-unbounded (JS slice with a negative end counts back from the array's end) — added a `jsSlice` helper replicating the exact JS semantics for that one branch instead of assuming the same "negative = unbounded" rule applied uniformly. AgentsRouter's unknown `?status=` now short-circuits to `[]` instead of silently querying `.waiting`. SearchRouter got its own `searchCosts`/`matchSearchRule` (raw-order `startsWith` on trailing-`%`-stripped pattern, per `search.js` lines 82-103, confirmed exact) instead of routing through the shared `CostCalculator`. New `RequestDecodingTests.swift` (10 tests) + additions to `WorkflowsRouterTests.swift`/`ReadRoutersTests.swift`. Both agents verified every fix against actual Node source line numbers (not the approximate ones in the gate write-up) — see each commit for the corrected references. **Minor gate findings needed no action** (usage_extras metadata gap, SubagentStop path-join parity, stale pricing seed row) — left as documented, not bugs.
| 2026-07-04 | P4.3 ∥ P4.4 dispatched | Sonnet 5 | 🟦 | Two parallel agents dispatched after the hardening-fix verification (377/377 green, build clean): `p4-3-ccconfig` (cc-config explorer/watcher/updates/export bundles — fenced to new files under PodiumCore/Discovery + new PodiumServer/Routes/{CcConfigRouter,UpdatesRouter,ExportRouter}.swift) and `p4-4-diagnostics` (no §6 prompt existed for this task — orchestrator wrote a full spec inline referencing P3.3's `ServerRuntimeInfo.swift`; fenced to new files under PodiumCore/Diagnostics + new PodiumServer/Routes/DiagnosticsRouter.swift + new Sources/PodiumApp/DiagnosticsView.swift). **Both agents told NOT to touch `PodiumServerCLI/main.swift`'s `mounts:` array or `EmbeddedServer.swift`'s `makeServerMounts()`** (both P5.1-added files, same list duplicated in two places) — instead each reports back the exact `RouterMount.Type` name(s) to add, and the orchestrator will hand-merge both sets of mount registrations after both land, avoiding a repeat of the P3.2/P3.3-wave merge friction noted earlier in this log.
| 2026-07-04 | 🟦 reconcile #3 (session-3 ended) | Fable 5 | ✅ | Session-3's P4.3/P4.4 agents unreachable (died with it, ~09:35 CEST). P4.3 partial: Discovery/{CcConfig,CcMutate,CcWatcher,UpdateCheck}, CcConfigRouter/UpdatesRouter, watcher+update services, ZIPFoundation dep — all committed; PodiumStore+SessionBundle.swift was half-written referencing a never-created SessionExportBundle model (broke the build) → parked at .agent-stash/ for the successor; ExportRouter + tests missing. P4.4 partial: LogRingBuffer/DiagnosticsResponse/DiagnosticsRouter/DiagnosticsView + HooksRouter recording committed; DiagnosticsTests:114 reset test failing (handed to successor). Checkpoint 1353377; baseline 393/394. Both re-dispatched ~09:45 CEST as -r2 with resume-audit prompts; mounts still orchestrator-owned in BOTH main.swift and EmbeddedServer.makeServerMounts(). |
| 2026-07-04 | P4.4 diagnostics | Sonnet 5 (2 agents, resumed) | ✅ | The failing reset test exposed a REAL race, not a test artifact: DiagnosticsRecorder fired detached `Task { log.append }` instead of awaiting — /api/diagnostics could read a stale log; fixed by making the methods properly async (call sites already awaited). Removed a 200ms sleep workaround the race had forced into a sibling test. Native panel wired into ContentView sidebar (new "System" section). HooksRouter stale "NOT YET MOUNTED" comment fixed. 394/394 green. Orchestrator added DiagnosticsRouterMount to BOTH mounts arrays (main.swift + EmbeddedServer.makeServerMounts()), build+suite verified green after. Note: agent used pathspec-limited commits to avoid scooping P4.3's concurrent staged work — good pattern for shared-checkout agents. |
| 2026-07-04 | P4.3 cc-config/updates/export | Sonnet 5 (2 agents, resumed) | ✅ | Predecessor's Discovery/{CcConfig,CcMutate,CcWatcher,UpdateCheck} + CcConfigRouter/UpdatesRouter + services audited solid. **Real deadlock fixed in restored PodiumStore+SessionBundle.swift:** importSessionBundle's row helpers called db.run INSIDE db.transaction's serial-queue sync — libdispatch SIGTRAP; rewired helpers handle-based per Schema.swift's topUpDefaultPricing pattern. SessionExportBundle model preserves export.js validation order; ExportRouter mounted at BOTH /api/export and /api/import (Node mounts it twice). 25 new tests (backup rotation, traversal rejects, fake GitHub transport, export→import round trip). **Deviation (parity over prompt): export.js does NOT zip — plain res.json + Content-Disposition; §6 P4.3 prompt's "zip bundle" was wrong. Orchestrator dropped the now-unused ZIPFoundation dep.** ServicesRunner.defaultServices() already includes both new services — no activation wiring needed. Orchestrator wired CcConfig/Updates/Export mounts into BOTH arrays. |
| 2026-07-04 | Negative-uptime flake (orchestrator fix) | Fable 5 | ✅ | P4.3 flagged DiagnosticsRouterTests failing "consistently"; actually ~50% flaky. Root cause: Date() is non-monotonic — uptimeSeconds read within the same quantum as the lazy processStartDate capture returned −1e-06s; /api/diagnostics could genuinely report negative uptime. Fixed with max(0,…) clamp in ServerRuntimeInfo.uptimeSeconds; 8/8 isolated runs + full suite 419/419 green. |
| 2026-07-04 | PodiumApp inventory audit (pre-P5.3/P5.4) | Explore agent | ✅ | 36 files (CLAUDE.md says 10). **P5.3 ~90% done** (Conversation+Thinking tabs w/ cursor pagination, SearchView+Cmd+K, rename/export/cleanup actions, bonus SessionReplayView) — only real gap: live transcript append on WS new_event + jump-to-latest. **P5.4 ~70% done**; gap list: (1) ConfigExplorerView reads LOCAL FS directly, not /api/cc-config — wrong in client mode, no edit/save/backups (highest value); (2) WorkflowsView never calls top-level GET /api/workflows (fakes overview from sessions/analytics); (3) analytics() passes no tzOffset; (4) RunView missing permission-mode/effort pickers + run_input_ack WS handling; cwd picker uses NSOpenPanel not /api/run/cwds (acceptable deviation?). §6 P5.3/P5.4 prompts MUST be rewritten as audit-and-fix, NOT build — an agent following them as written would rebuild+regress working UI. Conventions to enforce: isInitialLoad spinner gating, @AppStorage appearance (no hardcoded dark), @Observable only, EmbeddedServer.shared.mode, camelCase run wire family. |
| 2026-07-04 | **Phase-4 hardening gate** | Sonnet 5 (reviewer) | ⚠️ FAIL→fixing | 419/419 baseline. **2 BLOCKERS:** (1) GET /api/diagnostics?log_limit=-1 = unauthenticated remote crash-DoS — queryInt unbounded → LogRingBuffer.snapshot → Array.prefix(-1) traps fatally (server binds 0.0.0.0); fix = min/max clamp like every sibling router. (2) Systemic camelCase corruption in cc-config wire: ~30 fields Node emits camelCase (claudeHome, mcpServers, backupPath, projectScoped, plugin/marketplace panels…) get convertToSnakeCase'd — live vendored client reads undefined (Overview roots/counts, MCP tab, backup toasts). CodingKeys can't bypass the strategy (re-transforms resolved keys); fix = manual encode via [String:JSONValue] dicts (dictionary keys bypass keyEncodingStrategy — verified). Contrast: SessionExportBundle deliberately chose names that snake-case correctly — footgun known, unevenly applied. **MINOR (non-blocking):** symlink-following gap in isUnder/readFileSafe is EXACT Node parity (path.resolve has the same hole) — joint follow-up ticket, both codebases; watcher shutdown uses unawaited detached stop() (matches documented shutdown philosophy, fine while process exits after). **Confirmed clean:** SessionBundle deadlock fix complete (all transaction call sites grepped), Diagnostics actor/ring bounds, all 4 new mounts in both arrays, services swapped in, export/import round trip + CodedErrorResponse vs actual client, CcMutate name regex blocks traversal, watcher debounce. **P5.4 verdict: do NOT build UI on /api/cc-config until blocker 2 lands.** |
| 2026-07-04 | P5.3 transcript polish (rescoped) | Sonnet 5 | ✅ | Live transcript append: AppState.transcriptEventTick bumped per WS new_event → new TranscriptLiveStore (@Observable, RunState pattern) debounces 600ms, fetches after:lastLine, drains ≤5 pages/burst, single-flight guard; scroll preserved via bottom-sentinel PreferenceKey (macOS-14-safe; onScrollGeometryChange needs 15) — near-bottom auto-scrolls, scrolled-up grows silently + gold "N new messages ↓" pill (new; Thinking tab gets append but no pill by design). **Latent bug fixed in passing: no .id(sessionId) in the master-detail nav path meant tab view identity was reused across session switches → stale transcript; store now recreated via .task(id:).** Token-0: loadTranscriptTokens already falls back correctly, untouched. 419/419 green. Disclosed gaps: no PodiumAppTests target exists (store built DI-ready; creating the target = Package.swift/CI change, deliberately not done unasked); **live click-through NOT done — agent declined to kill Gaël's running PodiumApp (PID since 7:20) — HUMAN VERIFY: open Conversation tab on an active session, fire a hook event, expect append/auto-scroll or pill.** Commits 2592454/0858788/de154d0/a5528d7. |
| 2026-07-04 | Phase-4 gate fixes → **GATE PASS** | Sonnet 5 | ✅ | Both blockers fixed, 432/432 (13 new tests), orchestrator re-verified. B1: log_limit clamped (min:0, max:ring cap) + defensive guard in LogRingBuffer.snapshot (guard limit>0) so the actor can never trap regardless of caller; regression tests -1/0/huge → 200. B2: new PodiumJSON.AnyEncodable — custom encode(to:) building [String:AnyEncodable] (Dictionary keys bypass keyEncodingStrategy at any depth; verified both directions — init(from:) synthesis intact since convertFromSnakeCase is a no-op on camelCase keys). 12 structs fixed across CcConfig/CcMutate. **Corrected a dispatch-list false positive: SettingsSource.rawSize is legitimately snake_case (raw_size in Node + client) — left alone.** Wire-format tests assert raw bytes via JSONSerialization, not round-trip. MINORs (symlink parity gap, watcher shutdown) left documented per instruction. Phase 4 CLOSED. |
| 2026-07-04 | P5.4 native UI gaps | Sonnet 5 (bg re-dispatch, died post-completion) | ✅ | Verified complete by orchestrator at 22:50: ConfigExplorerView repointed to /api/cc-config (new PodiumAPI+CcConfig.swift + Models+CcConfig.swift, edit/save via PUT /file, backups browser), WorkflowsView overview now calls real GET /api/workflows, analytics passes tz_offset (minutes, -secondsFromGMT/60), RunView gained permission-mode + effort pickers, RunState handles run_input_ack. Agent died before reporting — completeness verified by grep + build + 432/432 green. No formal report; treat undocumented corners with suspicion at P6.2 E2E. |
| 2026-07-04 | P5.5 onboarding tour | Sonnet 5 | ✅ | Native: OnboardingTour.swift — 5-step glass overlay w/ spotlight cutouts on real sidebar rows (preference-key anchors), Help→Show Tour re-run, live legacy-import count on step 1 (marker-baseline check ordering in PodiumApp.swift is load-bearing). Web: welcome card added to Dashboard.tsx mirroring the existing notif-banner localStorage pattern; proper flow — scratch copy → npm build → vendored dist + WebClient/patches/first-visit-card.patch; verified by booting real server + grepping served bundle. 433/433 green (excluding P6.2a-@P's uncommitted WIP ContractTests). **HUMAN VERIFY pending: visual light/dark pass of the tour (agent could not launch — Gaël's app was running).** Gitignore hazard flagged → orchestrator warned P6.1 mid-flight to anchor its dist/ patterns. |
| 2026-07-04 | F1 import perf | Sonnet 5 | ✅ | Profiled on synthetic 320-file/78MB corpus (CLAUDE_HOME fixture). Root causes confirmed: no file-level skip anywhere (every call full-parses the corpus; Node has the same gap), reimport double-parses (importAllSessions then backfillCompactions re-read identical bytes), unbatched writes. Fix: additive import_file_cache table (path, mtime_ms, size — CREATE IF NOT EXISTS, no migration), batched cache lookups, unchangedFileFilter shared by both passes (second pass sees first pass's fresh entries → skips), files cached only after SUCCESSFUL import (failures retry), writes batched in short 25-op BEGIN/COMMIT transactions (deliberately short so live hook writes never fold into the import txn on the serial DB queue). Before→after: repeat reimport 29.4s→0.09s (~380x); first run 33.9s→15s. Deterministic regression test (skipped==50, not timing-based). **Follow-up flagged, not v1-blocking: cold-cache first import still ~seconds-per-hundred-files of CPU; making POST /reimport async w/ progress needs Routes changes — revisit if real-corpus first-run UX warrants.** All import tests green. |
| 2026-07-04 | 🟦 reconcile #4 (P5.4, morning scheduled pickup) | Sonnet 5 (Podium Standalone scheduled orchestrator) | ⚠️ dead, re-dispatched | Picked up cold ~12:48 CEST; previous session's P5.4 dispatch (logged at commit 01e7245, ~10:26 CEST) left **zero trace**: working tree clean, no new commits under Sources/PodiumApp since a5528d7 (P5.3), `swift test` still exactly 432/432 (the Phase-4 gate baseline, no new P5.4 tests). Agent died before its first commit/auto-commit fired. Re-dispatched fresh per §0 step 2, same fences as the inventory audit (ConfigExplorerView/WorkflowsView/AnalyticsView/RunView), explicitly told cc-config blocker 2 (camelCase corruption) is now fixed so it may build real UI against `/api/cc-config`. |
| 2026-07-04 | P5.4 `p5-4-native-ui`'s full report recovered (scheduled orchestrator) | Sonnet 5 (Podium Standalone scheduled orchestrator) | ✅ | This agent (dispatched ~12:55 CEST, same one the interactive Fable session already verified via grep+build at 22:50 and flipped ✅) actually **did** report back to this session — the Fable session's "agent died before reporting, no formal report" caveat can be relaxed. Full self-report, condensed: all 4 gaps closed as already logged. **New details not previously captured:** verification method was live — booted the real `podium-server` binary against a seeded `CLAUDE_HOME`, curled every new `/api/cc-config/*` endpoint, decoded live JSON with a standalone script using an exact copy of `JSONDecoder.podium` (no PodiumAppTests target exists, so this stood in for unit tests); PUT-then-GET-backups-then-GET-file round trip confirmed live against the real server. New `PodiumAPI+CcConfig.swift` (ccOverview/ccSkills/ccAgents/ccCommands/ccOutputStyles/ccPlugins/ccMcpServers/ccHooks/ccSettings/ccMemory/ccMarketplaces/ccKeybindings/ccStatusline/ccHookScripts/ccBackups/ccReadFile/ccWriteFile/ccDeleteFile) + `Models+CcConfig.swift` (CcOverview, CcSkillItem, CcMdItem, CcPlugin*, CcMcp*, CcHooks*, CcSettingsSource, CcMarketplace*, CcKeybinding*, CcStatusline*, CcHookScript*, CcMemoryItem, CcFileReadResult/CcWriteResult/CcDeleteResult, CcBackup, CcJSONValue) + new `WorkflowSummary`/`WorkflowDetail` models in Models.swift + `RunInputAckMessage` in RunState.swift + non-breaking `APIError.badStatusWithMessage(Int, String?)` case. **Deliberate deviations, confirmed not bugs:** old `WorkflowSessionRaw`/`PodiumAPI.workflowSession` (narrower shape) kept but now unused by WorkflowsView — dead code candidate for a future cleanup pass, not wired to anything wrong; MCP servers tab is read-only by design (CcMutate's own hard constraint, not a corner cut); **backup *restore* (copy-back) is NOT wired** — Backups tab is browse-only with an in-UI note, flagged as a natural P5.5+/follow-up rather than silently missing. No server-side bugs found outside the agent's fence — all cc-config/workflows/analytics routers matched documented wire shapes exactly under live testing. This closes the "treat undocumented corners with suspicion at P6.2" flag for P5.4 specifically — the one known open corner (backup restore) is now explicit, not hidden. |
| 2026-07-04 | Scheduled orchestrator standing down | Sonnet 5 (Podium Standalone scheduled orchestrator) | ✅ | Per the interactive Fable session's coordination note in HANDOVER.md (22:55 CEST): P5.5 and P6.1 are claimed 🟦@F and being driven by that session. This session dispatched nothing further (P5.4's own re-dispatch, already reconciled above, was this session's only action) and is disabling the `podium-standalone-morning-pickup` scheduled task per that note and per its own dedup rule (last commit was 1 minute old at check time — another orchestrator is unambiguously live). |

### Notes for future runs

- Podium also contains an `mcp/` server and an Electron `desktop/` shell — **out of
  scope** (the Swift app replaces Electron; MCP can be a later idea).
- Known Podium backend token bug mentioned in memory (`feedback_ui_bugs_wave4.md`) —
  when porting token logic (P2.3/P3.1), verify token-0 sessions render correctly.
- The other session's `native-superpowers` branch may overlap with P5.x — check
  `git branch -a` before starting P5 tasks.
- **Discovered during P0.1 (2026-07-03):** `develop` already contains far more native
  UI than repo CLAUDE.md documents — `RunView`, `SearchView`, `WorkflowsView`,
  `KanbanView`, `ConfigExplorerView`, `SessionReplayView`, `MenuBarView`,
  `SessionExporter`, Spotlight/App Intents, widgets (32 source files). **Re-audit
  Sources/PodiumApp before dispatching P5.1/P5.3/P5.4 and rewrite those prompts to
  fill only the actual gaps** (they were written against the stale CLAUDE.md
  inventory). P5.2 (re-theme + spinner fix) is unaffected.

#### P0.1 notes (2026-07-03)

- **Hummingbird version pin:** latest `hummingbird`/`hummingbird-websocket`/`swift-nio-ssl`/
  `swift-asn1` require Swift **tools-version 6.1**, not 6.0. The plan's CI suggestion said
  "container swift:6.0 or swift:5.10" — neither works. CI now uses `container: swift:6.1`.
  Verified locally via Docker (`swift:6.1` image): `swift build` and `swift test` both pass,
  producing `podium-server`, `podium-hook`, and (with the fix below) `PodiumApp` binaries.
- **PodiumApp needs a non-macOS fallback entry point.** Wrapping every PodiumApp source in
  `#if os(macOS)` (as instructed) removes the `@main` on Linux, but `swift build`/`swift test`
  with no `--product` filter still try to link every target, including `PodiumApp` — link
  fails with "undefined symbol 'PodiumApp_main'". Fixed by adding
  `Sources/PodiumApp/LinuxStub.swift`, a small always-compiled file with a `#if !os(macOS)`
  `@main` stub that just prints a "use podium-server" message. This is required for `swift
  build`/`swift test` (no product filter) to succeed on Linux; `run.sh` now explicitly builds
  `swift build --product PodiumApp` so it doesn't need to build the server targets at all.
- **CSQLite uses a shim header**, not `header "sqlite3.h"` directly — `Sources/CSQLite/shim.h`
  does `#include <sqlite3.h>` and the modulemap points at the shim. This avoids relying on
  `sqlite3.h` being on the default include search path in a specific way across apt/brew/SDK;
  no `pkgConfig` needed since `link "sqlite3"` + system providers suffice on both platforms
  (verified: macOS SDK ships `sqlite3.h` directly; Linux via `apt-get install libsqlite3-dev`).
- **Pre-existing bug fixed in passing:** `Theme.swift`'s `glassSurface()` called
  `.glassEffect()`, a macOS 26–only API, while `Package.swift` claimed macOS 14 — this only
  "worked" before because the platform requirement was bogus (`"26.0"`). Now gated with
  `@available(macOS 26.0, *)`; the function has zero callers today so behavior is unchanged.
  Flagging in case a future task wants a macOS-14-compatible glass surface implementation.
- **Web client vendored as a straight copy**, not a rebuild — the reference repo's
  `dashboard/client/dist/` was already fresher than every file under `src/` at copy time, so
  per the task's "if fresh, just copy it" branch, no `npm install`/`npm run build` was run.
  See `WebClient/SYNC.md` for the exact rebuild command if a future task needs to refresh it.
- **Package.resolved is checked in** (new) — first time this repo has external dependencies;
  pins hummingbird 2.25.0, swift-crypto 3.15.1, swift-argument-parser 1.8.2, and their
  transitive graph (swift-nio 2.101.2, swift-service-lifecycle 2.11.0, etc).
