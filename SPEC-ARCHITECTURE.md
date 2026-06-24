# PodiumSwiftApp — Architecture Spec

## File Structure (target state)

```
Sources/PodiumApp/
│
├── App/
│   ├── PodiumApp.swift          (existing — add MenuBarExtra)
│   └── AppDelegate.swift        (existing — keep NSApplicationDelegate)
│
├── State/
│   ├── AppState.swift           (existing — extend with new data slices)
│   └── RunState.swift           (new — manages active runs list + streaming)
│
├── API/
│   ├── PodiumAPI.swift          (existing — add new methods per SPEC-API.md)
│   ├── WebSocketClient.swift    (existing — add run_event + notification types)
│   └── PodiumError.swift        (new — extract error enum from PodiumAPI)
│
├── Models/
│   └── Models.swift             (existing — add new structs per SPEC-API.md)
│
├── Views/
│   ├── ContentView.swift        (existing — extend NavDestination, add new sidebar sections)
│   │
│   ├── Dashboard/
│   │   └── DashboardView.swift  (existing)
│   │
│   ├── Sessions/
│   │   ├── SessionsView.swift      (existing)
│   │   └── SessionDetailView.swift (existing — add Conversation + Cost tabs)
│   │
│   ├── ActivityFeed/
│   │   └── ActivityFeedView.swift  (new)
│   │
│   ├── Workflows/
│   │   ├── WorkflowsView.swift     (new — session picker + detail tabs)
│   │   ├── WorkflowDAGView.swift   (new — Canvas-based DAG renderer)
│   │   ├── WorkflowTimelineView.swift (new — Gantt bars)
│   │   └── WorkflowMetricsView.swift  (new — stat cards)
│   │
│   ├── Kanban/
│   │   └── KanbanView.swift        (new)
│   │
│   ├── Run/
│   │   ├── RunView.swift           (new — split: list + detail)
│   │   └── RunOutputView.swift     (new — streaming event renderer)
│   │
│   ├── Analytics/
│   │   └── AnalyticsView.swift     (existing)
│   │
│   ├── Settings/
│   │   └── SettingsView.swift      (existing — add tabbed sections)
│   │
│   ├── CCConfig/
│   │   ├── CCConfigView.swift      (new — master-detail)
│   │   └── CCConfigDetailView.swift (new — per-category list)
│   │
│   ├── Search/
│   │   └── SearchPanel.swift       (new — floating NSPanel / SwiftUI window)
│   │
│   ├── MenuBar/
│   │   └── MenuBarContent.swift    (new — popover content)
│   │
│   └── Import/
│       └── ImportView.swift        (new — drag-drop + file picker)
│
├── Components/
│   ├── Components.swift            (existing — refactor glass modifier)
│   └── WorkflowCanvas.swift        (new — Canvas drawing helpers)
│
└── Theme/
    └── Theme.swift                 (existing — migrate to .glassEffect())
```

---

## Navigation Graph

```
NavDestination enum:
  .dashboard        (⌘1)
  .sessions         (⌘2)
  .analytics        (⌘3)
  .activityFeed     (⌘4)   ← new
  .workflows        (⌘5)   ← new
  .kanban           (⌘6)   ← new
  .run              (⌘7)   ← new
  .ccConfig                ← new (Configure section)
  .importSessions          ← new (File menu / Settings)
  .settings                (⌘,)

Sidebar sections:
  "Observe":
    Dashboard, Sessions, Analytics, Activity Feed, Workflows, Kanban, Run
  "Configure":   ← new section
    CC Config
  "Settings" (bottom pinned, existing pattern):
    Settings footer area
```

---

## AppState Extensions

Add these `@Published`-equivalent properties to `AppState`:

```swift
// Activity Feed
var eventsPage: EventsPage? = nil
var isLoadingMoreEvents = false

// Workflows
var workflowData: [String: WorkflowData] = [:]   // keyed by sessionId

// Run
var activeRuns: [RunSession] = []

// CC Config
var ccConfig: CCConfig? = nil

// System Info
var systemInfo: SystemInfo? = nil

// Pricing
var pricingRules: [PricingRule] = []
```

The `RunState` actor handles the streaming buffer for the active run separately (not in `AppState`) to avoid re-rendering the entire view tree on every streamed token.

---

## RunState (new)

```swift
@Observable
final class RunState {
    var runs: [String: [RunEvent]] = [:]   // runId → events buffer

    func append(_ event: RunEvent) {
        runs[event.runId, default: []].append(event)
    }

    func clear(runId: String) {
        runs.removeValue(forKey: runId)
    }
}
```

`RunState` is injected via `.environment(RunState())` in `PodiumApp.swift`, separately from `AppState`.

---

## WebSocket Changes

Extend `handleWebSocketMessage` in `AppState`:

```swift
case "run_event":
    if let runId = msg["runId"] as? String,
       let eventData = msg["event"],
       let event = decode(RunEvent.self, from: eventData) {
        runState.append(event)
    }

case "notification":
    if let title = msg["title"] as? String,
       let body = msg["body"] as? String {
        sendLocalNotification(title: title, body: body)
    }
```

---

## Notification Setup

In `PodiumApp.swift`, on launch:

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
    // store granted state in UserDefaults
}
```

`sendLocalNotification()` helper in `AppState`:

```swift
func sendLocalNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
}
```

---

## MenuBarExtra Setup

In `PodiumApp.swift`:

```swift
@main
struct PodiumApp: App {
    @State var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .environment(appState)

        MenuBarExtra("Podium", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarContent()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

`MenuBarContent` reads `appState` and displays the mini stats popover from SPEC-FEATURES.md §8.

---

## Liquid Glass Migration Checklist

When migrating `Theme.swift` and `Components.swift`:

- [ ] Replace `GlassCardModifier` body with `.glassEffect()` + availability check
- [ ] Replace `glassBackground()` function with a `@ViewBuilder` wrapper
- [ ] Add `#available(macOS 26, *)` guards; fallback to current implementation
- [ ] Test with both light and dark system appearance
- [ ] Test with all system accent colors (macOS lets users pick their accent)
- [ ] Remove manual `.shadow()` calls — Liquid Glass handles its own shadow
- [ ] Remove manual `strokeBorder` gradient — Liquid Glass handles specular highlight

```swift
// New glassCard() extension
extension View {
    func glassCard(radius: CGFloat = Theme.cornerRadius) -> some View {
        Group {
            if #available(macOS 26, *) {
                self.glassEffect(in: .rect(cornerRadius: radius))
            } else {
                // existing fallback
                modifier(GlassCardModifier(radius: radius))
            }
        }
    }
}
```

---

## Minimum Deployment Target

Set to **macOS 15.0** in `Package.swift` (current), but add `@available(macOS 26, *)` guards around Liquid Glass API calls so the app still builds and runs on 15.x with the material fallback.

When macOS 26 is released and 15.x share drops enough, bump the target to 26.0 and remove all fallback branches.
