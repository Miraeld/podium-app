# Podium — Post-v1.0 Roadmap & Dispatch Plan

> **Author:** Fable 5, acting PO (2026-07-05).
> **Audience:** the next orchestrator session (any model — see `/orch-fable`
> skill), or Gaël dispatching Sonnet agents directly. Every task below carries
> a **copy-paste-ready agent prompt**. Nothing here requires conversation
> context: this file + the repo are the whole briefing.
>
> **How to use:** work top-to-bottom inside a phase; phases are strictly
> ordered. Before dispatching anything, read "Operating rules" once. Update
> the checkbox + STANDALONE_PLAN.md §7 run log after every task.

---

## 1. Where the product stands (2026-07-05)

**v1.0 implementation is DONE.** All of STANDALONE_PLAN.md phases 0–5 + F1 +
P6.1 (packaging) shipped. P6.2a contract suite adopted, completed and green
(29/29; six wire-parity bug families fixed on the way). P6.2b docs written
(README, MIGRATION, CLAUDE.md). Full local suite: **463/463**.

CI: real hang root-caused and fixed (RunSpawner `waitUntilExit` was parking
Swift-concurrency cooperative-pool threads — deadlocked 2–4-core runners,
never reproduced on a many-core dev Mac). Remaining CI reds are **runner-
environment artifacts**, policy below.

**Not implementation work, still open:**
- Phase 0 (CI truth + P6.2 close) and Phase 1 (v1.0 close-out) below.
- The **supervised switchover** (HUMAN + orchestrator together): stop the
  plugin-era Docker, app takes over `dashboard.db`. Steps in MIGRATION.md.
  Gaël's standing decision: remove the prod container AS PART of the
  switchover, never before.

## 2. Binding product frame (do not re-litigate)

From STANDALONE_PLAN.md §6b + Gaël's memory notes:

1. Podium is pitched inside **GroupOne** as a standalone product:
   **useful, easy, uncluttered, sexy.** The objection to kill: *"too
   complicated."* Bar: download → open → agents appear live. Any step
   needing a README explanation is a **defect**, not a docs task.
2. **Quality over breadth.** Nothing ships half-working. Harden between
   phases. One polished feature beats three drafts.
3. **Cost features stay de-emphasized** (team subscription; not a pain
   point). No budget alerts. Don't grow the cost UI.
4. **Linux gets the macOS niceties wherever possible** (esp. notifications).
5. Explicitly REJECTED (don't propose again): iOS companion, Raycast/Alfred,
   session-diff views, cost budget alerts.

## 3. Operating rules for the orchestrator

- **Board discipline:** `git pull` before editing STANDALONE_PLAN.md; push
  after every commit. Log every task outcome in §7 (one row, dense).
- **Model tiering:** Sonnet for implementation and doc drafts; Haiku only
  for mechanical greps/renames; Opus/Fable-class for review, root-causing,
  and anything touching wire format or concurrency.
- **Every dispatch prompt must include the fence block** (§8 below) and name
  the exact files the agent may touch.
- **Verify agents' claims yourself** (build + run the relevant tests) before
  flipping a board status. Agents die silently; commits misattribute
  (auto-commit hook commits the whole dirty tree — real authorship =
  `git show <sha> -- <file>`).
- **Wire-format gate:** `swift test --filter ContractTests` must stay 29/29
  green after ANY router/model change. Full suite before every push.
- **CI truth policy (Gaël's call, 2026-07-05):** a test that passes locally
  (macOS + local Linux docker) but fails/hangs on GitHub-hosted runners is
  gated with `XCTSkip` under `GITHUB_ACTIONS` — with a comment explaining
  the exact runner behavior. It still runs everywhere real. Never delete the
  test; never skip unconditionally; never skip a test that also fails
  locally. Current gated set: DiagnosticsRouterTests (Linux container
  networking), ContractTests health-wait (same), HookClientTests dead-port
  latency (both OSes).

---

## PHASE 0 — CI green + P6.2 closed  *(½ day, mostly Sonnet)*

### 0.1 ☑ First fully-green CI run — DONE 2026-07-05, run 28755002211 (both jobs green)
Already in flight when this file was written: HookClient dead-port skip
pushed; watch `gh run list`. If the Linux job surfaces one more
runner-environment failure, gate it per the CI truth policy (same XCTSkip
pattern, same comment style) and push once. **DOD: one run with both jobs
green on GitHub.** No agent needed — orchestrator does this directly.

### 0.2 ☐ `scripts/contract-check.sh`
The last mechanical piece of P6.2a. **Model: Sonnet.**

```
TASK — scripts/contract-check.sh for PodiumSwiftApp (repo root: this repo, branch develop).

Read first: Tests/PodiumServerTests/ContractTests.swift (header comment + bootServer/seedViaHooks), STANDALONE_PLAN.md §6 "P6.2", scripts/package-macos.sh (style reference for our shell scripts — set -euo pipefail, step echo style).

Goal: a self-contained smoke script a human (or CI, later) can run against a REAL podium-server binary — the out-of-process complement to the in-process ContractTests. It must:
1. Build the release binary if missing (swift build -c release --product podium-server).
2. Boot it on a random high port with CLAUDE_HOME + DASHBOARD_DATA_DIR pointed at a mktemp fixture dir (NEVER the real ~/.claude — see ClaudeHome.current() gotcha in CLAUDE.md).
3. Seed via POST /api/hooks/event with the same recorded-style hook sequence ContractTests.seedViaHooks uses (SessionStart → PreToolUse/PostToolUse → Agent spawn → SubagentStop → Stop → SessionEnd; write the JSON bodies inline in the script).
4. curl every GET endpoint ContractTests covers and assert with jq: (a) HTTP 200, (b) spot-check one casing-sensitive key per family — sessions.started_at, workflows stats.totalSessions, settings info transcript_cache.maxSize, push vapid publicKey, run/binary path key present (null ok), updates git_repo. Fail loud with the endpoint name + actual body on mismatch.
5. Kill the server (trap EXIT), clean the temp dir, print PASS/FAIL summary + count.
Constraints: bash + curl + jq only (no python). Must run on macOS AND Linux. Exit non-zero on any failure. Do not touch any file except creating scripts/contract-check.sh. Do not commit.
Verify: run it yourself, paste the PASS output into your report. Then run `swift test --filter ContractTests` and confirm 29/29 (you changed nothing that affects it, prove it anyway).
[+ fence block §8]
```

### 0.3 ☐ Browser walk of every web page (the human-eyes half of P6.2a)
**Model: Sonnet + Playwright/preview tooling, or Gaël manually (30 min).**
PO note: automated agent walk is worth trying once; if tooling friction eats
>1h, fall back to Gaël + a checklist — this is a one-time verification, not
a regression suite (ContractTests is the regression suite).

```
TASK — Manual E2E browser walk of the Podium web dashboard against the SWIFT server.

Read first: STANDALONE_PLAN.md §6 "P6.2" item 2, README.md "Verified compatibility".
Setup: build + boot podium-server (release) on a fresh port with a COPY of a realistic dashboard.db if available (ask; otherwise seed via scripts/contract-check.sh's hook sequence, then also spawn one real run from the Run page). Open http://localhost:<port> in a real browser.
Walk EVERY page: Dashboard, Sessions, SessionDetail (incl. transcript tab + thinking blocks), ActivityFeed, Analytics, Workflows (all 12 d3 charts render with data), Search, Run (spawn a headless run with claude binary present; watch live envelopes), Kanban, Import, CcConfig (every sub-tab), Settings (server info card renders — heapTotal/maxSize fields).
For each page record: renders? console errors? data correct vs API response? interactions work (filters, search, pagination, buttons)?
Output: a table in a new file P6.2A-WALK.md (page | status ✅/⚠️/❌ | notes), plus for each ❌ a precise repro + suspected layer (client expectation vs server response — check the network tab response against client/src/lib/types.ts before blaming either).
Fix NOTHING yourself. Report only. Do not commit anything except P6.2A-WALK.md.
[+ fence block §8]
```

### 0.4 ☐ Close-out edits
After 0.2 + 0.3: fill README's "Verified compatibility" placeholder with the
walk results, flip P6.2a/P6.2b ✅ on the board, log §7. Orchestrator, 10 min.

---

## PHASE 1 — v1.0 close-out  *(1 day incl. human time)*

### 1.1 ☐ F2 — Gaël's three native-app bugs (board entry F2)
**PO judgment:** suspect all three are CLIENT-MODE artifacts (app talking to
the plugin-era Node Docker, which lacks the new endpoints). That's why the
task is *diagnose in embedded mode first*, and the likely deliverable is
graceful degradation, not three bug fixes. **Model: Sonnet.**

```
TASK — F2: triage + fix the three native-app v1 bugs (STANDALONE_PLAN.md §5 board entry F2 has the full symptom list — read it first).

Bugs as reported: (a) Thinking tab empty on a session that should have thinking blocks; (b) Settings "Re-install hooks" → "error reinstalling"; (c) Diagnostics tab "Diagnostics unavailable".
MANDATORY first step — reproduce in EMBEDDED mode: launch the app via ./run.sh with a fixture CLAUDE_HOME/DASHBOARD_DATA_DIR and NO other server on the port (the app must self-host; verify via the connection indicator + lsof). Also reproduce in CLIENT mode against a Node-era server if available.
Hypothesis to test for (b)+(c): in client mode against the plugin-era Node server those endpoints (POST /api/settings/hooks/reinstall, GET /api/diagnostics) do not exist → the UI shows raw errors. If confirmed: the fix is graceful degradation — the UI must detect capability absence (404/decode failure) and show "Available when Podium hosts its own server" (copy tone: calm, one line), NOT an error state. NO retry loops.
For (a): trace the real transcript through TranscriptMessageParser thinking extraction and the SessionDetail thinking-tab filter (suspect the P5.3 store rewrite's tab filtering). Write a failing unit test from a real thinking-block JSONL line BEFORE fixing.
Files: Sources/PodiumApp/** (UI), Sources/PodiumCore/Transcripts/** if (a) is a parser bug. Server routes are NOT in scope — if you believe the server is wrong, STOP and report instead.
DOD: each bug either fixed-with-test or explained-with-evidence (repro steps + exact failing layer). swift test fully green incl. ContractTests 29/29. Update the F2 board row with the outcome.
[+ fence block §8]
```

### 1.2 ☐ Final v1 QA sweep
**Model: Sonnet.** Empty/error states + light/dark pass on the new surfaces
(tour, diagnostics, config explorer, replay, exporter). Board "v1 close-out"
item 1. Deliverable: QA report + trivial fixes inline; anything structural
becomes a board entry, not a drive-by fix. *(Prompt: reuse the maestro:qa
pattern — boot app with empty fixture DB, then with the walk DB; screenshot
each view in both appearances; table of findings.)*

### 1.3 ☐ `main` branch + default
`git checkout -b main && git push -u origin main`, set GitHub default to
`main`, keep develop as integration. Plan convention expects PRs → main.
Orchestrator directly, 5 min. **After** 0.1 (CI green proof on develop).

### 1.4 ☐ THE SWITCHOVER *(HUMAN — Gaël + orchestrator live)*
MIGRATION.md is the script. Copy-first, verify, only then `docker rm` the
prod container (it's currently UNHEALTHY anyway since ~07-04). DMG ready at
dist/Podium-1.0.dmg. **This is the v1.0 finish line.**

---

## PHASE 2 — v1.1 features (PO-prioritized)

Ranked by GroupOne-pitch value ÷ effort. **Ship each one polished before
starting the next** (quality-over-breadth).

**EXECUTION ORDER (Gaël, 2026-07-06 — section numbers are historical, do
NOT follow them):** first **2.9a → 2.9b** (update system — it's the
distribution channel; everything else is fixes that need a way to reach
users), then **2.0** (UX parity), then 2.1, 2.2a/b/c, 2.9c
(self-updater — needs a real release to update FROM, so it lands after
at least one 2.9a-cut release), 2.3, 2.4, and the rest as numbered.

### 2.0 ☐ Native UX parity pass  *(M — inserted 2026-07-06 from Gaël's web-vs-app review; runs after 2.9a/b, before the menu bar extra)*

Gaël's findings, reviewing the web app side by side with the native app:
the web app's UX is currently BETTER than the native app's. Specifics:
(a) web session overview shows agent cards; clicking one jumps to the
conversation filtered to that agent; (b) the native app STACKS a new
column per click, shrinking reading space — the web replaces the page,
which reads better; (c) web dashboard sessions are clickable straight
into detail w/ the agent list; (d) the native Workflows page "feels
useless"; (e) native Settings opens directly into the column view,
breaking flow vs other pages; (f) web settings/config-explorer leads
with count cards (quick numbers) — better orientation.

PO decisions (binding for the dispatches below):
- **Kill column accumulation.** One sidebar + ONE detail pane whose
  content is REPLACED on navigation (NavigationStack push inside the
  detail pane, Back button + ⌘[ ). This alone fixes (b) and (e).
- **Workflows (d): do NOT port the web's 12 d3 charts.** Native page
  becomes a focused per-session orchestration view (agent tree,
  swimlanes, tool timeline — the /api/workflows/session/:id data it
  already fetches) plus 2–3 aggregate stat cards, and an "Open full
  analysis in browser" button (opens localhost web app). Honest cut.
- Adopt (a), (c), (f) as-is from the web patterns.

```
TASK 2.0a — Native navigation restructure + web-parity interactions.

Read first: CLAUDE.md (constraints), Sources/PodiumApp/ContentView.swift (current NavigationSplitView shell), SessionDetailView.swift, DashboardView.swift, SettingsView (or the settings entry view), AppState.swift. Then open the WEB app on a live server and click through Dashboard → session → agent → conversation to feel the target (this is the reference UX).
Goals, in priority order:
1. Replace column-stacking with a single detail pane using NavigationStack: sidebar selects the section; every drill-in PUSHES in the detail pane (Back + ⌘[ works). No view may open a new accumulating column.
2. Dashboard: session rows/cards become clickable → push SessionDetail (web parity (c)).
3. SessionDetail overview: agent list as cards; clicking a card pushes the Conversation/Transcript view pre-filtered to that agent (web parity (a)). Check how the web does the filter (agent id query on the transcript/messages fetch) and mirror the semantics.
4. Settings: entry page becomes a summary-cards page (counts: sessions, agents, events, db size, hooks status, server mode — data already available via /api/settings/info + /api/stats), each card pushing into its detail section (web parity (e)+(f)).
5. Workflows: strip to per-session drill-in (tree, swimlanes, timeline — models already exist: WorkflowDetail) + 2–3 aggregate stat cards + "Open full analysis in browser" (NSWorkspace.shared.open on the web URL). Delete what this obsoletes rather than hiding it.
Constraints: pure SwiftUI, keep @Observable AppState pattern (no new state containers), keep Theme tokens (no hardcoded colors), do not touch PodiumCore/PodiumServer. Keyboard: Back must work with ⌘[. Verify each flow by launching via ./run.sh against a seeded fixture (CLAUDE_HOME override — never the real one).
DOD: all five goals demoed (list the click paths you exercised), no column accumulation anywhere, swift build + full test suite green, board §7 row.
[+ fence block §4]
```

```
TASK 2.0b — Ambient orb background for the native app (web-parity "Aurora Glass").

Read first: Sources/PodiumApp/Theme.swift (current backgroundGradient + glassCard), the web reference: ~/Desktop/Work/Claude/podium/dashboard/client/src/index.css (body gradient + orb/glow definitions), and the palette note in the memory file podium-brand-palette (dark = gold orb rgba(254,210,58,0.05) tint from top-left; light = blue rgba(37,99,235,0.05) → indigo rgba(99,102,241,0.04)).
Goal: a reusable OrbBackground SwiftUI view — 2–3 large blurred radial-gradient circles (Canvas or blurred Circles, .blur(radius: 80+)), gold-tinted in dark mode, blue/indigo in light mode, positioned like the web (one top-left, one bottom-right, subtle — opacity ≤ 0.06 equivalent). Applied ONCE at the root behind the NavigationSplitView, UNDER the existing .ultraThinMaterial glass cards so the glass picks up the color bleed exactly like the web's glassmorphism.
Constraints: static (no animation — battery), must not measurably affect scroll performance (test with a 1k-session list), respects reduced-transparency accessibility setting (fall back to the flat gradient). Touch only Theme.swift + a new OrbBackground.swift + the root view application point.
DOD: side-by-side screenshot vs the web app in both appearances; build + tests green.
[+ fence block §4]
```

```
TASK 2.0c — Onboarding tour depth pass (Gaël: "very quick, gives not much information, a bit sad").

Read first: Sources/PodiumApp/OnboardingTour.swift (P5.5 — 5-step glass overlay w/ spotlight anchors), STANDALONE_PLAN.md §7 row for P5.5 (the anchor mechanism is load-bearing — marker-baseline ordering in PodiumApp.swift).
Goal: same mechanism, better content. (1) Rewrite every step's copy: each step = what this page shows + ONE concrete thing to try ("Click a session to see its agents live"). Tone: confident, short, zero filler. (2) Add steps for Run, CC Config, and Diagnostics (and the menu bar extra if 2.1 has landed). (3) Final step links "Show this tour again: Help → Show Tour". Keep it skippable at every step; keep the live legacy-import count on step 1.
Constraints: no new dependencies, don't touch the anchor/preference-key mechanism beyond adding anchors for the new steps, copy reviewed against the product frame (useful/easy/uncluttered — if a step needs 3 sentences, the step is wrong).
DOD: tour run-through screen-recorded or screenshotted per step, light + dark; build green.
[+ fence block §4]
```

### 2.1 ☐ Menu bar extra  *(S — highest value/effort ratio)*
Always-visible presence = the "it's alive" wow in a demo, zero clutter.
**Model: Sonnet.**

```
TASK — Menu bar extra for PodiumApp (macOS).

Read first: CLAUDE.md (architecture + constraints), Sources/PodiumApp/PodiumApp.swift (App entry, activation-policy note — do NOT break it), AppState.swift (@Observable, where session/agent state lives).
Build: MenuBarExtra scene showing (a) live active-agent count as the label — eye logo template icon + count, gold tint when >0 (Theme.accent #FED23A); (b) dropdown: up to 5 most-recent active sessions (name, status dot, relative time — reuse StatusDot/Theme), each clickable → activates main window + navigates to that session; (c) "Awaiting input" section listing sessions with awaitingInputSince set, topmost; (d) footer: Open Podium / server mode indicator (embedded vs client) / Quit.
Constraints: pure SwiftUI MenuBarExtra (macOS 14+, .menuBarExtraStyle(.window) for the rich dropdown). State comes ONLY from the existing AppState via WS updates — no new polling, no new API calls. Window activation must respect the activation-policy fix (test: app closed-to-menubar → click reopens window correctly). Add a Settings toggle "Show menu bar icon" (default ON), persisted in UserDefaults.
DOD: builds + runs via ./run.sh; menu updates live while an agent runs; no retain cycle (AppState is @Observable environment — pass it explicitly to the scene); swift test green; board §7 row.
[+ fence block §8]
```

### 2.2 ☐ Awaiting-input notification + ANSWER-FROM-POPUP  *(L — the flagship)*
§6b №2, approved "ambitious version", and the single most product-defining
feature: Claude is blocked → notification → answer INLINE from the popup.
**Split into 3 dispatches, strictly in order. Model: Sonnet each, Opus-class
review between steps** (this touches RunSpawner stdin — the concurrency-
sensitive file; the cooperative-pool lesson lives there).

```
TASK 2.2a — Control-response framing in RunSpawner.sendInput (PodiumCore only, NO UI).

Read first: Sources/PodiumCore/Runs/RunSpawner.swift ENTIRELY (esp. StdinWriter, the Thread.detachNewThread waitUntilExit comment — understand WHY it's a real thread before touching anything), RunState.swift RunInputAckMessage, STANDALONE_PLAN.md §6b №2 + the §7 note "answer-from-popup needs a stdin control-response framing extension in RunSpawner.sendInput".
Goal: when a Podium-spawned run (stream-json protocol) emits a permission-request/control envelope, (1) parse + surface it on the RunHandle (new field, camelCase wire family, mirror Node's naming if the vendored client types have one — check client/src/lib/api.ts RunHandle first; if absent, name it pendingControlRequest and document it as a Swift-native extension), (2) broadcast a WS event run_control_request, (3) extend sendInput to write a correctly-framed control_response back to stdin (the claude stream-json control protocol — verify the exact frame against Claude Code docs/source, do NOT guess field names).
Tests: unit tests with a fixture script that emits a control-request envelope and asserts the response frame lands on its stdin verbatim. All timing via bounded polls (see RunSpawnerTests.poll). Remember /usr/bin/true not /bin/true.
Do NOT touch UI, PushNotifier, or the router beyond exposing the new field. ContractTests must stay 29/29 — if the RunHandle wire shape changes, update assertRunHandleShape in the SAME commit with a comment.
[+ fence block §8]
```

```
TASK 2.2b — macOS notification with inline reply (after 2.2a merges).

Read first: Sources/PodiumCore/Push/PushNotifier.swift + NativeNotifier protocol, AppState.swift, 2.2a's run log entry.
Goal: UNUserNotificationCenter notification when (a) a session/agent sets awaiting_input_since, or (b) a Podium-spawned run emits run_control_request. For (b): UNTextInputNotificationAction ("Reply…") for free-text prompts and UNNotificationAction buttons for allow/deny-style permission requests → route the response through the 2.2a API. For (a) (external terminal sessions): notification + click focuses the app on that session (NO keystroke injection — rejected in §6b).
Also: notification preferences pane in Settings (per-event toggles: completed / error / awaiting-input / control-request; default all ON except completed).
DOD: end-to-end demo — spawn a run from the Run page in acceptDangerously=OFF mode that triggers a permission ask, answer it from the notification popup without touching the window, run continues. Record the demo steps in the §7 row.
[+ fence block §8]
```

```
TASK 2.2c — Linux parity (after 2.2b): notify-send desktop notification for the same events via LinuxDesktopNotifier (NOTE: its waitUntilExit runs on a blocking call — check it's not on the cooperative pool; fix with the same Thread pattern as RunSpawner if it is, it's 3 lines). Web push click-through already exists; wire the run_control_request event into the web client ONLY if the vendored client already has a handler (do not fork the React app for this — if absent, log as future web work and stop).
[+ fence block §8]
```

### 2.3 ☐ Backup restore wiring  *(S)*
Backups tab is browse-only with an in-UI note (P5.4 flagged it explicit).
Close the loop: restore = copy-back with a pre-restore safety copy +
confirmation dialog naming both paths. **Model: Sonnet.** *(Prompt: extend
PodiumAPI+CcConfig restore call → CcMutate copy-back guarded by a
`.pre-restore-<timestamp>` sibling copy; UI confirm; unit test the copy
logic against a fixture dir.)*

### 2.4 ☐ Session hygiene: delete + cleanup UI  *(S)*
`POST /api/settings/cleanup` exists server-side; surface it: per-session
delete (context menu, confirm) + Settings "Clean up sessions older than N
days" with a dry-run count first. Uncluttered dashboards sell the GroupOne
demo. **Model: Sonnet.**

### 2.5 ☐ Async reimport with progress  *(M)*
Cold-cache first import is CPU-bound seconds-per-hundred-files (documented
debt). Move to a background task + `import_progress` WS events (the message
type already exists — `ImportProgressMessage`), progress UI in Import page +
native app. **Only worth it if the switchover (1.4) shows real-corpus pain**
— PO gate: measure first with Gaël's actual dashboard.db, then decide.

### 2.6 ☐ Pre-migration DB backup  *(XS — do together with 2.5 or 1.4)*
§6b №1, parked-but-cheap: on first takeover of an existing dashboard.db, the
app writes `dashboard.db.pre-podium-<version>` next to it, once. ~20 lines +
test. Fold into whichever adjacent task touches PodiumPaths first.

### 2.7 ☐ Residual purple audit  *(XS)*
Brand palette (gold/navy "Aurora Glass") is APPLIED since Wave 6, but the
memory note flags stragglers: hardcoded `Color(red:0.6,green:0.4,blue:1)`
purples and cyan "active" states (web uses gold for live). One Haiku-tier
sweep: grep all Color literals in Sources/PodiumApp, table of hits, replace
with Theme tokens per the palette memory. Screenshot before/after.

### 2.9 ☐ Update system  *(M — added 2026-07-06 on Gaël's ask. RANK: FIRST in Phase 2 (Gaël's call: "the update thing should be a priority, others are more like fixes") — it is the distribution channel that lets every later fix reach users. Numbered 2.9 only to avoid renumbering an in-use file.)*

Goal: tag a GitHub release → users see "Update available" in the app, read
the changelog, download the new build. **60% exists already**:
`UpdateCheck.swift` (P4.3) polls the GitHub Releases API and
`/api/updates/status` + the `update_status` WS broadcast serve it — nothing
PRODUCES releases today, and nothing DISPLAYS the check.

**Staged, PO decision (revised 2026-07-06 — NO Apple Developer ID
available; Gaël needs to prove the product first, so the update path must
be free):**
- Stage 1 (below): notify + changelog + download link. No signing needed.
- Stage 2 (free self-updater, NO Developer ID required): the app updates
  ITSELF. Why this works without notarization: Gatekeeper only evaluates
  files carrying the com.apple.quarantine xattr, and quarantine is OPT-IN
  for the downloading process — browsers set it, the app's own URLSession
  does not (don't add LSFileQuarantineEnabled). So: app downloads
  Podium-<v>.zip via its own URLSession → verifies an ed25519 signature
  (CI signs with a GitHub-secret key; app embeds the PUBLIC key —
  swift-crypto Curve25519.Signing, already a dependency) → unpacks to
  temp → atomically swaps the .app bundle (rename old aside, move new in,
  relaunch; if the install dir isn't writable, fall back to "reveal
  download in Finder") → relaunch. The replaced app is the same ad-hoc
  build class the user already runs — no new Gatekeeper prompt.
  Caveats to state honestly in RELEASING.md: (1) FIRST install keeps the
  one-time right-click→Open friction — unavoidable without notarization;
  (2) trust root is the embedded pubkey + repo secret, which is real
  integrity (better than checksum-from-same-server) but not Apple's chain.
- Later, if GroupOne funds a Developer ID: add notarization to release.yml
  and keep the same updater — it's a drop-in improvement, nothing thrown
  away. (Sparkle becomes optional at that point, not required.)

```
TASK 2.9c — Free self-updater (Stage 2). Model: Sonnet, Opus-class review (it swaps the app bundle on disk — the failure mode is a broken install). AFTER 2.9a + 2.9b ship and one real release exists.

Read first: the Stage 2 rationale above (quarantine opt-in fact, ed25519 scheme), UpdateCheck.swift, 2.9a's release.yml, scripts/package-macos.sh, Package.swift (swift-crypto already pinned).
Goal:
1. release.yml additions: zip the .app (ditto -c -k --keepParent), sign the zip with ed25519 (private key from repo secret PODIUM_UPDATE_SIGNING_KEY; document one-time key generation in RELEASING.md), attach Podium-<v>.zip + Podium-<v>.zip.sig as release assets.
2. App-side Updater (PodiumApp only, macOS): download the .zip asset via its own URLSession to a temp dir (verify NO quarantine xattr lands — assert in tests via xattr check on a fixture download), verify the .sig against the embedded public key BEFORE unpacking (reject loudly on mismatch — this is the security boundary), unpack, validate the bundle (Info.plist version matches the release tag), atomic swap: move current .app to ~/.Trash (or temp) → move new into place → relaunch via a detached /bin/sh -c 'sleep 1; open <path>' + terminate. If the parent dir isn't writable or the app isn't running from a normal location (translocation check), fall back to opening the downloaded zip in Finder with a one-line instruction.
3. UI: the 2.9b banner gains "Install update" next to "Download"; progress + a clear failure state that NEVER leaves the user without a working app (the old bundle is only moved aside after the new one verified).
4. Linux: out of scope (systemd unit + install script already handle it; print the one-line update command in the daemon log instead).
Constraints: no Sparkle, no new dependencies, signature verification is NOT skippable (no env flag to bypass), never delete the old bundle before the new one is verified-in-place.
DOD: full self-update demo against a real GitHub release (0.9.x fixture → latest), including a tampered-zip test proving the signature gate rejects it; full suite green.
[+ fence block §4]
```

```
TASK 2.9a — Release pipeline (producer side). Model: Sonnet.

Read first: .github/workflows/ci.yml (style/conventions incl. timeout-minutes + the --product-per-invocation footgun note), scripts/package-macos.sh, scripts/build-linux.sh, Sources/PodiumCore/Discovery/UpdateCheck.swift (currentAppVersion — env PODIUM_APP_VERSION, falls back "dev").
Goal: .github/workflows/release.yml triggered on tag push v* :
1. macOS job: run package-macos.sh with the version STAMPED from the tag (extend the script to accept VERSION: writes CFBundleShortVersionString into the bundle Info.plist AND names the DMG Podium-<version>.dmg). timeout-minutes: 40.
2. Linux job: build-linux.sh --host inside the swift:6.1 container (mind the docker-in-docker issue — if build-linux.sh insists on docker, use its host-toolchain path since the job ALREADY runs in the swift container), tarball named podium-linux-<version>-<arch>.tar.gz.
3. Release job (needs both): gh release create for the tag with BOTH assets and --generate-notes (auto changelog from merged PRs/commits).
Constraints: reuse ci.yml conventions; do NOT touch ci.yml itself; concurrency group per tag; the workflow must be a no-op for non-tag pushes. Verify by dry-running the version-stamping script paths locally (you cannot push a tag — document the manual verification steps you DID run and what the first real tag will prove).
DOD: workflow file + updated packaging scripts + a RELEASING.md section (5 lines max: how to cut a release = git tag vX.Y.Z && git push --tags).
[+ fence block §4]
```

```
TASK 2.9b — In-app updates UI + changelog (consumer side). Model: Sonnet. AFTER 2.9a.

Read first: Sources/PodiumCore/Discovery/UpdateCheck.swift ENTIRELY (appRepoSlug env resolution + doc comment; GitHubRelease/transport), Sources/PodiumServer/Routes/UpdatesRouter.swift, Models/Updates.swift + the updates assertions in ContractTests (testUpdatesStatusContract — any wire change must keep it green in the SAME commit), the Settings UI entry in Sources/PodiumApp/.
Goal:
1. Default appRepoSlug() to "Miraeld/podium-app" (env PODIUM_APP_GITHUB_REPO still overrides; update the stale doc comment saying no remote exists).
2. currentAppVersion(): prefer the bundle's CFBundleShortVersionString (stamped by 2.9a), then env, then "dev".
3. Extend GitHubRelease + the API decode with the release NOTES body (markdown) — new optional snake_case wire field on RepoUpdateStatus (release_notes); ContractTests updates test must stay green.
4. Native UI (Settings → "Updates" card): current version, "Check for updates" (POST /api/updates/check), and when updateAvailable: a banner (Theme.accent) + a changelog sheet rendering the release notes (AttributedString(markdown:) is enough — no new deps) + "Download" button opening releaseUrl in the browser. Also listen for the update_status WS broadcast so the banner appears without a manual check (max one auto-check per app launch — no polling loops).
5. Linux daemon: log "update available: <version> — <url>" once per process when detected. Web client: NO fork — note in the report whether the vendored UpdateNotifier.tsx could be re-enabled via the patches/ flow, but do not do it.
Constraints: no auto-download/install (Stage 2), no Sparkle, no new dependencies. Respect the update-check being best-effort (offline must never error the UI — show "couldn't check" quietly).
DOD: demo path — set env PODIUM_APP_VERSION=0.9.0 with a real 1.0 release published (or a fixture transport in tests) → banner appears, changelog renders, download opens. Unit tests for the version-compare + release_notes decode. Full suite + ContractTests green.
[+ fence block §4]
```

### 2.8 ☐ Quick Look extension  *(parked — revisit after 2.1–2.4 ship)*
Neat, not pitch-critical. Re-evaluate only when everything above is done.

---

## PHASE 3 — Tech-debt ledger (fold into adjacent work, never a dedicated sprint)

| Debt | Where | Fold into |
|---|---|---|
| PushNotifier Sendable-closure warning (Swift 6 mode) | Push/PushNotifier.swift:26 | 2.2b |
| LinuxDesktopNotifier blocking `waitUntilExit` — audit vs cooperative pool | Push/LinuxDesktopNotifier.swift:34 | 2.2c |
| Same audit: GitContext.swift:93, RunBinaryLocator.swift:44 | app/core | any Sonnet task touching those files |
| cc-config symlink-following gap (exact Node parity — joint ticket) | Discovery/CcConfig | when Node side moves |
| Web-push click-through fields snake_case vs future client camelCase | Push | 2.2c (no consumer yet) |
| `WorkflowSessionRaw` dead code | PodiumApp Models | 2.7 sweep |
| Web app over-eager refetch — UI "stutters"/spinner storm on WS events (Gaël 2026-07-06, parked by his call: low investment). Likely fix = debounce refetch-on-WS + skeleton instead of spinner | WebClient (vendored — needs the patches/ + rebuild flow) | only if it still annoys after the switchover |
| RunSpawner stdin-backpressure question (from CI diagnosis era — likely resolved by the Thread fix, but never explicitly tested with a slow-reading child) | Runs/RunSpawner.swift | 2.2a MUST add a test: child that never reads stdin + 1MB write → sendInput must not block the actor |

## 4. §8 — The fence block (append to EVERY dispatch prompt, verbatim)

```
FENCES — non-negotiable:
- Touch ONLY the files named in this task. If the fix seems to belong elsewhere, STOP and report.
- Never touch: ~/.claude/podium/data (live Docker bind-mount), any running PodiumApp process, the prod `podium` Docker container, WebClient/dist (vendored build — patches go through WebClient/patches/ + rebuild flow only).
- Wire format is LAW: snake_case via PodiumJSON; deliberate camelCase families use the AnyEncodable dictionary pattern (see PodiumJSON.swift doc comment); errors are CodedErrorResponse {"error":{"code","message"}}; never mix snake_case CodingKeys with .convertFromSnakeCase. ContractTests (29) is the gate — run it.
- Tests: /usr/bin/true not /bin/true. Bounded polls only. New XCTSkip gates need GITHUB_ACTIONS guard + comment, and ONLY for runner-env behavior that passes locally.
- Do not commit or push unless the task says to; an auto-commit hook may fire on saves — ignore it, never amend/rebase around it.
- Report: outcome first, then evidence (test output), then deviations. If you deviated from the spec, say so explicitly — undeclared deviations are treated as bugs.
```

## 5. Suggested session shapes

- **One evening:** Phase 0 complete (0.1 orchestrator + 0.2 Sonnet + 0.3) →
  README close-out. CI green + P6.2 ✅ is a clean stopping point.
- **One day:** Phase 1 (F2 + QA sweep + main branch), switchover with Gaël
  in the evening. **v1.0 done-done.**
- **v1.1 week:** 2.9a/b (update channel) → 2.0 (UX parity) → 2.1 →
  2.2a/b/c → 2.9c → 2.3 → 2.4, one at a time, each polished.
- Always end a session with: board updated, §7 logged, HANDOVER.md
  resealed, everything pushed, CI verdict known.
