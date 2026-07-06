#if os(macOS)
import SwiftUI

// MARK: - Sort Order

enum SortOrder: String, CaseIterable {
    case lastActive = "Last Active"
    case duration   = "Duration"
    case cost       = "Cost"
}

// MARK: - Sessions View

struct SessionsView: View {
    @Environment(AppState.self) var state
    @State private var searchText = ""
    @State private var statusFilter: Session.SessionStatus? = nil
    @State private var selectedId: String? = nil
    @State private var searchResults: [Session]? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var sortOrder: SortOrder = .lastActive
    @State private var directoryFilter: String? = nil
    @State private var renamingId: String? = nil
    @State private var renameText: String = ""

    private var uniqueDirectories: [String] {
        let cwds = state.sessions.compactMap(\.cwd)
        return Array(Set(cwds)).sorted()
    }

    private var displayedSessions: [Session] {
        var list: [Session]
        if let results = searchResults {
            list = results
        } else if let filter = statusFilter {
            list = state.sessions.filter { $0.status == filter }
        } else {
            list = state.sessions
        }

        if let dir = directoryFilter {
            list = list.filter { $0.cwd == dir }
        }

        let now = Date()
        switch sortOrder {
        case .lastActive:
            list.sort { $0.updatedAt > $1.updatedAt }
        case .duration:
            list.sort {
                let d0 = ($0.endedAt ?? now).timeIntervalSince($0.startedAt)
                let d1 = ($1.endedAt ?? now).timeIntervalSince($1.startedAt)
                return d0 > d1
            }
        case .cost:
            list.sort { ($0.cost ?? 0) > ($1.cost ?? 0) }
        }

        return list
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

                    if uniqueDirectories.count >= 2 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(label: "All Projects", active: directoryFilter == nil) {
                                    directoryFilter = nil
                                }
                                ForEach(uniqueDirectories, id: \.self) { dir in
                                    FilterChip(
                                        label: Theme.projectName(from: dir),
                                        active: directoryFilter == dir
                                    ) {
                                        directoryFilter = directoryFilter == dir ? nil : dir
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)

                Divider().opacity(0.3)

                HStack {
                    if statusFilter != nil || !searchText.isEmpty {
                        Text("\(displayedSessions.count) of \(state.sessionTotal)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(state.sessionTotal) sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isInitialLoad { ProgressView().scaleEffect(0.7).tint(.cyan) }
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)

                List(selection: $selectedId) {
                    ForEach(displayedSessions) { session in
                        SessionListRow(
                            session: session,
                            isSelected: selectedId == session.id,
                            onRename: {
                                renamingId = session.id
                                renameText = session.name ?? Theme.projectName(from: session.cwd)
                            }
                        )
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
                .alert("Rename Session", isPresented: Binding(
                    get: { renamingId != nil },
                    set: { if !$0 { renamingId = nil } }
                )) {
                    TextField("Session name", text: $renameText)
                    Button("Rename") {
                        if let id = renamingId, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                            Task { await state.renameSession(id, name: renameText.trimmingCharacters(in: .whitespaces)) }
                        }
                        renamingId = nil
                    }
                    Button("Cancel", role: .cancel) { renamingId = nil }
                } message: {
                    Text("Enter a new name for this session.")
                }
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
    var onRename: (() -> Void)? = nil

    private let color: Color

    init(session: Session, isSelected: Bool, onRename: (() -> Void)? = nil) {
        self.session = session
        self.isSelected = isSelected
        self.onRename = onRename
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
                if session.awaitingInputSince != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                        Text("Awaiting input")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.15), in: Capsule())
                }
                StatusBadge(label: session.status.label, color: color)
                HStack(spacing: 6) {
                    if let agents = session.agentCount, agents > 0 {
                        Label("\(agents)", systemImage: "person.2")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let cost = session.cost, cost > 0 {
                        Text(String(format: "$%.4f", cost))
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
        .contextMenu {
            Button {
                onRename?()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }
}

// MARK: - Filter Chip (local override removed — use Components.swift version)

#endif
