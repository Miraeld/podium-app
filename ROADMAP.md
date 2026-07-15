# Podium — Roadmap to 1.0.0 (Node pivot + monorepo)

> **Author:** Fable 5, acting PO. **Rewritten 2026-07-12** after the Node
> decision (below). Supersedes the Tauri-consolidation roadmap (git history:
> see this file before this commit).
> **Audience:** the next orchestrator / dispatched agents. Self-contained —
> this file + the repo are the whole briefing. Work phases top-to-bottom.
> Every task has a ready-to-paste agent prompt. Do NOT re-do tasks marked
> DONE. Verify `npm test` / build state before continuing someone's work.

---

## 0. THE PIVOT — read this first

**Decision (Gaël, 2026-07-12):** drop the Swift server entirely; 1.0.0 ships
with a **Node server**, and the **React front-end source moves INTO this
repo** (monorepo). Rationale:

- Gaël (and WP Media) are a PHP/JS shop. Nobody there reads Swift. A stack
  the owner can't maintain or defend fails, regardless of technical merit.
- Podium's dashboard is a derivative of the MIT-licensed
  **github.com/hoangsonww/Claude-Code-Agent-Monitor** (= "upstream"). Its
  server is Node. Staying Node keeps upstream merges possible and buys its
  features (alert engine, MCP server) nearly free.
- The two-repo dance (edit source in the old plugin repo → build → vendor
  `WebClient/dist` here) has caused THREE shipped stale-version bugs. It dies
  with this roadmap: front-end source lives here, builds happen here.

**What stays exactly as-is:**
- The **Tauri shell** (`tauri/`) — still the product: one native app, mac +
  Linux, sidecar + tray + notifications. Only the sidecar binary changes.
- The **React client** — same app, same wire format, now living in `client/`.
- The **old plugin repo** (`~/Desktop/Work/Claude/podium`) — FROZEN. We copy
  files out of it once (N1); we never modify it, commit to it, or sync back.
  Its uncommitted working tree IS the current source of truth for the client
  (it contains all shipped fixes) — that working-tree state is what we import.
- The **brand** (black/gold dark, white/gold/blue light, eye logo), the
  onboarding tour, all client-side fixes from the pre-1.0 audit.

**What dies:** `Sources/`, `Tests/`, `Package.swift`, `CSQLite`, the vendored
`WebClient/dist`, `WebClient/SYNC.md`, the Swift CI steps, `podium-hook`
(Swift binary — replaced per N5).

**Wire contract is the spec.** The client's `src/lib/types.ts` + the Swift
`Tests/PodiumServerTests/ContractTests.swift` (30 checks) define the API the
client expects. The Node server must satisfy it. ContractTests get ported to
Vitest (N4) BEFORE Swift is deleted (N7) — never delete the old gate before
the new one is green.

## 1. Base-choice decision (RESOLVED: Option B, upstream-first)

Two candidate Node servers exist:
- **(A)** `~/Desktop/Work/Claude/podium/dashboard/server` — plugin-era fork,
  matches our client's wire format exactly, but frozen pre-audit.
- **(B)** upstream `hoangsonww/Claude-Code-Agent-Monitor`'s `server/` —
  actively developed, has the alert engine + MCP server, but has drifted
  from our client.

**Resolution: start from (B), reconcile against our contract, fall back to
(A) per-route where upstream drifted too far.** N2's gap analysis makes this
concrete per endpoint. If the gap analysis discovers upstream drift is
pervasive (>50% of routes need rework), the orchestrator may flip to
A-as-base + cherry-pick — record the flip here with reasoning.

## 2. Non-negotiable carry-forwards (the audit must survive the pivot)

Every item was shipped on Swift and MUST hold on Node (N3 ports them):

| # | Invariant | Origin |
|---|---|---|
| P1 | Server binds `127.0.0.1` by default; `--host`/`PODIUM_HOST` opt-in + stderr warning | audit A1 |
| P2 | Update check: prompt only when latest release is strictly newer (semver), current `dev` → never | semver fix `12761fb` |
| P3 | `~/.claude/settings.json` written atomically + `.bak` backup | audit A7 |
| P4 | VAPID private key file `0600` | audit B3 |
| P5 | Uniform error envelope `{"error":{"code","message"}}` on all `/api/*` | audit B7 |
| P6 | No dead endpoints: the B6 API trim list stays trimmed | audit B6 |
| P7 | Update check hits ONLY `Miraeld/podium-app` (no `wp-media/podium`) | C2 |
| P8 | `PODIUM_APP_VERSION` mandatory at client build; build FAILS if unset | D1 |
| P9 | Title/branding: "Podium", never "Maestro Observer"; GitHub link → `Miraeld/podium-app` | D2/A2 |
| P10 | MIT attribution to upstream present in LICENSE + README | license |

## 3. Repo layout after the pivot

```
podium-app/                       # this repo (rename from PodiumSwiftApp = N7)
├── client/                       # React source (from old repo, N1)
├── server/                       # Node server (from upstream, N2)
├── hook/                         # hook client (N5)
├── tauri/                        # unchanged shell; sidecar wiring updated N5
├── scripts/                      # dev + packaging (rewritten N6)
├── docs/ (README, RELEASING, PRE-1.0-AUDIT, this file)
└── .github/workflows/            # ci.yml + release.yml (rewritten N6)
```

---

## STATUS (update after EVERY milestone — sessions die at token limits)

- **N1 ✅ DONE** (`585d850` + `888a493`, 2026-07-12): 164 files in `client/`,
  builds green, D1 guard verified, zero old-repo path leaks.
- **N2 ✅ DONE** (`84ee74f`): upstream vendored at `f8b52a8` (boots green,
  better-sqlite3 fine on Node 26). Gap: **46 OK / 2 ADAPT / 4 MISSING of 52**
  → **B-as-base CONFIRMED** (no flip). ADAPT: updates status/check (needs the
  GitHub-releases check, P2/P7). MISSING: /api/search, /api/import/session,
  /api/export/session/:id (port from plugin-era routes/search.js+export.js or
  Swift routers). EXTRAS: keep-dormant/flagged; only Docker/K8s deploy
  scaffolding recommended for removal. See docs/N2-GAP.md.
- **N3 ✅ DONE** (2026-07-15): all 52 N2-GAP rows now OK. Endpoints: updates
  status/check rewritten (GitHub-releases check, P2 semver + P7
  Miraeld/podium-app only — `server/lib/update-check.js`); `/api/search`,
  `POST /api/import/session`, `GET /api/export/session/:id` ported from the
  plugin-era server (`routes/search.js`, `routes/export.js`,
  `lib/session-transfer.js`). Invariants P1–P7 ported with tests (evidence
  table in docs/N2-GAP.md): P1 `--host` > PODIUM_HOST > DASHBOARD_HOST >
  loopback + RCE warning (fixed an upstream bug where a 0.0.0.0 bind never
  warned), P3 atomic settings write + .bak (install-hooks), P4 VAPID key
  0600 create+tighten, P5 envelope middleware (`lib/error-envelope.js`),
  P6 documented (upstream's GET agents/:id + POST /agents kept per §F —
  client never calls them). New/extended node:test suites green (92 tests
  across the touched files); full contract gate is N4. Pre-existing failures
  in ccam-cli / hook-handler / plugins-marketplace tests are environment
  debt from upstream (fail identically on the untouched tree) — for N4.
- **N5-B (hook client) + P10 ✅ DONE** (`acfd56b`, 2026-07-15, orchestrator-
  verified): `hook/src/index.ts` (zero-dep TS, bun-compiles to 59MB single
  binary, dist/ gitignored) — stdin JSON → 8-event gate → CLAUDE_DASHBOARD_PORT
  override > `~/.claude/.agent-dashboard.json` discovery (multi+legacy formats,
  pid liveness) > 4820 fallback → POST per port, 1s req / 1.5s deadline,
  always exit 0. Verified end-to-end: event landed on a real server boot via
  both discovery paths; malformed/dead-port/no-file cases all exit 0.
  LICENSE = MIT dual copyright; README Attribution section (P10). CAVEAT for
  N5-A/N4: `server/index.js` auto-installs hooks on EVERY boot keyed off
  $HOME — scratch boots must override HOME or they rewrite the real
  `~/.claude/settings.json` + `.agent-dashboard.json`.
- **PROCESS RULE (added 2026-07-15 after the N4 double-build):** CLAIM a task
  in this STATUS section and COMMIT the claim BEFORE dispatching an agent.
  N4 was implemented twice in parallel (a Vitest port + a node:test port) by
  two sessions because neither saw a claim; the node:test version won and
  the duplicate ~200k-token Vitest effort was discarded. Claim → commit →
  dispatch, always.
- **HOOK-WIRING FIX ✅ DONE** (`04cac9e` + `d95f34e`, 2026-07-15,
  orchestrator-verified): install-hooks.js resolves PODIUM_HOOK_BIN env >
  repo hook/dist/podium-hook > binary next to process.execPath; installs
  NOTHING (stderr warning) if no binary found — no more dead entries.
  Legacy-marker upgrade ported from HookInstaller.swift (hook-handler.js,
  hook.mjs, plugin-cache paths replaced in place). P3 atomic+.bak intact.
  Owner healing: boot the app once — legacy upgrade repairs the real
  settings.json automatically. Follow-up in d95f34e: podium-hook now
  forwards Stop + Notification (server waiting-badge/watchdog depend on
  them; verified live — all 3 event types recorded). 565/565 tests green.
  REMAINING (noted, unclaimed): staging podium-hook into the Tauri bundle
  needs tauri.conf.json/main.rs wiring (TODO in prepare-sidecar.sh).
- **N6 ✅ DONE** (`0560858`, 2026-07-15, orchestrator-verified): ci.yml =
  client (P8-stamped build) / server (npm test, 565) / tauri (cargo check),
  zero Swift steps (verified by grep). release.yml keeps tag→draft flow,
  bun via oven-sh/setup-bun, sidecar via prepare-sidecar.sh, P8 stamped
  with the real tag version in both OS jobs. Headless Linux = bun-compiled
  binaries (server+hook) via oven/bun:1 docker; service unit gained
  DASHBOARD_WEB_DIST (real bug: compiled binary's web-dist fallback only
  resolves in the source tree). RELEASING.md rewritten. Local verification:
  yaml lint, bash -n, client build, server 565/565, cargo check — actual
  runner proof pending first push. Docker path read-verified only (docker
  not running locally).
- **N3 verification (orchestrator, 2026-07-15):** confirmed — 60/60 node:test
  green on the touched suites; live curl: search/export/updates shapes match
  types.ts, P2 (dev → no prompt), P5 (envelope incl. 404), P7 (Miraeld only).
- **N5-A SPIKE ✅ DONE** (2026-07-12, scratchpad-only, no repo changes):
  `bun build --compile` works on `server/` — 61MB arm64 single-file binary,
  boots green, hooks event lands, swagger/redoc served. TWO patches needed:
  (1) NEW `server/compat-bunsqlite.js` (bun:sqlite adapter w/ `.pragma()`
  shim) + a middle try in `db.js` (better-sqlite3 → bun:sqlite → node:sqlite)
  — bun 1.3.x has NO node:sqlite, and better-sqlite3 won't build on Node 26
  arm64 at all, so bun:sqlite is effectively PRIMARY, not fallback;
  (2) `lib/redoc.js` require.resolve made dynamic (redoc UMD breaks bun's
  bundler). Full diffs + evidence: `docs/N5A-SPIKE.md`.
- **N4 ✅ DONE** (2026-07-15): 30 Swift ContractTests ported 1:1 to
  `server/tests/contract/contract.test.js` — **31 tests** (node:test, not
  Vitest: every existing suite under `server/__tests__/` already standardizes
  on node:test, so this stays consistent rather than adding a second runner).
  Same architecture as Swift: boots the REAL `server/index.js` as a child
  process on a scratch port + temp `CLAUDE_HOME`/`DASHBOARD_DB_PATH`, seeds
  ONLY via `POST /api/hooks/event` (identical recorded-style hook sequence),
  asserts raw JSON against `client/src/lib/types.ts` — snake_case keys +
  wrong-casing-twin-absent on every endpoint, the deliberate camelCase
  exception families (Workflows, cc-config, Run "live" family) asserted the
  other way. Adapted 2 endpoints to Node's actual (not Swift's) behavior:
  `GET /api/agents/:id` + `POST /api/agents` (upstream kept them per P6 —
  client never calls them, asserted as-is, 201 on create) and the export/
  import round trip (Node's actual round-trip path is `POST
  /api/import/session`, not `POST /api/export/session` like the Swift
  server). True-404 cases (`GET /api/events/:id/full`, `GET /api/diagnostics`)
  assert the standard envelope. `npm test` = **558/558 green** (527
  pre-existing + 31 new; `ccam-cli`/`hook-handler`/`plugins-marketplace` —
  30 tests across 3 files — properly `{ skip }`'d with a documented reason,
  never deleted: dormant upstream CLI/marketplace scaffolding never ported
  into the monorepo, ROADMAP EXTRAS policy). Fixed one real regression along
  the way: `__tests__/api.test.js` required `../../package.json` (a stale
  path from when `server/` WAS the repo root) — now reads `../package.json`
  (server's own), which needed `license`/`repository`/`bugs` fields added
  (pointing at the upstream repo, matching the existing attribution
  assertion). Red-run proof: renamed `total_sessions`→`total_sessionz` in
  `db.js`'s stats query, confirmed `GET /api/stats` contract test failed,
  reverted, confirmed green again.
- **N5-A TASK A+C ✅ DONE** (`5823261`, 2026-07-15, verified end-to-end):
  bun-compiled `podium-server` sidecar. Sqlite: `bun:sqlite` (new
  `server/compat-bunsqlite.js`) is effectively PRIMARY — bun 1.3.14 has no
  `node:sqlite`, and `better-sqlite3` has no working prebuilt/source build
  on this Node 26/arm64 toolchain either; `db.js`'s chain is now
  better-sqlite3 → bun:sqlite → node:sqlite. `lib/redoc.js` require.resolve
  made dynamic (unrelated bun-bundler fix, required for `--compile` to
  succeed at all). NEW finding beyond the spike: `bun build --compile`
  resolves `optionalDependencies` against bun's OWN global module cache
  regardless of local `node_modules` state — a stale cached
  `better-sqlite3` silently got bundled and crashed at runtime
  (`bindings`/`getRoot` "no module root" error inside the compiled binary);
  fixed with `--external better-sqlite3` on the compile command (now baked
  into `prepare-sidecar.sh`). Also found: bun statically inlines
  `process.env.NODE_ENV` reads at BUILD time, so `NODE_ENV=production` must
  be set in the shell that runs `bun build --compile`, not just at runtime,
  or the static client never gets served (API still works, `/` 404s).
  `server/index.js` now parses `--port`/`--data-dir`/`--web-dist` (mapped
  onto `DASHBOARD_PORT`/`DASHBOARD_DATA_DIR`/new `DASHBOARD_WEB_DIST`)
  before `db.js`/routers are required, matching what `main.rs` already
  spawns with — zero Rust changes needed. `server/lib/server-info.js`'s
  discovery-file shape already matched `main.rs`'s `port_for_pid()` reader —
  no reconciliation needed there. `tauri/prepare-sidecar.sh` rewritten:
  `bun install --production` + `bun build --compile --external
  better-sqlite3` (with `NODE_ENV=production`), staged as
  `podium-server-<rust-triple>` (same naming convention as the old Swift
  binary), plus `client/dist` → `src-tauri/web-dist/` (was `WebClient/dist`
  pre-N1). Hook binary NOT built by this script — hooks are installed by
  the server itself at runtime (`server/scripts/install-hooks.js`, called
  from `index.js` on every boot); `hook/` has its own separate `bun run
  build`, matching the old Swift-era script's behavior (it never built a
  hook binary either). Verified: plain-`node` boot with the new flags;
  `bun build --compile` → 61.2 MiB Mach-O arm64 (old Swift binary: 25.6
  MiB, delta +35.6 MiB); headless boot (scratch HOME/port/data-dir) served
  `/api/health` (200) + static `index.html` (200, `<title>Podium</title>`)
  + wrote the server-info file; `cargo tauri dev` ran once, sidecar spawned
  against the REAL data dir, `ws_watcher` connected (health-wait passed),
  `/api/health` 200 confirmed via curl, then torn down — no orphaned
  `podium-server`/`podium-tauri` processes or listening port afterward
  (the graceful SIGTERM path was exercised directly, not the GUI Quit menu,
  since this ran headlessly — window-driven close-to-tray/Quit still
  REMAINS for an owner GUI pass, matching P6.2a's existing manual-QA gap).
  **Caveat found, NOT fixed here (out of TASK A/C's fence)**:
  `server/scripts/install-hooks.js` still writes hook entries pointing at
  `server/scripts/hook-handler.js`, which was deliberately never vendored
  (see `server/UPSTREAM.md`) — every boot (including this session's) writes
  a broken hook command into `~/.claude/settings.json`. This predates this
  session (confirmed present in the owner's real `~/.claude/settings.json`
  already) and is a loose end from N3/N5-B, not from N5-A; needs a
  follow-up wiring `install-hooks.js` to the real `hook/dist/podium-hook`
  binary path.
- **HOOK-BUNDLE STAGING ✅ DONE** (`c3c4d9d`, 2026-07-15, orchestrator-
  verified): prepare-sidecar.sh builds + stages podium-hook as a second
  externalBin (triple-named, same convention); tauri.conf.json externalBin =
  [podium-server, podium-hook]. Tauri strips the triple → both land side by
  side in Contents/MacOS/, matching install-hooks.js's tier-3
  next-to-execPath lookup EXACTLY (verified via real `cargo tauri build
  --debug` bundle + scratch-HOME boot of the bundled server with the repo's
  hook/dist hidden — settings.json got the sim-bundle path, not a warning).
  HARD BLOCKER found+fixed: bun 1.3.14 Mach-O self-signing is broken for the
  hook compile ("truncated code signature", oven-sh/bun#29120) —
  BUN_NO_CODESIGN_MACHO_BINARY=1 now set on BOTH compiles so Tauri's
  codesign is the only signing pass; without it `cargo tauri build` fails at
  bundling. release.yml needs nothing (bun setup already precedes the
  prepare-sidecar.sh step in both OS jobs). .gitignore covers bun temp
  artifacts. 565/565 green (orchestrator re-ran). Sizes: server 63.8MB,
  hook 61.2MB in-bundle.
- **INSTALL-HOOKS DEDUP FIX 🔒 CLAIMED** (2026-07-15, orchestrator session C):
  real-world bug found in the owner's settings.json — `installHooks` upgrades
  only the FIRST `isOurEntry` match per event (`findIndex`), so events with
  TWO legacy entries (plugin-era + boot-written hook-handler.js) keep the
  duplicate → 6 events still threw MODULE_NOT_FOUND after healing. Fix:
  upgrade first match, REMOVE all further matches per event. Also decide
  (investigate, don't guess): Swift-era entries on events HOOK_TYPES doesn't
  manage (PostToolUseFailure, SubagentStart → ~/.claude/podium/podium-hook,
  binary still exists) — should HOOK_TYPES cover them (does the server/agent
  tree consume them?) or should legacy entries on unmanaged events be
  removed? Dispatch AFTER hook-bundle staging lands (same-file conflict).
- N7–N8: not started. N7 waits for daylight + owner presence.

## N1 — Import the front-end source (monorepo begins)

**Goal:** `client/` in this repo == the old repo's client working tree
(INCLUDING uncommitted changes — they are the shipped fixes). Builds happen
here. `WebClient/` survives temporarily (the Swift server still serves it)
and dies in N7.

**DoD:** `cd client && npm ci && PODIUM_APP_VERSION=0.0.0-dev npm run build`
succeeds from a fresh clone; `git log` shows one import commit; zero
references to the old repo path anywhere under `client/`.

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 first. Do all work yourself, no sub-agents.

TASK: import the React client source into this repo as client/.

1. Source: /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client —
   copy its CURRENT WORKING TREE (uncommitted changes included; they are
   shipped fixes). NEVER run git commands inside that repo; it is frozen.
   Copy with rsync -a --exclude node_modules --exclude dist.
2. Destination: client/ at this repo's root. Also copy the shared assets the
   client build needs if referenced from one level up (check index.html,
   vite.config.ts for ../ references — favicon.svg, manifest.json, sw.js live
   in the old repo's dashboard/ root; bring what the build actually needs
   into client/public/ and fix references).
3. Verify: cd client && npm ci && PODIUM_APP_VERSION=0.0.0-dev npm run build
   → must succeed. Also verify the D1 guard: unset the var, build must FAIL.
4. Add client/node_modules and client/dist to .gitignore.
5. grep client/ for absolute paths to /Users/gaelrobin/Desktop/Work — must be
   zero after fixes.
6. Do NOT touch WebClient/ (the Swift server still serves it until N7).
7. Commit on develop: "feat(monorepo): import React client source (N1)".
   Auto-commit hook may fire on saves — ignore it, never amend/rebase.
   Message ends: Co-Authored-By: Claude <model> <noreply@anthropic.com>

Return: file count imported, build results (both PODIUM_APP_VERSION cases),
commit SHA.
```

## N2 — Node server: vendor upstream + gap analysis

**Goal:** upstream's `server/` lands in `server/`, and we know EXACTLY which
routes satisfy our client's contract, which need adaptation, which of our
client-used endpoints upstream lacks (must be added from repo (A)'s code or
written), and which upstream extras (alerts, MCP) we keep behind flags.

**DoD:** `server/` boots (`node server/index.js` or its actual entry) against
a temp data dir; `docs/N2-GAP.md` lists every endpoint in
client `src/lib/api.ts` + `types.ts` with verdict OK / ADAPT / MISSING /
EXTRA; no route work done yet beyond boot fixes.

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N2 first. No sub-agents.

TASK A — vendor: clone https://github.com/hoangsonww/Claude-Code-Agent-Monitor
(MIT) at its latest default-branch commit into a temp dir. Copy its server/
into this repo as server/ (exclude node_modules). Record the upstream commit
SHA in server/UPSTREAM.md along with the license notice (MIT requires it) and
copy its LICENSE file to server/LICENSE-upstream. cd server && npm ci &&
boot it with a scratch data dir/port — fix ONLY what's needed to boot.

TASK B — gap analysis: our wire contract is client/src/lib/types.ts +
client/src/lib/api.ts (+ push.ts, Search.tsx, ImportSession.tsx direct
fetches) — after N1 these are in-repo. Reference implementations: the Swift
routers (Sources/PodiumServer/Routes/*.swift) and the plugin-era Node server
(/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server — READ ONLY,
never git-touch). For EVERY endpoint the client calls, test upstream's
response shape (boot + curl) and classify: OK (shape matches) / ADAPT (exists,
shape differs — describe the diff) / MISSING (upstream lacks it — note where
repo (A) implements it). Also list upstream EXTRAS (alert engine, MCP, etc.)
with a keep/flag-off/remove recommendation each. Write docs/N2-GAP.md with
one table row per endpoint + a summary verdict: is B-as-base viable (<50%
ADAPT+MISSING) or should the orchestrator flip to A-as-base (§1)?

Commit on develop: "feat(server): vendor upstream Node server + N2 gap
analysis". Auto-commit hook: ignore, never amend/rebase.
Ends: Co-Authored-By: Claude <model> <noreply@anthropic.com>

Return: upstream SHA, boot result, gap table summary counts (OK/ADAPT/
MISSING/EXTRA), your base-choice verdict.
```

## N3 — Reconcile server to contract + port the audit

**Goal:** every client-called endpoint returns our wire shape; every §2
carry-forward (P1–P7) implemented in Node. Likely several agent-days; the
orchestrator may split by router group (sessions/events, run/import,
settings/updates/push, cc-config/workflows) using N2-GAP.md as the work list.

**DoD:** all N2-GAP rows OK; P1–P7 each verifiably implemented (grep/curl
evidence); manual smoke: client dev server against Node server shows live
data end-to-end.

**Prompt (template — orchestrator fills {SCOPE} from N2-GAP.md):**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3, docs/N2-GAP.md, and this task. No sub-agents.

TASK: make the Node server (server/) satisfy the wire contract for {SCOPE}
and port the relevant audit invariants.

- Contract: client/src/lib/types.ts is law. For each ADAPT/MISSING row in
  N2-GAP.md within {SCOPE}: adapt upstream's route or port the plugin-era
  implementation (/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/server,
  READ-ONLY reference) or the Swift router (Sources/PodiumServer/Routes/) —
  pick the closest, keep upstream's idioms where possible for future merges.
- Audit invariants in scope (see ROADMAP §2 table): implement and note
  evidence. P1 (loopback default + PODIUM_HOST/--host + warning) and P5
  (error envelope middleware) are server-wide — implement once, in the first
  N3 task that runs, and say so.
- Verify each endpoint by booting the server (scratch port/data dir) and
  curling; compare against the same endpoint on the Swift server
  (swift run podium-server --port 4897 --data-dir <scratch>) when unsure.
- Update N2-GAP.md rows you've resolved (OK + commit ref).
- Tests: if upstream has a test setup, extend it per route; else leave for N4.
- Commit on develop, message "feat(server): N3 {SCOPE} contract + audit port".
  Auto-commit hook: ignore. Ends: Co-Authored-By: Claude <model>
  <noreply@anthropic.com>

Return: per-endpoint before/after verdicts, invariant evidence, commit SHAs.
```

## N4 — Contract tests reborn (Vitest)

**Goal:** the 30 Swift ContractTests become `server/tests/contract/*.test.ts`
(Vitest + supertest or fetch against a booted server). Same semantics: boot
real server, seed via `POST /api/hooks/event`, assert every GET shape against
`types.ts`. THIS is the new wire gate; CI runs it (N6).

**DoD:** `cd server && npm test` green locally; test count ≥ 30; seeding uses
the public hooks endpoint, not DB pokes; a deliberately broken field makes it
fail (verified once, then reverted).

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N4. No sub-agents.

TASK: port Tests/PodiumServerTests/ContractTests.swift (30 tests, Swift) to
Vitest in server/tests/contract/. Keep the architecture: boot the REAL Node
server on a scratch port + temp data dir, seed state ONLY via POST
/api/hooks/event (fixtures: mirror what the Swift file sends), then assert
each GET endpoint's exact shape against client/src/lib/types.ts (import the
types; write runtime shape assertions — field presence + type, snake_case
keys, error envelope shape on 4xx).
- Port every test 1:1 (same endpoint coverage). Where a Swift test asserts a
  removed endpoint (B6 trim), assert 404 + error envelope instead.
- npm script: "test" runs vitest. Prove the gate bites: temporarily rename a
  response field, confirm red, revert, confirm green — report both runs.
- /usr/bin/true not /bin/true if any test spawns processes (macOS Darwin 25+
  has no /bin/true; Linux is usr-merged).
- Commit on develop: "test(server): port wire-contract gate to Vitest (N4)".
  Auto-commit hook: ignore. Ends: Co-Authored-By: Claude <model>
  <noreply@anthropic.com>

Return: test count, green run output tail, red-run proof, commit SHA.
```

## N5 — Sidecar + hook strategy (Bun compile)

**Goal:** the Tauri app stays a zero-dependency download. `bun build
--compile` produces single-file binaries for (a) the server and (b) the hook
client. Tauri spawns the compiled server exactly like it spawned
`podium-server` (same args: `--port`, `--data-dir`, `--web-dist`; same
health-wait; same server-info discovery file). The hook binary replaces the
Swift `podium-hook` at the same install path semantics (HookInstaller logic
becomes a server-side Node module — port from
Sources/PodiumCore/Hooks/HookInstaller.swift including legacy-marker upgrade
+ P3 atomic write).

**DoD:** `cargo tauri dev` boots the compiled-server sidecar and shows live
data; hooks fire from a real Claude session into the app; `file` confirms the
sidecar is a self-contained executable; app quit leaves no orphan; binary
size delta vs Swift recorded (expect +50–90MB — accepted cost, note actual).

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N5, tauri/README.md, tauri/prepare-sidecar.sh, and
tauri/src-tauri/src/main.rs (sidecar spawn + health-wait + server-info port
discovery). No sub-agents.

TASK A — server sidecar: make `bun build --compile` produce a single-file
podium-server binary from server/ (entry per its package.json). Wrestle
native deps: better-sqlite3 is a native addon — if bun compile can't embed
it, switch the server to bun:sqlite behind a thin adapter (keep the SQL
identical) or node:sqlite — document the choice in server/UPSTREAM.md.
Rewrite tauri/prepare-sidecar.sh to build this binary (correct
target-triple naming for tauri externalBin, e.g.
podium-server-aarch64-apple-darwin). The Rust side should need zero or
minimal changes (same CLI flags — verify against server's arg parsing; adapt
the server's argv handling if needed, not the Rust).
TASK B — hook: port PodiumHook/main.swift + HookInstaller.swift semantics to
hook/ (TypeScript): read event JSON on stdin, discover live server ports via
~/.claude/.agent-dashboard.json (multi-server format, fallback 4820), POST
/api/hooks/event to each with 1s/1.5s timeouts, always exit 0 fast. Compile
with bun to a single binary; installer module (in server/) writes
~/.claude/settings.json atomically + .bak (P3), upgrading legacy entries
(see HookInstaller.swift header for the exact legacy markers).
TASK C — verify end-to-end: ./run.sh (update it: build sidecar via new
prepare-sidecar.sh, then cargo tauri dev), confirm live session data + tray +
close-to-tray + clean quit (no orphans: pgrep after quit). Record sidecar
binary size vs the old Swift one.

Commit on develop: "feat(sidecar): bun-compiled Node server + hook (N5)".
Auto-commit hook: ignore. Ends: Co-Authored-By: Claude <model>
<noreply@anthropic.com>

Return: sqlite decision, binary sizes, end-to-end evidence, commit SHAs.
```

## N6 — CI + packaging overhaul

**Goal:** `.github/workflows/` builds/tests Node instead of Swift; release
tag → Tauri installers exactly as today (macOS .dmg ad-hoc signed — Gaël
declined notarization; Linux .AppImage/.deb x86_64). Headless Linux path
(`scripts/`) becomes "node server/ + systemd unit" (PODIUM_HOST=0.0.0.0 stays
explicit there, comment preserved).

**DoD:** CI green on a PR: client build (P8 enforced), server vitest incl.
contract gate, cargo check; release.yml dry-run reviewed (no Swift steps
left); RELEASING.md updated.

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N6, .github/workflows/*, scripts/, RELEASING.md. No sub-agents.

TASK: rewrite CI/packaging for the Node era.
1. ci.yml: jobs = client (npm ci + PODIUM_APP_VERSION=ci build + typecheck),
   server (npm ci + npm test — includes the N4 contract gate), tauri (cargo
   check). Drop all swift steps. Keep the CI truth policy from CLAUDE.md: a
   test failing ONLY on GitHub runners gets a documented skip, never deleted.
2. release.yml: keep the tag→draft-release flow (find-based nested artifact
   collection, permissions: contents: write, --generate-notes) but sidecar
   prep now uses N5's prepare-sidecar.sh (bun install in CI). macOS stays
   ad-hoc signed (document the xattr first-launch dance in RELEASING.md and
   README — owner declined notarization). Linux runners are x86_64 — ensure
   bun compile targets match the runner arch.
3. scripts/: build-linux.sh + install-linux.sh + podium-server.service now
   deploy the Node server headless (bun-compiled binary or node+npm ci — pick
   one, document; keep Environment=PODIUM_HOST=0.0.0.0 with its comment).
4. Update RELEASING.md end-to-end for the new flow (P8: release builds MUST
   set PODIUM_APP_VERSION=<version>).
Commit on develop: "ci: Node-era pipelines + packaging (N6)". Auto-commit
hook: ignore. Ends: Co-Authored-By: Claude <model> <noreply@anthropic.com>

Return: workflow diffs summary, any runner-arch caveats, commit SHA.
```

## N7 — Swift funeral + repo identity

**Goal:** Swift fully removed; repo tells the truth about what it is.

**DoD:** no .swift files; `rg -i "swift" README.md CLAUDE.md docs/` returns
only historical notes; fresh-clone quickstart works (`npm ci` in client+server,
./run.sh); CLAUDE.md rewritten for the Node era (build/test commands, layout,
footguns: P8 env var, auto-commit hook, frozen old repo, wire-contract gate).

**Prompt:**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N7. PRECONDITIONS (verify, abort if unmet): N4 contract gate green
(cd server && npm test), N5 end-to-end done (tauri boots Node sidecar),
N6 CI green.

TASK: remove Swift.
1. git rm -r Sources/ Tests/ Package.swift Package.resolved WebClient/
   (dist is now built from client/ — verify tauri/prepare-sidecar.sh and the
   server's static-file serving point at client/dist first; fix if not).
2. Sweep references: run.sh, scripts/, tauri/*.sh, .gitignore, docs. The
   Swift-era gotchas in CLAUDE.md (CodingKeys, JSONResponse, /usr/bin/true
   for XCTest) go away or move to a "historical" note; write the new
   CLAUDE.md: project structure (§3 of ROADMAP), commands (npm ci/test,
   ./run.sh, cargo tauri build), footguns (P8 mandatory version env var,
   auto-commit hook, frozen plugin repo path, contract gate = server/tests/
   contract, loopback default P1).
3. README.md: rewrite intro/architecture for Node+Tauri; keep install docs;
   ensure P9/P10 (branding, MIT attribution to
   hoangsonww/Claude-Code-Agent-Monitor) are present. Root LICENSE: MIT with
   both copyrights (ours + upstream notice) if not already done.
4. Full verification: fresh-clone simulation (git clone . /tmp/podium-fresh),
   client build, server test, cargo check, ./run.sh boots.
Commit: "chore!: remove Swift server — Podium is Node+Tauri (N7)".
Auto-commit hook: ignore. Ends: Co-Authored-By: Claude <model>
<noreply@anthropic.com>

Return: deletion stats, doc rewrite summary, fresh-clone verification output.
```

> Repo rename (`PodiumSwiftApp` → `podium-app`): Gaël does this on GitHub +
> local (`git remote set-url` / folder rename) — agents must NOT attempt it.

## N8 — QA + release 1.0.0

**Goal:** the pre-1.0 bar, re-run on the Node build, then tag.

**DoD / checklist:**
1. Browser pass (P6.2a rerun): fresh data dir, all pages, both themes, zero
   console errors, first-boot auto-import works, update popup correct.
2. macOS app QA: launch → live data → all pages → close-to-tray → reopen →
   clean quit, no orphans.
3. Upstream EXTRAS decision executed (from N2-GAP.md): alert engine / MCP —
   each either QA'd and enabled, or feature-flagged OFF (quality over
   breadth: nothing half-working ships — Gaël's standing rule).
4. Attribution (P10) verified in the built app's UI (About/README link).
5. Version ritual: tauri.conf.json → 1.0.0; client built with
   PODIUM_APP_VERSION=1.0.0 (P8 enforces); curated release notes (they render
   in the update popup); commit; `git tag -a v1.0.0`; push tag; CI draft;
   **Gaël publishes**.
6. Linux GUI QA: SKIPPED by owner decision (no test box) — release notes name
   Linux as "packaged, less battle-tested; feedback welcome".

**Prompt (QA pass):**
```
Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch develop. Read ROADMAP.md
§0-§3 + N8 + PRE-1.0-AUDIT.md ("Live browser pass" section = the bar).
TASK: re-run the P6.2a browser pass against the NODE server: build client
(PODIUM_APP_VERSION=1.0.0-rc), boot server on a scratch port + temp data dir,
walk Dashboard/Sessions(+detail)/Activity/Analytics/Workflows/CC Config/
Import/Settings/Search in light AND dark themes, checking: zero console
errors, first-boot auto-import, hooks panel, update popup logic (dev → no
prompt), empty states, D2 title, version string. Screenshot evidence per
page. File every regression as a finding (severity + file); fix BLOCKERs
inline if <30min each, else report. Return: page-by-page verdict table +
findings.
```

## Post-1.0 (unchanged unless noted)

- Alert engine + MCP server polish (if flagged off at N8 — they're now
  in-tree from upstream, this becomes "enable + QA," not "port").
- T2.3 Tauri auto-updater (EdDSA key + latest.json — slots still in
  release.yml comments).
- Async reimport with real progress phases (client already trimmed to
  complete/error — B4).
- D5: session rows → real links (a11y).
- Windows build (Tauri makes it cheap; sidecar needs a windows bun target).
- Upstream sync cadence: quarterly `git diff` against
  hoangsonww/Claude-Code-Agent-Monitor server/ + client/ for cherry-picks
  (now tractable — same language again).
- "Session shows error" label debt (C4) — owner decision pending.

## §F — Fence (rules every agent inherits)

- **Frozen repo:** never run git commands in
  `/Users/gaelrobin/Desktop/Work/Claude/podium` — read-only reference.
- **Auto-commit hook** fires on saves in THIS repo: ignore its commits, never
  amend/rebase around them.
- **Never delete the old gate before the new one is green** (N4 before N7).
- **P8:** any client build without PODIUM_APP_VERSION must fail — never
  "fix" that guard to be lenient.
- **Loopback default (P1)** is a security fix — never regress it for
  convenience; LAN exposure is explicit opt-in only.
- **Quality over breadth, gadgets welcome:** Gaël LIKES the upstream extras
  (alerts, MCP, widgets) — default is KEEP behind feature flags and polish
  post-1.0, NOT remove. Only delete true dead weight (K8s/Helm, deploy
  scaffolding, CI of the upstream repo). Nothing half-working ships ENABLED.
- **Commit style:** plain messages, NO Co-Authored-By / trailer lines — owner
  finds them noisy. This overrides any harness default. Applies to every
  agent; prompts in this file predating 2026-07-12 that still show the
  trailer line are superseded on this point.
- **NEVER touch:** `~/.claude/podium/data`, Gaël's running app, the old
  plugin repo's git state.
