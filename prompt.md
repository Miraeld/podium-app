# PodiumSwiftApp — Full Implementation Prompt

You are about to implement a complete native macOS SwiftUI app called **Podium** — a real-time observer dashboard for Claude Code sessions. The app already has a working foundation; you are adding a large set of new features, a design system upgrade, and native macOS integrations.

**Do not ask for confirmation. Execute the full plan below.**

---

## Project location

```
/Users/gaelrobin/Desktop/PodiumSwiftApp/
```

### Existing source files (13 Swift files, all in `Sources/PodiumApp/`):

- `PodiumApp.swift` — app entry point + AppDelegate
- `ContentView.swift` — NavigationSplitView + Sidebar (3 destinations: dashboard, sessions, analytics)
- `AppState.swift` — @Observable state manager + WebSocket handler
- `Models.swift` — all data models (Session, Agent, DashboardEvent, Stats, Analytics, CostResult, SessionStats, WSMessage)
- `PodiumAPI.swift` — HTTP actor with all current REST endpoints
- `WebSocketClient.swift` — WebSocket with exponential backoff reconnection
- `Theme.swift` — design tokens, glassmorphism card modifier, color helpers
- `Components.swift` — reusable UI components (badges, charts, loading states)
- `DashboardView.swift` — stats cards + live event feed
- `SessionsView.swift` — sessions list with search + status filters
- `SessionDetailView.swift` — 3-tab detail: Overview, Agents tree, Events
- `AnalyticsView.swift` — token trends, daily charts, tool usage, agent types
- `SettingsView.swift` — server URL configuration only
- `Package.swift` — SPM executable, platform macOS 14, single target `PodiumApp`

### Spec files (read ALL of these before doing anything):

```
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-OVERVIEW.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-DESIGN.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-FEATURES.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-API.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-ARCHITECTURE.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-NATIVE-SUPERPOWERS.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-MONITORING.md
/Users/gaelrobin/Desktop/PodiumSwiftApp/SPEC-INSIGHTS-WORKFLOW.md
```

---

## Team structure

You will spawn **7 agents** across **3 sequential phases**. Phases are gated — do not start Phase 2 until Phase 1 is fully committed. Do not start Phase 3 until Phase 2 is fully committed.

Model assignments:
- **Opus** — Architect agent, Insights agent (complex algorithms)
- **Sonnet** — all other agents

---

## Phase 1 — Foundation (run sequentially, Architect first)

### Agent 1 · Architect (Opus)

**Task:** Xcode project migration + Liquid Glass design system.

Read these files in full before starting:
- `SPEC-DESIGN.md` — the complete design system spec
- `SPEC-ARCHITECTURE.md` — target file structure and notes on the Xcode migration
- `SPEC-NATIVE-SUPERPOWERS.md` §Prerequisites — explains exactly why the SPM executable must become an Xcode project
- All 13 existing Swift source files

**What to do:**

1. **Migrate from SPM to Xcode project.**
   - Create a new Xcode project at `/Users/gaelrobin/Desktop/PodiumSwiftApp/Podium.xcodeproj`
   - App target name: `Podium`, bundle ID: `com.wpMedia.podium`
   - Deployment target: macOS 14.0
   - Move all 13 existing `.swift` files into the app target (update file references, do not duplicate files)
   - Add App Group entitlement `group.com.wpMedia.podium` to the app target's `.entitlements` file
   - Add `NSAppleEventsUsageDescription` to `Info.plist`: `"Podium needs to open your terminal to navigate to project directories."`
   - Add `NSUserActivityTypes` array to `Info.plist` with one entry: `"com.wpMedia.podium.viewSession"`
   - Window config in `PodiumApp.swift`: `.defaultSize(width: 1200, height: 760)`, `.windowStyle(.titleBar)`, `.windowToolbarStyle(.unified(showsTitle: false))`
   - Keep `Package.swift` in place but it no longer needs to build — the Xcode project is the primary build system

2. **Add Widget Extension target.**
   - Target name: `PodiumWidget`, bundle ID: `com.wpMedia.podium.widget`
   - Add it to the same App Group: `group.com.wpMedia.podium`
   - Create `PodiumWidget/` directory at the project root for widget-specific files
   - Do NOT implement the widget views yet — that is Phase 3. Just scaffold the target with a placeholder `PodiumWidget.swift`

3. **Migrate design system to Liquid Glass.**
   - Rewrite `Theme.swift` and `Components.swift` following `SPEC-DESIGN.md` exactly:
     - Replace `GlassCardModifier` / `glassBackground()` with the new `glassCard()` extension that uses `.glassEffect(in: .rect(cornerRadius: radius))` behind `#available(macOS 26, *)` and falls back to the current implementation for macOS 14/15
     - Add the `Spacing` and `Radius` enums from the spec
     - Add `MenuBarExtra` scaffold in `PodiumApp.swift` (placeholder `MenuBarContent` struct, implement later in Phase 2)
     - Update `PodiumApp.swift` to add the `onOpenURL` deep-link handler and the `.task { PodiumShortcuts.updateAppShortcutParameters() }` scaffold (the `PodiumShortcuts` type will be created in Phase 3)
   - All existing views must continue to compile — do not change view logic, only the modifier implementations

4. **Create shared data helpers** needed by the widget and intents:
   - `Shared/WidgetData.swift` — `WidgetSnapshot` struct + `WidgetStore` enum (exact code in `SPEC-NATIVE-SUPERPOWERS.md` §1 Data Sharing)
   - `Shared/IntentAPIClient.swift` — lightweight API client for intents (exact code in `SPEC-NATIVE-SUPERPOWERS.md` §2)
   - Both files go in a `Shared/` directory inside the Xcode project and are added to BOTH the app target and (when it exists) the widget target

5. Verify the project builds successfully with `xcodebuild -project Podium.xcodeproj -scheme Podium build` before committing.

---

### Agent 2 · Data Layer (Sonnet)

**Starts after Agent 1 commits.** Read `SPEC-API.md` and `SPEC-ARCHITECTURE.md` in full.

**What to do:**

1. **Extend `Models.swift`** with every new struct listed in `SPEC-API.md` §New Models:
   - `EventsPage`, `WorkflowData`, `WorkflowNode`, `WorkflowEdge`, `WorkflowMetrics`
   - `RunSession`, `RunMode`, `RunStatus`, `RunEvent`, `RunEventType`, `RunResponse`
   - `SearchResults`, `PricingRule`
   - `CCConfig`, `CCPlugin`, `CCSkill`, `CCAgent`, `CCMCPServer`, `CCKeybinding`, `CCMemoryFile`
   - `ImportResult`, `SystemInfo`
   - `HeatMapDay`, `HeatMapData` (from `SPEC-INSIGHTS-WORKFLOW.md` §1)
   - `GitContext` (from `SPEC-INSIGHTS-WORKFLOW.md` §3)
   - `CostForecast` + the `CostResult.forecast()` extension (from `SPEC-MONITORING.md` §5)

2. **Extend `PodiumAPI.swift`** with every new method listed in `SPEC-API.md` §New PodiumAPI Methods. Follow the existing actor pattern exactly (same `get<T>()` private helper, same `JSONDecoder.podium` decoder).

3. **Extend `PodiumError`** — add the new error cases from `SPEC-API.md` §Error Handling. Currently the enum is called `APIError` in the file; rename it to `PodiumError` and add `runNotFound` and `importFailed([String])`.

4. **Create `Sources/PodiumApp/MonitoringEngine.swift`** — the full `MonitoringEngine` actor from `SPEC-MONITORING.md`. Implement all 5 monitoring features completely: session cost limit, weekly cost limit, stuck session detector, cost anomaly alert, cost forecasting. Include `NotificationHelper` enum in the same file.

5. **Create `Sources/PodiumApp/SpotlightIndexer.swift`** — the full `SpotlightIndexer` actor from `SPEC-NATIVE-SUPERPOWERS.md` §3.

6. **Create `Sources/PodiumApp/GitContextReader.swift`** — the `GitContextReader` actor and `SessionExporter` struct, exact code from `SPEC-INSIGHTS-WORKFLOW.md` §3 and §5.

7. **Extend `AppState.swift`**:
   - Add all new state properties from `SPEC-ARCHITECTURE.md` §AppState Extensions
   - Add `private let spotlight = SpotlightIndexer()` and call `spotlight.index(sessions)` after refresh and `spotlight.indexOne(session)` in `upsertSession`
   - Add the new WebSocket cases `run_event` and `notification` from `SPEC-ARCHITECTURE.md` §WebSocket Changes
   - Add `sendLocalNotification(title:body:)` helper
   - Add `var costForecast: CostForecast?` and set it after `totalCost` loads
   - Add `var gitContextCache: [String: GitContext] = [:]` and `loadGitContext(for:)` method

8. **Create `Sources/PodiumApp/RunState.swift`** — exact code from `SPEC-ARCHITECTURE.md` §RunState.

9. **Inject** `MonitoringEngine` and `RunState` into `PodiumApp.swift` alongside `AppState`. Add `UNUserNotificationCenter.current().requestAuthorization(...)` call at launch.

10. Verify the project builds before committing.

---

## Phase 2 — Features (run all 4 agents in parallel after Phase 1 commits)

Each agent owns a distinct set of files. They will not conflict.

---

### Agent 3 · Views-A (Sonnet)

Read `SPEC-FEATURES.md` sections 1, 3, 9, and 8. Read `SPEC-ARCHITECTURE.md` for file layout.

**Create these files:**

1. `Sources/PodiumApp/Views/ActivityFeed/ActivityFeedView.swift`
   - Full paginated event stream. Filter toolbar (type, session, date range) pinned at top via `safeAreaInset`. Expandable rows (tap → full JSON in scrollable code block). "Load more" button appending next page. New events slide in from top on WebSocket `new_event`. Use `PodiumAPI.events(limit:offset:type:sessionId:)`.

2. `Sources/PodiumApp/Views/Kanban/KanbanView.swift`
   - Four columns: Active, Completed, Error, Abandoned. Toggle between Sessions and Agents mode (persisted to `UserDefaults("kanbanMode")`). Drag-and-drop with `draggable()` / `dropDestination()`. Dropping a session into Abandoned calls `PATCH /api/sessions/{id}` (add this method to `PodiumAPI` if missing). Cards use `.glassEffect()`, column headers use tinted glass. Card tap opens `SessionDetailView`. Mini card layout exactly as in the spec.

3. `Sources/PodiumApp/Views/Import/ImportView.swift`
   - Drag-and-drop zone for `.jsonl` files + "Choose Files…" `NSOpenPanel`. Selected file list. Import progress bar. Calls `PodiumAPI.importSessions(fileURLs:)`. Shows result: imported / skipped / errors.

4. `Sources/PodiumApp/Views/MenuBar/MenuBarContent.swift`
   - Popover content for the `MenuBarExtra` (scaffolded in Phase 1). Shows: active sessions, active agents, events today, total cost, last 5 sessions list, "Open Podium…" button. Reads from `AppState`. "Open Podium…" calls `NSApplication.shared.activate(ignoringOtherApps: true)`.

5. **Extend `ContentView.swift`**:
   - Add `.activityFeed` and `.kanban` to `NavDestination` enum
   - Add them to the sidebar under the existing "Observe" section with icons `waveform` and `squares.below.rectangle`
   - Add keyboard shortcuts ⌘4 and ⌘6
   - Add routing in the `switch selection` block

---

### Agent 4 · Views-B (Sonnet)

Read `SPEC-FEATURES.md` sections 4, 7, 5, and 6. Read `SPEC-ARCHITECTURE.md`.

**Create these files:**

1. `Sources/PodiumApp/Views/Run/RunView.swift` and `RunOutputView.swift`
   - Split panel: left = run list + "New Run" button; right = working directory picker (NSOpenPanel), multiline `TextEditor` prompt, mode picker (Conversation / One-shot), Run button, streaming output area.
   - `RunOutputView` renders typed event rows: `text` (plain + markdown via `AttributedString`), `tool_use` (colored badge + name + truncated input), `tool_result` (indented), `error` (red border). Stop button calls `PodiumAPI.killRun(runId:)`. Follow-up input re-enables after run completes in conversation mode.

2. `Sources/PodiumApp/Views/CCConfig/CCConfigView.swift` and `CCConfigDetailView.swift`
   - Master-detail. Left: category list (Plugins, Skills, Agents, MCP Servers, Keybindings, Memory). Right: per-category list. Tap any item → shows detail in a popover or secondary panel. All read-only. Loads from `PodiumAPI.ccConfig()`. Uses a "Configure" sidebar section (separate from "Observe").

3. `Sources/PodiumApp/Views/Search/SearchPanel.swift`
   - Floating search window opened by ⌘Shift+F. Use a secondary `WindowGroup` with `.windowStyle(.plain)` and a custom `.glassEffect()` chrome. Results grouped by Sessions / Agents / Events. Arrow-key navigation. Enter → switch main window to that item via deep link. Calls `PodiumAPI.search(query:limit:)`.

4. **Extend `SettingsView.swift`** with 4 tabs: Connection (existing), Pricing Rules, Monitoring, System Info.
   - Pricing Rules tab: sortable table of `PricingRule`, inline edit, add/delete. Calls `PodiumAPI.pricingRules()` and `PodiumAPI.savePricingRules(_:)`.
   - Monitoring tab: exactly the layout in `SPEC-MONITORING.md` §Monitoring Settings Tab Layout. All controls use `@AppStorage` with the keys from `MonitoringKey`.
   - System Info tab: grid of server stats from `PodiumAPI.systemInfo()`. "Purge old sessions" danger button (stub — show confirmation alert, API call TBD).

5. **Extend `ContentView.swift`**:
   - Add `.run` and `.ccConfig` to `NavDestination`
   - Add Run to "Observe" sidebar section (icon `terminal`, ⌘7)
   - Add CC Config to a new "Configure" sidebar section (icon `gearshape.2`)
   - Add routing in the `switch selection` block
   - Add ⌘Shift+F keyboard shortcut to open the search window
   - Add ⌘, shortcut to open Settings sheet

---

### Agent 5 · Insights (Opus)

Read `SPEC-FEATURES.md` §2 (Workflows), `SPEC-INSIGHTS-WORKFLOW.md` §2 (Session Replay). These are the two most algorithmically complex features.

**Create these files:**

1. `Sources/PodiumApp/Views/Workflows/WorkflowsView.swift`
   - Two-panel layout. Left: session picker list (search field + sessions sorted by recency, active sessions highlighted). Right: tab bar with DAG, Timeline, Metrics tabs.
   - Loads `PodiumAPI.workflowData(sessionId:)` when a session is selected.

2. `Sources/PodiumApp/Views/Workflows/WorkflowDAGView.swift`
   - Renders `WorkflowData.nodes` and `WorkflowData.edges` using SwiftUI `Canvas`.
   - **Node layout algorithm:** Use a simple layered layout. Group nodes by depth (`WorkflowNode.depth`). Place nodes left-to-right within each depth layer, layers top-to-bottom. Node width: 160pt, height: 48pt, horizontal gap: 32pt between nodes at same depth, vertical gap: 80pt between layers.
   - **Edge rendering:** Draw Bézier curves from the bottom-center of the source node to the top-center of the target node. Control points at 40pt below source and 40pt above target. Stroke: 1.5pt, color from `Theme.color(for: sourceNode.status)`, opacity 0.6. Animate with a dashed line phase when source node status is `working`.
   - **Node rendering:** Rounded rectangle (radius 10), filled with status color at 15% opacity, stroked at 40%. Name truncated to 1 line, status badge below. Pulsing status dot (`.symbolEffect(.pulse)`) when active.
   - **Interactions:** `MagnificationGesture` for zoom (scale 0.3–3.0), `DragGesture` on background for pan. Track `@State var scale: CGFloat = 1` and `@State var offset: CGSize = .zero`. Tap a node → popover showing the agent's start time, end time, token count, cost.
   - Render everything inside `Canvas { context, size in ... }` — do not use `ForEach` + `ZStack` (performance).

3. `Sources/PodiumApp/Views/Workflows/WorkflowTimelineView.swift`
   - Horizontal Gantt chart. X-axis = seconds since session start. One row per agent sorted by start time. Bar color = status color. Bars drawn in SwiftUI `Canvas`. Show agent name label on the left (fixed 140pt column). Parallel agents overlap correctly on Y-axis (they get their own rows, not stacked in the same row).

4. `Sources/PodiumApp/Views/Workflows/WorkflowMetricsView.swift`
   - Simple `LazyVGrid` of `StatCard` views: total agents, max concurrency, total tokens (formatted with `Theme.formatTokens`), total cost, error rate %, duration. Data from `WorkflowData.metrics`.

5. `Sources/PodiumApp/Views/Sessions/SessionReplayView.swift`
   - New file implementing the replay tab. Contains `ReplayState` @Observable class (exact code from `SPEC-INSIGHTS-WORKFLOW.md` §2). Contains `ReplayTransportBar` view (exact code from the spec). Main body: `ReplayTransportBar` at top, below it a `ScrollView` with `ForEach(replay.visibleEvents)` rendering each event as a styled row (reuse `EventFeedRow` from `DashboardView`). Auto-scrolls to bottom when `currentIndex` changes via `.onChange(of: replay.currentIndex)` + `ScrollViewReader.scrollTo`. Load all events via `PodiumAPI.allEvents(sessionId:)` in `.task`.

6. **Extend `SessionDetailView.swift`**:
   - Add "Replay" tab (Tab 4) that shows `SessionReplayView`
   - Create a `@State var replay = ReplayState()` in the view

7. **Extend `ContentView.swift`**:
   - Add `.workflows` to `NavDestination`
   - Add to "Observe" sidebar (icon `arrow.triangle.branch`, ⌘5)
   - Add routing

---

### Agent 6 · Monitoring + Simple Insights (Sonnet)

Read `SPEC-MONITORING.md` (heat map display only — the engine was created in Phase 1), `SPEC-INSIGHTS-WORKFLOW.md` §1 (Heat Map), §3 (Git Context display), §4 (Terminal/Finder), §5 (Export).

**Create these files:**

1. `Sources/PodiumApp/Views/Analytics/HeatMapView.swift`
   - `HeatMapView`, `HeatMapTooltip` exactly as specified in `SPEC-INSIGHTS-WORKFLOW.md` §1. Use SwiftUI `Canvas` for the cell grid. `onContinuousHover` for tooltip. Mode toggle (Sessions / Cost). 5-level color scale using the `heatColor(value:max:mode:)` static function. Wrap in a `GlassCard` with "Usage History" header.
   - Embed at the top of `AnalyticsView.swift` above the existing charts.

2. **Extend `SessionDetailView.swift`** Overview tab:
   - Add a "Git" section below the stats grid showing `GitContext` data: branch (with copy button), last commit, remote URL (with Safari open button + SSH→HTTPS conversion via `httpsURL(from:)` from the spec), dirty status indicator.
   - Load git context in `.task(id: session.id)` calling `state.loadGitContext(for: session)`.
   - Add "Conversation" tab (Tab 5): scrollable list of events with `summary` field rendered as `AttributedString` markdown. Tool use events show collapsed `DisclosureGroup` with raw data. Auto-scroll to bottom on load.
   - Add "Cost Breakdown" tab (Tab 6): native `Table` view (macOS 13+) with columns Model, Calls (count events), Input tokens, Output tokens, Cost. Sortable by cost column by default. Data from `state.sessionCostCache[session.id]`.

3. **Add `WorkingDirActions`** view from `SPEC-INSIGHTS-WORKFLOW.md` §4 to `Components.swift`. Add `.contextMenu` with it to session rows in `DashboardView`, `SessionsView`, and `KanbanView`.

4. **Add export actions** to `SessionDetailView` toolbar: a `Menu` button (icon `square.and.arrow.up`) with "Export as Markdown…" and "Export as PDF…" items. Both call `SessionExporter` methods (created in Phase 1 by the Data Layer agent).

5. **Dashboard additions**:
   - Below the Total Cost `StatCard`, add a cost forecast line using `state.costForecast` with the trend arrow (↑/→/↓) and "~$X projected this month" text.
   - Update `WidgetStore.save(snapshot:)` call in `AppState.refresh()` to include the forecast (update `WidgetSnapshot` to include `forecastedMonthlyCost`).

---

## Phase 3 — System Integrations + Wiring (run in parallel after Phase 2 commits)

---

### Agent 7 · Integrations (Sonnet)

Read `SPEC-NATIVE-SUPERPOWERS.md` in full.

**What to do:**

1. **WidgetKit — `PodiumWidget/PodiumWidget.swift`**
   - Implement `PodiumProvider`, `PodiumEntry`, `PodiumStatsWidget`, `PodiumWidgetBundle` exactly as specified.
   - Implement `SmallWidgetView`, medium view, large view as specified.
   - Add the `widgetURL` modifier and deep-link `podium://session/{id}` URLs on medium/large session rows.
   - Include `WidgetData.swift` (from `Shared/`) in the widget target.

2. **App Intents — `Sources/PodiumApp/Intents/PodiumIntents.swift`**
   - Implement all 4 intents: `GetTodayCostIntent`, `GetActiveSessionsIntent`, `ListRecentSessionsIntent`, `OpenSessionIntent` exactly as specified.
   - Implement `PodiumShortcuts: AppShortcutsProvider` with the Siri phrases from the spec.
   - The `.task { PodiumShortcuts.updateAppShortcutParameters() }` call was scaffolded in Phase 1 — it will now resolve.

3. **CoreSpotlight — verify `SpotlightIndexer.swift`** (created in Phase 1):
   - Add `NSUserActivity` to each `CSSearchableItem` for the deep-link callback (the exact code is in `SPEC-NATIVE-SUPERPOWERS.md` §3 Handling Spotlight Tap)
   - Verify the `onContinueUserActivity` handler in `PodiumApp.swift` is correctly wired (was scaffolded in Phase 1)

4. **`UNNotificationCategory` registration** for stuck sessions: add the `STUCK_SESSION` category with "Open" action and the `UNUserNotificationCenterDelegate` handler in `AppDelegate.swift` (exact code in `SPEC-MONITORING.md` §3 Trigger Logic, Notification action section).

5. **`MenuBarContent.swift`** — verify it was created in Phase 2 by Views-A. If it exists, just wire the `onOpenURL` deep-link handler in `PodiumApp.swift` to also handle `podium://dashboard` by setting `selection = .dashboard`.

6. Verify the full Xcode project builds: `xcodebuild -project Podium.xcodeproj -scheme Podium build`.

---

## Final quality checks (run after all agents commit)

After all 7 agents have committed:

1. **Build check**: `xcodebuild -project Podium.xcodeproj -scheme Podium build` — must succeed with zero errors.
2. **No force-unwraps** in new code: `grep -r "!\." Sources/PodiumApp/` — fix any found.
3. **No `DispatchQueue.main` calls** in new code (use `@MainActor` and `Task` instead): `grep -r "DispatchQueue.main" Sources/PodiumApp/` — fix any found.
4. **Keyboard shortcuts complete**: verify ⌘1–⌘7, ⌘F, ⌘Shift+F, ⌘, are all registered in `ContentView.swift`.
5. **All NavDestinations routed**: verify the `switch selection` in `ContentView` has a case for every member of `NavDestination`.

---

## Key constraints for all agents

- **Never use `DispatchQueue.main`** — use `@MainActor`, `Task { @MainActor in }`, or `withMainActor`
- **Never force-unwrap optionals** (`!`) — use `guard let`, `if let`, or `??`
- **Never add comments explaining what code does** — only add a comment when the WHY is non-obvious
- **Liquid Glass**: all new card containers use `.glassCard()` (the updated modifier with `#available(macOS 26, *)` guard). Never use raw `.background(Color(...))` for card surfaces
- **No new custom fonts** — use system font at standard sizes with weight/design modifiers
- **Follow existing patterns**: new API methods follow the `get<T>()` pattern in `PodiumAPI`. New state follows the `@Observable @MainActor final class` pattern of `AppState`
- **Shared files** (`WidgetData.swift`, `IntentAPIClient.swift`) must be added to both the app target and the widget target in Xcode — set target membership in the file inspector
- **The existing 3 views** (Dashboard, Sessions, Analytics) must continue to work exactly as before — do not break any existing functionality
