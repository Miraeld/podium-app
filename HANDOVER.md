# HANDOVER — Podium

> Cold-start briefing for the next session. Last sealed: 2026-07-06 (Fable 5,
> interactive). Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch
> `develop`, remote github.com/Miraeld/podium-app (public, CI live).

## Paste-ready cold-start prompt

```
You're taking over the Podium project (/Users/gaelrobin/Desktop/PodiumSwiftApp,
branch develop). Read HANDOVER.md then ROADMAP.md at the repo root — the
project just PIVOTED: we're retiring the SwiftUI app and shipping the web
dashboard as ONE native app on Mac + Linux via Tauri (server bundled as a
sidecar). ROADMAP.md is fully rewritten around this; work its phases in order
(§9 has the execution order). Verify build/tests actually pass before
continuing. Same rules as always (global + project CLAUDE.md, the fence block
in ROADMAP §7). Don't re-do "Done" items.
```

## State (verify before trusting)

- **Branch develop @ `e5599d8`** (WebSocket auto-ping crash fix). Working tree
  should be clean except whatever the T1.1 Tauri agent is writing under
  `tauri/` (see In flight).
- **Build/tests: `swift build` clean, `swift test` = 465/465, ContractTests
  29/29** (as of this seal — re-run to confirm).
- **Releases shipped:** v0.5.0, v0.5.1, v0.5.2 (SwiftUI DMG + Linux tarball,
  via .github/workflows/release.yml — the pipeline works, 3 green runs). 0.5.2
  is the latest release.
- **The SwiftUI app (PodiumApp) is FROZEN** — being retired in the pivot. No
  new SwiftUI feature work; only the crash fix landed (unreleased, on develop).

## THE PIVOT (the one thing to internalize)

The vendored **web dashboard** (React, served by podium-server, at
`http://localhost:4820`) is far more complete/polished than the SwiftUI app we
were building. Decision: **consolidate on the web UI, ship it as a native app
via Tauri.**
- **1.0.0 = a Tauri app (macOS + Linux)** bundling `podium-server` as a
  sidecar, showing the web UI in a native window. Windows later.
- Swift **server stays 100%** (backend + sidecar); SwiftUI app **retired**.
- Full plan + dispatch prompts: **ROADMAP.md** (rewritten 2026-07-06). Old
  SwiftUI-era tasks are cleared (ROADMAP §5). Recommendations demoted to
  post-1.0 (§6; full spec preserved in git commit 48c37a4).

## Done this session

- **Shipped v0.5.0 → v0.5.2** via the (now-proven) release pipeline; each cut
  a GitHub Release with DMG + Linux tarball + auto notes.
- **Supervised switchover DONE**: stopped the plugin-era Docker, copied its
  465MB dashboard.db into the app's data dir; app now self-hosts the full 1551
  sessions. Original untouched at ~/.claude/podium/data (backup).
- **Fixed the crash saga** — root-caused to WebSocket auto-ping
  (`swift-websocket` `runAutoPingLoop` -> `swift_task_dealloc` abort on any WS
  disconnect). 0.5.2 fixed the on-quit trigger (graceful-shutdown wait);
  `e5599d8` fixed it for good by **disabling autoPing** in
  `Sources/PodiumServer/PodiumServerApp.swift`. Not released (SwiftUI frozen)
  but on develop → carries into the Tauri sidecar.
- **0.5.1/0.5.2 polish** (now largely moot post-pivot but shipped): Data
  settings rebuilt, dashboard card alignment, toolbar padding, Diagnostics
  "Idle" label, update-popup re-prompt fix, **Kanban removed from nav**.
- **ROADMAP.md rewritten** around the Tauri pivot.

## In flight / just landed

- **T1.1 — Tauri scaffold + sidecar: WORKING** (committed `b49a978`, in
  `tauri/`). The native Tauri window renders the LIVE web dashboard served by
  the podium-server sidecar — **the pivot is validated.** Run it:
  `cd tauri && ./prepare-sidecar.sh && cargo tauri dev` (prepare-sidecar.sh
  builds `swift build -c release --product podium-server` and copies it to
  src-tauri/bin/podium-server-<triple>; the 26MB binary is gitignored). See
  `tauri/README.md` for exact commands.
- **One T1.1 DoD item left to verify:** the no-orphan cleanup — after closing
  the window, `lsof -iTCP:4820 -sTCP:LISTEN` + `pgrep -fl podium-server` must
  be empty (the main.rs only kills the sidecar IF it spawned it, not a reused
  server). Confirm this, then T1.1 is fully done.

## Next up (ROADMAP §9 order)

1. Verify T1.1 orphan cleanup (above).
2. **T1.2** mac `.dmg` + vibrancy (glass), **T1.3** Linux `.AppImage`, **T1.4**
   tray + notifications.
3. **T2.1** update popup + **T2.2** onboarding tour → moved into the web client.
4. **T3.1** Tauri release pipeline → **T2.3** built-in updater → **T3.4** QA
   both platforms → **T3.2** delete SwiftUI target → **T3.3** docs → tag 1.0.0.

## Gotchas (carry forward — still valid)

- **Model tiering matters for cost:** Gaël is token-conscious. Do
  implementation/exploration via **Sonnet agents** (esp. greenfield like the
  Tauri work); keep Opus/Fable for review + root-causing. T1.1 was dispatched
  to Sonnet for exactly this reason.
- **Auto-commit hook** commits the whole dirty tree on any agent save — commit
  file-lists misattribute; real authorship = `git show <sha> -- <file>`. Your
  explicit `git commit` will often say "nothing to commit" because the hook
  already committed — just `git push`.
- **ContractTests is the wire gate** (`swift test --filter ContractTests`, 29
  tests) — keep green after ANY server/model change; the web client (now the
  ONLY UI) depends on exact wire format. snake_case via PodiumJSON; camelCase
  exception families use the AnyEncodable dict pattern; errors are
  CodedErrorResponse; never mix snake_case CodingKeys with .convertFromSnakeCase.
- **`/usr/bin/true` not `/bin/true`** in tests (Darwin 25 removed /bin/true).
- **CI truth policy:** local-green + GH-runner-red ⇒ GITHUB_ACTIONS-gated
  XCTSkip with the mechanism documented; never gate a local failure.
- **podium-server already serves the web UI** (WebClient/dist + API over HTTP)
  — the Tauri window just navigates to localhost; no separate asset bundling.
- **Data paths:** DASHBOARD_DB_PATH > DASHBOARD_DATA_DIR > platform default
  (macOS ~/Library/Application Support/Podium). The 465MB live DB is there.
- **NEVER touch:** ~/.claude/podium/data (old Docker DB, kept as backup),
  Gaël's running app, WebClient/dist except via WebClient/patches + rebuild.
- **Code signing:** no Apple Developer ID ($99 not funded). Mac installs need
  the one-time `xattr -dr com.apple.quarantine <app>` or right-click→Open.
  Tauri's built-in updater doesn't need it; first-install Gatekeeper step is
  unavoidable without notarization.
- **Open bug (debt ledger):** live sessions can show as "Abandoned"/not
  "active" — verify podium-hook reaches the embedded/sidecar server
  post-switchover; sweep-vs-live status logic. Server-side, carries to Tauri.
