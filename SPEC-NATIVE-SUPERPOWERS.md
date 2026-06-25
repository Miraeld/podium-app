# PodiumSwiftApp — Native macOS Superpowers Spec

Covers: WidgetKit, App Intents / Siri, CoreSpotlight indexing.

---

## Prerequisites: Xcode Project Migration

All three features require entitlements and extension targets that are **impossible in a bare `Package.swift` executable**. Before implementing any of this:

1. Create a new Xcode project (`File → New → Project → macOS App`) named `Podium`
2. Set bundle ID: `com.wpMedia.podium` (adjust to match your provisioning)
3. Add an **App Group** entitlement: `group.com.wpMedia.podium` (needed for widget data sharing)
4. Move all `Sources/PodiumApp/*.swift` files into the Xcode app target
5. Keep `Package.swift` only for local development builds if desired, but Xcode is the primary build system going forward
6. Minimum deployment target: **macOS 26.0** (already the Package.swift target)

---

## 1. WidgetKit Widget

### Overview

A WidgetKit extension that displays live Podium stats in the macOS desktop, Notification Center, or Spotlight. Refreshes every 5 minutes via timeline, and is force-refreshed by the main app on any WebSocket event that changes stats.

### Xcode Target Setup

Add a new target: `File → New → Target → Widget Extension`
- Product name: `PodiumWidget`
- Bundle ID: `com.wpMedia.podium.widget`
- Check "Include Configuration Intent": NO (we use static configuration)
- Add to App Group: `group.com.wpMedia.podium`

### Data Sharing — App → Widget

The widget cannot import `AppState` (different process). Use a shared `UserDefaults` suite backed by the App Group.

**Shared data helper** (new file `Shared/WidgetData.swift`, included in BOTH the app target and widget target):

```swift
struct WidgetSnapshot: Codable {
    let activeSessions: Int
    let activeAgents: Int
    let totalCostToday: Double
    let forecastedMonthlyCost: Double      // see SPEC-MONITORING.md
    let recentSessions: [WidgetSession]
    let updatedAt: Date

    struct WidgetSession: Codable, Identifiable {
        let id: String
        let name: String
        let status: String   // raw string, no import of Session type
        let cost: Double?
    }
}

enum WidgetStore {
    private static let defaults = UserDefaults(suiteName: "group.com.wpMedia.podium")!
    private static let key = "widgetSnapshot"

    static func save(_ snapshot: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
        WidgetCenter.shared.reloadAllTimelines()   // force widget refresh
    }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
```

**Write from AppState** — call `WidgetStore.save(snapshot)` in `AppState.refresh()` and in `handleWSMessage` whenever `stats_update` or `session_updated` fires.

### Widget Implementation

```swift
// PodiumWidget/PodiumWidget.swift

import WidgetKit
import SwiftUI

struct PodiumEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct PodiumProvider: TimelineProvider {
    func placeholder(in context: Context) -> PodiumEntry {
        PodiumEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PodiumEntry) -> Void) {
        completion(PodiumEntry(date: .now, snapshot: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PodiumEntry>) -> Void) {
        let entry = PodiumEntry(date: .now, snapshot: WidgetStore.load())
        // Refresh every 5 minutes as fallback; main app triggers early via WidgetCenter
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

@main
struct PodiumWidgetBundle: WidgetBundle {
    var body: some Widget {
        PodiumStatsWidget()
    }
}

struct PodiumStatsWidget: Widget {
    let kind = "PodiumStats"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PodiumProvider()) { entry in
            PodiumWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Podium")
        .description("Live Claude Code session stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
```

### Widget Views

#### Small (systemSmall) — cost + active count

```
┌──────────────────┐
│  ⬡ Podium        │
│                  │
│  3               │
│  active sessions │
│                  │
│  $1.24 today     │
└──────────────────┘
```

```swift
struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(snapshot.activeSessions)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("active sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatCost(snapshot.totalCostToday) + " today")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
```

#### Medium (systemMedium) — stats + last 3 sessions

```
┌─────────────────────────────────────────┐
│  ⬡ Podium        3 active · $1.24 today │
│  ─────────────────────────────────────  │
│  ● imagify-plugin     working    $0.45  │
│  ● wp-rocket          completed  $0.32  │
│  ○ backwpup-pro       error      $0.18  │
└─────────────────────────────────────────┘
```

#### Large (systemLarge) — full mini dashboard

Adds: agent count, events today, 7-day forecast, last 6 sessions.

### Deep Link on Widget Tap

Add a `widgetURL` modifier so tapping a session row opens the app at that session:

```swift
// On each session row in medium/large widget:
Link(destination: URL(string: "podium://session/\(session.id)")!) {
    SessionRowView(session: session)
}

// On the widget itself (small):
.widgetURL(URL(string: "podium://dashboard"))
```

Handle in the main app's `PodiumApp.swift`:

```swift
.onOpenURL { url in
    guard url.scheme == "podium" else { return }
    if url.host == "session", let id = url.pathComponents.last {
        appState.selectedSessionId = id
    }
}
```

---

## 2. App Intents / Siri

### Framework

`import AppIntents` — available macOS 13+, matches our target.

All intent structs go in a new file: `Sources/PodiumApp/Intents/PodiumIntents.swift`.

### Shared NetworkClient for Intents

Intents run in a sandboxed context, potentially out-of-process. They cannot access `AppState` (which is a `@MainActor` singleton). They need their own lightweight API call.

Create `Shared/IntentAPIClient.swift` (included in both app and any future intents extension):

```swift
struct IntentAPIClient {
    // Reads server config from shared UserDefaults (App Group)
    private static var baseURL: URL {
        let defaults = UserDefaults(suiteName: "group.com.wpMedia.podium")!
        let host = defaults.string(forKey: "podium_host") ?? "localhost"
        let port = defaults.integer(forKey: "podium_port") == 0 ? 4820 : defaults.integer(forKey: "podium_port")
        return URL(string: "http://\(host):\(port)")!
    }

    static func stats() async throws -> Stats {
        let url = baseURL.appending(path: "/api/stats")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder.podium.decode(Stats.self, from: data)
    }

    static func totalCost() async throws -> CostResult {
        let url = baseURL.appending(path: "/api/pricing/cost")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder.podium.decode(CostResult.self, from: data)
    }

    static func sessions(status: String? = nil, limit: Int = 5) async throws -> [Session] {
        var comps = URLComponents(url: baseURL.appending(path: "/api/sessions"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [.init(name: "limit", value: "\(limit)")]
        if let s = status { items.append(.init(name: "status", value: s)) }
        comps.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder.podium.decode(SessionsResponse.self, from: data).sessions
    }
}
```

### Intent 1: Get Today's Cost

```swift
struct GetTodayCostIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Claude Cost"
    static var description = IntentDescription("Returns the total Claude Code spend for today.")

    // Siri phrase: "What did I spend on Claude today?"
    static var parameterSummary: some ParameterSummary { Summary("Get today's Claude Code cost") }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let cost = try await IntentAPIClient.totalCost()
        // Sum today's cost from dailyCosts
        let today = ISO8601DateFormatter.shortDate(Date())
        let todayCost = cost.dailyCosts.first(where: { $0.date == today })?.cost ?? 0
        let formatted = todayCost < 0.01
            ? String(format: "$%.4f", todayCost)
            : String(format: "$%.2f", todayCost)
        return .result(value: formatted, dialog: "You've spent \(formatted) on Claude Code today.")
    }
}
```

### Intent 2: Get Active Sessions

```swift
struct GetActiveSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Active Claude Sessions"
    static var description = IntentDescription("Returns the number of active Claude Code sessions.")

    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let stats = try await IntentAPIClient.stats()
        let n = stats.activeSessions
        let word = n == 1 ? "session" : "sessions"
        return .result(
            value: n,
            dialog: "\(n) active Claude Code \(word) right now."
        )
    }
}
```

### Intent 3: List Recent Sessions

```swift
struct ListRecentSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Recent Claude Sessions"

    @Parameter(title: "Limit", default: 5, inclusiveRange: (1, 10))
    var limit: Int

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let sessions = try await IntentAPIClient.sessions(limit: limit)
        let lines = sessions.map { s in
            let name = s.name ?? URL(fileURLWithPath: s.cwd ?? "").lastPathComponent
            return "\(name) — \(s.status.rawValue)"
        }
        let result = lines.joined(separator: "\n")
        return .result(value: result, dialog: "Here are your last \(sessions.count) Claude Code sessions.")
    }
}
```

### Intent 4: Open Session in Podium

```swift
struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Session in Podium"
    static var openAppWhenRun = true   // brings app to foreground

    @Parameter(title: "Session ID")
    var sessionId: String

    func perform() async throws -> some IntentResult {
        // The app handles podium://session/{id} deep link
        await NSWorkspace.shared.open(URL(string: "podium://session/\(sessionId)")!)
        return .result()
    }
}
```

### App Shortcuts (Siri phrases)

Register concrete Siri phrases in an `AppShortcutsProvider`:

```swift
struct PodiumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTodayCostIntent(),
            phrases: [
                "What did I spend on Claude today",
                "How much have I spent on \(.applicationName)",
                "Show me my \(.applicationName) cost"
            ],
            shortTitle: "Today's Claude Cost",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: GetActiveSessionsIntent(),
            phrases: [
                "How many active Claude sessions",
                "Show \(.applicationName) sessions",
                "Are any Claude sessions running"
            ],
            shortTitle: "Active Sessions",
            systemImageName: "person.fill.badge.clock"
        )
    }
}
```

Register at app launch in `PodiumApp.swift`:

```swift
.task {
    PodiumShortcuts.updateAppShortcutParameters()
}
```

### Shortcuts.app Actions

All four intents automatically appear in **Shortcuts.app** under "Podium" without extra work. Users can chain them: e.g., "Every morning, get today's Claude cost and send it to myself in Messages."

---

## 3. CoreSpotlight Indexing

### Overview

Sessions are indexed in macOS Spotlight. Searching `claude imagify` in Spotlight returns matching sessions. Tapping a result opens Podium focused on that session.

### Files

New file: `Sources/PodiumApp/SpotlightIndexer.swift`

### Implementation

```swift
import CoreSpotlight
import UniformTypeIdentifiers

actor SpotlightIndexer {
    static let domainIdentifier = "com.wpMedia.podium.sessions"
    static let activityType = "com.wpMedia.podium.viewSession"

    // MARK: - Index sessions

    func index(_ sessions: [Session]) async {
        let items = sessions.map { makeItem(for: $0) }
        // Batch for performance
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    func indexOne(_ session: Session) async {
        try? await CSSearchableIndex.default().indexSearchableItems([makeItem(for: session)])
    }

    func removeAll() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }

    func remove(sessionId: String) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [spotlightId(sessionId)])
    }

    // MARK: - Build item

    private func makeItem(for session: Session) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .data)

        let projectName = session.name ?? URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
        attrs.title = "Session: \(projectName)"
        attrs.contentDescription = [
            "Status: \(session.status.rawValue)",
            session.cwd.map { "Path: \($0)" },
            session.cost.map { "Cost: \(Theme.formatCost($0))" },
            "Started: \(session.startedAt.formatted(.relative(presentation: .named)))"
        ].compactMap { $0 }.joined(separator: " · ")

        attrs.keywords = [
            "podium", "claude", "session",
            session.status.rawValue,
            projectName,
            session.cwd ?? "",
            session.model ?? ""
        ]

        // Map status to a meaningful content type description
        attrs.contentType = UTType.data.identifier
        attrs.relatedUniqueIdentifier = spotlightId(session.id)

        return CSSearchableItem(
            uniqueIdentifier: spotlightId(session.id),
            domainIdentifier: domainIdentifier,
            attributeSet: attrs
        )
    }

    private func spotlightId(_ sessionId: String) -> String {
        "podium.session.\(sessionId)"
    }
}
```

### AppState Integration

Add to `AppState`:

```swift
private let spotlight = SpotlightIndexer()

// In refresh(), after sessions are loaded:
Task.detached(priority: .background) {
    await self.spotlight.index(sessions)
}

// In upsertSession(_:):
Task.detached(priority: .background) {
    await self.spotlight.indexOne(session)
}
```

### Handling Spotlight Tap

In `PodiumApp.swift`:

```swift
WindowGroup {
    ContentView()
}
.handlesExternalEvents(matching: Set(arrayLiteral: "*"))
.onContinueUserActivity(SpotlightIndexer.activityType) { activity in
    if let sessionId = activity.userInfo?["sessionId"] as? String {
        appState.selectedSessionId = sessionId
        // Switch to sessions tab
        appState.spotlightNavigation = .sessions
    }
}
```

For this to work, the `CSSearchableItem` needs a `userActivity` linked to it. Register an `NSUserActivity` in the item:

```swift
// In makeItem(), add:
let activity = NSUserActivity(activityType: SpotlightIndexer.activityType)
activity.title = attrs.title ?? ""
activity.userInfo = ["sessionId": session.id]
activity.isEligibleForSearch = true
activity.isEligibleForPublicIndexing = false
return CSSearchableItem(
    uniqueIdentifier: spotlightId(session.id),
    domainIdentifier: domainIdentifier,
    attributeSet: attrs
)
// Note: associate the activity via attrs.relatedUniqueIdentifier
// The system links the CSSearchableItem → NSUserActivity by matching uniqueIdentifier
```

Register the activity type in `Info.plist`:

```xml
<key>NSUserActivityTypes</key>
<array>
    <string>com.wpMedia.podium.viewSession</string>
</array>
```

### Index Lifecycle

| Trigger | Action |
|---|---|
| `AppState.refresh()` completes | `spotlight.index(sessions)` — full re-index |
| WebSocket `session_created` | `spotlight.indexOne(session)` |
| WebSocket `session_updated` | `spotlight.indexOne(session)` |
| App terminates | No action needed — Spotlight index persists |
| User clears data (future) | `spotlight.removeAll()` |

### Performance

- Batch indexing on `refresh()` handles 1000+ sessions in <1s (CoreSpotlight is fast)
- Use `Task.detached(priority: .background)` so indexing never blocks the UI
- `CSSearchableIndex.default().beginBatch()` / `endBatch()` for large initial imports
