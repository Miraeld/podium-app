# Podium

Podium observes your Claude Code agent sessions in real time — sessions, agents,
tool events, transcripts, workflows, cost, and the ability to spawn new runs — all
backed by a local SQLite database. On macOS it's a native app; on Linux it's a
lightweight daemon. Both serve the same React dashboard from `http://localhost:4820`.

## macOS

Download `dist/Podium-1.0.dmg`, drag Podium to Applications, open it. That's it.

Podium embeds its own server, installs the Claude Code hook entries into
`~/.claude/settings.json` itself, and imports your existing session history on
first launch. No terminal, no config file, no separate "start the server" step.
If another Podium instance (or the legacy Docker dashboard) is already listening
on the configured port, the app connects to it as a client instead of double-hosting.

## Linux

```bash
tar xzf podium-linux-<version>.tar.gz
cd podium-linux-<version>
./install-linux.sh
```

This installs `podium-server` + `podium-hook` to `/usr/local/bin`, the web
dashboard to `/usr/local/share/podium/web`, and a systemd `--user` unit
(`podium-server.service`) that starts on install and auto-installs the hooks on
first run. Dashboard at `http://localhost:4820`. Run
`loginctl enable-linger $USER` once if you want it to survive logout.

Build the tarball yourself with `scripts/build-linux.sh` (uses a `swift:6.1`
Docker container by default; `--host` to build with a local Linux toolchain).

## Migrating from the plugin-era dashboard

Already running the Node/Docker Podium plugin? Your existing `dashboard.db` just
works — copy it into place and launch the app. See `MIGRATION.md` for the
step-by-step switchover.

## Architecture

- `PodiumCore` — models, SQLite store, hook ingestion, transcripts, pricing,
  discovery, run-spawning, web push. Cross-platform, no Apple-only APIs.
- `PodiumServer` — Hummingbird 2 HTTP + WebSocket server; all routes live under
  `Sources/PodiumServer/Routes/`.
- The server serves the vendored React client (`WebClient/dist`) as static
  files, and exposes the same REST + WS API to both the web dashboard and the
  native macOS app.
- `podium-hook` is a small native binary Claude Code shells out to on every
  hook event; it POSTs to `/api/hooks/event` on the running server.
- `PodiumApp` (macOS only) embeds `PodiumServer` in-process and wraps the same
  API in a native SwiftUI dashboard.

## Dev

```bash
swift build                      # build everything
swift test                       # run PodiumCoreTests + PodiumServerTests
./run.sh                         # build + launch the native macOS app
scripts/package-macos.sh         # release build → .app + DMG under dist/
scripts/build-linux.sh           # release build → tarball under dist-linux/
```

## Verified compatibility

<!-- P6.2a browser walk pending — do not claim full web-parity until it lands -->

`Tests/PodiumServerTests/ContractTests.swift` (29 tests) locks the wire format
of every REST/WS response against the vendored React client's `types.ts`, so
regressions in the Swift server surface as test failures rather than silent
breakage in the browser.
