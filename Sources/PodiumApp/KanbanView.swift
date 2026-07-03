#if os(macOS)
import SwiftUI

// MARK: - Kanban Board Mode

private enum KanbanMode: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case agents   = "Agents"
    var id: String { rawValue }
}

// MARK: - Kanban View

struct KanbanView: View {
    @Environment(AppState.self) var state
    @State private var mode: KanbanMode = .sessions

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Kanban Board")
                    .font(.headline.weight(.semibold))
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(KanbanMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Board
            switch mode {
            case .sessions: SessionsBoard()
            case .agents:   AgentsBoard()
            }
        }
    }
}

// MARK: - Sessions Board

private struct SessionsBoard: View {
    @Environment(AppState.self) var state

    private let statuses: [String] = ["active", "waiting", "completed", "error", "abandoned"]

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(statuses, id: \.self) { status in
                        let items = sessions(for: status)
                        KanbanColumn(
                            status: status,
                            count: items.count,
                            isPulsing: status == "active" || status == "waiting"
                        ) {
                            if items.isEmpty {
                                KanbanEmptyColumn()
                            } else {
                                ForEach(items) { session in
                                    SessionKanbanCard(session: session)
                                        .onTapGesture { navigate(to: session.id) }
                                }
                            }
                        }
                        .frame(width: columnWidth(geo: geo))
                    }
                }
                .padding()
            }
        }
    }

    private func sessions(for status: String) -> [Session] {
        state.sessions
            .filter { $0.status.rawValue == status }
            .prefix(20)
            .map { $0 }
    }

    private func columnWidth(geo: GeometryProxy) -> CGFloat {
        max(200, (geo.size.width - 14 * CGFloat(statuses.count + 1)) / CGFloat(statuses.count))
    }

    private func navigate(to id: String) {
        state.selectedSessionId = id
        state.navigationRequest = .sessions
    }
}

// MARK: - Agents Board

private struct AgentsBoard: View {
    @Environment(AppState.self) var state

    private let liveStatuses: [String] = ["working", "waiting"]
    private let offlineStatuses: [String] = ["completed", "error"]

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // Live columns
                    ForEach(liveStatuses, id: \.self) { status in
                        let items = agents(for: status)
                        KanbanColumn(
                            status: status,
                            count: items.count,
                            isPulsing: true
                        ) {
                            if items.isEmpty {
                                KanbanEmptyColumn()
                            } else {
                                ForEach(items) { agent in
                                    AgentKanbanCard(agent: agent)
                                        .onTapGesture { navigate(to: agent.sessionId) }
                                }
                            }
                        }
                        .frame(width: columnWidth(geo: geo))
                    }

                    // Non-live columns: only working/waiting tracked live
                    ForEach(offlineStatuses, id: \.self) { status in
                        KanbanColumn(
                            status: status,
                            count: 0,
                            isPulsing: false
                        ) {
                            VStack(spacing: 8) {
                                Image(systemName: "clock.badge.xmark")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.tertiary)
                                Text("Not tracked live")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                        .frame(width: columnWidth(geo: geo))
                    }
                }
                .padding()
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text("Live view — only active agents shown. Completed/error agents not tracked in memory.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 12)
        }
    }

    private func agents(for status: String) -> [Agent] {
        state.activeAgents
            .filter { $0.status.rawValue == status }
            .prefix(20)
            .map { $0 }
    }

    private func columnWidth(geo: GeometryProxy) -> CGFloat {
        let cols = liveStatuses.count + offlineStatuses.count
        return max(200, (geo.size.width - 14 * CGFloat(cols + 1)) / CGFloat(cols))
    }

    private func navigate(to sessionId: String) {
        state.selectedSessionId = sessionId
        state.navigationRequest = .sessions
    }
}

// MARK: - Kanban Column

private struct KanbanColumn<Content: View>: View {
    let status: String
    let count: Int
    let isPulsing: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Column header
            HStack(spacing: 8) {
                StatusDot(color: Theme.color(for: status), active: isPulsing)
                Text(status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.color(for: status).opacity(0.18))
                        .foregroundStyle(Theme.color(for: status))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Cards
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    content()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Theme.color(for: status).opacity(0.15),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Kanban Empty Column

private struct KanbanEmptyColumn: View {
    var body: some View {
        Text("No items")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }
}

// MARK: - Session Kanban Card

private struct SessionKanbanCard: View {
    let session: Session

    private var isActive: Bool {
        session.status == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: Theme.color(session: session.status), active: isActive)
                Text(session.name ?? Theme.projectName(from: session.cwd))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusBadge(
                    label: session.status.label,
                    color: Theme.color(session: session.status)
                )
            }

            if let cwd = session.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                if let count = session.agentCount, count > 0 {
                    Label("\(count) agent\(count == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let last = session.lastActivity ?? session.updatedAt as Date? {
                    Text(Theme.shortDate(last))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .glassCard(radius: 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Agent Kanban Card

private struct AgentKanbanCard: View {
    let agent: Agent

    private var isActive: Bool {
        agent.status == .working || agent.status == .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: Theme.color(agent: agent.status), active: isActive)
                Text(agent.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if let subtype = agent.subagentType {
                    StatusBadge(label: subtype, color: .blue)
                }
                if let tool = agent.currentTool {
                    Text(tool)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.14))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
            }

            if let task = agent.task, !task.isEmpty {
                Text(task)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Text(Theme.shortDate(agent.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .glassCard(radius: 10)
        .contentShape(Rectangle())
    }
}

#endif
