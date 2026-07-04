# Handover prompt — paste this into a fresh Claude session to continue

> Keep this file updated: the orchestrator refreshes the "Live state" section
> after every task completion. Last update: 2026-07-04 ~07:45 CEST (Sonnet 5,
> Phase-3 gate + all 8 fixes landed, P5.1 done + live-verified, P4.3 ∥ P4.4
> in flight).

## Paste-ready prompt

```
You are taking over as orchestrator of the "Podium Standalone" project in
/Users/gaelrobin/Desktop/PodiumSwiftApp (branch develop).

Read STANDALONE_PLAN.md — start with §0 (resume protocol, binding), then §5
(task board), §7 (run log, bottom-up), §4 + §6b (working agreements + product
decisions). Then HANDOVER.md "Live state" for what was in flight when the
previous session ended.

Your job: reconcile any 🟦 tasks per §0 step 2 (P4.3/P4.4 were in flight —
check if the agents finished; if so verify + merge their reported
RouterMount names into PodiumServerCLI/main.swift's mounts array AND
EmbeddedServer.swift's makeServerMounts() by hand, since both agents were
told not to touch those files themselves to avoid a merge fight), then keep
dispatching Sonnet dev agents per §0 step 3 until the board is done, updating
the board + run log + this file as you go. Quality over breadth (agreement #8).
```

## Live state (refresh me on every board change)

- **In flight RIGHT NOW (2 parallel agents, dispatched ~07:32 CEST):**
  `p4-3-ccconfig` (P4.3 — fenced to new files under PodiumCore/Discovery +
  new PodiumServer/Routes/{CcConfigRouter,UpdatesRouter,ExportRouter}.swift),
  `p4-4-diagnostics` (P4.4 — no §6 prompt existed, orchestrator wrote the
  spec inline referencing P3.3's ServerRuntimeInfo.swift; fenced to new files
  under PodiumCore/Diagnostics + new PodiumServer/Routes/DiagnosticsRouter.swift
  + new Sources/PodiumApp/DiagnosticsView.swift). **Neither agent touches
  PodiumServerCLI/main.swift's `mounts:` array or EmbeddedServer.swift's
  `makeServerMounts()`** — both will report back the exact `RouterMount.Type`
  name(s) to add; the next orchestrator turn must hand-merge both sets into
  BOTH files (they're duplicated, not shared — see the P5.1 run-log entry).
  If picking this up cold and these aren't done: check `git log`, ping the
  agents via SendMessage before re-dispatching (see environment quirk below).
- **Phase-3 hardening gate + all 8 fixes: ✅ done.** Gate found 8 confirmed,
  non-blocking bugs (see STANDALONE_PLAN.md §7 "Phase-3 hardening gate" +
  "Phase-3 hardening fixes" entries for full detail); two parallel fix-it
  agents fixed all 8 and added regression tests, 377/377 green (orchestrator
  re-verified `swift build && swift test` clean after both landed). Highest-
  priority fix was Workflows API's top-level JSON key casing (`toolFlow` etc.
  were being wrongly snake_cased — fixed via a new `JSONResponse(fields:)`
  raw-fragment assembler in JSONResponse.swift, since Swift's
  `.convertToSnakeCase` can't be bypassed per-key via CodingKeys). Others:
  Ingest notifier-before-COMMIT race, transcript cache trim watermark,
  lenient int query parsing, negative `limit` clamp, unknown agent status
  filter, empty-string PATCH collapse, SearchRouter's own cost-match
  algorithm (found a genuinely distinct JS `Array.slice` negative-offset
  quirk here too, different from SQL's negative-LIMIT-means-unbounded rule —
  see the fix-routes run-log entry).
- **P5.1 (app embeds server): ✅ done, live-verified both directions**
  without touching Gaël's real data — see the full P5.1 run-log entry.
  `EmbeddedServer.swift` is the whole feature; single-instance check
  correctly detects his live Docker container and falls back to pure-client
  mode; hosts+hooks+notifications all confirmed working end-to-end in an
  isolated sandbox with a real piped hook payload showing up live in the app.
- **Done (16/22):** P0.1, P1.1, P1.2, P2.1, P2.2, P2.3, P2.4, P3.1, P3.2,
  P3.3, P3.4, P4.1, P4.2, P5.1, P5.2. Phase 2 E2E-gate + Phase-3 hardening
  gate both passed. 377/377 green as of this handover.
- **P3.2 (legacy import + sweeps): audited clean, nothing needed fixing.**
  LegacyImporter.swift (1165 lines: importAllSessions/backfillCompactions/
  importCompactions/scanAndImportSubagents), ImportRouter.swift (guide/
  rescan/scan-path/upload incl. a hand-rolled multipart parser — no new
  dependency added), ServicesRunner.swift's 4 real services (legacyImport
  w/ `.legacy-import.done` marker written only post-success, periodicSweep
  w/ session_updated/agent_updated broadcasts, watchdog 15s API-error loop,
  stuckAgentCheck 60s loop — both P2.3-deferred timers present and tested).
  `scanAndImportSubagents` is wired live from HooksRouter post-SubagentStop,
  not deferred (better than the original plan expected). All pre-existing
  tests (LegacyImporterTests/ImportRouterTests/ServicesRunnerTests) verified
  passing.
- **P4.2 (web-push): test suite written from zero, all passing.**
  `WebPushEncryptorTests` — byte-exact RFC 8291 §5 worked example (fixed
  sender key + fixed salt), header layout assertions, an independent
  receiver-side decrypt round trip. `VAPIDKeysTests` — P-256 key validity,
  Node web-push `vapid-keys.json` camelCase format round trip (temp dirs
  only), malformed-file error path, VAPID JWT header/payload/compact-
  signature (r||s, not DER) shape. `PushRouterTests` — 12 HTTP tests:
  vapid-public-key, subscribe upsert + validation, unsubscribe, send fan-out
  over multiple subscriptions with header assertions, 404/410 pruning, 5xx
  non-pruning — all via a `StubWebPushTransport` (zero real network calls).
  `PushNotifierTests` — 7 tests: all 4 `NotifierEvent` cases fire correct
  title/body (incl. session-name-missing fallback), payload decrypted
  end-to-end via a capturing transport + the subscription's own keys,
  matches `sw.js`'s `NotificationOptions` spread contract. **Real, harmless
  finding:** `PushNotifier`'s additive `data.sessionId`/`url` fields go
  through `PodiumJSON.encoder` (`.convertToSnakeCase`) so the wire key is
  `session_id` — no client JS reads it yet (click-through isn't wired into
  `push.ts`/`sw.js`), but note this before any future click-through UI work.
- **Wiring debt CLOSED:** `ImportRouterMount` + `PushRouterMount` added to
  `PodiumServerCLI/main.swift`'s mounts array. `reimportRunner`/`pushService`
  params were being silently dropped between `main.swift` and
  `PodiumServerApp` (missing from `PodiumServerLifecycle.makeApp`/`.run`) —
  fixed, now threaded all the way through. `LegacyImporterReimportRunner`
  adapter (wraps `LegacyImporter.importAllSessions` + `backfillCompactions`
  into the `ReimportResult{imported,skipped,errors}` shape) built and passed
  at the CLI call site — `POST /api/settings/reimport` no longer 503s.
  `PushService`/`PushNotifier` construction was already correctly defaulted
  by P4.2 itself (`PodiumServerApp`/`RouterRegistry` build a real
  `PushService(store:)` when `nil` is passed, no side effects until first
  use) — no extra work needed there.
- **Manually smoke-tested the real `podium-server` binary** (temp data dir,
  `--no-hooks`, random port, backgrounded + killed after): `/api/health`,
  `/api/import/guide`, `/api/push/vapid-public-key` all respond correctly.
  `POST /api/settings/reimport` against an isolated empty fixture dir (via
  `CLAUDE_HOME` override, NOT the user's real `~/.claude`) returns
  `{ok:true,imported:0,skipped:0,errors:0}` in ~10ms, confirming the wiring
  end-to-end. **Follow-up flagged (task_6163054d), not fixed in this pass:**
  the SAME endpoint against the user's real `~/.claude/projects` (294 real
  files) pinned one core at 100% CPU for 2+ minutes without finishing before
  being killed — `backfillCompactions` re-scans every session's full JSONL
  on every call and `snapshotTranscript` copies every file unconditionally
  per import; likely culprits, needs profiling against large real
  transcripts (not fixture-scale ones) to confirm and fix.
- **After P3.2 + P4.2 + wiring (now closed): Phase-3 hardening gate**
  (working agreement #8): code review over the phases 2+3 diff (everything
  since 38b08ba) + contract sanity check against WebClient/dist's React
  client. THEN P4.3 ∥ P4.4 (P4.4 can build on P3.3's
  Diagnostics/ServerRuntimeInfo.swift), then P5.1 → P5.3 → P5.4 → P5.5
  (re-audit Sources/PodiumApp first — see §7 "Notes for future runs": the P5
  prompts were written against a stale inventory), then P6.
- **PO decision (Fable 5, 2026-07-04 ~02:00):** after the Phase-3 gate, P5.1
  jumps the queue (app embeds server = the zero-setup demo moment); P4.3/P4.4
  trail behind it. Gaël's live data (Docker `podium` container, port 4820,
  ~/.claude/podium/data/) stays untouched until he's awake and watching the
  switchover, verified against a COPY of his real DB first.
- **Dependent-task notes live in the run log (§7):** P5.4 response models +
  camelCase-live/snake_case-history wire split (P4.1 entry); P5.3 drop-in
  transcript endpoints (P3.1); pattern-mining double-count parity quirk (P3.4);
  Hummingbird does NOT percent-decode path params (P3.3 — check any router
  with encodable path params); §6b №2 answer-from-popup needs a stdin
  control-response framing extension in RunSpawner.sendInput (P4.1).
- **Standing corrections:** error responses are CodedErrorResponse
  {"error":{"code","message"}} — some §6 prompts still show the flat shape;
  route responses must go through JSONResponse; never mix snake_case
  CodingKeys with .convertFromSnakeCase (PodiumJSON.swift footgun). These
  constraint blocks must be re-attached verbatim on any re-dispatch.
- **Test count:** 355/355 as of this handover (324 baseline + 31 new P4.2
  tests). `swift build` clean.
- **Environment quirks:** repo has an auto-commit hook that commits the WHOLE
  dirty tree on any agent save — commit file-lists misattribute parallel work;
  real authorship = `git show <commit> -- <file>`. Agents habitually finish
  then go idle WITHOUT sending their report — ping them via SendMessage before
  assuming death or re-dispatching. /Applications/Podium.app (old install) can
  shadow the dev bundle when UI-testing — check `ps` first. Session-limit
  errors can kill an Agent spawn with 0 tokens used — just re-dispatch. A USER
  INTERRUPT of the main conversation also kills running background agents
  (SendMessage answers "stopped by the user, won't be resumed") — relaunch via
  a fresh Agent call. Liveness check: stat the RESOLVED transcript path twice
  ~20s apart (tasks/*.output is a symlink whose own 150-byte size is
  meaningless); flat mtime + no new commits = dead/stalled → ping, then
  relaunch. The user's live plugin data (Docker `podium` container, port
  4820) bind-mounts ~/.claude/podium/data/dashboard.db + vapid-keys.json —
  NEVER point tests at it; the Swift server is schema-compatible and will
  take over that DB at switchover (planned after P5.1). `ClaudeHome.current()`
  defaults to the REAL `~/.claude` regardless of `--data-dir` — only
  `CLAUDE_HOME` env or the settings-file override redirect it; smoke tests
  that must not touch real history need `CLAUDE_HOME` pointed at a fixture
  dir, not just `--data-dir`.
