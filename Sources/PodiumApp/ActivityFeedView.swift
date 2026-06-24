import SwiftUI

struct ActivityFeedView: View {
    @Environment(AppState.self) var state
    @State private var events: [DashboardEvent] = []
    @State private var totalEvents = 0
    @State private var isLoading = false
    @State private var filterType: String? = nil
    @State private var expandedIdx: Int? = nil

    private let knownEventTypes = ["tool_use", "agent_start", "agent_stop", "session_start", "session_stop", "error"]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().opacity(0.3)
            if isLoading && events.isEmpty {
                LoadingView()
            } else if events.isEmpty {
                EmptyStateView(icon: "waveform", title: "No Events", message: "Events appear here as sessions run.")
            } else {
                eventList
            }
        }
        .task { await loadEvents(reset: true) }
        .onChange(of: filterType) { _, _ in Task { await loadEvents(reset: true) } }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", active: filterType == nil) { filterType = nil }
                ForEach(knownEventTypes, id: \.self) { t in
                    FilterChip(label: t, active: filterType == t) {
                        filterType = filterType == t ? nil : t
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                    ActivityEventRow(event: event, isExpanded: expandedIdx == idx) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedIdx = expandedIdx == idx ? nil : idx
                        }
                    }
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

    private func loadEvents(reset: Bool) async {
        isLoading = true
        if reset { events = [] }
        defer { isLoading = false }
        do {
            let resp = try await state.fetchEvents(type: filterType, limit: 50, offset: 0)
            events = resp.events
            totalEvents = resp.total
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
        } catch {}
    }
}

struct ActivityEventRow: View {
    let event: DashboardEvent
    let isExpanded: Bool
    let onTap: () -> Void

    private var color: Color {
        let t = event.eventType.lowercased()
        if t.contains("error") || t.contains("fail") { return .red }
        if t.contains("stop") { return .orange }
        if t.contains("start") { return .cyan }
        if t.contains("tool") { return Color(red: 0.6, green: 0.4, blue: 1) }
        return .secondary
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(event.eventType)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color)
                            if let tool = event.toolName {
                                Text("· \(tool)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Theme.shortDate(event.createdAt))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        HStack {
                            if let summary = event.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(isExpanded ? nil : 2)
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

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let id = event.id {
                            Text("ID: \(id)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        Text("Session: \(event.sessionId)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        if let agentId = event.agentId {
                            Text("Agent: \(agentId)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
