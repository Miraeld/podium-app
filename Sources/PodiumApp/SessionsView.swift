import SwiftUI

struct SessionsView: View {
    @Environment(AppState.self) var state
    @State private var searchText = ""
    @State private var statusFilter: Session.SessionStatus? = nil
    @State private var selectedId: String? = nil
    @State private var searchResults: [Session]? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    private var displayedSessions: [Session] {
        if let results = searchResults { return results }
        if let filter = statusFilter {
            return state.sessions.filter { $0.status == filter }
        }
        return state.sessions
    }

    var body: some View {
        HSplitView {
            // List panel
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search sessions…", text: $searchText)
                            .textFieldStyle(.plain)
                            .onChange(of: searchText) { _, q in triggerSearch(q: q) }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .glassCard(radius: 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(label: "All", active: statusFilter == nil) {
                                statusFilter = nil; searchResults = nil
                            }
                            ForEach(Session.SessionStatus.allCases, id: \.self) { status in
                                FilterChip(
                                    label: status.label,
                                    color: Theme.color(session: status),
                                    active: statusFilter == status
                                ) {
                                    statusFilter = statusFilter == status ? nil : status
                                    triggerSearch(q: searchText)
                                }
                            }
                        }
                    }
                }
                .padding(16)

                Divider().opacity(0.3)

                HStack {
                    Text("\(displayedSessions.count) sessions")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if state.isLoading { ProgressView().scaleEffect(0.7).tint(.cyan) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                List(selection: $selectedId) {
                    ForEach(displayedSessions) { session in
                        SessionListRow(session: session, isSelected: selectedId == session.id)
                            .tag(session.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    if displayedSessions.count < state.sessionTotal && searchResults == nil {
                        Button {
                            Task { await state.loadMoreSessions(offset: state.sessions.count) }
                        } label: {
                            Text("Load more…").font(.callout).foregroundStyle(.cyan).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 340, idealWidth: 380)
            .onChange(of: selectedId) { _, id in
                if let id {
                    state.selectedSessionId = id
                    Task { await state.loadSessionDetail(id) }
                }
            }

            // Detail panel
            if let id = selectedId ?? state.selectedSessionId {
                SessionDetailView(sessionId: id)
            } else {
                ZStack {
                    ThemeBackground()
                    EmptyStateView(
                        icon: "list.bullet.rectangle.portrait",
                        title: "Select a Session",
                        message: "Pick a session from the list to see its details."
                    )
                }
            }
        }
    }

    private func triggerSearch(q: String) {
        searchTask?.cancel()
        guard !q.isEmpty || statusFilter != nil else { searchResults = nil; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let results = await state.searchSessions(q: q, status: statusFilter?.rawValue)
            if !Task.isCancelled { searchResults = results }
        }
    }
}

// MARK: - Session List Row

struct SessionListRow: View {
    let session: Session
    let isSelected: Bool
    private let color: Color

    init(session: Session, isSelected: Bool) {
        self.session = session
        self.isSelected = isSelected
        self.color = Theme.color(session: session.status)
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: color, active: session.status == .active)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name ?? Theme.projectName(from: session.cwd))
                    .font(.callout.weight(.medium)).lineLimit(1)
                if let cwd = session.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(label: session.status.label, color: color)
                HStack(spacing: 6) {
                    if let agents = session.agentCount, agents > 0 {
                        Label("\(agents)", systemImage: "person.2")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Theme.shortDate(session.updatedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .glassCard(radius: 12)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    var color: Color = .white
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(active ? color.opacity(0.2) : Color.primary.opacity(0.06))
                .foregroundStyle(active ? color : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(active ? color.opacity(0.4) : Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
