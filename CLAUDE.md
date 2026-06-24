# PodiumApp — Claude Context

Personal macOS SwiftUI app that wraps the [Podium](~/Desktop/Work/Claude/podium) REST + WebSocket API into a native glassmorphism dashboard for observing Claude Code agent sessions in real time.

## How to run

```bash
./run.sh          # build + wrap in .app bundle + open (recommended)
swift build       # build only
```

`run.sh` is the canonical launch path. It builds the SPM package, assembles a minimal `.app` bundle under `PodiumApp.app/`, writes an `Info.plist`, and calls `open`. The bundle is required because macOS won't show windows for raw Unix executables (`.prohibited` activation policy).

The Podium server must be running first: `/podium start` from the Podium project.

## Project structure

```
PodiumSwiftApp/
├── Package.swift                   # SPM manifest, macOS 14+, single executable target
├── run.sh                          # Build + .app bundle wrapper + open
├── CLAUDE.md                       # This file
└── Sources/PodiumApp/
    ├── PodiumApp.swift             # @main App entry point + AppDelegate
    ├── Models.swift                # All Codable types (Session, Agent, Event, Stats, …)
    ├── PodiumAPI.swift             # Async REST client (actor)
    ├── WebSocketClient.swift       # URLSessionWebSocketTask wrapper with reconnect
    ├── AppState.swift              # @Observable central state, coordinates API + WS
    ├── Theme.swift                 # Colors, formatters, glassBackground() modifier
    ├── Components.swift            # Reusable views (StatusDot, StatCard, MiniBarChart, …)
    ├── ContentView.swift           # NavigationSplitView shell + Sidebar
    ├── DashboardView.swift         # Overview: stat cards + recent sessions + live feed
    ├── SessionsView.swift          # Sessions list with search + status filter
    ├── SessionDetailView.swift     # Session detail: Overview / Agents / Events tabs
    ├── AnalyticsView.swift         # Token usage, daily charts, tool usage, agent types
    └── SettingsView.swift          # Host/port config + connection status
```

## Key decisions & non-obvious constraints

**Activation policy fix** (`PodiumApp.swift`): SPM executables run with `NSApplication.activationPolicy == .prohibited` by default — the window server ignores them. `NSApplication.shared.setActivationPolicy(.regular)` is called in `App.init()` (before the run loop), and `NSApp.activate(ignoringOtherApps: true)` fires in `applicationDidFinishLaunching`. Both are required; removing either breaks launch.

**`@main` + `@NSApplicationDelegateAdaptor`**: The `AppDelegate` class exists solely for the two activation calls above. Don't remove it.

**JSON decoder** (`PodiumAPI.swift`): A shared `JSONDecoder.podium` static instance uses `.convertFromSnakeCase` + a custom ISO 8601 date decoder that handles both fractional-second (`2024-01-01T00:00:00.000Z`) and non-fractional formats. All model properties use camelCase; no custom `CodingKeys` needed.

**`SessionDetailResponse` uses `var`** (`Models.swift`): The fields are `var` (not `let`) so `AppState.updateAgentInCache()` can mutate the cached detail in place when a WS `agent_updated` message arrives.

**WebSocket receive loop** (`WebSocketClient.swift`): `receive()` re-schedules itself inside a `Task { @MainActor in … }` closure to avoid Swift concurrency warnings about calling `@MainActor`-isolated methods from a Sendable closure. The reconnect uses exponential backoff (1s → 2s → 4s … capped at 30s).

**No Charts framework import for tool usage bars** (`Components.swift`): `MiniBarChart` is a plain SwiftUI `GeometryReader`-based bar chart used in session detail. `AnalyticsView.swift` uses `import Charts` (SwiftUI Charts, available macOS 13+) for the richer daily/tool/pie charts.

## Podium API (backend)

Base URL: `http://localhost:4820` (configurable in Settings)
WebSocket: `ws://localhost:4820/ws`

Relevant endpoints used by this app:

| Endpoint | Used in |
|---|---|
| `GET /api/health` | `AppState.refresh()` connectivity check |
| `GET /api/stats` | `DashboardView` stat cards |
| `GET /api/sessions` | `SessionsView` list + search |
| `GET /api/sessions/:id` | `SessionDetailView` header + agents + events |
| `GET /api/sessions/:id/stats` | `SessionDetailView` Overview tab |
| `GET /api/agents` | (available, not used directly in UI yet) |
| `GET /api/analytics` | `AnalyticsView` |
| `GET /api/pricing/cost` | Dashboard total cost card |
| `GET /api/pricing/cost/:id` | Session detail cost breakdown |
| `WS /ws` | Live updates for all views |

WebSocket message shape: `{ "type": string, "data": object, "timestamp": ISO8601 }`

Handled types: `session_created`, `session_updated`, `agent_created`, `agent_updated`, `new_event`, `stats_update`.

## Data flow

```
Podium server (port 4820)
       │
       ├── REST (URLSession async/await) ──▶ PodiumAPI (actor)
       │                                          │
       └── WebSocket (URLSessionWebSocketTask)    │
                  │                               │
                  ▼                               ▼
           WebSocketClient ──────────────▶ AppState (@Observable, @MainActor)
                                                  │
                                    ┌─────────────┼─────────────────┐
                                    ▼             ▼                  ▼
                             DashboardView  SessionsView      AnalyticsView
                                                  │
                                                  ▼
                                         SessionDetailView
                                    (Overview / Agents / Events)
```

`AppState` is injected via SwiftUI's `@Environment` from the root. Views read directly from `@Environment(AppState.self)`. No `@StateObject`/`@ObservableObject` used — everything is Swift 5.9 `@Observable`.

## Glassmorphism design system

- **Background**: `Theme.backgroundGradient` — dark navy-purple linear gradient, applied once at the root and in detail panels.
- **Cards**: `.glassCard()` modifier → `.ultraThinMaterial` fill + 1px gradient border (white 22% → 4%) + `shadow(radius: 20)`.
- **Status colours**: `Theme.color(for:)` → cyan (active/working), emerald (completed), red (error), amber (abandoned), yellow (waiting).
- **Pulse animation**: `StatusDot` — outer ring expands and fades on a 1.6s repeat for active/working states.
- **Typography**: SF Pro via system fonts; no custom fonts imported.

## What's not yet built (possible next additions)

- Transcript viewer (API: `GET /api/sessions/:id/transcript`) — messages JSONL with cursor pagination
- Workflow graph view (API: `GET /api/workflows/session/:id`) — `tree` field gives agent hierarchy + `swimLanes` for timeline
- Menu bar extra (show active agent count / cost in the menu bar without opening the full window)
- Notifications (`UNUserNotificationCenter`) when a session completes or errors
- Session deletion / cleanup actions (API: `POST /api/settings/cleanup`)
- Export button (API: `GET /api/settings/export`)
- Dark/light mode toggle (currently hardcoded dark via `.preferredColorScheme(.dark)`)
- Sidebar can't be collapsed
- Setting page like on the web app.
- The session always refresh, at least quite often, so it's a bit annoying as you don't get the time to read anything as there is the loading spinner always poping in.
