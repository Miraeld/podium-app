import SwiftUI
import UniformTypeIdentifiers

enum SessionTab: String, CaseIterable {
    case overview      = "Overview"
    case agents        = "Agents"
    case events        = "Events"
    case conversation  = "Conversation"
    case thinking      = "Thinking"
    case cost          = "Cost"
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

                    // Annotation card
                    SessionAnnotationView(sessionId: sessionId)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)

                    // Tab picker
                    HStack(spacing: 0) {
                        ForEach(SessionTab.allCases, id: \.self) { t in
                            TabButton(title: t.rawValue, selected: tab == t) { tab = t }
                        }
                    }
                    .padding(.horizontal, 24)
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
                    case .conversation:
                        ConversationTabView(sessionId: sessionId)
                    case .thinking:
                        ThinkingTabView(sessionId: sessionId)
                    case .cost:
                        CostTabView(sessionId: sessionId)
                    }
                }
            } else {
                LoadingView()
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
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
                } label: {
                    if isExporting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .help("Export session as JSON")
                .disabled(isExporting)
            }
        }
        .task(id: sessionId) {
            await state.loadSessionDetail(sessionId)
            await state.loadSessionStats(sessionId)
            await state.loadSessionCost(sessionId)
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
                HStack(spacing: 10) {
                    StatusDot(color: color, active: session.status == .active)
                    Text(session.name ?? Theme.projectName(from: session.cwd))
                        .font(.title2.weight(.bold))
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
                Rectangle()
                    .fill(selected ? Color.cyan : .clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

// MARK: - Overview Tab

struct SessionOverviewTab: View {
    let sessionId: String
    @Environment(AppState.self) var state

    private var stats: SessionStats? { state.sessionStatsCache[sessionId] }
    private var cost: CostResult?  { state.sessionCostCache[sessionId] }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if let stats {
                    // Token stats
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Token Usage")
                        let total = stats.tokens.inputTokens + stats.tokens.outputTokens
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                            MiniStat(label: "Input", value: Theme.formatTokens(stats.tokens.inputTokens), color: .cyan)
                            MiniStat(label: "Output", value: Theme.formatTokens(stats.tokens.outputTokens), color: Color(red: 0.6, green: 0.4, blue: 1))
                            MiniStat(label: "Cache Read", value: Theme.formatTokens(stats.tokens.cacheReadTokens), color: .green)
                            MiniStat(label: "Cache Write", value: Theme.formatTokens(stats.tokens.cacheWriteTokens), color: .yellow)
                        }
                        // Progress bars
                        if total > 0 {
                            VStack(spacing: 8) {
                                TokenBar(label: "Input", value: stats.tokens.inputTokens, max: total, color: .cyan)
                                TokenBar(label: "Output", value: stats.tokens.outputTokens, max: total, color: Color(red: 0.6, green: 0.4, blue: 1))
                                TokenBar(label: "Cache Read", value: stats.tokens.cacheReadTokens, max: total, color: .green)
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

                    // Cost
                    if let cost, cost.totalCost > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Cost Breakdown")
                            HStack {
                                Text("Total").font(.callout)
                                Spacer()
                                Text(Theme.formatCost(cost.totalCost))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                            Divider().opacity(0.3)
                            ForEach(cost.breakdown) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.model).font(.caption).lineLimit(1)
                                        Text("\(Theme.formatTokens(item.inputTokens)) in / \(Theme.formatTokens(item.outputTokens)) out")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Theme.formatCost(item.cost))
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                        .padding(Theme.cardPadding)
                        .glassCard()
                    }

                    // Top tools
                    if !stats.toolsUsed.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Top Tools Used")
                            MiniBarChart(
                                items: stats.toolsUsed.prefix(10).map { ($0.toolName, $0.count) },
                                color: Color(red: 0.6, green: 0.4, blue: 1)
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
        else if t.contains("tool") { color = Color(red: 0.6, green: 0.4, blue: 1) }
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

struct ConversationTabView: View {
    let sessionId: String
    @Environment(AppState.self) var state
    @State private var messages: [TranscriptMessage] = []
    @State private var isLoading = false
    @State private var hasMore = false
    @State private var firstLine: Int? = nil

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
                    }
                    .padding(16)
                }
            }
        }
        .task(id: sessionId) { await loadTranscript() }
    }

    private func loadTranscript() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await state.fetchTranscript(sessionId)
            messages = resp.messages
            hasMore = resp.hasMore
            firstLine = resp.firstLine
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
                        .foregroundStyle(Color.indigo)
                    Text("Thinking")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.indigo)
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
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.20), lineWidth: 0.75)
        )
    }
}

struct MessageBubbleView: View {
    let message: TranscriptMessage
    @State private var expandedIdx: Int? = nil

    private var isUser: Bool { message.type == "user" }
    private var roleColor: Color { isUser ? .accentColor : Color(red: 0.6, green: 0.4, blue: 1) }

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
                    .foregroundStyle(Color(red: 0.6, green: 0.4, blue: 1))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(red: 0.6, green: 0.4, blue: 1).opacity(0.1))
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

// MARK: - Cost Tab

struct CostTabView: View {
    let sessionId: String
    @Environment(AppState.self) var state

    private var cost: CostResult? { state.sessionCostCache[sessionId] }

    var body: some View {
        Group {
            if let c = cost {
                ScrollView {
                    VStack(spacing: 16) {
                        // Total cost header card
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Cost").font(.headline)
                                Text(Theme.formatCost(c.totalCost))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.1, green: 0.82, blue: 0.48))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                let totalInput = c.breakdown.reduce(0) { $0 + $1.inputTokens }
                                let totalOutput = c.breakdown.reduce(0) { $0 + $1.outputTokens }
                                Label(Theme.formatTokens(totalInput), systemImage: "arrow.down.circle")
                                    .font(.callout).foregroundStyle(.cyan)
                                Label(Theme.formatTokens(totalOutput), systemImage: "arrow.up.circle")
                                    .font(.callout).foregroundStyle(Color(red: 0.6, green: 0.4, blue: 1))
                            }
                        }
                        .padding(Theme.cardPadding)
                        .glassCard()

                        // Per-model breakdown
                        if !c.breakdown.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Input").frame(width: 80, alignment: .trailing)
                                    Text("Output").frame(width: 80, alignment: .trailing)
                                    Text("Cost").frame(width: 70, alignment: .trailing)
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                Divider().opacity(0.3)
                                ForEach(c.breakdown) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.model).font(.caption).lineLimit(1)
                                            if let rule = item.matchedRule {
                                                Text(rule).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(Theme.formatTokens(item.inputTokens))
                                            .font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                                        Text(Theme.formatTokens(item.outputTokens))
                                            .font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                                        Text(Theme.formatCost(item.cost))
                                            .font(.caption.weight(.semibold).monospacedDigit()).frame(width: 70, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    Divider().opacity(0.2)
                                }
                            }
                            .glassCard()
                        }
                    }
                    .padding(16)
                }
            } else {
                EmptyStateView(
                    icon: "dollarsign.circle",
                    title: "Cost Unavailable",
                    message: "Cost data is not available for this session."
                )
            }
        }
        .task(id: sessionId) { await state.loadSessionCost(sessionId) }
    }
}
