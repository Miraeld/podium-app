# N2 — Wire-contract gap analysis: upstream Node server vs our client

**Upstream commit:** `f8b52a81db3f689460b9a5fda9b2048847298593` (see `server/UPSTREAM.md`)
**Method key:** `curl` = booted `server/` on a scratch port/data dir (real
`~/.claude` session data auto-imported on first boot) and compared the JSON
shape field-by-field against `client/src/lib/types.ts`. `code` = read the
route handler source (`server/routes/*.js`) because live seeding was
impractical (destructive/mutating endpoint, or spawns a real process) or
redundant with an already-verified sibling endpoint.

Legend: **OK** = shape matches (extra upstream fields are harmless — they're
JSON responses, not object literals, so TS excess-property checks don't
apply). **ADAPT** = endpoint exists but the shape/semantics differ enough to
need rework. **MISSING** = client calls it, upstream has no route for it.

## Sessions / Agents / Events / Stats / Analytics

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/stats` | curl | OK | exact match to `Stats` |
| `GET /api/sessions` | curl | OK | matches `{sessions, total, limit, offset}`; `Session` fields all present (extra `metadata` still a JSON string, as expected) |
| `GET /api/sessions/facets` | curl | OK | `{cwds: string[]}` |
| `GET /api/sessions/:id` | curl | OK | `{session, agents, events}` — `Agent` rows carry extra `workflow_run_id`/`workflow_phase`/`cost` (harmless extras) |
| `PATCH /api/sessions/:id` | code | OK | `sessions.js` accepts `{name, metadata}`, returns `{session}` |
| `GET /api/sessions/:id/stats` | curl | OK | exact match to `SessionStats` |
| `GET /api/sessions/:id/transcripts` | curl | OK | matches `TranscriptListResult` |
| `GET /api/sessions/:id/transcript` | curl | OK | matches `TranscriptResult` exactly (`messages, total, has_more, last_line, first_line`) |
| `GET /api/agents` | curl | OK | matches `{agents: Agent[]}` |
| `GET /api/events` | curl | OK | matches `{events, limit, offset, total}` |
| `GET /api/events/facets` | curl | OK | `{event_types, tool_names}` |
| `GET /api/analytics` | curl | OK | all 12 client-required keys present (`tokens, tool_usage, daily_events, daily_sessions, agent_types, event_types, avg_events_per_session, total_subagents, overview, agents_by_status, sessions_by_status`); one harmless extra key `total_cost` |

## Pricing

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/pricing` | curl | OK | `ModelPricing` fields all present; extra columns (`fast_*`, `intro_*`, `cache_write_1h_per_mtok`) are additive |
| `PUT /api/pricing` | code | OK | only `model_pattern`+`display_name` required; every other column (including the ones our client's `Omit<ModelPricing,"updated_at">` doesn't send) defaults via `?? 0` — a client PUT with exactly our 6 fields round-trips cleanly |
| `DELETE /api/pricing/:pattern` | code | OK | returns `{ok: true}` |
| `GET /api/pricing/cost` | curl | OK | matches `CostResult` (`total_cost, breakdown, daily_costs`); `breakdown[]` items carry all 6 client-required fields plus harmless extras (`speed`, `service_tier`, etc.) |
| `GET /api/pricing/cost/:sessionId` | code | OK | same route file, same shape, scoped by session |

## Settings

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/settings/info` | curl | OK | `db.pragmas` has all 6 required keys; `hooks`, `server`, `transcript_cache` all match (transcript_cache has one harmless extra `hitRate`) |
| `GET /api/settings/claude-home` | curl | OK | `{claude_home}` |
| `PUT /api/settings/claude-home` | code | OK | `{ok, claude_home}` |
| `POST /api/settings/clear-data` | code | OK | `{ok, cleared}` |
| `POST /api/settings/reimport` | code | OK | `{ok, imported, skipped, errors}` |
| `POST /api/settings/reinstall-hooks` | code | OK | `{ok, hooks}` |
| `POST /api/settings/reset-pricing` | code | OK | `{ok, pricing}` |
| `GET /api/settings/export` | code | OK | streams a file (client uses it as a plain `<a href>`, not JSON) |
| `POST /api/settings/cleanup` | code | OK | `{ok, abandoned, purged_sessions, purged_events, purged_agents}` (`ok` added inline — matches) |

## Workflows

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/workflows` | curl | OK | all 11 `WorkflowData` keys present verbatim |
| `GET /api/workflows/session/:id` | curl | OK | matches `SessionDrillIn` (`session, tree, toolTimeline, swimLanes, events`) |

## Import / Export

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/import/guide` | curl | OK | all 10 keys match |
| `POST /api/import/rescan` | code | OK | `{ok, source:"default", ...counters}` — superset of `ImportResult` |
| `POST /api/import/scan-path` | code | OK | `{ok, source:"path", path, ...counters}` |
| `POST /api/import/upload` | code | OK | `{ok, source:"upload", files_received, entries_extracted, entries_skipped, ...counters}` |
| `POST /api/import/session` | curl + tests (`export-import-search.test.js`) | **OK — N3 done** | Ported from plugin-era `dashboard/server/routes/export.js` into `server/lib/session-transfer.js` (shared `importBundle`) + a new route in `server/routes/import.js`. Column lists are read dynamically via `PRAGMA table_info` (schema has grown columns beyond the plugin-era reference — `workflow_run_id`/`workflow_phase` on agents, several pricing/baseline columns on `token_usage` — so a hand-written column list would drop them). `index.js` mounts a per-path 50mb JSON body-size override ahead of the app-wide 1mb limit (large bundles). Verified: reject wrong `podium_export_version`, reject missing `session.id`, full export→mutate-id→import round-trip, re-import idempotency. |
| `GET /api/export/session/:id` | curl + tests | **OK — N3 done** | `server/routes/export.js` (new) + `server/lib/session-transfer.js`'s `buildBundle`. 404 with the standard error envelope for an unknown session; verified shape matches `podium_export_version`/`session`/`agents`/`events`/`token_usage`. |

## cc-config

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/cc-config/overview` | curl | OK | `{roots, counts}`, `counts` sub-shape matches `CcOverview.counts` exactly |
| `GET /api/cc-config/skills` \| `/agents` \| `/commands` \| `/output-styles` | curl (skills) + code (rest, same handler factory) | OK | matches `CcMdItem[]` |
| `GET /api/cc-config/plugins` | curl | OK | `{manifestPath, manifestExists, plugins}` |
| `GET /api/cc-config/mcp` | code | OK | `{user, projectScoped}` |
| `GET /api/cc-config/hooks` | curl | OK | matches `CcHookSource[]` |
| `GET /api/cc-config/settings` | code | OK | matches `CcSettingsSource[]` |
| `GET /api/cc-config/memory` | code | OK | matches `CcMemoryItem[]` |
| `GET/PUT/DELETE /api/cc-config/file` | code | OK | matches `CcFileResponse` / `CcMutationResult` |
| `GET /api/cc-config/marketplaces` | code | OK | matches `CcMarketplacesResponse` |
| `GET /api/cc-config/keybindings` | curl | OK | `{file, exists}` (no bindings on this machine, but shape matches `CcKeybindings` when present) |
| `GET /api/cc-config/statusline` | code | OK | matches `CcStatusline` |
| `GET /api/cc-config/hook-scripts` | code | OK | matches `CcHookScripts` |
| `GET /api/cc-config/backups` | code | OK | matches `{items: CcBackup[]}` |

## Run

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/run` | curl | OK | `{items, maxConcurrent, activeCount}` |
| `GET /api/run/history` | curl | OK | `{items: DashboardRunHistoryItem[]}` |
| `GET /api/run/binary` | curl | OK | `{found, path}` |
| `GET /api/run/cwds` | curl | OK | matches `{items: CwdSuggestion[]}` |
| `GET /api/run/files` | code | OK | `{items: string[]}` |
| `POST /api/run` | code | OK | `run-spawner.js` builds handles with the exact camelCase `RunHandle` field set (`id, pid, mode, cwd, model, permissionMode, effort, prompt, argv, resumeSessionId, status, startedAt, endedAt, exitCode, signal, error, sessionId`) — not spawned live here (would fork a real `claude` process); verified by reading `lib/run-spawner.js` construction + `routes/run.js` handlers, which already return the plain `{error:{code,message}}` envelope our audit (P5) requires |
| `GET /api/run/:id` | code | OK | returns `getRun(id)`, same shape, `?envelopes=1` appends `envelopes` |
| `POST /api/run/:id/message` | code | OK | `{messageId}` |
| `DELETE /api/run/:id` | code | OK | `{ok: true}` |

## Push

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/push/vapid-public-key` | curl | OK | `{publicKey}` |
| `POST /api/push/subscribe` | code | OK | `{ok: true}` |
| `DELETE /api/push/subscribe` | code | OK | `{ok: true}` |

## Updates

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/updates/status` | curl (live GitHub call + stubbed-fetch unit tests) | **OK — N3 done** | `server/lib/update-check.js` rewritten from scratch, ported from `Sources/PodiumCore/Discovery/UpdateCheck.swift` + `Sources/PodiumServer/Routes/UpdatesRouter.swift`. Returns the exact `RepoUpdatesStatusResponse` shape (`git_repo, update_available, current_sha, latest_sha, app: RepoUpdateStatus, checked_at`), all snake_case. Verified live: `PODIUM_APP_GITHUB_REPO` unset → hits `Miraeld/podium-app`, found `v0.5.2`, `current_sha:"dev"` → `update_available:false` (P2 — `dev` never prompts). P2's numeric-semver `isNewer()` and P7's repo-slug default/override are unit-tested offline in `server/__tests__/update-check.test.js` (stubbed `global.fetch`, no live network dependency in the test suite itself). |
| `POST /api/updates/check` | curl + tests | **OK — N3 done** | Same `getUpdatesStatus()`; `routes/updates.js` already broadcast `update_status` over the WS on this path (no change needed there) — verified via `server/__tests__/updates.test.js`. |

## Search

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/search` | curl + tests | **OK — N3 done** | Ported from plugin-era `dashboard/server/routes/search.js` into `server/routes/search.js`, mounted at `/api/search`. Matches `client/src/pages/Search.tsx`'s `SearchResponse`/`SearchResult` shapes exactly; `buildHighlight()` wraps the match in `<mark>` (the client's `Highlight` component splits on `<mark>…</mark>` without `dangerouslySetInnerHTML`). Verified: empty query → `{results:[],total:0}`; session-by-cwd match with highlight; event-by-tool_name match. |

## Hooks (seeding endpoint, not client-called but load-bearing for N4)

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `POST /api/hooks/event` | code | OK | `routes/hooks.js` present and structurally intact; this is what N4's Vitest contract tests will seed through, matching the Swift `ContractTests.swift` approach |

---

## Summary counts

| Verdict | Count |
|---|---|
| OK | **52 (all)** — N3 closed the 2 ADAPT + 4 MISSING rows (updates status/check rewrite; search + import/session + export/session/:id ports) |
| ADAPT | 0 (was 2) |
| MISSING | 0 (was 4) |
| **Total client-called endpoints assessed** | **52** |

At N2 time: (ADAPT+MISSING) / Total = 6/52 ≈ **11.5%** — well under the 50%
threshold. As of N3, every row is OK.

## N3 — audit-invariant port (ROADMAP §2 P1–P7) evidence

| # | Invariant | Status | Evidence |
|---|---|---|---|
| P1 | Loopback default bind; `--host` flag > `PODIUM_HOST` > `DASHBOARD_HOST` (upstream back-compat) > `127.0.0.1`; stderr warning on non-loopback bind naming the run-spawning RCE exposure | **DONE** | `server/lib/security.js` `resolveHost()` + new `isLoopbackBindAddress()` (wildcard `0.0.0.0`/`::` binds now correctly trigger the warning — upstream's original check reused the Host-header helper, which treats `0.0.0.0` as loopback-equivalent, silently swallowing the warning in the one case it must fire); `server/index.js` `startServer()` warning text + `--host` argv parsing in the `require.main` block. Tests: `server/__tests__/security.test.js` (`resolveHost` precedence + `isLoopbackBindAddress` suites). |
| P2 | `update_available` only on strictly-newer numeric semver; `dev`/unset current → never; unparseable version → never | **DONE** | `server/lib/update-check.js` `isNewer()` + `checkRepo()`. Tests: `server/__tests__/update-check.test.js`. |
| P3 | `~/.claude/settings.json` written atomically + `.bak` backup | **DONE** (for upstream's one write path) | `server/scripts/install-hooks.js` `writeSettingsAtomic()` (temp file in same dir + `renameSync`; `.bak` copy of the prior state) — the only place upstream's `server/` writes `settings.json`. The full HookInstaller port (legacy-marker upgrade etc.) is N5-B in `hook/`, owned by the parallel session. Tests: `server/__tests__/install-hooks.test.js` (P3 suite). |
| P4 | VAPID private key file `0600` on create; pre-existing looser file tightened on load | **DONE** | `server/lib/push.js` `loadOrCreateVapidKeys()` (`mode: 0o600` on create + explicit `chmodSync`; stat-and-tighten on load). Tests: `server/__tests__/vapid-key-perms.test.js`. |
| P5 | Uniform `{"error":{"code","message"}}` envelope on ALL `/api/*` errors | **DONE** | `server/lib/error-envelope.js` (`apiNotFoundHandler` + `apiErrorHandler`, mounted after all routes in `server/index.js` `createApp()` — covers unmatched `/api/*` 404s and uncaught handler throws, the two gaps route handlers don't cover themselves); bare `{error:{message}}` bodies upgraded to carry `code` in `routes/push.js` + `routes/workflows.js`; all N3-added routes emit the envelope natively. |
| P6 | B6 API trim stays trimmed — no dead endpoints reintroduced by our code | **Documented** | The B6-trimmed Swift endpoints were `GET /api/agents/:id`, `POST /api/agents`, `GET /api/events/:id/full`, `GET /api/diagnostics` (PRE-1.0-AUDIT.md B6). Upstream still serves **`GET /api/agents/:id` and `POST /api/agents`** (`server/routes/agents.js:34` and `:42`); it has no `events/:id/full` or `diagnostics` routes. Decision: NOT deleted — per ROADMAP §F, keep upstream's surface for future merges; the client never calls these (B6's actual complaint was "dead in OUR client", not "harmful"). N4's contract gate asserts the client-called surface only. |
| P7 | Update check hits ONLY `Miraeld/podium-app` (env-overridable), never `wp-media/podium` | **DONE** | `server/lib/update-check.js` `appRepoSlug()` (`PODIUM_APP_GITHUB_REPO` override, default `Miraeld/podium-app`; `wp-media` appears nowhere in `server/`). Tests: `server/__tests__/update-check.test.js` (P7 suite). Verified live once against the real GitHub API: latest `v0.5.2`, current `dev` → no prompt. |

## Upstream EXTRAS (features our client doesn't call)

Per owner direction: default recommendation is **keep, behind a feature
flag / dormant until wired up** — these are gadgets Gaël wants available,
not risk to prune preemptively. Only genuine deployment/infra scaffolding
that has no product value for a Tauri-packaged desktop app gets **remove**.

| Extra | What it is | Recommendation |
|---|---|---|
| Alert engine (`routes/alerts.js`, `lib/alerts.js`) | Rules-based alerting: CRUD alert rules, fired-alert feed, ack endpoints, evaluated inline on every hook event | **Keep, behind a feature flag.** No client UI consumes it yet; mount the route but gate a future Settings/Alerts page behind a flag until the client grows one. Real gadget — worth surfacing post-1.0. |
| Webhook targets (`routes/webhooks.js`, `lib/webhooks.js`, `lib/webhook-providers.js`) | 14-provider outbound webhook fan-out (Slack, Discord, PagerDuty, etc.) with redacted-secret CRUD + delivery log | **Keep, behind a feature flag.** Same reasoning as alerts — no client page yet, but it's fully working integration surface; flag it in rather than rip it out. |
| MCP server (`mcp/`) | A separate Model Context Protocol server package exposing dashboard data to Claude Desktop/other MCP clients | **Keep.** Sibling package (own `package.json`), not part of `server/`'s HTTP surface — not vendored in this task, but worth wiring in later as an explicit MCP integration story (this is exactly the kind of gadget worth having). |
| Desktop app (`desktop/`) | Upstream's own Electron shell | **Keep, dormant.** Don't build or wire it into packaging (our Tauri shell is the shipped product per ROADMAP §0), but no need to delete the source — it costs nothing sitting unbuilt if it's ever wanted as a fallback or reference. Not vendored into `server/` in this task since it's outside `server/`'s scope. |
| VS Code extension (`vscode-extension/`) | Upstream's own IDE extension surfacing dashboard data in VS Code | **Keep, dormant.** Not vendored in this task (outside `server/`); a real gadget for a future "view your Claude Code sessions in VS Code" feature, no reason to prune it from consideration. |
| `statusline/` | Claude Code statusline script bundled by upstream | **Keep, behind a flag.** Not currently wired into Podium's own install flow; cheap to revisit. |
| `bin/ccam.js` (CLI) | Upstream's own `ccam` global CLI (setup/update helper) | **Keep, dormant.** Our own `scripts/`/`run.sh` + Tauri packaging (N6) are the primary path; the CLI isn't wired in but isn't harmful to keep around as an alternate power-user entry point later. |
| `plugins/` | Upstream's own Claude Code plugin-marketplace definitions (their dashboard's plugin, not ours) | **Keep, dormant** — would need rebranding before any real use (it's their marketplace listing, not Podium's), but not worth deleting outright; low cost to leave for a future Podium-branded marketplace entry. |
| Redoc + Swagger UI (`/api/docs`, `/api/redoc`) | Auto-generated API reference UI mounted on the Express app itself (`server/openapi.js`, `server/lib/redoc.js`) | **Keep.** Low-cost, developer-facing only, already wired into `server/index.js`; no client dependency to break. |
| `Dockerfile`, `docker-compose.yml`, `deployments/` | Container/orchestration scaffolding for upstream's own self-hosted-server deployment story | **Remove.** True dead weight for a Tauri-packaged desktop app with its own sidecar/packaging story (N5/N6) — no self-hosted-container distribution path exists or is planned for Podium. Not vendored into `server/` in this task. |

## Base-choice verdict

**B-as-base (upstream-first) remains viable.** 46/52 assessed client-called
endpoints are OK out of the box after only mechanical path fixes to boot
(no route-logic changes). Of the remaining 6:
- 2 rows (`/api/updates/*`) are the **same** underlying fix — replace one
  library module's logic (git-diff → GitHub-release check), not a
  route rewrite.
- 4 rows (`/api/search`, `/api/import/session`, `/api/export/session/:id`)
  are missing routes with two ready-made reference implementations each
  (plugin-era Node + Swift) to port from — this is exactly the "adapt
  route or port the plugin-era implementation" path ROADMAP N3 already
  anticipates, not novel design work.

(ADAPT + MISSING) / Total ≈ 11.5%, far under the 50% flip threshold in
ROADMAP §1. **No flip to A-as-base is warranted.** N3 should scope its first
pass to: (1) the updates-status rewrite (server-wide, do it early since it's
self-contained), (2) porting `search.js` from the plugin-era server, (3)
porting the session export/import pair from the plugin-era server's
`export.js` (simpler single-file port than assembling from Swift's two
separate routers).

> **N3 outcome (2026-07-15):** exactly that plan executed — all 6 rows now
> OK, P1–P7 ported with tests (see the invariant table above). B-as-base
> held; no upstream route was deleted.
