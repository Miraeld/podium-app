# Podium

Podium observes your Claude Code agent sessions in real time — sessions, agents,
tool events, transcripts, workflows, cost, and the ability to spawn new runs — all
backed by a local SQLite database, in a **native desktop app on macOS and Linux**.

Under the hood it's one React dashboard served by a bundled Swift server
(`podium-server`), wrapped in a [Tauri](https://v2.tauri.app) native window. The
app runs the server for you, keeps observing in the background from the tray, and
needs no terminal, no Docker, and no separate "start the server" step.

## Install

### macOS

1. Download `Podium_<version>_aarch64.dmg` from the
   [latest release](https://github.com/Miraeld/podium-app/releases).
2. Open the `.dmg`, drag **Podium** to Applications.
3. First launch only: right-click Podium → **Open** → confirm (or run
   `xattr -dr com.apple.quarantine /Applications/Podium.app` once). Podium isn't
   notarized with an Apple Developer ID yet, so macOS Gatekeeper asks the first
   time — this is a one-time step per machine.

Open it and your agents appear live.

### Linux

Download from the [latest release](https://github.com/Miraeld/podium-app/releases):

- **AppImage** (portable): `chmod +x Podium_<version>_<arch>.AppImage && ./Podium_<version>_<arch>.AppImage`
- **Debian/Ubuntu**: `sudo dpkg -i Podium_<version>_<arch>.deb`

Same app, same experience as macOS — a real window, not a browser tab.

## How it works

On launch Podium spawns `podium-server` (bundled as a Tauri sidecar), waits for
it to answer `/api/health`, then shows the dashboard in the window. The server:

- installs the Claude Code hook entries into `~/.claude/settings.json` itself
  (native `podium-hook` binary — no Node, no `hook.mjs`),
- imports your existing session history on first launch,
- reads/writes a local SQLite database at the platform default
  (macOS `~/Library/Application Support/Podium`, Linux `~/.local/share/podium`).

**Closing the window keeps Podium running in the tray** so it never stops
observing your sessions — reopen from the tray's *Open Podium*, and fully quit
from the tray's *Quit* (which cleanly stops the bundled server). If a server is
already listening on the port (another Podium, or a headless `podium-server`),
the app connects to it instead of double-hosting.

## Architecture

- **`PodiumCore`** — models, SQLite store, hook ingestion, transcripts, pricing,
  discovery, run-spawning, web push. Cross-platform, no Apple-only APIs.
- **`PodiumServer`** — Hummingbird 2 HTTP + WebSocket server; one router per
  resource under `Sources/PodiumServer/Routes/`.
- **`podium-server`** (`Sources/PodiumServerCLI`) — the server as a standalone
  binary; serves the vendored React client (`WebClient/dist`) as static files
  and the REST + WS API. This is what the Tauri app bundles as a sidecar, and
  what runs headless on a Linux server.
- **`podium-hook`** (`Sources/PodiumHook`) — a tiny native binary Claude Code
  shells out to on every hook event; it POSTs to `/api/hooks/event`.
- **`tauri/`** — the Tauri v2 shell: spawns the sidecar, shows the dashboard in
  a native window with macOS vibrancy, tray + notifications, and packages the
  `.dmg` / `.AppImage` / `.deb`. See [`tauri/README.md`](tauri/README.md).
- **`WebClient/dist`** — vendored build of the React dashboard (source lives in
  a separate repo; see [`WebClient/SYNC.md`](WebClient/SYNC.md)).

## Dev

```bash
swift build                      # build the libraries + podium-server + podium-hook
swift test                       # PodiumCoreTests + PodiumServerTests (465 tests)
./run.sh                         # build the sidecar + launch the Tauri app (dev)
cd tauri && cargo tauri build    # release build → .dmg / .app (macOS)
```

For Linux installers (`.AppImage` / `.deb`), see
[`tauri/linux-build/README.md`](tauri/linux-build/README.md) (built in a
`swift:6.1`-based container). Release installers are produced by CI on `v*`
tags — see [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Wire-format gate

`Tests/PodiumServerTests/ContractTests.swift` (29 tests) locks the wire format
of every REST/WS response against the vendored React client's `types.ts`, so
server regressions surface as test failures rather than silent breakage in the
UI. Keep it green after any server change.
