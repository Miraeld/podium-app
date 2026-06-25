import SwiftUI
import Charts

// MARK: - Session date filter helper

private extension Array where Element == Session {
    func filtered(by range: TimeRange) -> [Session] {
        guard let days = range.days else { return self }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return self }
        return self.filter { s in
            let reference = s.lastActivity ?? s.updatedAt
            return reference >= cutoff || s.startedAt >= cutoff
        }
    }
}

// MARK: - WorkflowsView

struct WorkflowsView: View {
    @Environment(AppState.self) var state
    @State private var selectedSessionId: String? = nil
    @State private var workflowData: WorkflowSessionRaw? = nil
    @State private var isLoadingWorkflow = false
    @State private var loaded = false
    @State private var range: TimeRange = .week

    private var filteredSessions: [Session] {
        state.sessions.filtered(by: range)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                workflowStatsRow

                sessionDrilldownSection

                if let analytics = state.analytics, !analytics.agentTypes.isEmpty {
                    agentTypeSection(analytics.agentTypes)
                }

                if let analytics = state.analytics, !analytics.toolUsage.isEmpty {
                    toolFlowSection(analytics.toolUsage)
                }

                if !filteredSessions.isEmpty {
                    complexitySection
                }

                patternSection
            }
            .padding(24)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if state.sessions.isEmpty { await state.refresh() }
            await state.loadAnalytics()
        }
        .onChange(of: selectedSessionId) { _, id in
            guard let id else { workflowData = nil; return }
            isLoadingWorkflow = true
            Task {
                workflowData = try? await state.loadWorkflow(id)
                isLoadingWorkflow = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Time range", selection: $range) {
                    ForEach(TimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            ToolbarItem(placement: .automatic) {
                Picker("Session", selection: $selectedSessionId) {
                    Text("Overview").tag(nil as String?)
                    ForEach(Array(state.sessions.prefix(50))) { s in
                        Text(s.name ?? Theme.projectName(from: s.cwd)).tag(s.id as String?)
                    }
                }
                .frame(width: 220)
            }
            ToolbarItem {
                Button {
                    Task { await state.loadAnalytics() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Stats Row

    @ViewBuilder
    var workflowStatsRow: some View {
        let sessions = filteredSessions
        let totalSessions = sessions.count
        let totalAgents = sessions.compactMap(\.agentCount).reduce(0, +)
        let avgSubagents: Double = totalSessions > 0
            ? Double(totalAgents) / Double(totalSessions)
            : 0
        let peakConcurrency = state.stats?.activeAgents ?? 0

        HStack(spacing: 16) {
            StatCard(
                title: "Total Sessions",
                value: "\(totalSessions)",
                icon: "folder.badge.gearshape",
                color: .cyan
            )
            StatCard(
                title: "Total Agents",
                value: "\(totalAgents)",
                icon: "person.3.fill",
                color: Color(red: 0.6, green: 0.4, blue: 1.0)
            )
            StatCard(
                title: "Avg Agents/Session",
                value: String(format: "%.1f", avgSubagents),
                icon: "chart.bar.fill",
                color: Color(red: 0.1, green: 0.82, blue: 0.48)
            )
            StatCard(
                title: "Peak Concurrency",
                value: "\(peakConcurrency)",
                icon: "bolt.fill",
                color: Color(red: 0.85, green: 0.78, blue: 0.1)
            )
        }
    }

    // MARK: - Session Drilldown

    @ViewBuilder
    var sessionDrilldownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header row with inline session picker
            HStack(spacing: 12) {
                Text("SESSION DRILLDOWN")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                if selectedSessionId != nil {
                    Text("Agent Tree")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("Session", selection: $selectedSessionId) {
                    Text("None selected").tag(nil as String?)
                    ForEach(Array(state.sessions.prefix(50))) { s in
                        Text(s.name ?? Theme.projectName(from: s.cwd)).tag(s.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
            }

            if selectedSessionId == nil {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle.dotted")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Select a session above to drill into its workflow.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    Spacer()
                }
                .glassCard()
            } else if isLoadingWorkflow {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView().tint(.cyan)
                        Text("Loading workflow…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(40)
                    Spacer()
                }
                .glassCard()
            } else if let workflow = workflowData {
                VStack(alignment: .leading, spacing: 0) {
                    // Session header
                    HStack(spacing: 10) {
                        StatusDot(
                            color: Theme.color(session: workflow.session.status),
                            active: workflow.session.status == .active
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.session.name ?? Theme.projectName(from: workflow.session.cwd))
                                .font(.headline)
                            Text(Theme.shortDate(workflow.session.startedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            label: workflow.session.status.label,
                            color: Theme.color(session: workflow.session.status)
                        )
                        Text("\(workflow.tree.count) top-level agent\(workflow.tree.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                    Divider().opacity(0.15)

                    // Agent tree
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(workflow.tree) { node in
                            AgentTreeNodeView(node: node, depth: 0)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .glassCard()
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("No workflow data available for this session.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    Spacer()
                }
                .glassCard()
            }
        }
    }

    // MARK: - Agent Type Distribution

    @ViewBuilder
    func agentTypeSection(_ types: [Analytics.AgentTypeStat]) -> some View {
        let sorted = types.sorted { $0.count > $1.count }.prefix(10)
        let total = sorted.reduce(0) { $0 + $1.count }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Agent Type Distribution", trailing: "\(sorted.count) types")
                Spacer()
                Text("All time")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 0) {
                Chart(Array(sorted)) { stat in
                    BarMark(
                        x: .value("Count", stat.count),
                        y: .value("Type", stat.subagentType ?? "orchestrator")
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.3, green: 0.6, blue: 1), Color(red: 0.6, green: 0.3, blue: 1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .annotation(position: .trailing) {
                        let pct = total > 0 ? Int(Double(stat.count) / Double(total) * 100) : 0
                        Text("\(stat.count) (\(pct)%)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: CGFloat(sorted.count) * 32 + 40)
                .padding(20)
            }
            .glassCard()
        }
    }

    // MARK: - Tool Execution Flow

    @ViewBuilder
    func toolFlowSection(_ tools: [Analytics.ToolUsageStat]) -> some View {
        let sorted = tools.sorted { $0.count > $1.count }.prefix(12)
        let maxCount = sorted.map(\.count).max() ?? 1

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Tool Usage Across All Sessions", trailing: "\(sorted.count) tools")
                Spacer()
                Text("All time")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sorted)) { stat in
                    HStack(spacing: 10) {
                        Text(stat.toolName)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .trailing)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.primary.opacity(0.07))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: [.cyan, Color(red: 0.2, green: 0.5, blue: 0.9)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: geo.size.width * (Double(stat.count) / Double(maxCount)))
                            }
                        }
                        .frame(height: 16)
                        Text("\(stat.count) calls")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .glassCard()
        }
    }

    // MARK: - Session Complexity

    @ViewBuilder
    var complexitySection: some View {
        let sessions = filteredSessions
        let maxAgents = sessions.compactMap(\.agentCount).max() ?? 1
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Session Complexity (by agent count)",
                trailing: "\(sessions.count) sessions"
            )

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(sessions.prefix(40)) { session in
                    SessionComplexityTile(session: session, maxAgents: maxAgents)
                }
            }
        }
    }

    // MARK: - Workflow Patterns

    @ViewBuilder
    var patternSection: some View {
        let sessions = filteredSessions
        let total = sessions.count

        let deepOrchestration = sessions.filter { ($0.agentCount ?? 0) > 5 }.count
        let deepPct = total > 0 ? Int(Double(deepOrchestration) / Double(total) * 100) : 0

        let errorSessions = sessions.filter { $0.status == .error }.count
        let errorPct = total > 0 ? Int(Double(errorSessions) / Double(total) * 100) : 0

        let longRunning: Int = {
            sessions.filter { s in
                let end = s.endedAt ?? Date()
                return end.timeIntervalSince(s.startedAt) > 3600
            }.count
        }()

        let bashHeavy: Bool = {
            guard let tools = state.analytics?.toolUsage, !tools.isEmpty else { return false }
            let totalCalls = tools.reduce(0) { $0 + $1.count }
            let bashCalls = tools.first(where: { $0.toolName.lowercased() == "bash" })?.count ?? 0
            return totalCalls > 0 && Double(bashCalls) / Double(totalCalls) > 0.5
        }()

        let patterns: [(icon: String, title: String, metric: String, description: String, color: Color)] = [
            (
                icon: "arrow.triangle.branch",
                title: "Deep Orchestration",
                metric: "\(deepOrchestration) (\(deepPct)%)",
                description: "Sessions spawning more than 5 agents, indicating complex multi-agent workflows.",
                color: Color(red: 0.4, green: 0.6, blue: 1.0)
            ),
            (
                icon: "exclamationmark.octagon",
                title: "High Error Rate",
                metric: "\(errorSessions) (\(errorPct)%)",
                description: "Sessions that ended in an error state, potentially due to tool failures or API issues.",
                color: Color(red: 1, green: 0.35, blue: 0.35)
            ),
            (
                icon: "clock.fill",
                title: "Long-Running Sessions",
                metric: "\(longRunning)",
                description: "Sessions running for more than 1 hour, indicating heavy workloads or waiting states.",
                color: Color(red: 0.85, green: 0.65, blue: 0.1)
            ),
            (
                icon: "terminal.fill",
                title: "Tool-Heavy Workflows",
                metric: bashHeavy ? "Bash > 50%" : "Balanced",
                description: bashHeavy
                    ? "Bash calls dominate tool usage — sessions are heavily script-oriented."
                    : "Tool usage is spread across multiple tool types.",
                color: bashHeavy ? Color(red: 0.1, green: 0.82, blue: 0.48) : .secondary
            )
        ]

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Workflow Patterns", trailing: "\(patterns.count) insights")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(Array(patterns.enumerated()), id: \.offset) { _, p in
                    PatternCard(
                        icon: p.icon,
                        title: p.title,
                        metric: p.metric,
                        description: p.description,
                        color: p.color
                    )
                }
            }
        }
    }
}

// MARK: - Agent Tree Node View

struct AgentTreeNodeView: View {
    let node: AgentTreeNode
    let depth: Int
    @State private var expanded = true

    private var agentColor: Color { Theme.color(agent: node.status) }

    private var duration: String? {
        guard let end = node.endedAt else {
            if node.status == .working || node.status == .waiting {
                return Theme.shortDate(node.startedAt)
            }
            return nil
        }
        let secs = Int(end.timeIntervalSince(node.startedAt))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m \(secs % 60)s" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if node.children.isEmpty {
                // Leaf node — no disclosure group
                nodeRow
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(node.children) { child in
                            AgentTreeNodeView(node: child, depth: depth + 1)
                        }
                    }
                    .padding(.leading, 16)
                    .overlay(
                        Rectangle()
                            .fill(agentColor.opacity(0.25))
                            .frame(width: 2),
                        alignment: .leading
                    )
                } label: {
                    nodeRow
                }
                .disclosureGroupStyle(PlainDisclosureGroupStyle())
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    var nodeRow: some View {
        HStack(spacing: 10) {
            StatusDot(
                color: agentColor,
                active: node.status == .working
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(depth == 0 ? .callout.weight(.semibold) : .caption.weight(.medium))
                        .lineLimit(1)

                    if let sub = node.subagentType {
                        StatusBadge(label: sub, color: agentColor)
                    } else if node.type == .main {
                        StatusBadge(label: "main", color: .cyan)
                    }
                }

                if let task = node.task {
                    Text(task)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let dur = duration {
                    Text(dur)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !node.children.isEmpty {
                    Text("\(node.children.count) sub")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Plain Disclosure Group Style (no default chevron row)

struct PlainDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .padding(.leading, 6)
                }
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

// MARK: - Session Complexity Tile

struct SessionComplexityTile: View {
    let session: Session
    let maxAgents: Int

    var body: some View {
        let color = Theme.color(session: session.status)
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name ?? Theme.projectName(from: session.cwd))
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                StatusDot(
                    color: color,
                    active: session.status == .active
                )
                Text("\(session.agentCount ?? 0) agent\(session.agentCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: CGFloat(30 + (session.agentCount ?? 0) * 8))
        .glassCard(radius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Pattern Card

struct PatternCard: View {
    let icon: String
    let title: String
    let metric: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Text(metric)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(color)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .glassCard(radius: 12)
    }
}
