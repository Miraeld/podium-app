import SwiftUI

// MARK: - Search View

struct SearchView: View {
    @Environment(AppState.self) var state
    @State private var query: String = ""
    @State private var searchResult: SearchResult? = nil
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var fieldFocused: Bool

    // Derived: recent sessions when query is too short
    private var recentSessions: [Session] {
        Array(state.sessions.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions and events…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($fieldFocused)
                    .onChange(of: query) { _, newValue in
                        scheduleSearch(newValue)
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchResult = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.cyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()

            Divider()

            // Results area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if query.count < 2 {
                        recentSessionsSection
                    } else if let result = searchResult {
                        if result.sessions.isEmpty && result.events.isEmpty {
                            noResultsView
                        } else {
                            if !result.sessions.isEmpty {
                                sessionResultsSection(result.sessions)
                            }
                            if !result.events.isEmpty {
                                eventResultsSection(result.events)
                            }
                        }
                    } else if !isLoading {
                        // Transitional empty state before first result
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Search Podium",
                            message: "Type at least 2 characters to search sessions and events."
                        )
                        .padding(.top, 60)
                    }
                }
                .padding()
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                fieldFocused = true
            }
        }
    }

    // MARK: - Sections

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent Sessions")
            if recentSessions.isEmpty {
                Text("No sessions yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(recentSessions) { session in
                        SessionHitRow(
                            id: session.id,
                            name: session.name,
                            status: session.status.rawValue,
                            cwd: session.cwd,
                            highlight: nil
                        )
                        .onTapGesture { navigate(to: session.id) }
                    }
                }
            }
        }
    }

    private func sessionResultsSection(_ hits: [SessionHit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Sessions", trailing: "\(hits.count) result\(hits.count == 1 ? "" : "s")")
            VStack(spacing: 6) {
                ForEach(hits) { hit in
                    SessionHitRow(
                        id: hit.id,
                        name: hit.name,
                        status: hit.status,
                        cwd: hit.cwd,
                        highlight: hit.highlight
                    )
                    .onTapGesture { navigate(to: hit.id) }
                }
            }
        }
    }

    private func eventResultsSection(_ hits: [EventHit]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Events", trailing: "\(hits.count) result\(hits.count == 1 ? "" : "s")")
            VStack(spacing: 6) {
                ForEach(hits) { hit in
                    EventHitRow(hit: hit)
                        .onTapGesture { navigate(to: hit.sessionId) }
                }
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No results for \"\(query)\"")
                .font(.title3.weight(.semibold))
            Text("Try a different search term.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func navigate(to sessionId: String) {
        state.selectedSessionId = sessionId
        state.navigationRequest = .sessions
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        guard q.count >= 2 else {
            searchResult = nil
            isLoading = false
            return
        }
        isLoading = true
        searchTask = Task {
            // 300ms debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await state.searchGlobal(q: q)
                if !Task.isCancelled {
                    searchResult = result
                    isLoading = false
                }
            } catch {
                if !Task.isCancelled {
                    searchResult = nil
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Session Hit Row

private struct SessionHitRow: View {
    let id: String
    let name: String?
    let status: String
    let cwd: String?
    let highlight: String?

    private var isActive: Bool {
        status == "active" || status == "working"
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: Theme.color(for: status), active: isActive)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let highlight = highlight, !highlight.isEmpty {
                        HighlightedText(raw: highlight)
                            .font(.callout.weight(.medium))
                    } else {
                        Text(name ?? id)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusBadge(label: status.capitalized, color: Theme.color(for: status))
                }
                if let cwd = cwd, !cwd.isEmpty {
                    Text(Theme.projectName(from: cwd))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(radius: 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Event Hit Row

private struct EventHitRow: View {
    let hit: EventHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Event type pill
            Text(hit.eventType)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.color(for: hit.eventType).opacity(0.18))
                .foregroundStyle(Theme.color(for: hit.eventType))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.color(for: hit.eventType).opacity(0.3), lineWidth: 1))
                .fixedSize()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let tool = hit.toolName {
                        Text(tool)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    if let sessionName = hit.sessionName {
                        Text("in \(sessionName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("in session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let highlight = hit.highlight, !highlight.isEmpty {
                    HighlightedText(raw: highlight)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(radius: 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Highlighted Text
// Parses <mark>…</mark> tags and renders marked segments in cyan bold.
// Uses AttributedString to avoid the deprecated Text + Text concatenation.

struct HighlightedText: View {
    let raw: String

    var body: some View {
        Text(attributedString)
    }

    private var attributedString: AttributedString {
        var result = AttributedString()
        var remaining = raw

        while !remaining.isEmpty {
            if let openRange = remaining.range(of: "<mark>"),
               let closeRange = remaining.range(of: "</mark>") {

                // Plain text before the mark
                let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !before.isEmpty {
                    result.append(AttributedString(before))
                }

                // Highlighted segment
                let markedStr = String(remaining[openRange.upperBound..<closeRange.lowerBound])
                if !markedStr.isEmpty {
                    var seg = AttributedString(markedStr)
                    seg.foregroundColor = Color.cyan.opacity(0.9)
                    seg.font = .body.bold()
                    result.append(seg)
                }

                remaining = String(remaining[closeRange.upperBound...])
            } else {
                // Strip any remaining HTML tags
                let cleaned = remaining.replacingOccurrences(
                    of: "<[^>]+>", with: "", options: .regularExpression)
                result.append(AttributedString(cleaned))
                remaining = ""
            }
        }

        return result.characters.isEmpty ? AttributedString(raw) : result
    }
}
