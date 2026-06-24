# PodiumSwiftApp — Smart Monitoring Spec

Covers: session cost limit, weekly cost limit, stuck session detector, cost anomaly alert, cost forecasting.

All monitoring features share one new file: `Sources/PodiumApp/MonitoringEngine.swift`.
Settings for each are stored in `UserDefaults.standard` and surfaced in the Settings view (extended per `SPEC-FEATURES.md §6`).

---

## Shared Infrastructure

### UserDefaults Keys

```swift
enum MonitoringKey {
    static let sessionCostLimit    = "podium.monitoring.sessionCostLimit"     // Double, 0 = disabled
    static let weeklyCostLimit     = "podium.monitoring.weeklyCostLimit"      // Double, 0 = disabled
    static let stuckThresholdMins  = "podium.monitoring.stuckThresholdMins"   // Int, default 30
    static let anomalyMultiplier   = "podium.monitoring.anomalyMultiplier"    // Double, default 3.0
    static let notifiedSessionIds  = "podium.monitoring.notifiedSessionIds"   // [String] (session cost)
    static let notifiedWeeklyAt    = "podium.monitoring.notifiedWeeklyAt"     // [Double] thresholds already notified
    static let lastWeeklyCheck     = "podium.monitoring.lastWeeklyCheck"      // Date
}
```

### NotificationHelper

```swift
enum NotificationHelper {
    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(id: String, title: String, body: String, categoryId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let cat = categoryId { content.categoryIdentifier = cat }
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Remove a delivered notification (e.g. session resolved itself)
    static func remove(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
```

### MonitoringEngine Actor

```swift
@Observable
@MainActor
final class MonitoringEngine {
    private var stuckCheckTask: Task<Void, Never>?
    private var notifiedStuckSessions: Set<String> = []
    private var lastKnownSessionCosts: [String: Double] = [:]

    func start(observing state: AppState) {
        startStuckSessionLoop(state: state)
    }

    func stop() {
        stuckCheckTask?.cancel()
    }
}
```

Injected alongside `AppState` in `PodiumApp.swift`:

```swift
@State var monitoring = MonitoringEngine()

WindowGroup { ContentView() }
    .environment(appState)
    .environment(monitoring)
    .task { monitoring.start(observing: appState) }
```

---

## 1. Session Cost Limit

### Purpose

Alert when a single session's cumulative cost exceeds a user-configured threshold. Useful when you leave a long-running session unattended.

### Settings UI (Settings → Monitoring tab)

```
Session cost limit
[  $ 1.00  ▲▼ ]   [ Enable ]
Notify when a single session exceeds this amount.
```

- `Toggle` bound to `sessionCostLimit > 0`
- `TextField` for the dollar value, min $0.01, max $999
- Disabled input when toggle is off (saves 0)

### Trigger Logic

Called from two places:
1. `AppState.handleWSMessage` when `session_updated` arrives with a new `cost` field
2. `AppState.loadSessionCost(_:)` after it stores into `sessionCostCache`

```swift
// In MonitoringEngine:
func checkSessionCostLimit(session: Session) {
    let limit = UserDefaults.standard.double(forKey: MonitoringKey.sessionCostLimit)
    guard limit > 0,
          let cost = session.cost,
          cost >= limit else { return }

    // Don't re-notify if we already fired for this session at this limit
    var notified = (UserDefaults.standard.array(forKey: MonitoringKey.notifiedSessionIds) as? [String]) ?? []
    let key = "\(session.id):\(Int(limit * 100))"   // include limit in key so re-notifies if user raises limit
    guard !notified.contains(key) else { return }
    notified.append(key)
    UserDefaults.standard.set(notified, forKey: MonitoringKey.notifiedSessionIds)

    let name = session.name ?? URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
    NotificationHelper.send(
        id: "session_cost_\(session.id)",
        title: "Session cost limit reached",
        body: "\(name) has spent \(Theme.formatCost(cost)) — over your \(Theme.formatCost(limit)) limit."
    )
}
```

**When session completes:** remove the notification and the notified key so the next session from the same project starts clean.

```swift
// In upsertSession when status changes to .completed or .error:
if [.completed, .error, .abandoned].contains(session.status) {
    NotificationHelper.remove(id: "session_cost_\(session.id)")
}
```

### Model change

`Session.cost` already exists as `var cost: Double?` — no model change needed. ✅

---

## 2. Weekly Cost Limit

### Purpose

Alert when the rolling 7-day total spend approaches or exceeds a weekly threshold. Fires at 80% and 100%.

### Settings UI

```
Weekly cost limit
[  $ 20.00  ▲▼ ]   [ Enable ]
Notify at 80% and 100% of this weekly budget.
```

### Trigger Logic

Computed from `CostResult.dailyCosts` which is already fetched in `AppState.refresh()`.

```swift
// In MonitoringEngine:
func checkWeeklyCostLimit(dailyCosts: [CostResult.DailyCost]) {
    let limit = UserDefaults.standard.double(forKey: MonitoringKey.weeklyCostLimit)
    guard limit > 0 else { return }

    // Sum last 7 days
    let calendar = Calendar.current
    let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
    let weeklyTotal = dailyCosts
        .filter {
            guard let date = formatter.date(from: $0.date) else { return false }
            return date >= sevenDaysAgo
        }
        .reduce(0) { $0 + $1.cost }

    let percent = weeklyTotal / limit

    var notifiedAt = (UserDefaults.standard.array(forKey: MonitoringKey.notifiedWeeklyAt) as? [Double]) ?? []

    // Check 80% threshold
    if percent >= 0.80 && !notifiedAt.contains(0.80) {
        notifiedAt.append(0.80)
        NotificationHelper.send(
            id: "weekly_cost_80",
            title: "Weekly cost at 80%",
            body: "You've spent \(Theme.formatCost(weeklyTotal)) this week — 80% of your \(Theme.formatCost(limit)) limit."
        )
    }

    // Check 100% threshold
    if percent >= 1.00 && !notifiedAt.contains(1.00) {
        notifiedAt.append(1.00)
        NotificationHelper.send(
            id: "weekly_cost_100",
            title: "Weekly cost limit reached",
            body: "You've spent \(Theme.formatCost(weeklyTotal)) this week, exceeding your \(Theme.formatCost(limit)) limit."
        )
    }

    UserDefaults.standard.set(notifiedAt, forKey: MonitoringKey.notifiedWeeklyAt)

    // Reset notifiedAt on Monday (new week)
    let weekday = calendar.component(.weekday, from: Date())
    let lastCheck = UserDefaults.standard.object(forKey: MonitoringKey.lastWeeklyCheck) as? Date ?? .distantPast
    if weekday == 2 && !calendar.isDate(lastCheck, inSameDayAs: Date()) {
        UserDefaults.standard.removeObject(forKey: MonitoringKey.notifiedWeeklyAt)
    }
    UserDefaults.standard.set(Date(), forKey: MonitoringKey.lastWeeklyCheck)
}
```

**Call site:** After `AppState.refresh()` loads `totalCost`:

```swift
// In AppState.refresh(), after totalCost is set:
if let costs = totalCost?.dailyCosts {
    monitoring.checkWeeklyCostLimit(dailyCosts: costs)
}
```

---

## 3. Stuck Session Detector

### Purpose

Alert when an `active` session stops emitting events for longer than a configurable threshold. Catches runaway agents, hung tool calls, or forgotten sessions.

### Settings UI

```
Stuck session detection
[ 30 minutes  ▲▼ ]   [ Enable ]
Alert when an active session has no new events for this duration.
```

### Implementation

A periodic background loop in `MonitoringEngine`:

```swift
private func startStuckSessionLoop(state: AppState) {
    stuckCheckTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))   // check every minute
            guard let self else { break }
            await self.checkStuckSessions(state: state)
        }
    }
}

private func checkStuckSessions(state: AppState) {
    let thresholdMins = UserDefaults.standard.integer(forKey: MonitoringKey.stuckThresholdMins)
    guard thresholdMins > 0 else { return }
    let threshold = TimeInterval(thresholdMins * 60)
    let now = Date()

    for session in state.sessions where session.status == .active {
        let lastActivity = session.lastActivity ?? session.updatedAt
        let idle = now.timeIntervalSince(lastActivity)

        if idle >= threshold && !notifiedStuckSessions.contains(session.id) {
            notifiedStuckSessions.insert(session.id)
            let name = session.name ?? URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
            let minutes = Int(idle / 60)
            NotificationHelper.send(
                id: "stuck_\(session.id)",
                title: "Session may be stuck",
                body: "\(name) has been idle for \(minutes) minutes with no new events.",
                categoryId: "STUCK_SESSION"
            )
        }
    }
}
```

**Clear the stuck flag** when the session emits a new event:

```swift
// In AppState.handleWSMessage, case "new_event":
monitoring.clearStuck(sessionId: event.sessionId)

// In MonitoringEngine:
func clearStuck(sessionId: String) {
    if notifiedStuckSessions.remove(sessionId) != nil {
        NotificationHelper.remove(id: "stuck_\(sessionId)")
    }
}
```

**Notification action:** Register a `UNNotificationCategory` with an "Open" action so the user can tap the notification to jump directly to the session.

```swift
// In AppDelegate or PodiumApp:
let openAction = UNNotificationAction(identifier: "OPEN_SESSION", title: "Open", options: .foreground)
let category = UNNotificationCategory(
    identifier: "STUCK_SESSION",
    actions: [openAction],
    intentIdentifiers: [],
    options: []
)
UNUserNotificationCenter.current().setNotificationCategories([category])
```

Handle response:

```swift
// UNUserNotificationCenterDelegate:
func userNotificationCenter(_ center: UNUserNotificationCenter,
                             didReceive response: UNNotificationResponse) async {
    if response.actionIdentifier == "OPEN_SESSION" {
        let id = response.notification.request.identifier.replacingOccurrences(of: "stuck_", with: "")
        appState.selectedSessionId = id
    }
}
```

---

## 4. Cost Anomaly Alert

### Purpose

Alert when a session's cost suddenly spikes far above your typical session cost. Catches accidental infinite loops or runaway prompts before they become expensive.

### Algorithm

Rolling average: sum of all non-active sessions' costs divided by their count (or zero if no history).

On each `session_updated` WebSocket event:

```swift
func checkCostAnomaly(session: Session, allSessions: [Session]) {
    let multiplier = UserDefaults.standard.double(forKey: MonitoringKey.anomalyMultiplier)
    guard multiplier > 0,
          let newCost = session.cost,
          newCost > 0 else { return }

    let oldCost = lastKnownSessionCosts[session.id] ?? 0
    let delta = newCost - oldCost
    lastKnownSessionCosts[session.id] = newCost

    // Calculate rolling average from completed sessions (exclude current, exclude zeros)
    let completedCosts = allSessions
        .filter { $0.id != session.id && $0.status == .completed }
        .compactMap { $0.cost }
        .filter { $0 > 0 }

    guard completedCosts.count >= 3 else { return }   // need baseline
    let average = completedCosts.reduce(0, +) / Double(completedCosts.count)
    guard average > 0 else { return }

    // Alert if current session total is > N× average, but only once per session
    if newCost > average * multiplier {
        let notifId = "anomaly_\(session.id)"
        // Avoid repeated firing — check if we already sent this one
        let notified = (UserDefaults.standard.array(forKey: "podium.notifiedAnomalies") as? [String]) ?? []
        guard !notified.contains(notifId) else { return }
        UserDefaults.standard.set(notified + [notifId], forKey: "podium.notifiedAnomalies")

        let name = session.name ?? URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
        NotificationHelper.send(
            id: notifId,
            title: "Unusual session cost",
            body: "\(name) has spent \(Theme.formatCost(newCost)) — \(String(format: "%.1f×", newCost / average)) your average."
        )
    }
}
```

### Settings UI

```
Cost anomaly detection
Alert when a session costs [ 3× ] your average.
[ Enable ]
```

`Stepper` for multiplier, range 1.5–10×, step 0.5.

---

## 5. Cost Forecasting

### Purpose

Show a projected end-of-month cost based on the rolling 7-day daily average. Displayed inline on the Dashboard and in the widget.

### Computation

```swift
struct CostForecast {
    let dailyAverage: Double          // 7-day average
    let projectedMonthlyTotal: Double // daily avg × remaining days + spent so far this month
    let trend: Trend                  // up / flat / down vs. prior 7 days

    enum Trend { case up, flat, down }
}

extension CostResult {
    func forecast() -> CostForecast {
        let calendar = Calendar.current
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()

        // Last 7 days
        let recent7 = dailyCosts.filter {
            guard let d = formatter.date(from: $0.date) else { return false }
            return calendar.dateComponents([.day], from: d, to: now).day ?? 99 <= 7
        }
        // Prior 7 days (8–14 days ago)
        let prior7 = dailyCosts.filter {
            guard let d = formatter.date(from: $0.date) else { return false }
            let age = calendar.dateComponents([.day], from: d, to: now).day ?? 0
            return age >= 8 && age <= 14
        }

        let avg7 = recent7.isEmpty ? 0 : recent7.reduce(0) { $0 + $1.cost } / Double(recent7.count)
        let avgPrior = prior7.isEmpty ? 0 : prior7.reduce(0) { $0 + $1.cost } / Double(prior7.count)

        // This month's spend so far
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let spentThisMonth = dailyCosts.filter {
            guard let d = formatter.date(from: $0.date) else { return false }
            return d >= monthStart
        }.reduce(0) { $0 + $1.cost }

        // Days remaining in month
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)!.count
        let dayOfMonth = calendar.component(.day, from: now)
        let daysRemaining = daysInMonth - dayOfMonth

        let projected = spentThisMonth + avg7 * Double(daysRemaining)

        let trend: CostForecast.Trend
        if avg7 > avgPrior * 1.1 { trend = .up }
        else if avg7 < avgPrior * 0.9 { trend = .down }
        else { trend = .flat }

        return CostForecast(dailyAverage: avg7, projectedMonthlyTotal: projected, trend: trend)
    }
}
```

### Display locations

**Dashboard — inline below Total Cost stat card:**

```
Total Cost         $1.24 today
──────────────────────────────
↑ $28.50 projected this month
  ($1.01/day avg · 7 days)
```

Trend arrow: `↑` red, `→` secondary, `↓` green.

**Widget small:** replace secondary line of Total Cost card with forecast.

**Analytics view:** add a dashed projection line on the daily cost chart, extending from today to end of month.

### AppState integration

```swift
// In AppState:
var costForecast: CostForecast?

// After totalCost is loaded in refresh():
costForecast = totalCost?.forecast()
```

No new API call needed — uses the already-fetched `CostResult.dailyCosts`. ✅

---

## Monitoring Settings Tab Layout

Add a "Monitoring" tab to `SettingsView`:

```
┌─ Monitoring ────────────────────────────────────────────────────────┐
│                                                                      │
│  Session Cost Limit                            [ Enable ○ ]         │
│  Alert when a session exceeds:   [$  1.00  ▲▼]                     │
│                                                                      │
│  Weekly Cost Limit                             [ Enable ○ ]         │
│  Alert at 80% and 100% of:       [$ 20.00  ▲▼]                    │
│                                                                      │
│  Stuck Session Detection                       [ Enable ●]          │
│  Alert after idle:               [ 30 min  ▲▼]                     │
│                                                                      │
│  Cost Anomaly Detection                        [ Enable ●]          │
│  Alert when session cost is:     [  3.0×   ▲▼] your average        │
│                                                                      │
│  ─────────────────────────────────────────────────────────────────  │
│  Cost Forecasting                              [ Enable ●]          │
│  Show projected monthly cost on dashboard and widget.               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

All toggles and fields live-write to `UserDefaults` via `@AppStorage`.
