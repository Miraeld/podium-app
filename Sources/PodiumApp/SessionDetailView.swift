#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum SessionTab: String, CaseIterable {
    case overview      = "Overview"
    case agents        = "Agents"
    case events        = "Events"
    case replay        = "Replay"
    case conversation  = "Conversation"
    case thinking      = "Thinking"
}

struct SessionDetailView: View {
    let sessionId: String
    @Environment(AppState.self) var state
    @State private var tab: SessionTab = .overview
    @State private var isExporting = false

    private var detail: SessionDetailResponse? { state.sessionDetailCache[sessionId] }
    private var session: Session? { detail?.session ?? state.sessions.first(where: { $0.id == sessionId }) }

    var body: some View {
        ZStack {
            ThemeBackground()

            if let session {
                VStack(spacing: 0) {
                    // Header
                    SessionDetailHeader(
                        session: session,
                        errorCount: state.sessionStatsCache[session.id]?.errorCount,
                        onErrorChipTap: { tab = .events }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                    .contextMenu {
                        if let cwd = session.cwd, directoryExists(cwd) {
                            Button("Show in Finder") { openInFinder(cwd) }
                            Button("Open in Terminal") { openInTerminal(cwd) }
                            Divider()
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cwd, forType: .string)
                            }
                            Divider()
                        }
                        Button("Copy Session ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.id, forType: .string)
                        }
                    }

                    // Annotation card
                    SessionAnnotationView(sessionId: sessionId)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)

                    // Tab picker — scrolls horizontally if labels don't fit so
                    // they never wrap or hyphenate ("Conversation", "Thinking").
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(SessionTab.allCases, id: \.self) { t in
                                TabButton(title: t.rawValue, selected: tab == t) { tab = t }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 16)

                    Divider().opacity(0.3)

                    // Content
                    switch tab {
                    case .overview:
                        SessionOverviewTab(sessionId: sessionId)
                    case .agents:
                        SessionAgentsTab(agents: detail?.agents ?? [])
                    case .events:
                        SessionEventsTab(events: detail?.events ?? [], sessionId: sessionId)
                    case .replay:
                        SessionReplayView(sessionId: sessionId)
                    case .conversation:
                        ConversationTabView(sessionId: sessionId)
                    case .thinking:
                        ThinkingTabView(sessionId: sessionId)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .toolbar {
            // Open working directory in Finder / Terminal
            if let cwd = session?.cwd, directoryExists(cwd) {
                ToolbarItemGroup {
                    Button { openInFinder(cwd) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show in Finder")

                    Button { openInTerminal(cwd) } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Open in Terminal")
                }
            }

            ToolbarItem {
                Menu {
                    Button("Export JSON") { exportJSON() }
                    Button("Export Markdown") { exportMarkdown() }
                    Button("Export PDF") { exportPDF() }
                } label: {
                    if isExporting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .help("Export session")
                .disabled(isExporting)
            }
        }
        .task(id: sessionId) {
            await state.loadSessionDetail(sessionId)
            await state.loadSessionStats(sessionId)
            await state.loadSessionCost(sessionId)
            if let session { await state.loadGitContext(for: session) }
        }
    }

    // MARK: - Export helpers

    private func exportJSON() {
        Task { @MainActor in
            isExporting = true
            defer { isExporting = false }
            guard let data = try? await state.exportSession(sessionId) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "podium-session-\(sessionId.prefix(8)).json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func exportMarkdown() { presentExport(format: .markdown) }
    private func exportPDF()      { presentExport(format: .pdf) }

    private func presentExport(format: SessionExporter.ExportFormat) {
        guard let session else { return }
        SessionExporter.presentSavePanel(
            session: session,
            agents: state.sessionDetailCache[session.id]?.agents ?? [],
            events: state.sessionDetailCache[session.id]?.events ?? [],
            stats: state.sessionStatsCache[session.id],
            format: format
        )
    }
}

// MARK: - Working-directory actions

private func directoryExists(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

private func openInFinder(_ cwd: String) {
    guard directoryExists(cwd) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
}

private func openInTerminal(_ cwd: String) {
    guard directoryExists(cwd) else { return }
    let dir = URL(fileURLWithPath: cwd)

    // Resolve the user's preferred terminal. NSWorkspace.open(dir) alone would
    // hand a directory to Finder, so we target a terminal app explicitly.
    // iTerm2 wins when installed; otherwise fall back to Terminal.app.
    let candidates = ["com.googlecode.iterm2", "com.apple.Terminal"]
    let terminal = candidates
        .lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        .first

    guard let terminal else {
        // No known terminal installed — fall back to revealing in Finder.
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        return
    }

    NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: .init()) { _, error in
        if error != nil {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}

// MARK: - Header

struct SessionDetailHeader: View {
    let session: Session
    var errorCount: Int? = nil
    var onErrorChipTap: (() -> Void)? = nil
    private let color: Color

    init(session: Session, errorCount: Int? = nil, onErrorChipTap: (() -> Void)? = nil) {
        self.session = session
        self.errorCount = errorCount
        self.onErrorChipTap = onErrorChipTap
        self.color = Theme.color(session: session.status)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    StatusDot(color: color, active: session.status == .active)
                    Text(session.name ?? Theme.projectName(from: session.cwd))
                        .font(.title2.weight(.bold))
                    // Status pills grouped with their own spacing so adjacent
                    // pill borders never touch, regardless of the title width.
                    HStack(spacing: 8) {
                        StatusBadge(label: session.status.label, color: color)
                        if session.awaitingInputSince != nil {
                            StatusBadge(label: "Awaiting Input", color: .yellow)
                        }
                        if let count = errorCount, count > 0 {
                            Button {
                                onErrorChipTap?()
                            } label: {
                                Label("\(count) error\(count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.red.opacity(0.18))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .fixedSize()
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let model = session.model {
                    Label(model, systemImage: "cpu")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Started \(Theme.shortDate(session.startedAt))")
                    .font(.caption).foregroundStyle(.tertiary)
                if let ended = session.endedAt {
                    let dur = ended.timeIntervalSince(session.startedAt)
                    Text(formatDuration(dur))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

// MARK: - Annotation

struct SessionAnnotationView: View {
    let sessionId: String
    @State private var isExpanded = false
    @State private var text: String

    init(sessionId: String) {
        self.sessionId = sessionId
        let saved = UserDefaults.standard.string(forKey: "annotation-\(sessionId)") ?? ""
        _text = State(initialValue: saved)
    }

    private func save() {
        UserDefaults.standard.set(text, forKey: "annotation-\(sessionId)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(isExpanded ? "Note" : (text.isEmpty ? "Add a note…" : text))
                        .font(.caption)
                        .foregroundStyle(text.isEmpty && !isExpanded ? .tertiary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                TextEditor(text: $text)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .onChange(of: text) { _, _ in save() }
            }
        }
        .padding(10)
        .glassCard(radius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle()
                    .fill(selected ? Theme.accent : .clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

// MARK: - Overview Tab

struct SessionOverviewTab: View {
    let sessionId: String
    @Environment(AppState.self) var state

    @State private var transcriptTokens: TokenTotals? = nil
    @State private var transcriptPartial = false

    private var stats: SessionStats? { state.sessionStatsCache[sessionId] }
    private var cost: CostResult?  { state.sessionCostCache[sessionId] }
    private var session: Session? {
        state.sessionDetailCache[sessionId]?.session
            ?? state.sessions.first(where: { $0.id == sessionId })
    }

    /// Resolved token counts. The per-session `/stats` endpoint currently
    /// reports 0 for token totals, so we prefer numbers aggregated from the
    /// transcript and fall back to the stats endpoint when those are present.
    private var resolvedTokens: TokenTotals {
        let statsTotals = stats.map {
            TokenTotals(input: $0.tokens.inputTokens,
                        output: $0.tokens.outputTokens,
                        cacheRead: $0.tokens.cacheReadTokens,
                        cacheWrite: $0.tokens.cacheWriteTokens)
        }
        if let statsTotals, statsTotals.grandTotal > 0 { return statsTotals }
        if let transcriptTokens, transcriptTokens.grandTotal > 0 { return transcriptTokens }
        return statsTotals ?? .zero
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if let stats {
                    let tokens = resolvedTokens
                    // Token stats
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            SectionHeader(title: "Token Usage")
                            Spacer()
                            if transcriptPartial && tokens.grandTotal > 0 {
                                Text("partial")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .help("Aggregated from the most recent transcript messages; older messages are not yet included.")
                            }
                        }
                        let total = tokens.input + tokens.output
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                            MiniStat(label: "Input", value: Theme.formatTokens(tokens.input), color: .cyan)
                            MiniStat(label: "Output", value: Theme.formatTokens(tokens.output), color: Theme.accent)
                            MiniStat(label: "Cache Read", value: Theme.formatTokens(tokens.cacheRead), color: .green)
                            MiniStat(label: "Cache Write", value: Theme.formatTokens(tokens.cacheWrite), color: .yellow)
                        }
                        // Progress bars
                        if total > 0 {
                            VStack(spacing: 8) {
                                TokenBar(label: "Input", value: tokens.input, max: total, color: .cyan)
                                TokenBar(label: "Output", value: tokens.output, max: total, color: Theme.accent)
                                TokenBar(label: "Cache Read", value: tokens.cacheRead, max: total, color: .green)
                            }
                        }
                    }
                    .padding(Theme.cardPadding)
                    .glassCard()

                    // Counters
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 12) {
                        MiniStat(label: "Total Events", value: "\(stats.totalEvents)", color: .primary)
                        MiniStat(label: "Errors", value: "\(stats.errorCount)", color: stats.errorCount > 0 ? .red : .green)
                        MiniStat(label: "Agents", value: "\(stats.agents.total)", color: .cyan)
                    }

                    // Cost — de-emphasized: just a small secondary line.
                    if let cost, cost.totalCost > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "dollarsign.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("Estimated cost \(Theme.formatCost(cost.totalCost))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    // Git context
                    if let git = state.gitContextCache[sessionId] {
                        GitContextCard(git: git)
                    }

                    // Top tools
                    if !stats.toolsUsed.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Top Tools Used")
                            MiniBarChart(
                                items: stats.toolsUsed.prefix(10).map { ($0.toolName, $0.count) },
                                color: Theme.accent
                            )
                        }
                        .padding(Theme.cardPadding)
                        .glassCard()
                    }

                } else {
                    LoadingView().frame(height: 200)
                }
            }
            .padding(24)
        }
        .task(id: sessionId) { await loadTranscriptTokens() }
        .task(id: session?.cwd) {
            if let session { await state.loadGitContext(for: session) }
        }
    }

    /// Aggregate token usage from the transcript because the per-session
    /// `/stats` endpoint reports 0. The transcript endpoint caps each page at
    /// 200 messages, so we walk backwards with the `before` cursor up to a
    /// bounded number of pages; if more remain we flag the total as partial.
    private func loadTranscriptTokens() async {
        // Skip if the stats endpoint already has real token data.
        if let stats, (stats.tokens.inputTokens + stats.tokens.outputTokens
                       + stats.tokens.cacheReadTokens + stats.tokens.cacheWriteTokens) > 0 {
            return
        }
        var totals = TokenTotals.zero
        var before: Int? = nil
        var partial = false
        let maxPages = 12   // 200 msgs/page → up to ~2400 messages
        for page in 0..<maxPages {
            guard let resp = try? await state.fetchTranscript(sessionId, before: before) else { break }
            for msg in resp.messages {
                if let u = msg.usage { totals.add(u) }
            }
            if resp.hasMore, let first = resp.firstLine {
                before = first
                if page == maxPages - 1 { partial = true }
            } else {
                break
            }
        }
        await MainActor.run {
            self.transcriptTokens = totals
            self.transcriptPartial = partial
        }
    }
}

/// Simple aggregate of the four token dimensions.
struct TokenTotals {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    static let zero = TokenTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    var grandTotal: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ u: TranscriptUsage) {
        input += u.inputTokens
        output += u.outputTokens
        cacheRead += u.cacheReadTokens
        cacheWrite += u.cacheWriteTokens
    }
}

struct MiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(radius: 12)
    }
}

// MARK: - Git Context Card

struct GitContextCard: View {
    let git: GitInfo

    private var hasAny: Bool {
        git.branch != nil || git.lastCommit != nil || git.remoteURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Git Context")

            if hasAny {
                if let branch = git.branch {
                    row(label: "Branch", systemImage: "arrow.triangle.branch") {
                        Text(branch)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        copyButton(branch)
                    }
                }
                if let commit = git.lastCommit {
                    row(label: "Last commit", systemImage: "checkmark.seal") {
                        Text(commit)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }
                }
                if let remote = git.remoteURL {
                    row(label: "Remote", systemImage: "link") {
                        if let url = git.remoteWebURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(url.host.map { $0 + url.path } ?? url.absoluteString)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.cyan)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(remote)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                // Status badge
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(git.isDirty ? .yellow : .green)
                    Text(git.isDirty ? "Dirty (uncommitted changes)" : "Clean working tree")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else {
                Text("Not a git repository")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    @ViewBuilder
    private func row<Content: View>(label: String,
                                    systemImage: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Copy branch name")
    }
}

// MARK: - Agents Tab

struct SessionAgentsTab: View {
    let agents: [Agent]

    private var mainAgents: [Agent]  { agents.filter { $0.type == .main } }
    private var subAgents:  [Agent]  { agents.filter { $0.type == .subagent } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if agents.isEmpty {
                    EmptyStateView(icon: "person.2", title: "No Agents", message: "Agents will appear here once the session starts.")
                        .frame(height: 200)
                } else {
                    ForEach(mainAgents) { agent in
                        AgentCard(agent: agent, children: subAgents.filter { $0.parentAgentId == agent.id })
                    }
                    let orphans = subAgents.filter { sub in !mainAgents.contains(where: { $0.id == sub.parentAgentId }) }
                    if !orphans.isEmpty {
                        ForEach(orphans) { agent in AgentCard(agent: agent, children: []) }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AgentCard: View {
    let agent: Agent
    let children: [Agent]
    @State private var expanded = true
    private let color: Color

    init(agent: Agent, children: [Agent]) {
        self.agent = agent
        self.children = children
        self.color = Theme.color(agent: agent.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main agent row
            HStack(spacing: 12) {
                Image(systemName: agentIcon(agent.type, subtype: agent.subagentType))
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(agent.name)
                            .font(.callout.weight(.semibold))
                        if let sub = agent.subagentType {
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let task = agent.task {
                        Text(task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let tool = agent.currentTool {
                        Label(tool, systemImage: "wrench")
                            .font(.caption2).foregroundStyle(.cyan)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(label: agent.status.rawValue.capitalized, color: color)
                    Text(Theme.shortDate(agent.startedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !children.isEmpty {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            // Children
            if expanded && !children.isEmpty {
                Divider().opacity(0.3).padding(.leading, 56)
                ForEach(children) { child in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 2)
                            .padding(.leading, 32).padding(.vertical, 4)
                        AgentChildRow(agent: child)
                    }
                    if child.id != children.last?.id {
                        Divider().opacity(0.15).padding(.leading, 56)
                    }
                }
            }
        }
        .glassCard()
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }
}

struct AgentChildRow: View {
    let agent: Agent
    private let color: Color

    init(agent: Agent) {
        self.agent = agent
        self.color = Theme.color(agent: agent.status)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agentIcon(agent.type, subtype: agent.subagentType))
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.subagentType ?? agent.name)
                    .font(.caption.weight(.medium))
                if let task = agent.task {
                    Text(task).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            StatusBadge(label: agent.status.rawValue.capitalized, color: color)
            Text(Theme.shortDate(agent.startedAt))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Events Tab

struct SessionEventsTab: View {
    let events: [DashboardEvent]
    let sessionId: String
    @State private var typeFilter: String? = nil

    private var eventTypes: [String] { Array(Set(events.map(\.eventType))).sorted() }
    private var filtered: [DashboardEvent] {
        guard let f = typeFilter else { return events }
        return events.filter { $0.eventType == f }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Type filter
            if !eventTypes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", active: typeFilter == nil) { typeFilter = nil }
                        ForEach(eventTypes, id: \.self) { t in
                            FilterChip(label: t, active: typeFilter == t) {
                                typeFilter = typeFilter == t ? nil : t
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 12)
                Divider().opacity(0.3)
            }

            if events.isEmpty {
                EmptyStateView(icon: "bolt.slash", title: "No Events", message: "Events will appear as the session runs.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { event in
                        EventRow(event: event)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 24, bottom: 3, trailing: 24))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct EventRow: View {
    let event: DashboardEvent
    @State private var expanded = false
    private let color: Color

    init(event: DashboardEvent) {
        self.event = event
        let t = event.eventType.lowercased()
        if t.contains("error") || t.contains("fail") { color = .red }
        else if t.contains("stop") { color = .orange }
        else if t.contains("start") { color = .cyan }
        else if t.contains("tool") { color = Theme.accent }
        else { color = .secondary }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(event.eventType)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                        if let tool = event.toolName {
                            Text("· \(tool)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Theme.shortDate(event.createdAt))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let summary = event.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }
                }

                if event.summary?.count ?? 0 > 80 {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { if event.summary?.count ?? 0 > 40 { expanded.toggle() } }
        }
        .glassCard(radius: 10)
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }
}

// MARK: - Conversation Tab

/// Reports where the bottom-of-list sentinel currently sits, in the
/// coordinate space of the ScrollView's containing `GeometryReader` (fixed
/// to the viewport, not the scrolling content) — used to tell whether the
/// user is following along at the bottom or has scrolled up to read.
private struct BottomAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ConversationTabView: View {
    let sessionId: String
    @Environment(AppState.self) var state
    @State private var messages: [TranscriptMessage] = []
    @State private var isLoading = false
    @State private var hasMore = false
    @State private var firstLine: Int? = nil
    @State private var lastLine: Int? = nil
    @State private var isAppendingLive = false
    @State private var appendDebounce: Task<Void, Never>? = nil
    @State private var isNearBottom = true
    @State private var pendingNewCount = 0

    var body: some View {
        Group {
            if isLoading && messages.isEmpty {
                LoadingView()
            } else if messages.isEmpty {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "No Transcript",
                    message: "Transcript is not available for this session."
                )
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottom) {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    if hasMore {
                                        Button("Load earlier messages") {
                                            Task { await loadMore() }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.cyan)
                                        .padding(.top, 8)
                                    }
                                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                                        MessageBubbleView(message: message)
                                    }
                                    Color.clear
                                        .frame(height: 1)
                                        .id("bottomAnchor")
                                        .background(
                                            GeometryReader { anchor in
                                                Color.clear.preference(
                                                    key: BottomAnchorKey.self,
                                                    value: anchor.frame(in: .named("conversationViewport")).minY
                                                )
                                            }
                                        )
                                }
                                .padding(16)
                            }
                            .onPreferenceChange(BottomAnchorKey.self) { minY in
                                // Sentinel visible within ~120pt of the viewport's
                                // bottom edge counts as "following along".
                                let nearBottom = minY <= viewport.size.height + 120
                                if nearBottom != isNearBottom {
                                    isNearBottom = nearBottom
                                    if nearBottom { pendingNewCount = 0 }
                                }
                            }

                            if pendingNewCount > 0 {
                                Button {
                                    withAnimation { proxy.scrollTo("bottomAnchor", anchor: .bottom) }
                                    pendingNewCount = 0
                                } label: {
                                    Label("\(pendingNewCount) new message\(pendingNewCount == 1 ? "" : "s")", systemImage: "arrow.down")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Theme.accent.opacity(0.85))
                                        .foregroundStyle(.black)
                                        .clipShape(Capsule())
                                        .shadow(radius: 8)
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .coordinateSpace(name: "conversationViewport")
                        .onChange(of: messages.count) { _, _ in
                            if isNearBottom {
                                withAnimation { proxy.scrollTo("bottomAnchor", anchor: .bottom) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: sessionId) { await loadTranscript() }
        .onChange(of: state.transcriptEventTick[sessionId]) { _, _ in
            scheduleLiveAppend()
        }
        .onDisappear { appendDebounce?.cancel() }
    }

    private func loadTranscript() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await state.fetchTranscript(sessionId)
            messages = resp.messages
            hasMore = resp.hasMore
            firstLine = resp.firstLine
            lastLine = resp.lastLine
        } catch {}
    }

    private func loadMore() async {
        guard let before = firstLine else { return }
        do {
            let resp = try await state.fetchTranscript(sessionId, before: before)
            messages = resp.messages + messages
            hasMore = resp.hasMore
            firstLine = resp.firstLine
        } catch {}
    }

    /// New hook events can burst (several PostToolUse events in quick
    /// succession); debounce so a run of events triggers one fetch instead
    /// of one per event.
    private func scheduleLiveAppend() {
        appendDebounce?.cancel()
        appendDebounce = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await appendLiveMessages()
        }
    }

    private func appendLiveMessages() async {
        guard var cursor = lastLine, !isAppendingLive else { return }
        isAppendingLive = true
        defer { isAppendingLive = false }
        // Cap the number of forward pages drained per burst so a pathological
        // number of new lines can't stall the debounce loop indefinitely —
        // any remainder is picked up by the next tick.
        for _ in 0..<5 {
            guard let resp = try? await state.fetchTranscript(sessionId, after: cursor, limit: 200) else { break }
            guard !resp.messages.isEmpty else { break }
            messages.append(contentsOf: resp.messages)
            cursor = resp.lastLine ?? cursor
            lastLine = cursor
            if !isNearBottom { pendingNewCount += resp.messages.count }
            guard resp.hasMore else { break }
        }
    }
}

private struct ThinkingBlockView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.accentText)
                    Text("Thinking")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentText)
                    Text("· \(text.count) chars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().opacity(0.4)
                ScrollView {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.20), lineWidth: 0.75)
        )
    }
}

struct MessageBubbleView: View {
    let message: TranscriptMessage
    @State private var expandedIdx: Int? = nil

    private var isUser: Bool { message.type == "user" }
    private var roleColor: Color { isUser ? .accentColor : Theme.accent }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(isUser ? "You" : "Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                    .padding(.horizontal, 4)
                ForEach(Array(message.content.enumerated()), id: \.offset) { idx, block in
                    contentBlock(block, idx: idx)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func contentBlock(_ block: TranscriptContent, idx: Int) -> some View {
        switch block.type {
        case "text":
            if let text = block.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(isUser ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case "tool_use":
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedIdx = expandedIdx == idx ? nil : idx
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                        Text(block.name ?? "tool")
                        Spacer()
                        Image(systemName: expandedIdx == idx ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                if expandedIdx == idx, let input = block.toolInput {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(input)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        case "thinking":
            if let text = block.text {
                ThinkingBlockView(text: text)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Thinking Tab

private struct ThinkingTabView: View {
    let sessionId: String
    @Environment(AppState.self) var state
    @State private var messages: [TranscriptMessage] = []
    @State private var isLoading = false
    @State private var hasLoaded = false

    struct ThinkingEntry: Identifiable {
        let id = UUID()
        let timestamp: Date?
        let model: String?
        let text: String
    }

    private var thinkingEntries: [ThinkingEntry] {
        messages.compactMap { msg -> ThinkingEntry? in
            let blocks = msg.content.filter { $0.type == "thinking" && $0.text != nil }
            guard !blocks.isEmpty else { return nil }
            return blocks.first.map { block in
                ThinkingEntry(timestamp: msg.timestamp, model: msg.model, text: block.text!)
            }
        }
    }

    var body: some View {
        Group {
            if isLoading && !hasLoaded {
                ProgressView("Loading thinking blocks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if thinkingEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "brain").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No thinking blocks found")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Extended thinking was not enabled in this session, or no thinking data is available.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        HStack {
                            Text("\(thinkingEntries.count) thinking block\(thinkingEntries.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(thinkingEntries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    if let ts = entry.timestamp {
                                        Text(Theme.shortDate(ts))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    if let model = entry.model {
                                        Text(model)
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("\(entry.text.count) chars")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                ThinkingBlockView(text: entry.text)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task(id: sessionId) {
            guard !hasLoaded else { return }
            isLoading = true
            do {
                let resp = try await state.fetchTranscript(sessionId)
                messages = resp.messages
                hasLoaded = true
            } catch {}
            isLoading = false
        }
    }
}

#endif
