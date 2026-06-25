// PodiumWidget/PodiumWidget.swift
//
// WidgetKit extension for PodiumApp.
// This file is compiled into the PodiumWidget extension target only.
// WidgetData.swift (shared) is added to BOTH the app target and this target
// so WidgetSnapshot and WidgetStore are available here without re-importing
// the main app module.
//
// No cost fields are referenced — WidgetSnapshot intentionally omits them.

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct PodiumEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

// MARK: - Timeline Provider

struct PodiumProvider: TimelineProvider {

    func placeholder(in context: Context) -> PodiumEntry {
        PodiumEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PodiumEntry) -> Void) {
        completion(PodiumEntry(date: .now, snapshot: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PodiumEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        let entry = PodiumEntry(date: .now, snapshot: snapshot)
        // Refresh every 5 minutes as a fallback; the main app triggers early
        // via WidgetCenter.shared.reloadAllTimelines() on every stats_update.
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget Bundle

@main
struct PodiumWidgetBundle: WidgetBundle {
    var body: some Widget {
        PodiumStatsWidget()
    }
}

// MARK: - Widget Configuration

struct PodiumStatsWidget: Widget {
    let kind = "PodiumStats"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PodiumProvider()) { entry in
            PodiumWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Podium")
        .description("Live Claude Code session stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Top-level Widget View

struct PodiumWidgetView: View {
    let entry: PodiumEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall:
                SmallWidgetView(snapshot: snapshot)
            case .systemMedium:
                MediumWidgetView(snapshot: snapshot)
            case .systemLarge:
                LargeWidgetView(snapshot: snapshot)
            default:
                SmallWidgetView(snapshot: snapshot)
            }
        } else {
            EmptyWidgetView()
        }
    }
}

// MARK: - Empty / Placeholder State

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No data yet")
                .font(.caption.weight(.semibold))
            Text("Open Podium to connect.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Small Widget  (systemSmall)
//
// Shows: big active-sessions count + active-agents count.
// Tapping the whole widget opens podium://dashboard.

struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")

        VStack(alignment: .leading, spacing: 4) {
            Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(snapshot.activeSessions)")
                .font(.system(size: 42, weight: .bold, design: .rounded))

            Text("active sessions")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                Text("\(snapshot.activeAgents) agents")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .applyWidgetURL(dashboardURL)
    }
}

// MARK: - Medium Widget  (systemMedium)
//
// Shows: header (active sessions · active agents) + last 3 sessions.

struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.activeSessions) active · \(snapshot.activeAgents) agents")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            // Last 3 sessions
            let sessions = Array(snapshot.recentSessions.prefix(3))
            if sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 5) {
                    ForEach(sessions) { session in
                        SessionRowView(session: session)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .applyWidgetURL(dashboardURL)
    }
}

// MARK: - Large Widget  (systemLarge)
//
// Adds agent count in header + last 6 sessions.

struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(snapshot.activeSessions) active sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(snapshot.activeAgents) agents")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            // Last 6 sessions
            let sessions = Array(snapshot.recentSessions.prefix(6))
            if sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        SessionRowView(session: session)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .applyWidgetURL(dashboardURL)
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: WidgetSnapshot.WidgetSession

    var body: some View {
        let sessionURL = URL(string: "podium://session/\(session.id)")

        let rowContent = HStack(spacing: 6) {
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 7, height: 7)
            Text(session.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(session.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let url = sessionURL {
            Link(destination: url) {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "active", "working":
            return .cyan
        case "completed":
            return .green
        case "error":
            return .red
        case "abandoned":
            return Color.orange
        case "waiting":
            return .yellow
        default:
            return .secondary
        }
    }
}

// MARK: - View Extension: widgetURL helper

private extension View {
    /// Applies `.widgetURL` when the URL is non-nil, otherwise returns unmodified view.
    @ViewBuilder
    func applyWidgetURL(_ url: URL?) -> some View {
        if let url = url {
            self.widgetURL(url)
        } else {
            self
        }
    }
}
