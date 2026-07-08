# Podium — Roadmap to 1.0.0 (Tauri consolidation)

> **Author:** Fable 5, acting PO. **Rewritten 2026-07-06** after the big
> pivot (below). Supersedes the previous SwiftUI-era roadmap.
> **Audience:** the next orchestrator / dispatched agents. Self-contained —
> this file + the repo are the whole briefing. Work phases top-to-bottom.

---

## 0. THE PIVOT — read this first

**Discovery (2026-07-06):** the vendored **web dashboard** (React, served by
the Swift server, visible at `http://localhost:4820`) is dramatically more
complete and polished than the native **SwiftUI app** we'd been building —
richer Workflows, Analytics, CC Config, Settings, everything. We had been
polishing the *weaker* of two UIs, and reimplementing in SwiftUI what already
existed and worked better on the web.

**Decision:** stop maintaining two UIs. Consolidate on the web UI and ship it
as **ONE native desktop app on every platform, via Tauri.**

- **1.0.0 = a Tauri native app on macOS + Linux** that bundles the existing
  Swift `podium-server` as a sidecar process and shows the web dashboard in a
  native window. Experience: **download → move to Applications → open →
  agents appear live.** Same on Mac and Linux.
- **Windows** is a near-free follow-up (Tauri targets it too) — deprioritized;
  the server already runs, so it's not blocking.
- **The Swift server stays 100%** (`podium-server`, `PodiumCore`,
  `PodiumServer`, ingestion, contract tests, packaging of the binary) — it
  becomes the bundled backend.
- **The SwiftUI app (`PodiumApp`, ~40 view files) is retired** once the Tauri
  shell reaches parity.

Everything SwiftUI-specific from the old plan is dropped — see §5 so nothing
vanishes silently.

## 1. Why Tauri (plain terms, for the record)

A **"shell"** = a native app window that displays a web page with no browser
chrome — to the user it's just an app.

**Tauri** builds one shell from one codebase and emits native installers for
every OS: `.dmg` (mac), `.AppImage`/`.deb` (linux), `.msi` (windows). It can
bundle an external binary as a **"sidecar"** — we bundle `podium-server`,
Tauri launches it on open and kills it on quit. The window then just points
at `http://localhost:<port>`, which the server already serves (the web UI is
served BY podium-server today — no separate asset bundling needed). Native
tray, notifications, and macOS window vibrancy (**glass survives**) are all
cross-platform. Tauri also ships a **built-in signed auto-updater** — this
replaces the entire custom self-update saga we were speccing.

**Bonus (robustness):** the server runs as a *separate process*, so a server
crash no longer kills the app window — the shell can detect and restart it.
That shrinks the blast radius of bugs like the WebSocket auto-ping crash from
"whole app dies" to "server blips and restarts."

**Fallback:** if Rust/Tauri proves painful, Electron does the same job
(heavier, ~150 MB, less native). Try Tauri first — it's purpose-built for
"native window + local web UI + bundled backend binary."

## 2. Product frame (unchanged, binding)

Podium is pitched inside **GroupOne** as a standalone product: **useful,
easy, uncluttered, sexy.** The objection to kill is *"too complicated."*
Acceptance bar: **download → open → your agents appear live, zero manual
steps.** Any step that needs a README to explain is a defect. Cost features
stay de-emphasized. Linux gets the same first-class experience as macOS —
which the Tauri pivot finally makes true (a real Linux app, not a browser
tab).

## 3. Transition strategy (how we don't break the current thing)

- **0.5.x (current SwiftUI app): FROZEN.** Only critical fixes ship (the
  crash, §4.0). No new SwiftUI feature work — that era is over.
- **1.0.0 (Tauri app): all new energy goes here.**
- At 1.0 we cut over: the Tauri app becomes THE product; the SwiftUI target
  is deleted. The web UI and Swift server carry across unchanged.

## 4. Operating rules (unchanged essentials)

- Board discipline: `git pull` before editing this file; push after every
  commit; log outcomes.
- Model tiering: Sonnet implements; Opus/Fable-class reviews + anything
  touching the sidecar lifecycle, wire format, or concurrency.
- Wire-format gate: `swift test --filter ContractTests` stays green after any
  server change. The web client depends on it — now more than ever, since
  it's the only UI.
- CI truth policy (Gaël, 2026-07-05): local-green + runner-red ⇒
  `GITHUB_ACTIONS`-gated `XCTSkip` with the mechanism documented.
- Every dispatch prompt ends with the fence block (§7).

---

## 4.0 ☐ DO NOW — fix the WebSocket auto-ping crash (independent of the pivot)

Root-caused 2026-07-06: the intermittent crashes (both on-quit and mid-use)
are a `swift_task_dealloc` fatal error inside `WebSocketHandler.runAutoPingLoop()`
(the `hummingbird-websocket` dependency's auto-ping loop). It fires whenever a
dashboard WebSocket connection closes while its `Task.sleep` is pending — i.e.
every time a tab disconnects. The 0.5.2 shutdown-wait fix only covered the
on-quit trigger.

**Fix:** disable auto-ping in the server's WebSocket config — deletes the
crashing code path entirely. In `Sources/PodiumServer/PodiumServerApp.swift`,
the `.http1WebSocketUpgrade(webSocketRouter:)` call takes a `configuration:`
(`WebSocketServerConfiguration`) with an `autoPing:` field — set it to
`.disabled`. Verify the exact API against `.build/checkouts/hummingbird-websocket`.
Liveness is a non-issue: the web client reconnects on its own, and half-open
connections are a minor resource concern vs a crash. Benefits BOTH the current
0.5.x app AND the future Tauri sidecar. Ship as **0.5.3**. Model: Sonnet;
verify by running the app with the dashboard open for a while + quit cycles.

---

## PHASE T1 — Tauri shell MVP  *(the core of the pivot)*

Goal at end of T1: a native app on macOS + Linux that, when opened, boots the
bundled server and shows the live dashboard. "Download → open → works."

### T1.1 ☐ Scaffold Tauri + bundle podium-server as a sidecar
**Model: Sonnet, Opus-class review (sidecar lifecycle is the load-bearing part).**

```
TASK T1.1 — Tauri app skeleton with podium-server as a sidecar.

Read first: CLAUDE.md; Sources/PodiumServerCLI/main.swift (the podium-server CLI — flags: --port, --data-dir, --no-hooks; it ALREADY serves the web UI over HTTP + the API); scripts/package-macos.sh + build-linux.sh (how the server binary is built per-platform); Sources/PodiumCore/Discovery/ (server-info file / port discovery). Skim the Tauri v2 docs on "sidecar / embedding external binaries" and "shell/process plugin".
Goal: a new `tauri/` directory at repo root containing a minimal Tauri v2 app that:
1. Bundles `podium-server` as a sidecar (externalBin), per-platform (macOS arm64 first; wire Linux x86_64/arm64 targets in config even if built later).
2. On launch: spawns the sidecar with a chosen port + a data-dir (default the same platform path PodiumPaths uses: macOS ~/Library/Application Support/Podium; Linux ~/.local/share/podium — so it reads the user's existing DB), waits for GET /api/health to return 200 (poll, timeout ~15s), THEN loads http://localhost:<port> in the main window.
3. On quit / window close: terminates the sidecar cleanly (no orphaned server process). Handle the case where a server is already running on the port (reuse it, like EmbeddedServer does today) vs spawn our own.
4. A basic window (title "Podium", reasonable default size, remembers size/position).
Constraints: Tauri v2, Rust shell kept MINIMAL (target < ~200 lines of Rust). Do NOT bundle the web assets separately — the sidecar serves them; the window just navigates to localhost. Do NOT modify the Swift server except (if needed) adding a CLI flag; if you think the server needs a change, STOP and report.
DOD: `cargo tauri dev` (or the npm equivalent) opens a window showing the live dashboard served by the spawned podium-server, against the real DB; closing the window leaves NO orphaned podium-server process (verify with lsof/ps). Document the exact run/build commands in tauri/README.md.
[+ fence block §7]
```

### T1.2 ☐ macOS packaging (.dmg) + vibrancy (glass)
**Model: Sonnet.**
```
TASK T1.2 — macOS .dmg + native glass for the Tauri app. AFTER T1.1.
Read first: T1.1's tauri/ setup; the current glass look (Sources/PodiumApp/Theme.swift ThemeBackground + the web CSS backdrop-filter); Tauri docs on macOS window vibrancy (the `window-vibrancy` crate / NSVisualEffectView) and on `.dmg` bundling + code signing (ad-hoc for now — NO paid Developer ID; document the xattr -dr com.apple.quarantine workaround in the release notes).
Goal: (1) `cargo tauri build` produces `Podium.app` + a `.dmg` (drag-to-Applications). (2) Enable macOS vibrancy so the window has the liquid-glass look: transparent webview over an NSVisualEffectView, OR the window-vibrancy crate — whichever gives the wallpaper-blur behind the web content. The web UI already has its own CSS glass, so worst case that shows; best case native vibrancy bleeds through. (3) App icon = the existing eye/AppIcon asset.
Constraints: ad-hoc signing only (no $99). Version stamped from a single source (align with the release pipeline in T3.1).
DOD: install the .dmg on a clean path, open it (note the one-time right-click/xattr step), confirm live dashboard + glass. Screenshot.
[+ fence block §7]
```

### T1.3 ✅ Linux packaging (.AppImage / .deb) — the payoff
**DONE 2026-07-07** — reproducible Docker build (swift:6.1 + Rust + WebKitGTK)
produces `.AppImage` + `.deb` with the Linux podium-server sidecar embedded.
ARM64 built + structurally verified; x86_64 cross-build path documented, not
run; GUI verify pending on a real Linux desktop (no display in Docker). See
`tauri/linux-build/README.md`.
**Model: Sonnet (build/run inside the swift:6.1 + Tauri toolchain; OrbStack/Docker on the dev Mac).**
```
TASK T1.3 — Linux native app packaging. AFTER T1.1.
Read first: T1.1; scripts/build-linux.sh (how podium-server is built for Linux via swift:6.1 docker); Tauri Linux bundling docs (.AppImage + .deb; WebKitGTK dependency).
Goal: produce a Linux `.AppImage` (and .deb) of the Tauri app bundling the Linux podium-server sidecar. Double-click → opens a native window with the dashboard. No browser, no systemd needed for the app (the app launches its own server sidecar; the standalone systemd daemon path still exists separately for headless servers).
Constraints: build inside a container so it's reproducible on the Mac dev box (document the exact docker/OrbStack commands). Ensure the Linux sidecar binary is the right arch.
DOD: run the .AppImage inside a Linux container/VM (or note the manual step if GUI-in-container is impractical), confirm the window loads the dashboard against a seeded DB. This is THE "real Linux app" milestone — call it out in the run log.
[+ fence block §7]
```

### T1.4 ✅ Tray icon + native notifications (cross-platform)
**DONE 2026-07-07** — menu-bar tray (Open / live server-status / Quit) +
native notifications on session finish/error/awaiting-input, driven by a
background thread watching podium-server's `/ws` stream (`ws_watcher.rs`).
Per-event toggles persisted as a hand-editable JSON file
(`<data_dir>/tauri-notifications.json`) — no settings UI yet (a web-client
panel is a later task). Fixed the tray "starting…" stuck-status bug (status
now seeds from the health check + refreshes from `/api/stats` on WS connect).
Verified on macOS: build, health, ws connect, real active→completed event
processed cleanly, Cmd+Q kills the sidecar with no orphan. Still wants a
human's eyes for **visual** notification confirmation + the first-launch
macOS notification-permission prompt. NOTE: real-session notifications
depend on live sessions actually being ingested — see the ingestion-status
debt item (§8), which the current session surfaced ("live session shows as
Abandoned / not in the web UI").
**Original task spec (kept for reference):**
```
TASK T1.4 — System tray + native notifications via Tauri.
Read first: T1.1; the events the server already broadcasts over WS (run_status, awaiting-input, agent/session updates — see Sources/PodiumServer/WebSocket/); the OLD SwiftUI notification intent (awaiting-input notification — was STANDALONE_PLAN §6b №2, file removed; see git history).
Goal: (1) A tray/menu-bar icon showing live active-agent count (gold when >0), with a menu: Open Podium / server status / Quit. (2) Native OS notifications (Tauri notification plugin — works on mac + linux + windows) fired when a session finishes, errors, or goes awaiting-input. The shell subscribes to the server's WS (or a small /api events poll) to know when to fire. Per-event toggles persisted.
Constraints: cross-platform (no platform-specific notification code where the Tauri plugin covers it). Don't reinvent state — read it from the server.
DOD: demo a notification firing on a real event on both mac and linux (linux can be the container/VM). Tray count updates live.
[+ fence block §7]
```

---

## PHASE T2 — Move the SwiftUI-only features into the web client

These features existed only in the native SwiftUI app. They now belong in the
React web client (`WebClient/` — built via the vendored client's patch/rebuild
flow, see the P5.5 tour work in git history for the WebClient/patches pattern),
so they work in the Tauri window on every platform AND in a plain browser.

### T2.1 ✅ Update popup + changelog → web client (done 2026-07-07, `f3670c0`; popup/Dismiss/Update semantics + Settings panel verified in-browser, ContractTests 29/29)
```
TASK T2.1 — Update-available popup in the React client.
Read first: Sources/PodiumCore/Discovery/UpdateCheck.swift (the /api/updates/status backend already exists + returns release notes); the vendored client — there's a stub UpdateNotifier.tsx waiting for exactly this; the retired SwiftUI UpdatesView.swift for the intended UX (popup with Dismiss / Update; Dismiss suppresses that version, Update opens the release page WITHOUT suppressing so it re-prompts if not installed).
Goal: a React "New update available" popup + a Settings "Updates" panel, consuming /api/updates/status, rendering the changelog (release notes markdown), with the exact Dismiss/Update semantics above (persist dismissed version in localStorage). Built through the WebClient patch/rebuild flow → vendored dist.
NOTE: the actual app self-update (download+install) is Tauri's built-in updater (T2.3), not this — this is notify + changelog + "open release page".
DOD: with a newer GitHub release published, the popup appears in the Tauri window; Dismiss/Update behave correctly. ContractTests for /api/updates stay green.
[+ fence block §7]
```

### T2.2 ✅ Onboarding tour → web client (done 2026-07-07; driver.js, 4-5 steps, re-runnable from Settings. Fixed a launch bug where onDestroyed marked "seen" on teardown → tour never showed. Auto-run/reload/replay all verified in-browser.)
```
TASK T2.2 — Onboarding tour in the React client.
Read first: the web client's existing welcome card (Dashboard.tsx, from the P5.5 work); a web tour lib (driver.js or shepherd.js — pick one, justify briefly).
Goal: a guided first-run tour over the real web UI — spotlight each nav section with one concrete "try this" per step (Sessions, Workflows, Run, CC Config, Diagnostics, Recommendations-when-it-lands), skippable, re-runnable from a Help/Settings entry, shown once (localStorage). Copy per the product frame: short, confident, one action per step.
DOD: tour runs in the Tauri window + a browser, light + dark; screen-record or screenshot each step.
[+ fence block §7]
```

### T2.3 ☐ Tauri built-in auto-updater (replaces the custom self-updater)
```
TASK T2.3 — Wire Tauri's built-in updater. AFTER T3.1 (release pipeline emits the update artifacts + signature).
Read first: Tauri v2 updater docs (updater plugin, update manifest, signing keys — Tauri's own EdDSA scheme, NO Apple Developer ID needed for the update mechanism itself); the free-updater rationale from git history (quarantine is opt-in for the app's own downloads).
Goal: the app checks a Tauri update manifest (published by the release pipeline), and on "Install update" downloads + swaps + relaunches — signed with the Tauri updater key (public key embedded, private key a CI secret). This is the real click-to-update, cross-platform, no paid signing required.
Constraints: signature verification NOT skippable. Feature-flaggable. First install still has the one-time Gatekeeper step on mac (unavoidable without notarization) — document it.
DOD: publish a test release, click Install update in an older build, get the new version. Tampered-artifact test proves the signature gate rejects it.
[+ fence block §7]
```

---

## PHASE T3 — Harden + ship 1.0.0

### T3.1 ✅ Release pipeline → Tauri installers (done 2026-07-07, `8eb4eec`; macOS job locally built a real .dmg + actionlint clean. REMAINING MANUAL DOD: push a real `v*` tag to prove the Linux job + end-to-end release/draft flow.)
```
TASK T3.1 — CI builds the Tauri installers. AFTER T1.1–T1.3.
Read first: the current .github/workflows/release.yml (builds the DMG + Linux tarball for the SwiftUI app — this gets replaced/extended); Tauri's official GitHub Action (tauri-apps/tauri-action) which builds + drafts a release with .dmg/.AppImage/.deb; T2.3's updater artifact + signing requirements.
Goal: on tag push v*, build the Swift podium-server per-platform, then the Tauri app for macOS + Linux, and publish a GitHub Release with .dmg + .AppImage (+ .deb) + the Tauri updater manifest/signature. Keep macOS + Linux jobs; keep the timeout-minutes + concurrency conventions.
DOD: a real tag produces a release with the Tauri installers attached; a fresh download opens and works on both platforms.
[+ fence block §7]
```

### T3.2 ✅ Retire the SwiftUI app target (done 2026-07-07, 69e803f/fc2ceaf; PodiumApp target + Sources/PodiumApp deleted, run.sh→Tauri dev, swift test 465/465)
```
TASK T3.2 — Remove PodiumApp (SwiftUI) once the Tauri app is at parity. AFTER T1+T2 verified.
Goal: delete the PodiumApp executable target from Package.swift and its Sources/PodiumApp/ tree (git history preserves it), plus run.sh's app-bundle path and scripts/package-macos.sh's SwiftUI packaging. KEEP: PodiumCore, PodiumServer, podium-server, podium-hook, WebClient, Tests. Update CLAUDE.md to describe the new architecture (Swift server + web client + Tauri shell).
Constraints: do this ONLY after 1.0 QA (T3.4) confirms the Tauri app fully replaces it. Full test suite stays green (the server/core tests are unaffected).
DOD: swift build + swift test green with PodiumApp gone; the app still ships (via Tauri).
[+ fence block §7]
```

### T3.3 ✅ Docs for the new architecture (done 2026-07-07; README + MIGRATION + CLAUDE.md rewritten for the Tauri app)
README + MIGRATION rewritten: what Podium is (native app on mac+linux via
Tauri, Swift server inside), install per platform, the one-time Gatekeeper
step, the plugin→standalone migration (unchanged: "your dashboard.db just
works"). Update CLAUDE.md. Orchestrator or Sonnet.

### T3.4 ◑ Final 1.0.0 QA — macOS DONE 2026-07-07 (launch→live data→render→close-to-tray→clean quit→all 9 pages, zero console errors). LINUX GUI QA + the v1.0.0 tag REMAIN (need a real Linux box/VM).
Clean-machine test on macOS + Linux: download installer → open → live agents
appear → walk every page → spawn a run → notifications fire. Fix or file
anything broken. When green on both: **tag v1.0.0.** This is the finish line.

---

## 5. DROPPED from the old (SwiftUI-era) roadmap — nothing lost, just moot

The pivot retires the SwiftUI UI, so these are gone (their *intent*, where it
still matters, is folded into the web client or Tauri shell above):

- Native UX parity pass (SwiftUI nav restructure, agent-card→conversation,
  settings summary cards) — **moot**; the web UI already has all this.
- Native **menu-bar extra** — replaced by the Tauri **tray** (T1.4).
- Answer-from-popup / awaiting-input **native notifications** — replaced by
  Tauri notifications (T1.4); inline-answer stays a later idea via the run
  stdin protocol (server-side, still valid).
- SwiftUI **orbs / purple audit / Theme** work — moot (web has its own glass;
  Tauri vibrancy in T1.2).
- SwiftUI **Data settings / CC Config redesigns / Diagnostics label / card
  alignment** — moot (web UI is the UI now).
- **F2** SwiftUI app bugs (Thinking tab, reinstall-hooks, Diagnostics
  unavailable) — moot (those were SwiftUI views; the web equivalents work).
- Custom Swift **self-updater (old 2.9c)** — replaced by Tauri's built-in
  updater (T2.3).
- **Kanban** — already removed from nav; not carried to the web nav either
  unless it earns its place (it doesn't today).

Kept and carried forward: the Swift server, ingestion, contract tests,
packaging of the server binary, the update *pipeline* (adapted), the
switchover (done), CI truth policy, the crash fix (§4.0).

## 6. Post-1.0 (mentioned, NOT scheduled — Gaël: not a priority now)

- **Windows** installer (.msi) — Tauri makes it mostly a build-target add;
  do it when there's demand.
- **Recommendations engine** — Gaël's idea: a view that analyses local
  history and surfaces actionable suggestions ("you've pasted this prompt
  100/150 sessions → make a /skill"). Works WITHOUT cloud AI via lexical +
  fuzzy matching and, on capable platforms, on-device embeddings (Apple
  `NLEmbedding` on mac; ONNX MiniLM cross-platform later). Must cross-check
  against the user's EXISTING skills/commands so it never recommends what
  already exists. Optional "✨ improve with AI" uses the user's own `claude`
  binary (no stored key). Full 3-stage spec preserved in git history
  (commit 48c37a4, the previous ROADMAP §2.10) — resurrect when prioritized.
- Tauri auto-updater key rotation / notarization if a Developer ID is ever
  funded (drop-in; nothing above changes).

## 7. §7 — The fence block (append to EVERY dispatch prompt, verbatim)

```
FENCES — non-negotiable:
- Touch ONLY the files/dirs named in this task. If the fix belongs elsewhere, STOP and report.
- Never touch: ~/.claude/podium/data (old Docker bind-mount, kept as backup), the user's running app/server, WebClient/dist except via the patches/ + rebuild flow.
- The Swift SERVER is the backend and stays authoritative: wire format is snake_case via PodiumJSON; camelCase exception families use the AnyEncodable dict pattern; errors are CodedErrorResponse; ContractTests (the wire gate) must stay green — run it after any server change.
- Sidecar lifecycle is load-bearing: never leave an orphaned podium-server process; always wait-for-health before loading the window; reuse an already-running server if the port is taken.
- Tests: /usr/bin/true not /bin/true; bounded polls; new XCTSkip gates need a GITHUB_ACTIONS guard + a comment naming the runner behavior, only for things that pass locally.
- Don't commit/push unless the task says to; an auto-commit hook may fire on save — ignore it, never amend/rebase around it.
- Report: outcome first, then evidence (build/run output), then deviations. Undeclared deviations are treated as bugs.
```

## 8. Debt ledger (server-side, trimmed to what still matters)

| Debt | Where | Fold into |
|---|---|---|
| WebSocket auto-ping crash | hummingbird-websocket / PodiumServerApp | §4.0 (do now) |
| PushNotifier Sendable-closure warning (Swift 6) | Push/PushNotifier.swift | any Push task |
| `waitUntilExit` on cooperative pool — audit LinuxDesktopNotifier / GitContext / RunBinaryLocator | app/core | any task touching them |
| Cold-cache first import CPU-bound | Ingest/LegacyImporter | if real-corpus UX warrants (measure first) |
| cc-config symlink-following gap (Node parity) | Discovery/CcConfig | when Node side moves |
| ~~Live-session ingestion: current session showed as Abandoned / not "active"~~ | Ingest + hook delivery post-switchover | **DIAGNOSED + mostly fixed 2026-07-07.** Root cause = sidecar server only ran while the window was open, so hooks fired into the void most of the time. Fixed with close-to-tray (`b658dd6`) — server now persists in the tray. NOT a hook conflict (settings.json has only native podium-hook on 8 events incl. PreToolUse/UserPromptSubmit; old plugin hook.mjs fully replaced; plugin declares no manifest hooks). Secondary, by-design: a transient `APIError` in the transcript flips a session to `error` (IngestEngine.swift:838/844, ported from Node hooks.js, 3 tests lock it in); it self-recovers on the next PreToolUse/UserPromptSubmit *when a live server exists* — which the tray fix now guarantees. |
| Observe-when-Podium-never-opened | Tauri app lifecycle | RESIDUAL after the tray fix: Podium must be *running* (window open OR in tray) to ingest. If the user never launches it, a session isn't observed — the old always-on Docker daemon covered this. Options for later: launch-at-login, or a separate headless `podium-server` daemon (already exists for Linux) auto-started on macOS. Low priority unless users expect zero-touch observation. |
| Imported historical sessions with past API errors show as `error` | Ingest legacy import | Cosmetic: batch import replays transcripts with no live user-action to recover, so any session that ever hit a rate-limit shows red in history. Revisit only if it bugs users — could suppress status-flip during import-only replay. |

## 9. Suggested execution order to 1.0.0

**§4.0 crash fix (ship 0.5.3)** → **T1.1 sidecar** (the make-or-break) →
T1.2 mac .dmg + T1.3 Linux .AppImage (parallel-ish) → T1.4 tray/notifs →
T2.1 update popup + T2.2 tour (web) → T3.1 Tauri release pipeline →
T2.3 built-in updater → T3.4 QA both platforms → **T3.2 delete SwiftUI** →
T3.3 docs → **tag 1.0.0.**
