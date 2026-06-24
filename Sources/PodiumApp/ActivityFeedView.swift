import SwiftUI

struct ActivityFeedView: View {
    @Environment(AppState.self) var state
    @State private var events: [DashboardEvent] = []
    @State private var totalEvents = 0
    @State private var isLoading = false
    @State private var filterType: String? = nil
    @State private var expandedIdx: Int? = nil
    @State private var isPaused = false
    @State private var bufferedEvents: [DashboardEvent] = []
    @State private var sessionNames: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().opacity(0.3)
            if isLoading && events.isEmpty {
                LoadingView()
            } else if events.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .task { await loadEvents(reset: true) }
        .onChange(of: filterType) { _, _ in Task { await loadEvents(reset: true) } }
        .onChange(of: state.recentEvents) { _, newEvents in
            guard let newest = newEvents.first else { return }
            let alreadyPresent = events.contains { $0.id == newest.id }
            guard !alreadyPresent else { return }
            let matchesFilter = filterType == nil || newest.eventType == filterType
            guard matchesFilter else { return }
            if isPaused {
                if !bufferedEvents.contains(where: { $0.id == newest.id }) {
                    bufferedEvents.insert(newest, at: 0)
                }
            } else {
                events.insert(newest, at: 0)
                totalEvents += 1
                expandedIdx = expandedIdx.map { $0 + 1 }
                Task { await fetchSessionName(for: newest.sessionId) }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", active: filterType == nil) {
                        filterType = nil
                    }
                    FilterChip(label: "Tool Call", color: .cyan, active: filterType == "tool_call") {
                        filterType = filterType == "tool_call" ? nil : "tool_call"
                    }
                    FilterChip(label: "Agent Start", color: .green, active: filterType == "agent_started") {
                        filterType = filterType == "agent_started" ? nil : "agent_started"
                    }
                    FilterChip(label: "Agent End", color: .secondary, active: filterType == "agent_completed") {
                        filterType = filterType == "agent_completed" ? nil : "agent_completed"
                    }
                    FilterChip(label: "Error", color: .red, active: filterType == "error") {
                        filterType = filterType == "error" ? nil : "error"
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            pauseButton
                .padding(.trailing, 12)
        }
    }

    // MARK: - Pause Button

    private var pauseButton: some View {
        Button {
            if isPaused {
                // Resume: flush buffer
                let fresh = bufferedEvents.filter { e in !events.contains { $0.id == e.id } }
                events.insert(contentsOf: fresh, at: 0)
                totalEvents += fresh.count
                bufferedEvents = []
                isPaused = false
            } else {
                isPaused = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.caption)
                if isPaused && !bufferedEvents.isEmpty {
                    Text("\(bufferedEvents.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.3))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isPaused ? .orange : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPaused ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isPaused ? Color.orange.opacity(0.35) : Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isPaused ? "Resume live feed" : "Pause live feed")
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if let active = filterType {
            EmptyStateView(
                icon: "bolt.slash",
                title: "No Results",
                message: "No \(active) events found."
            )
        } else {
            EmptyStateView(
                icon: "bolt.slash",
                title: "No Events Yet",
                message: "Events appear here as sessions run."
            )
        }
    }

    // MARK: - Event List

    private var eventList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                    ActivityEventRow(
                        event: event,
                        isExpanded: expandedIdx == idx,
                        sessionName: sessionName(for: event),
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedIdx = expandedIdx == idx ? nil : idx
                            }
                        },
                        onViewSession: {
                            state.selectedSessionId = event.sessionId
                            state.navigationRequest = .sessions
                        }
                    )
                    Divider().opacity(0.2)
                }
                let hasMore = events.count < totalEvents
                if hasMore {
                    Button("Load more… (\(totalEvents - events.count) remaining)") {
                        Task { await loadMore() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                    .padding()
                }
                if isLoading && !events.isEmpty {
                    ProgressView().tint(.cyan).padding()
                }
            }
        }
    }

    // MARK: - Session Name Helper

    private func sessionName(for event: DashboardEvent) -> String {
        if let sess = state.sessions.first(where: { $0.id == event.sessionId }) {
            return sess.name ?? Theme.projectName(from: sess.cwd)
        }
        return String(event.sessionId.prefix(8))
    }

    // MARK: - Data Loading

    private func loadEvents(reset: Bool) async {
        isLoading = true
        if reset { events = []; expandedIdx = nil }
        defer { isLoading = false }
        do {
            let resp = try await state.fetchEvents(type: filterType, limit: 50, offset: 0)
            events = resp.events
            totalEvents = resp.total
            await fetchSessionNames(for: resp.events)
        } catch {}
    }

    private func loadMore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await state.fetchEvents(type: filterType, limit: 50, offset: events.count)
            let newIds = Set(events.compactMap(\.id))
            let fresh = resp.events.filter { !newIds.contains($0.id ?? -1) }
            events.append(contentsOf: fresh)
            totalEvents = resp.total
            await fetchSessionNames(for: fresh)
        } catch {}
    }

    private func fetchSessionNames(for evts: [DashboardEvent]) async {
        let ids = Set(evts.map(\.sessionId)).subtracting(sessionNames.keys)
        for id in ids {
            await fetchSessionName(for: id)
        }
    }

    private func fetchSessionName(for sessionId: String) async {
        guard sessionNames[sessionId] == nil else { return }
        if let session = state.sessions.first(where: { $0.id == sessionId }) {
            sessionNames[sessionId] = session.name ?? Theme.projectName(from: session.cwd)
        }
    }
}

// MARK: - Event Type Color

private func eventTypeColor(_ type: String) -> Color {
    switch type {
    case "tool_call": return .cyan
    case "error": return .red
    case "agent_started": return .green
    case "agent_completed": return .secondary
    default: return .purple
    }
}

// MARK: - Activity Event Row

struct ActivityEventRow: View {
    let event: DashboardEvent
    let isExpanded: Bool
    let sessionName: String
    let onTap: () -> Void
    let onViewSession: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsed row
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(eventTypeColor(event.eventType))
                        .frame(width: 3, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            // Colored event type pill
                            let color = eventTypeColor(event.eventType)
                            Text(event.eventType)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.12), in: Capsule())

                            if let tool = event.toolName {
                                Text("· \(tool)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Theme.shortDate(event.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        HStack {
                            Text(sessionName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if let summary = event.summary, !summary.isEmpty {
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(isExpanded ? nil : 1)
                            }
                            Spacer()
                            Text(String(event.sessionId.prefix(8)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Expanded detail
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Full timestamp
                            Text(Theme.shortDate(event.createdAt))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)

                            // Session ID — copyable
                            Text("Session: \(event.sessionId)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)

                            // Agent ID — copyable if present
                            if let agentId = event.agentId {
                                Text("Agent: \(agentId)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }

                            // Event ID
                            if let id = event.id {
                                Text("ID: \(id)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }

                            // Full summary (not truncated)
                            if let summary = event.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // View Session link
                        Button(action: onViewSession) {
                            Label("View Session →", systemImage: "arrow.right.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
