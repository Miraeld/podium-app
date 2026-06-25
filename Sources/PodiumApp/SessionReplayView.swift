import SwiftUI

// MARK: - Replay State

@Observable
final class ReplayState {
    var allEvents: [DashboardEvent] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var speedMultiplier: Double = 1.0  // events per second; >1 = faster

    private var playTask: Task<Void, Never>?

    /// Events visible at current scrub position (up to and including currentIndex)
    var visibleEvents: ArraySlice<DashboardEvent> {
        guard !allEvents.isEmpty else { return [][...] }
        return allEvents.prefix(currentIndex + 1)
    }

    func play() {
        guard currentIndex < allEvents.count - 1 else { return }
        isPlaying = true
        playTask = Task { @MainActor in
            while self.isPlaying && self.currentIndex < self.allEvents.count - 1 {
                let nextIndex = self.currentIndex + 1
                let realGap = self.allEvents[nextIndex].createdAt
                    .timeIntervalSince(self.allEvents[self.currentIndex].createdAt)
                // Clamp: minimum 50 ms per step; divide by speed multiplier
                let delay = max(0.05, realGap / self.speedMultiplier)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                self.currentIndex = nextIndex
            }
            self.isPlaying = false
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    func stepForward()  { currentIndex = min(currentIndex + 1, max(0, allEvents.count - 1)) }
    func stepBackward() { currentIndex = max(currentIndex - 1, 0) }
    func jumpToStart()  { currentIndex = 0 }
    func jumpToEnd()    { currentIndex = max(0, allEvents.count - 1) }
}

// MARK: - Duration Formatter

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return String(format: "%ds", s)
}

// MARK: - Event Type Icon

private func eventTypeIcon(_ type: String) -> String {
    switch type.lowercased() {
    case "tool_use", "tool_result":   return "bolt.fill"
    case "session_start":             return "play.circle.fill"
    case "session_end":               return "stop.circle.fill"
    case "agent_start":               return "brain.head.profile"
    case "agent_end":                 return "checkmark.circle"
    case "error":                     return "exclamationmark.triangle.fill"
    case "message":                   return "text.bubble.fill"
    default:                          return "circle.fill"
    }
}

// MARK: - Mini Event Strip

/// A horizontal row of colored ticks — one per event — showing density and current position.
private struct MiniEventStrip: View {
    let events: [DashboardEvent]
    let currentIndex: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(1, events.count)
            let tickWidth = max(2, geo.size.width / CGFloat(count))

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 8)

                // Ticks
                Canvas { context, size in
                    for (i, event) in events.enumerated() {
                        let x = (CGFloat(i) / CGFloat(count)) * size.width
                        let color = Theme.color(for: event.eventType)
                        let rect = CGRect(
                            x: x,
                            y: 0,
                            width: max(2, tickWidth - 0.5),
                            height: size.height
                        )
                        // Dim events after the current position
                        let opacity: CGFloat = i <= currentIndex ? 0.85 : 0.18
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(color.opacity(opacity))
                        )
                    }
                }
                .frame(height: 8)

                // Current-position thumb
                let thumbX = events.isEmpty ? 0 :
                    (CGFloat(currentIndex) / CGFloat(count - 1)) * (geo.size.width - 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 14)
                    .offset(x: thumbX + 4.5, y: -3)
                    .shadow(color: .white.opacity(0.6), radius: 3)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Transport Bar

private struct ReplayTransportBar: View {
    @Bindable var replay: ReplayState

    var body: some View {
        VStack(spacing: 12) {
            // Mini event strip
            MiniEventStrip(events: replay.allEvents, currentIndex: replay.currentIndex)
                .padding(.horizontal, 2)

            // Slider row
            HStack(spacing: 10) {
                Button { replay.jumpToStart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button { replay.stepBackward() } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(replay.currentIndex) },
                        set: { newVal in
                            replay.pause()
                            replay.currentIndex = Int(newVal.rounded())
                        }
                    ),
                    in: 0...Double(max(1, replay.allEvents.count - 1)),
                    step: 1
                )
                .tint(.cyan)

                Button { replay.stepForward() } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button { replay.jumpToEnd() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text("\(replay.currentIndex + 1) / \(replay.allEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }

            // Play + speed + elapsed row
            HStack(spacing: 16) {
                Button {
                    if replay.isPlaying { replay.pause() } else { replay.play() }
                } label: {
                    Label(
                        replay.isPlaying ? "Pause" : "Play",
                        systemImage: replay.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(replay.isPlaying ? .orange : .cyan)
                .keyboardShortcut(.space, modifiers: [])

                Spacer()

                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $replay.speedMultiplier) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("Max").tag(1000.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                if let first = replay.allEvents.first,
                   !replay.allEvents.isEmpty,
                   replay.currentIndex < replay.allEvents.count {
                    let elapsed = replay.allEvents[replay.currentIndex].createdAt
                        .timeIntervalSince(first.createdAt)
                    Label("+" + formatDuration(elapsed), systemImage: "clock")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }
}

// MARK: - Current Event Card

private struct CurrentEventCard: View {
    let event: DashboardEvent
    let index: Int
    let total: Int

    private var color: Color { Theme.color(for: event.eventType) }
    private var label: String { event.summary ?? event.toolName ?? event.eventType }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: eventTypeIcon(event.eventType))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.eventType)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    if let tool = event.toolName {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(tool)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Theme.shortDate(event.createdAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let summary = event.summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }
}

// MARK: - Event Row (in the visible stream list)

private struct ReplayEventRow: View {
    let event: DashboardEvent
    let isCurrent: Bool
    let elapsed: TimeInterval

    private var color: Color { Theme.color(for: event.eventType) }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: color, active: isCurrent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.eventType)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? color : .secondary)
                    if let tool = event.toolName {
                        Text(tool)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("+" + formatDuration(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.quaternary)
                }
                if let summary = event.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isCurrent ? color.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Session Replay View

struct SessionReplayView: View {
    let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    @Environment(AppState.self) var state
    @State private var replay = ReplayState()
    @State private var isLoading = false

    private var events: [DashboardEvent] {
        (state.sessionDetailCache[sessionId]?.events ?? [])
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if events.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No Events",
                    message: "This session has no recorded events to replay."
                )
            } else {
                replayContent
            }
        }
        .task {
            await loadEvents()
        }
        .onDisappear {
            replay.pause()
        }
    }

    // MARK: - Main content

    private var replayContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // Transport controls
                    ReplayTransportBar(replay: replay)

                    // Current event highlight
                    if !replay.allEvents.isEmpty,
                       replay.currentIndex < replay.allEvents.count {
                        let current = replay.allEvents[replay.currentIndex]
                        CurrentEventCard(
                            event: current,
                            index: replay.currentIndex,
                            total: replay.allEvents.count
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .animation(.easeInOut(duration: 0.2), value: replay.currentIndex)
                    }

                    // Visible event stream
                    VStack(spacing: 0) {
                        SectionHeader(
                            title: "Event Stream",
                            trailing: "Events 1–\(replay.currentIndex + 1)"
                        )
                        .padding(.bottom, 8)

                        let firstDate = replay.allEvents.first?.createdAt ?? Date()
                        let visible = Array(replay.visibleEvents)

                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, event in
                            let elapsed = event.createdAt.timeIntervalSince(firstDate)
                            let isCurrent = idx == visible.count - 1

                            ReplayEventRow(
                                event: event,
                                isCurrent: isCurrent,
                                elapsed: elapsed
                            )
                            .id(event.id)

                            if idx < visible.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .padding(Theme.cardPadding)
                    .glassCard()
                    .onChange(of: replay.currentIndex) { _, _ in
                        if let last = Array(replay.visibleEvents).last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Data loading

    private func loadEvents() async {
        isLoading = true
        await state.loadSessionDetail(sessionId)
        isLoading = false

        let sorted = events
        if replay.allEvents.isEmpty && !sorted.isEmpty {
            replay.allEvents = sorted
            replay.currentIndex = 0
        }
    }
}
