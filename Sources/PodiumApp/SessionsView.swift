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
                    Text("\(displayedSessions.count) sessions")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if state.isLoading { ProgressView().scaleEffect(0.7).tint(.cyan) }
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
                            onRename: { newName in
                                await renameSession(session.id, name: newName)
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

    private func renameSession(_ id: String, name: String) async {
        do {
            try await state.renameSession(id, name: name)
        } catch {
            // Fallback: inline PATCH
            guard let url = URL(string: "http://\(state.host):\(state.port)/api/sessions/\(id)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.httpBody = try? JSONEncoder().encode(["name": name])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}

// MARK: - Session List Row

struct SessionListRow: View {
    let session: Session
    let isSelected: Bool
    let onRename: (String) async -> Void

    private let color: Color
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var editName = ""

    init(session: Session, isSelected: Bool, onRename: @escaping (String) async -> Void) {
        self.session = session
        self.isSelected = isSelected
        self.onRename = onRename
        self.color = Theme.color(session: session.status)
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: color, active: session.status == .active)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isRenaming {
                        TextField("Session name", text: $editName)
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.medium))
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(session.name ?? Theme.projectName(from: session.cwd))
                            .font(.callout.weight(.medium)).lineLimit(1)
                    }
                    if isHovering && !isRenaming {
                        Button {
                            editName = session.name ?? Theme.projectName(from: session.cwd)
                            isRenaming = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let cwd = session.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if isRenaming {
                HStack(spacing: 8) {
                    Button("Cancel") { isRenaming = false }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    Button("Save") { commitRename() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .buttonStyle(.plain)
                }
            } else {
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
        .onHover { isHovering = $0 }
    }

    private func commitRename() {
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !trimmed.isEmpty else { return }
        Task { await onRename(trimmed) }
    }
}

// MARK: - Filter Chip (local override removed — use Components.swift version)
