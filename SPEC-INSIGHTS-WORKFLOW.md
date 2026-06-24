# PodiumSwiftApp — Insights & Workflow Spec

Covers: usage heat map, session replay scrubber, git context, Open in Terminal/Finder, Markdown/PDF export.

---

## 1. Usage Heat Map

### Purpose

A GitHub-style contribution calendar showing 52 weeks of daily activity. Gives an at-a-glance picture of AI usage patterns — which days are heavy, which projects are busiest.

### Data

Two data series rendered as overlapping/switchable layers:
- **Session count per day** — from `Analytics.dailySessions`
- **Daily cost** — from `CostResult.dailyCosts`

The existing API returns only recent data. We need a `from` parameter:

```
GET /api/analytics?from=YYYY-MM-DD   (1 year ago)
GET /api/pricing/cost?from=YYYY-MM-DD
```

If the server already supports `from`/`to` query params on these endpoints, use them. If not, both endpoints need a small backend addition (out of scope for the Swift spec — flag for server work).

### View: `HeatMapView`

New file: `Sources/PodiumApp/Views/Analytics/HeatMapView.swift`

```
Display mode: [ Sessions ]  [ Cost ]  ← Toggle picker

      Jun  Jul  Aug  Sep  Oct  Nov  Dec  Jan  Feb  Mar  Apr  May  Jun
Mon  ░░░░ ░▒▒░ ░░▒▒ ░░░░ ░▒▒▒ ▒▒░░ ░░▒▒ ░░░░ ░░▒▒ ░▒▒░ ░░░░ ░▒▒░ ░
Wed  ░░░░ ░░░▒ ░░░░ ░▒▒░ ░░░░ ░░▒░ ░░░░ ▒▒░░ ░░░░ ░░░░ ▒▒▒░ ░░░░ ░
Fri  ░░▒░ ░░░░ ░░▒▒ ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ ░

     Total: 234 sessions · $28.45 · 174 active days
```

### Rendering — SwiftUI Canvas

```swift
struct HeatMapView: View {
    let days: [HeatMapDay]    // 365 entries, one per day

    private let cellSize: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        Canvas { ctx, size in
            for (index, day) in days.enumerated() {
                let week = index / 7
                let weekday = index % 7
                let x = CGFloat(week) * (cellSize + gap)
                let y = CGFloat(weekday) * (cellSize + gap)
                let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(path, with: .color(day.color))
            }
        }
        .frame(width: CGFloat(53) * (cellSize + gap), height: CGFloat(7) * (cellSize + gap))
    }
}

struct HeatMapDay: Identifiable {
    let id: String     // "yyyy-MM-dd"
    let date: Date
    let sessionCount: Int
    let cost: Double
    var color: Color   // computed from value + mode
}
```

### Color Scale

5 levels for both modes:

```swift
static func heatColor(value: Double, max: Double, mode: HeatMapMode) -> Color {
    guard max > 0 else { return Color.white.opacity(0.06) }
    let ratio = min(value / max, 1.0)
    let base: Color = mode == .sessions ? .cyan : Color(red: 0.2, green: 0.9, blue: 0.55)
    return ratio == 0
        ? Color.white.opacity(0.06)
        : base.opacity(0.2 + 0.8 * ratio)
}
```

### Tooltip on Hover

```swift
.onContinuousHover { phase in
    if case .active(let location) = phase {
        hoveredDay = dayAt(point: location)
    } else {
        hoveredDay = nil
    }
}
.overlay(alignment: .top) {
    if let day = hoveredDay {
        HeatMapTooltip(day: day)
            .offset(x: tooltipX(for: day), y: -36)
    }
}

struct HeatMapTooltip: View {
    let day: HeatMapDay
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.date.formatted(date: .long, time: .omitted))
                .font(.caption.weight(.semibold))
            Text("\(day.sessionCount) sessions · \(Theme.formatCost(day.cost))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .glassCard(radius: 8)
    }
}
```

### Placement

Embed in `AnalyticsView` as a new top section above the existing charts, inside a `GlassCard` with a "Usage History" header and the mode toggle.

### New Model

```swift
struct HeatMapData: Codable {
    let days: [HeatMapDay]
    let maxSessions: Int
    let maxCost: Double
    let totalSessions: Int
    let totalCost: Double
    let activeDays: Int
}
```

---

## 2. Session Replay Scrubber

### Purpose

Step through a session's events like scrubbing a video — forward, backward, at any speed. Makes it easy to understand exactly what an agent did and when, without scrolling through a static list.

### Placement

New **"Replay" tab** (Tab 4) in `SessionDetailView`, between "Events" and (future) "Conversation".

### State

```swift
@Observable
final class ReplayState {
    var allEvents: [DashboardEvent] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var speedMultiplier: Double = 1.0   // events per second in real-time; >1 = faster

    private var playTask: Task<Void, Never>?

    // Events visible at current scrub position
    var visibleEvents: ArraySlice<DashboardEvent> {
        allEvents.prefix(currentIndex + 1)
    }

    func play() {
        isPlaying = true
        playTask = Task { @MainActor in
            while isPlaying && currentIndex < allEvents.count - 1 {
                // Time between this event and next in real time, divided by speed
                let nextIndex = currentIndex + 1
                let realGap = allEvents[nextIndex].createdAt.timeIntervalSince(allEvents[currentIndex].createdAt)
                let delay = max(0.05, realGap / speedMultiplier)   // min 50ms per step
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { currentIndex = nextIndex }
            }
            isPlaying = false
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
    }

    func stepForward()  { currentIndex = min(currentIndex + 1, allEvents.count - 1) }
    func stepBackward() { currentIndex = max(currentIndex - 1, 0) }
    func jumpToStart()  { currentIndex = 0 }
    func jumpToEnd()    { currentIndex = max(0, allEvents.count - 1) }
}
```

### View Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  Transport bar:                                                       │
│  [|◀] [◀] [▶/⏸] [▶|]   ─────────○─────────────────────  124/234   │
│                         ↑ Slider                                     │
│  Speed: [1×] [5×] [10×] [Max]   Elapsed: +4m 32s                   │
├──────────────────────────────────────────────────────────────────────┤
│  Event stream (shows only events up to scrub position):              │
│                                                                       │
│  [●] session_start  +0s          "imagify-plugin started"            │
│  [⚡] tool_use      +2s          Bash: "git status"                  │
│  [⚡] tool_use      +5s          Read: "src/OptimizeMedia.php"       │
│  [●] agent_start    +12s    ←── current position                    │
│                                                                       │
│  (events after position are greyed out / hidden)                     │
└──────────────────────────────────────────────────────────────────────┘
```

### Transport Controls

```swift
struct ReplayTransportBar: View {
    @Bindable var replay: ReplayState

    var body: some View {
        VStack(spacing: 10) {
            // Slider
            HStack(spacing: 12) {
                Button(action: replay.jumpToStart)  { Image(systemName: "backward.end.fill") }
                Button(action: replay.stepBackward) { Image(systemName: "backward.fill") }

                Slider(
                    value: Binding(
                        get: { Double(replay.currentIndex) },
                        set: { replay.currentIndex = Int($0) }
                    ),
                    in: 0...Double(max(1, replay.allEvents.count - 1)),
                    step: 1
                )

                Button(action: replay.stepForward) { Image(systemName: "forward.fill") }
                Button(action: replay.jumpToEnd)   { Image(systemName: "forward.end.fill") }

                Text("\(replay.currentIndex + 1)/\(replay.allEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60)
            }

            // Play / speed controls
            HStack(spacing: 16) {
                Button {
                    replay.isPlaying ? replay.pause() : replay.play()
                } label: {
                    Label(replay.isPlaying ? "Pause" : "Play",
                          systemImage: replay.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Spacer()

                Text("Speed")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $replay.speedMultiplier) {
                    Text("1×").tag(1.0)
                    Text("5×").tag(5.0)
                    Text("10×").tag(10.0)
                    Text("Max").tag(1000.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if let first = replay.allEvents.first,
                   replay.currentIndex < replay.allEvents.count {
                    let elapsed = replay.allEvents[replay.currentIndex].createdAt
                        .timeIntervalSince(first.createdAt)
                    Text("+" + formatDuration(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .glassCard()
    }
}
```

### Data Loading

Load ALL events for the session when Replay tab is selected:

```swift
.task {
    if replay.allEvents.isEmpty {
        let response = await state.loadAllEvents(sessionId: session.id)
        replay.allEvents = response.sorted(by: { $0.createdAt < $1.createdAt })
    }
}
```

New API method needed: `events(sessionId:limit:offset:)` paged until `total` is reached.

```swift
// In PodiumAPI:
func allEvents(sessionId: String) async throws -> [DashboardEvent] {
    var all: [DashboardEvent] = []
    var offset = 0
    let pageSize = 200
    while true {
        let page = try await events(sessionId: sessionId, limit: pageSize, offset: offset)
        all.append(contentsOf: page.events)
        if all.count >= page.total { break }
        offset += pageSize
    }
    return all
}
```

---

## 3. Git Context

### Purpose

Show the git branch, last commit, and remote URL for a session's working directory — linking AI sessions to actual code changes.

### Data Model

```swift
struct GitContext {
    let branch: String?       // "enhancement/1107-imagify-mcp"
    let lastCommit: String?   // "a1b2c3d fix: correct array syntax"
    let remoteURL: String?    // "git@github.com:wp-media/imagify-plugin.git"
    let isDirty: Bool         // uncommitted changes exist
}
```

### Data Fetching

```swift
actor GitContextReader {
    func read(cwd: String) async -> GitContext {
        async let branch  = run("git", args: ["-C", cwd, "branch", "--show-current"])
        async let commit  = run("git", args: ["-C", cwd, "log", "-1", "--pretty=format:%h %s"])
        async let remote  = run("git", args: ["-C", cwd, "remote", "get-url", "origin"])
        async let dirty   = run("git", args: ["-C", cwd, "status", "--porcelain"])
        return GitContext(
            branch: try? await branch,
            lastCommit: try? await commit,
            remoteURL: try? await remote,
            isDirty: ((try? await dirty) ?? "").isEmpty == false
        )
    }

    private func run(_ command: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(command)")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // swallow stderr
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.isEmpty { throw CocoaError(.fileNoSuchFile) }
        return output
    }
}
```

### AppState Integration

```swift
// In AppState:
var gitContextCache: [String: GitContext] = [:]
private let gitReader = GitContextReader()

func loadGitContext(for session: Session) async {
    guard let cwd = session.cwd,
          gitContextCache[session.id] == nil else { return }
    let ctx = await gitReader.read(cwd: cwd)
    gitContextCache[session.id] = ctx
}
```

Call in `SessionDetailView.task`:

```swift
.task(id: session.id) {
    await state.loadGitContext(for: session)
}
```

### UI in SessionDetailView — Overview tab

New "Git" section below the stats grid:

```
┌─ Git ────────────────────────────────────────────────────────────┐
│  Branch      enhancement/1107-imagify-mcp                  [⎘]  │
│  Last commit a1b2c3d fix: correct array syntax                   │
│  Remote      github.com/wp-media/imagify-plugin            [↗]  │
│  Status      ● Dirty (uncommitted changes)                       │
└──────────────────────────────────────────────────────────────────┘
```

- `[⎘]` copies the branch name to clipboard
- `[↗]` opens the remote URL in Safari (convert SSH URL to HTTPS first)
- Dirty indicator uses the existing `Theme.color(for: "error")` yellow

### SSH → HTTPS URL conversion

```swift
func httpsURL(from remoteURL: String) -> URL? {
    // git@github.com:org/repo.git  →  https://github.com/org/repo
    if remoteURL.hasPrefix("git@") {
        let cleaned = remoteURL
            .replacingOccurrences(of: "git@", with: "")
            .replacingOccurrences(of: ":", with: "/")
            .replacingOccurrences(of: ".git", with: "")
        return URL(string: "https://" + cleaned)
    }
    return URL(string: remoteURL.replacingOccurrences(of: ".git", with: ""))
}
```

---

## 4. Open in Terminal / Finder

### Purpose

One-click context switch from any session to the project in Finder or Terminal. Saves the copy-paste-cd dance.

### Placement

- **Context menu** on session rows (right-click) everywhere: Dashboard, Sessions list, Kanban
- **Toolbar buttons** in `SessionDetailView` (secondary action group, right side)

### Implementation

```swift
struct WorkingDirActions: View {
    let cwd: String

    var body: some View {
        Menu {
            Button("Show in Finder") { showInFinder() }
            Button("Open in Terminal") { openInTerminal() }
            if isITermRunning {
                Button("Open in iTerm") { openInITerm() }
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
    }

    // MARK: - Actions

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    private func openInTerminal() {
        let escaped = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        tell application "Terminal"
            activate
            if (count windows) = 0 then
                do script "cd '\(escaped)'"
            else
                do script "cd '\(escaped)'" in front window
            end if
        end tell
        """
        runAppleScript(script)
    }

    private func openInITerm() {
        let escaped = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        tell application "iTerm"
            activate
            tell current window
                create tab with default profile
                tell current session
                    write text "cd '\(escaped)'"
                end tell
            end tell
        end tell
        """
        runAppleScript(script)
    }

    private var isITermRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
    }

    private func runAppleScript(_ source: String) {
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
```

### Context menu integration

```swift
// Add to any session row:
.contextMenu {
    if let cwd = session.cwd {
        WorkingDirActions(cwd: cwd)
        Divider()
    }
    Button("Copy Session ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
    }
}
```

### Entitlement requirement

AppleScript automation requires the `com.apple.security.automation.apple-events` entitlement for the specific apps being targeted:

```xml
<!-- In Podium.entitlements -->
<key>com.apple.security.automation.apple-events</key>
<true/>
```

And in `Info.plist`, for macOS 10.14+ privacy:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Podium needs to open your terminal to navigate to project directories.</string>
```

---

## 5. Markdown / PDF Export

### Purpose

Export any session as a portable document — for attaching to a PR, sharing with a client, or personal records.

### Placement

- Toolbar button in `SessionDetailView`: `Share` menu → "Export as Markdown…" / "Export as PDF…"
- Also accessible from right-click context menu on session rows

### Markdown Export

New file: `Sources/PodiumApp/Export/SessionExporter.swift`

```swift
struct SessionExporter {

    // MARK: - Markdown

    static func markdown(
        session: Session,
        detail: SessionDetailResponse,
        stats: SessionStats?,
        cost: CostResult?
    ) -> String {
        var lines: [String] = []
        let name = session.name ?? URL(fileURLWithPath: session.cwd ?? "").lastPathComponent

        lines += [
            "# Session: \(name)",
            "",
            "| Field | Value |",
            "|---|---|",
            "| Status | \(session.status.rawValue.capitalized) |",
            "| Started | \(session.startedAt.formatted()) |",
            session.endedAt.map { "| Ended | \($0.formatted()) |" },
            session.cwd.map  { "| Path | `\($0)` |" },
            session.model.map { "| Model | \($0) |" },
            cost.map { "| Total cost | \(Theme.formatCost($0.totalCost)) |" },
            stats.map { "| Events | \($0.totalEvents) |" },
            stats.map { "| Agents | \($0.agents.total) |" },
        ].compactMap { $0 }

        // Agents tree
        lines += ["", "## Agents (\(detail.agents.count))", ""]
        for agent in detail.agents.sorted(by: { $0.startedAt < $1.startedAt }) {
            let indent = agent.type == .subagent ? "  - " : "- "
            let typeTag = agent.subagentType.map { " (\($0))" } ?? ""
            lines.append("\(indent)**\(agent.name)**\(typeTag) — \(agent.status.rawValue)")
        }

        // Cost breakdown
        if let cost, !cost.breakdown.isEmpty {
            lines += ["", "## Cost Breakdown", "",
                "| Model | Input | Output | Cost |",
                "|---|---|---|---|"]
            for b in cost.breakdown {
                lines.append("| \(b.model) | \(Theme.formatTokens(b.inputTokens)) | \(Theme.formatTokens(b.outputTokens)) | \(Theme.formatCost(b.cost)) |")
            }
        }

        // Events (abbreviated — first 100)
        let events = detail.events.prefix(100)
        if !events.isEmpty {
            lines += ["", "## Events (first \(events.count) of \(detail.events.count))", "",
                "| Time | Type | Summary |",
                "|---|---|---|"]
            let t0 = detail.events.first?.createdAt ?? session.startedAt
            for event in events {
                let offset = Int(event.createdAt.timeIntervalSince(t0))
                let summary = event.summary ?? event.toolName ?? ""
                lines.append("| +\(offset)s | \(event.eventType) | \(summary.prefix(80)) |")
            }
        }

        lines += ["", "---", "*Exported from Podium on \(Date().formatted())*"]
        return lines.joined(separator: "\n")
    }

    // MARK: - Save Markdown

    @MainActor
    static func saveMarkdown(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).md"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - PDF Export

    @MainActor
    static func savePDF(
        session: Session,
        detail: SessionDetailResponse,
        stats: SessionStats?,
        cost: CostResult?
    ) {
        // Build a SwiftUI view for the PDF
        let exportView = SessionPDFView(
            session: session, detail: detail, stats: stats, cost: cost
        )

        // Render to a fixed-width NSHostingView
        let hostingView = NSHostingView(rootView: exportView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 10_000)
        hostingView.layoutSubtreeIfNeeded()

        // Shrink frame to fit content
        let fittingHeight = hostingView.fittingSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: fittingHeight)

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 612, height: 792)   // US Letter
        printInfo.topMargin = 36; printInfo.bottomMargin = 36
        printInfo.leftMargin = 36; printInfo.rightMargin = 36
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let operation = NSPrintOperation(view: hostingView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}
```

### PDF Layout View

```swift
struct SessionPDFView: View {
    let session: Session
    let detail: SessionDetailResponse
    let stats: SessionStats?
    let cost: CostResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(session.name ?? projectName)
                        .font(.title.weight(.bold))
                    Text("Claude Code Session · Podium")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date().formatted(date: .long, time: .shortened))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()

            // Stats grid (4 across)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()),
                                 .init(.flexible()), .init(.flexible())], spacing: 12) {
                InfoCell(label: "Status",   value: session.status.rawValue.capitalized)
                InfoCell(label: "Duration", value: duration)
                InfoCell(label: "Cost",     value: cost.map { Theme.formatCost($0.totalCost) } ?? "—")
                InfoCell(label: "Agents",   value: stats.map { "\($0.agents.total)" } ?? "—")
            }

            // Agent list
            if !detail.agents.isEmpty {
                Text("Agents").font(.headline)
                ForEach(detail.agents.sorted(by: { $0.startedAt < $1.startedAt })) { agent in
                    HStack {
                        Circle().fill(Theme.color(agent: agent.status)).frame(width: 8, height: 8)
                        Text(agent.name).font(.callout)
                        if let t = agent.subagentType { Text("(\(t))").foregroundStyle(.secondary).font(.caption) }
                        Spacer()
                        Text(agent.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, agent.type == .subagent ? 20 : 0)
                }
            }

            // Cost breakdown table
            if let cost, !cost.breakdown.isEmpty {
                Text("Cost Breakdown").font(.headline)
                Grid(alignment: .leading, columnSpacing: 16, rowSpacing: 4) {
                    GridRow {
                        Text("Model").bold(); Text("Input").bold()
                        Text("Output").bold(); Text("Cost").bold()
                    }
                    Divider()
                    ForEach(cost.breakdown) { b in
                        GridRow {
                            Text(b.model)
                            Text(Theme.formatTokens(b.inputTokens))
                            Text(Theme.formatTokens(b.outputTokens))
                            Text(Theme.formatCost(b.cost))
                        }
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(36)
        .environment(\.colorScheme, .light)   // PDF always renders in light mode
    }

    private var projectName: String {
        URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
    }

    private var duration: String {
        guard let end = session.endedAt else { return "ongoing" }
        let secs = Int(end.timeIntervalSince(session.startedAt))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}

struct InfoCell: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

### Share Sheet Integration

For a lighter-weight sharing option (AirDrop, Mail, Notes, etc.) in addition to save-to-disk:

```swift
// In SessionDetailView toolbar:
ShareLink(
    item: markdownText,
    subject: Text(sessionName),
    message: Text("Claude Code session export"),
    preview: SharePreview(sessionName, image: Image(systemName: "doc.text"))
)
```

`ShareLink` (SwiftUI, macOS 13+) handles the native macOS Share Sheet automatically.
