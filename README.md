# Podium

Podium observes your Claude Code agent sessions in real time — sessions, agents,
tool events, transcripts, workflows, cost, and the ability to spawn new runs — all
backed by a local SQLite database, in a **native desktop app on macOS and Linux**.

Under the hood it's one React dashboard served by a bundled Node server
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

- installs the Claude Code hook entries into `~/.claude/settings.json` itself,
  pointing at the bun-compiled `podium-hook` binary,
- imports your existing session history on first launch,
- reads/writes a local SQLite database at the platform default
  (macOS `~/Library/Application Support/Podium`, Linux `~/.local/share/podium`).

**Closing the window keeps Podium running in the tray** so it never stops
observing your sessions — reopen from the tray's *Open Podium*, and fully quit
from the tray's *Quit* (which cleanly stops the bundled server). If a server is
already listening on the port (another Podium, or a headless `podium-server`),
the app connects to it instead of double-hosting.

## Architecture

- **`client/`** — the React dashboard source (Vite + TypeScript). Builds to
  `client/dist`, served by the Node server as static files (or staged into
  the Tauri `.app` bundle as `web-dist`).
- **`server/`** — the Node HTTP + WebSocket server (`podium-server`), adapted
  from the upstream `Claude-Code-Agent-Monitor` (see Attribution below). One
  router per resource under `server/routes/`: sessions, agents, events,
  stats, analytics, search, pricing, settings, import, export, push, run,
  workflows, cc-config, updates, hooks, alerts, webhooks. This is what the
  Tauri app bundles as a sidecar, and what runs headless on a Linux server.
- **`hook/`** — `podium-hook`, a tiny zero-dependency binary (bun-compiled
  from TypeScript) Claude Code shells out to on every hook event; it POSTs to
  `/api/hooks/event`.
- **`tauri/`** — the Tauri v2 shell: spawns the sidecar, shows the dashboard
  in a native window with macOS vibrancy, tray + notifications, and packages
  the `.dmg` / `.AppImage` / `.deb`. See [`tauri/README.md`](tauri/README.md).

## Dev

```bash
cd client && npm ci && PODIUM_APP_VERSION=0.0.0-dev npm run build   # build the dashboard
cd server && npm ci && npm test                                    # 568 tests
./run.sh                                                            # sidecar + Tauri app (dev)
cd tauri/src-tauri && cargo check                                    # Rust shell sanity check
cargo tauri build                                                   # release build → .dmg / .app
```

For a headless Linux server (no GUI), see `scripts/build-linux.sh`, which
bun-compiles `podium-server` + `podium-hook` into a tarball (`dist-linux/`).
Linux `.AppImage` / `.deb` GUI installers are produced by CI on `v*` tags —
see [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Attribution

Podium's dashboard and Node server are derived from the MIT-licensed
[Claude-Code-Agent-Monitor](https://github.com/hoangsonww/Claude-Code-Agent-Monitor)
by Son Nguyen. Podium is itself MIT-licensed (see [LICENSE](LICENSE)); the
upstream copyright notice is retained there and in
[`server/LICENSE-upstream`](server/LICENSE-upstream) /
[`server/UPSTREAM.md`](server/UPSTREAM.md), per the MIT license terms.

## Wire-format gate

`server/tests/contract/contract.test.js` (31 tests) locks the wire format of
every REST/WS response against `client/src/lib/types.ts`, so server
regressions surface as test failures rather than silent breakage in the UI.
Keep it green after any server change.
