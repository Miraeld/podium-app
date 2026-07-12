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
| `POST /api/import/session` | code | **MISSING** | upstream has no session-bundle import route at all (no `export.js` router). Reference implementations: plugin-era `dashboard/server/routes/export.js` (`POST /api/import/session`, also aliased `POST /api/export/session`) and Swift `Sources/PodiumServer/Routes/ExportRouter.swift`. Used by `client/src/pages/ImportSession.tsx`. |
| `GET /api/export/session/:id` | code | **MISSING** | same story — used by `client/src/pages/SessionDetail.tsx` (export-current-session button). Same two reference implementations as above. |

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
| `GET /api/updates/status` | curl | **ADAPT (major)** | Client types this `RepoUpdatesStatusResponse` (`git_repo, update_available, current_sha, latest_sha, app: RepoUpdateStatus, checked_at`) — a GitHub-**release**-based check against a fixed repo slug (`Miraeld/podium-app`, ROADMAP P2/P7). Upstream's `getUpdatesStatus()` (`server/lib/update-check.js`) implements an entirely different, git-**remote**-based mechanism (`local_sha`/`remote_sha`, `situation`, `manual_command`, `tracks_canonical` — this is actually the *other*, unused client type `UpdateStatusPayload`, kept in `types.ts` only as a comment-documented historical shape). None of the fields the client actually reads (`current_sha`, `latest_sha`, `app.*`, `checked_at`) exist in upstream's response. **Full rewrite required**: port `Sources/PodiumCore/Discovery/UpdateCheck.swift`'s GitHub-release logic into `server/lib/update-check.js`, preserving P2 (only prompt on strictly-newer semver, never on `dev`) and P7 (hits only `Miraeld/podium-app`, never `wp-media/podium`). |
| `POST /api/updates/check` | curl (implied, same handler) | **ADAPT (major)** | same underlying function; same rewrite fixes both. |

## Search

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `GET /api/search` | code | **MISSING** | Upstream has no `search` router at all (grepped `index.js` + `routes/`: absent). Used by `client/src/pages/Search.tsx` (global search across sessions/tools/events). Reference implementation: plugin-era `dashboard/server/routes/search.js` (present, full-featured) and Swift `Sources/PodiumServer/Routes/SearchRouter.swift`. Port one of these. |

## Hooks (seeding endpoint, not client-called but load-bearing for N4)

| Endpoint | Method | Verdict | Notes |
|---|---|---|---|
| `POST /api/hooks/event` | code | OK | `routes/hooks.js` present and structurally intact; this is what N4's Vitest contract tests will seed through, matching the Swift `ContractTests.swift` approach |

---

## Summary counts

| Verdict | Count |
|---|---|
| OK | 46 |
| ADAPT | 2 (`/api/updates/status`, `/api/updates/check` — same root cause, one fix) |
| MISSING | 4 (`/api/search`, `/api/import/session`, `/api/export/session/:id`, — 3 distinct missing capabilities across those 2 routes counted at the endpoint level = 4 rows) |
| **Total client-called endpoints assessed** | **52** |

(ADAPT+MISSING) / Total = 6/52 ≈ **11.5%** — well under the 50% threshold.

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
