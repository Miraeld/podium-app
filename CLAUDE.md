# Podium — Claude Context

Standalone (no plugin, no Docker) macOS app + Linux daemon that observes Claude
Code agent sessions in real time. Node server + local SQLite database, serving
the React dashboard (`client/`, built to `client/dist`) over HTTP from the
same server on both platforms. Packaged as a native app by Tauri (`tauri/`),
which spawns the server as a sidecar.

## How to run / build / test

```bash
./run.sh                                        # prepare-sidecar.sh + cargo tauri dev (recommended)
cd client && npm ci && PODIUM_APP_VERSION=0.0.0-dev npm run build   # build the React dashboard
cd server && npm ci && npm test                 # 568 node:test tests, incl. server/tests/contract/
cd tauri/src-tauri && cargo check                # Rust shell sanity check
cargo tauri build                                # release packaging (.dmg / .AppImage / .deb)
scripts/build-linux.sh                          # headless Linux release → dist-linux tarball
```

`run.sh` builds the `podium-server` + `podium-hook` sidecars
(`tauri/prepare-sidecar.sh`, bun-compiled) and stages `client/dist`, then runs
the Tauri app in dev mode (`cargo tauri dev`) — see `tauri/README.md` for the
full lifecycle and prerequisites.

## Project structure

```
podium-app/ (repo dir currently PodiumSwiftApp — rename pending)
├── client/                # React dashboard source (Vite + TS). Builds to client/dist,
│                           #   which the server serves as static files (or Tauri stages
│                           #   into the .app bundle as web-dist).
├── server/                # Node HTTP + WebSocket server (Express-based, from
│                           #   hoangsonww/Claude-Code-Agent-Monitor upstream, adapted)
│   ├── index.js            #   entrypoint; parses --port/--data-dir/--web-dist sidecar flags
│   ├── db.js                #   SQLite access (better-sqlite3 → bun:sqlite → node:sqlite)
│   ├── routes/              #   one router per resource: sessions, agents, events, stats,
│   │                        #   analytics, search, pricing, settings, import, export, push,
│   │                        #   run, workflows, cc-config, updates, hooks, alerts, webhooks
│   ├── lib/                  #   claude-home, cc-discovery/mutate/watcher, error-envelope,
│   │                        #   push (VAPID), pricing, run-spawner, server-info, update-check,
│   │                        #   session-transfer, transcript-cache, token-usage
│   ├── scripts/              #   install-hooks.js (writes ~/.claude/settings.json hook entries)
│   └── tests/contract/        #   contract.test.js — wire-format gate (asserts against
│                              #   client/src/lib/types.ts)
├── hook/                  # podium-hook: zero-dep TS, bun-compiles to a single binary.
│                           #   stdin JSON → 8-event gate → POST to discovered server port.
├── tauri/                 # Tauri v2 shell — native app wrapping podium-server as a sidecar
│   ├── prepare-sidecar.sh  #   bun-compiles server + hook, stages client/dist as web-dist
│   └── src-tauri/           #   Rust (main.rs spawns/health-polls the sidecar, tray, notifications)
└── run.sh, scripts/       # dev launcher (Tauri) + packaging (build-linux.sh,
                            #   install-linux.sh, podium-server.service, contract-check.sh)
```

## Key decisions & non-obvious constraints

**P8 — mandatory version env var at client build:** `PODIUM_APP_VERSION` MUST
be set when running `npm run build` in `client/`; the build FAILS if it's
unset. Never weaken this guard — it exists so a shipped dashboard can never
silently claim the wrong version. Verify with an unset-var build (expect
failure) whenever touching the build config.

**Auto-commit hook fires on saves in this repo.** Its commits are automatic
and separate from anything you're doing — ignore them, never `git commit
--amend` or rebase to "clean them up".

**Frozen old plugin repo:** `~/Desktop/Work/Claude/podium` is the pre-pivot
source of the client and is FROZEN — read-only reference only. Never run git
commands there, never edit it, never sync anything back into it.

**Wire-contract gate:** `server/tests/contract/contract.test.js` (31 tests,
ported 1:1 from the old Swift `ContractTests.swift`) boots the real
`server/index.js` as a child process, seeds it via `POST /api/hooks/event`,
and asserts every GET endpoint's raw JSON shape against
`client/src/lib/types.ts` — snake_case keys, and the deliberate camelCase
exception families (Workflows, cc-config, Run "live" handle family) asserted
the other way. `client/src/lib/types.ts` is the spec; any router change
should keep this suite green.

**P1 — loopback default:** the server binds `127.0.0.1` by default;
`--host`/`PODIUM_HOST` is opt-in only, with a stderr warning on any
non-loopback bind. This is a security fix from the pre-1.0 audit — never
regress it for convenience.

**Server auto-installs hooks on every boot, keyed off `$HOME`:**
`server/scripts/install-hooks.js` runs on every `server/index.js` boot and
writes/upgrades hook entries into `~/.claude/settings.json` (atomic write +
`.bak` backup). Any scratch/test boot of the server MUST override `HOME` (and
usually `DASHBOARD_DATA_DIR`) to a throwaway directory, or it will rewrite the
owner's real `~/.claude/settings.json`. `CLAUDE_HOME` is a separate override
for the `.claude` directory root itself (`server/lib/claude-home.js`).

**`bun:sqlite` is the primary SQLite driver in compiled binaries.**
`better-sqlite3` has no working prebuilt/source build on Node 26 arm64 in
this environment, and bun 1.3.x has no `node:sqlite`, so `db.js`'s driver
chain (better-sqlite3 → bun:sqlite → node:sqlite) resolves to `bun:sqlite` in
practice for `bun build --compile` sidecars. See `server/compat-bunsqlite.js`.

**`BUN_NO_CODESIGN_MACHO_BINARY=1`** is required on both bun compile
invocations in `tauri/prepare-sidecar.sh` on macOS — bun 1.3.14's Mach-O
self-signing is broken (truncated code signature) and corrupts the binary
before Tauri's own codesign pass runs.

**`/usr/bin/true`, not `/bin/true`**, for test process spawns: modern macOS
(Darwin 25+) has no `/bin/true`; `/usr/bin/true` exists on both macOS and
Linux (usr-merged). Referenced in `server/tests/contract/contract.test.js`
and other node:test files that spawn placeholder child processes.

**CI truth policy:** tests that pass locally but fail on GitHub-hosted
runners due to runner-environment behavior (not a real bug) are skipped with
a documented reason under `GITHUB_ACTIONS`, never deleted, never skipped
unconditionally, never skipped if they also fail locally.

**Never block in `Task`/`Task.detached`-equivalent async patterns** on a
small CI runner (the historical Swift-era cooperative-pool deadlock lesson —
carries over conceptually: don't synchronously wait on a child process from
inside code that shares a small fixed-size worker pool).

**Data paths:** `DASHBOARD_DB_PATH` > `DASHBOARD_DATA_DIR` > platform default
(`~/Library/Application Support/Podium` on macOS, `$XDG_DATA_HOME/podium` or
`~/.local/share/podium` on Linux).

## Historical (Swift era, removed N7 — 2026-07-15)

Podium originally shipped as a Swift server (Hummingbird 2) + SwiftUI macOS
app. It was fully removed in favor of a Node server + Tauri shell (the N1-N7
migration, tracked in the now-removed internal roadmap; rationale and history
live in git log). Swift-
specific footguns (CodingKeys/snake_case decoding traps, Hummingbird's
`JSONResponse(fields:)` encoder workaround) no longer apply; they're
preserved only in git history if ever needed for archaeology.

## What's not yet built

- P6.2a: full browser walk of every page against the Node server (contract
  tests cover the wire format; a manual/automated UI pass is still pending).
- Async reimport with progress (cold-cache first import is CPU-bound
  seconds-per-hundred-files today).
- Answer-from-popup write-back for external terminal sessions (Podium-spawned
  runs support it via stdin; external sessions get notification + jump-to-
  terminal only).
