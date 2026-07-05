# Podium — Claude Context

Standalone (no plugin, no Docker) macOS app + Linux daemon that observes Claude
Code agent sessions in real time. Backed by a local SQLite database, serving a
vendored React dashboard (`WebClient/dist`) over HTTP from the same Swift
server on both platforms.

## How to run / build / test

```bash
./run.sh                    # build + wrap in .app bundle + open (macOS, recommended)
swift build                 # build all products
swift test                  # run PodiumCoreTests + PodiumServerTests
scripts/package-macos.sh    # release build → dist/PodiumApp.app + Podium-<ver>.dmg
scripts/build-linux.sh      # release build → dist-linux tarball (swift:6.1 docker by default)
```

`run.sh` builds `PodiumApp` and `podium-hook`, assembles a minimal `.app`
bundle, writes `Info.plist`, and opens it. The bundle is required because SPM
executables run with `.prohibited` activation policy — macOS won't show
windows otherwise.

## Project structure

```
PodiumSwiftApp/
├── Package.swift                    # SPM manifest: PodiumCore, PodiumServer (libraries);
│                                     #   podium-server, podium-hook, PodiumApp (executables)
├── run.sh, scripts/                 # dev launcher + packaging (package-macos.sh, build-linux.sh,
│                                     #   install-linux.sh, podium-server.service)
├── WebClient/dist                   # vendored React build, served as static files
├── Sources/
│   ├── CSQLite/                     # system library wrapping libsqlite3
│   ├── PodiumCore/                  # cross-platform: models, store, ingestion, discovery,
│   │   ├── Database/                #   runs, push. No UI, no Apple-only APIs.
│   │   ├── Models/                  #   PodiumJSON.swift, model types
│   │   ├── Ingest/                  #   hook event state machine
│   │   ├── Transcripts/             #   JSONL parsing + cursor pagination
│   │   ├── Discovery/               #   server-info file, cc-config, hook port discovery
│   │   ├── Workflows/                #   agent tree / swim-lane aggregation
│   │   ├── Runs/                    #   RunSpawner (spawns claude processes)
│   │   ├── Push/                    #   VAPID + RFC 8291 web push
│   │   ├── Hooks/                   #   HookInstaller, HookClient
│   │   ├── Pricing/                 #   cost calculation
│   │   └── Diagnostics/             #   log ring buffer, runtime info
│   ├── PodiumServer/                 # Hummingbird 2 HTTP + WebSocket server
│   │   ├── Routes/                  #   one router per resource (see below)
│   │   ├── WebSocket/                #   Broadcaster actor
│   │   ├── Static/                  #   hand-rolled static file handler
│   │   └── Services/                #   background services (import, sweep, watchdog)
│   ├── PodiumServerCLI/main.swift   # podium-server executable (headless daemon)
│   ├── PodiumHook/main.swift        # podium-hook executable (native hook.mjs replacement)
│   └── PodiumApp/                   # native SwiftUI macOS app (40 files) — embeds
│                                     #   PodiumServer in-process via EmbeddedServer.swift
└── Tests/
    ├── PodiumCoreTests/
    └── PodiumServerTests/           # includes ContractTests.swift — wire-format gate
```

## Key decisions & non-obvious constraints

**Activation policy fix** (`Sources/PodiumApp/PodiumApp.swift`): SPM
executables run with `.prohibited` activation policy — the window server
ignores them. `NSApplication.shared.setActivationPolicy(.regular)` is called
in `App.init()`, and `NSApp.activate(ignoringOtherApps: true)` fires in
`applicationDidFinishLaunching`. Both are required; removing either breaks
launch. The `AppDelegate` + `@NSApplicationDelegateAdaptor` exist solely for
these two calls plus `applicationWillTerminate` (graceful embedded-server
shutdown) — don't remove it.

**PodiumJSON** (`Sources/PodiumCore/Models/PodiumJSON.swift`): shared
snake_case encoder/decoder for wire parity with the old Node dashboard.
Timestamps are stored as plain `String` (not `Date`) so decode → encode
round-trips exactly, with `PodiumDate` helpers on top.

**Never mix explicit snake_case `CodingKeys` with `.convertFromSnakeCase`** —
it silently decodes fields to `nil`. Documented as a footgun in
`PodiumJSON.swift`; bit the project once already (P1.2).

**`JSONResponse(fields:)`**: Hummingbird 2's default encoder is plain camelCase
with no snake_case hook, and `KeyEncodingStrategy.convertToSnakeCase` cannot be
bypassed per-key even with `CodingKeys` (it re-transforms the resolved key
string). Route handlers needing intentionally-camelCase top-level keys (e.g.
`WorkflowsRouter`, the run live-handle family) use `JSONResponse(fields:)`,
which encodes each sub-object independently via `PodiumJSON.encoder` and
splices the result under literal camelCase keys.

**`PodiumJSON.AnyEncodable`**: for structs where individual *fields* (not just
top-level keys) must stay camelCase on the wire (cc-config responses), a
custom `Encodable` builds a `[String: AnyEncodable]` — dictionary keys bypass
`keyEncodingStrategy` at any nesting depth.

**Error envelope**: all error responses are `CodedErrorResponse`
(`{"error":{"code","message"}}`), not a flat `{"error":"…"}`. Route handlers
should return this shape, never a bare string.

**`ContractTests.swift`** (`Tests/PodiumServerTests/ContractTests.swift`, 29
tests): boots a real `podium-server`, seeds it via `/api/hooks/event`, and
asserts every GET endpoint's shape against the vendored client's `types.ts`.
This is the wire-format regression gate — any router change should keep it
green.

**`/usr/bin/true`, not `/bin/true`**, for test process spawns: modern macOS
(Darwin 25+) has no `/bin/true`; `/usr/bin/true` exists on both macOS and
Linux (usr-merged). See `ContractTests.swift` around line 150.

**CI truth policy**: tests that pass locally (macOS + local Linux docker)
but fail on GitHub-hosted runners due to runner-environment behavior are
gated with `XCTSkip` under `GITHUB_ACTIONS` + a comment naming the observed
runner behavior. Never delete such a test, never skip unconditionally, never
gate a test that also fails locally. Gated set: DiagnosticsRouterTests +
ContractTests health-wait (Linux container networking), HookClientTests
dead-port latency (both OSes). Never block in `Task`/`Task.detached`
(`waitUntilExit`, sync waits) — the cooperative pool's width is the CPU
count and small CI runners deadlock; use `Thread.detachNewThread` (see
`RunSpawner.swift`).

**Data paths** (`Sources/PodiumCore/Database/PodiumPaths.swift`):
`DASHBOARD_DB_PATH` > `DASHBOARD_DATA_DIR` > platform default
(`~/Library/Application Support/Podium` on macOS, `$XDG_DATA_HOME/podium` or
`~/.local/share/podium` on Linux).

**Hook install**: `HookInstaller` (`Sources/PodiumCore/Hooks/`) upgrades
legacy plugin-era hook entries in `~/.claude/settings.json` in place and
installs the native `podium-hook` binary path — see the file's header comment
for the exact legacy markers it detects and removes.

**Server API surface**: the server is now in this repo — see
`Sources/PodiumServer/Routes/` for the authoritative list of endpoints (one
router file per resource: Sessions, Agents, Events, Stats, Analytics, Search,
Pricing, Settings, Import, Export, Push, Run, Workflows, CcConfig, Updates,
Diagnostics, Hooks).

## What's not yet built

- P6.2a: full browser walk of every page against the Swift server (contract
  tests cover the wire format; a manual/automated UI pass is still pending).
- Async reimport with progress (cold-cache first import is CPU-bound
  seconds-per-hundred-files today).
- Answer-from-popup write-back for external terminal sessions (Podium-spawned
  runs support it via stdin; external sessions get notification + jump-to-
  terminal only).
