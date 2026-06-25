import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) var state

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                // Stat cards row
                if let stats = state.stats {
                    StatsRow(stats: stats, cost: state.totalCost?.totalCost)
                } else if state.isLoading && state.stats == nil {
                    ProgressView().tint(.cyan).frame(maxWidth: .infinity)
                }

                // Active agents / recent sessions + live feed
                HStack(alignment: .top, spacing: 20) {
                    // Left column: active agents tree, fall back to recent sessions
                    VStack(alignment: .leading, spacing: 14) {
                        if !state.activeAgents.isEmpty {
                            ActiveAgentsSection()
                        } else {
                            SectionHeader(title: "Recent Sessions", trailing: "\(state.sessions.count) total")
                            ForEach(state.sessions.prefix(8)) { session in
                                SessionRow(session: session)
                            }
                            if state.sessions.isEmpty && !state.isLoading {
                                EmptyStateView(
                                    icon: "clock",
                                    title: "No Sessions",
                                    message: "Start Claude Code to see sessions appear here."
                                )
                                .frame(height: 200)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Live event feed
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            SectionHeader(title: "Live Feed")
                            Spacer()
                            if state.wsConnected { LiveBadge() }
                        }
                        if state.recentEvents.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.tertiary)
                                Text("Waiting for events…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 150)
                        } else {
                            ForEach(state.recentEvents.prefix(15)) { event in
                                EventFeedRow(event: event)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        state.selectedSessionId = event.sessionId
                                        state.navigationRequest = .sessions
                                    }
                            }
                            Button {
                                state.navigationRequest = .activityFeed
                            } label: {
                                Text("View All")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.cyan)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 340)
                    .padding(Theme.cardPadding)
                    .glassCard()
                }
            }
            .padding(24)
        }
        .task {
            await state.loadActiveAgents()
        }
    }
}

// MARK: - Active Agents Section

private struct ActiveAgentsSection: View {
    @Environment(AppState.self) var state
    @State private var expandedIds: Set<String> = []

    private var mainAgents: [Agent] {
        state.activeAgents.filter { $0.type == .main }
    }

    private var orphanedSubagents: [Agent] {
        let mainIds = Set(mainAgents.map(\.id))
        return state.activeAgents.filter { agent in
            agent.type == .subagent &&
            (agent.parentAgentId == nil || !mainIds.contains(agent.parentAgentId ?? ""))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Active Agents", trailing: "\(state.activeAgents.count) running")

            if state.activeAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No active agents")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Sessions will appear here when Claude Code is running.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                // Main agents with their children
                ForEach(mainAgents) { mainAgent in
                    let children = state.activeAgents.filter { $0.parentAgentId == mainAgent.id }
                    let isExpanded = expandedIds.contains(mainAgent.id)

                    VStack(alignment: .leading, spacing: 0) {
                        // Main agent row with disclosure triangle
                        HStack(spacing: 8) {
                            if !children.isEmpty {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                    .onTapGesture {
                                        if isExpanded {
                                            expandedIds.remove(mainAgent.id)
                                        } else {
                                            expandedIds.insert(mainAgent.id)
                                        }
                                    }
                            } else {
                                Spacer().frame(width: 20)
                            }
                            AgentRow(agent: mainAgent)
                        }

                        // Subagent rows (indented)
                        if isExpanded {
                            ForEach(children) { child in
                                AgentRow(agent: child)
                                    .padding(.leading, 24)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(Theme.color(agent: child.status).opacity(0.6))
                                            .frame(width: 2)
                                            .padding(.leading, 12)
                                    }
                            }
                        }
                    }
                }

                // Orphaned subagents (no visible parent)
                ForEach(orphanedSubagents) { agent in
                    AgentRow(agent: agent)
                }
            }
        }
        .onAppear {
            // Default: expand all main agents
            for agent in mainAgents {
                expandedIds.insert(agent.id)
            }
        }
        .onChange(of: state.activeAgents) { _, agents in
            // Auto-expand newly appearing main agents
            for agent in agents where agent.type == .main {
                if !expandedIds.contains(agent.id) {
                    expandedIds.insert(agent.id)
                }
            }
        }
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: Agent
    @Environment(AppState.self) var state

    private var agentColor: Color { Theme.color(agent: agent.status) }
    private var isActive: Bool { agent.status == .working || agent.status == .waiting }

    private var displayName: String {
        if agent.name.isEmpty {
            return agent.subagentType ?? agent.type.rawValue
        }
        return agent.name
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: agentColor, active: isActive)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let task = agent.task, !task.isEmpty {
                    Text(task)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let tool = agent.currentTool {
                    Text(tool)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.15))
                        .foregroundStyle(.cyan)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                StatusBadge(label: agent.status.rawValue.capitalized, color: agentColor)
                Text(Theme.shortDate(agent.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard()
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedSessionId = agent.sessionId
            state.navigationRequest = .sessions
        }
    }
}

// MARK: - Stats Row

struct StatsRow: View {
    let stats: Stats
    var cost: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 16) {
                StatCard(
                    title: "Active Sessions",
                    value: "\(stats.activeSessions)",
                    icon: "clock.fill",
                    color: .cyan,
                    subtitle: "\(stats.totalSessions) total"
                )
                StatCard(
                    title: "Active Agents",
                    value: "\(stats.activeAgents)",
                    icon: "person.fill.badge.clock",
                    color: Theme.accent,
                    subtitle: "\(stats.totalAgents) total"
                )
                StatCard(
                    title: "Events Today",
                    value: Theme.formatTokens(stats.eventsToday),
                    icon: "bolt.fill",
                    color: .yellow,
                    subtitle: "\(Theme.formatTokens(stats.totalEvents)) total"
                )
                StatCard(
                    title: "Listeners",
                    value: "\(stats.wsConnections)",
                    icon: "dot.radiowaves.left.and.right",
                    color: Color(red: 0.2, green: 0.9, blue: 0.55),
                    subtitle: "live WS"
                )
            }
            if let cost = cost {
                Text("Total cost \(Theme.formatCost(cost)) all-time")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Session Row (dashboard)

struct SessionRow: View {
    let session: Session
    @Environment(AppState.self) var state
    let color: Color

    init(session: Session) {
        self.session = session
        self.color = Theme.color(session: session.status)
    }

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(color: color, active: session.status == .active)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? Theme.projectName(from: session.cwd))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                StatusBadge(label: session.status.label, color: color)
                HStack(spacing: 6) {
                    if let agents = session.agentCount, agents > 0 {
                        Label("\(agents)", systemImage: "person.2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let cost = session.cost, cost > 0 {
                        Text(Theme.formatCost(cost))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(Theme.shortDate(session.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard()
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedSessionId = session.id
            state.navigationRequest = .sessions
        }
    }
}

// MARK: - Event Feed Row

struct EventFeedRow: View {
    let event: DashboardEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor)
                .frame(width: 3)
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.eventType)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(eventColor)
                    Spacer()
                    Text(Theme.shortDate(event.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let tool = event.toolName {
                    Text(tool)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        Divider().opacity(0.3)
    }

    private var eventColor: Color {
        let t = event.eventType.lowercased()
        if t.contains("error") || t.contains("fail") { return .red }
        if t.contains("stop") { return .orange }
        if t.contains("start") { return .cyan }
        if t.contains("tool") { return Theme.accent }
        return .secondary
    }
}
