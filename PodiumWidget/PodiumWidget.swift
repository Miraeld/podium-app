// PodiumWidget/PodiumWidget.swift
//
// WidgetKit extension for PodiumApp — FREE PATH (no paid Apple Developer account needed).
//
// This widget fetches live data directly from the local Podium server at
// http://localhost:4820 using URLSession. This requires only the network-client
// sandbox entitlement, which is available to free personal Apple ID teams.
//
// It does NOT use App Groups or WidgetStore/WidgetSnapshot. Those types live in
// Sources/PodiumApp/WidgetData.swift (app-only file) and are not compiled into
// this target.
//
// NOTE on host/port: The base URL is hardcoded to http://localhost:4820 (Podium's
// default). A paid-account App-Group alternative would let the widget read the
// app's configured host/port from a shared UserDefaults container. On the free
// path, localhost:4820 is the pragmatic default — if you change the server port,
// update podiumBaseURL below.

import WidgetKit
import SwiftUI

// MARK: - Local Decodable models (self-contained — no app module import)

/// Response from GET /api/stats
struct WidgetStats: Decodable {
    let activeSessions: Int
    let activeAgents: Int
}

/// One session item from GET /api/sessions?limit=6
struct WidgetSessionDTO: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let cwd: String?
}

/// Wrapper for GET /api/sessions response
struct WidgetSessionsResponse: Decodable {
    let sessions: [WidgetSessionDTO]
    let total: Int
}

// MARK: - Shared decoder

private let podiumDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

// MARK: - Network helper

/// Base URL for the Podium server. Change only this constant if your server runs on a different port.
private let podiumBaseURL = "http://localhost:4820"

private func fetchStats() async -> WidgetStats? {
    guard let url = URL(string: "\(podiumBaseURL)/api/stats") else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    return try? podiumDecoder.decode(WidgetStats.self, from: data)
}

private func fetchSessions() async -> [WidgetSessionDTO] {
    guard let url = URL(string: "\(podiumBaseURL)/api/sessions?limit=6") else { return [] }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
    guard let response = try? podiumDecoder.decode(WidgetSessionsResponse.self, from: data) else { return [] }
    return response.sessions
}

// MARK: - Timeline Entry

struct PodiumEntry: TimelineEntry {
    let date: Date
    /// nil means the server could not be reached.
    let stats: WidgetStats?
    let sessions: [WidgetSessionDTO]
}

// MARK: - Timeline Provider

struct PodiumProvider: TimelineProvider {

    func placeholder(in context: Context) -> PodiumEntry {
        PodiumEntry(date: .now, stats: nil, sessions: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (PodiumEntry) -> Void) {
        Task {
            let stats = await fetchStats()
            let sessions = await fetchSessions()
            completion(PodiumEntry(date: .now, stats: stats, sessions: sessions))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PodiumEntry>) -> Void) {
        Task {
            let stats = await fetchStats()
            let sessions = await fetchSessions()
            let entry = PodiumEntry(date: .now, stats: stats, sessions: sessions)
            // Refresh approximately every 5 minutes. WidgetKit controls the exact cadence.
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
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
        if let stats = entry.stats {
            switch family {
            case .systemSmall:
                SmallWidgetView(stats: stats, sessions: entry.sessions)
            case .systemMedium:
                MediumWidgetView(stats: stats, sessions: entry.sessions)
            case .systemLarge:
                LargeWidgetView(stats: stats, sessions: entry.sessions)
            default:
                SmallWidgetView(stats: stats, sessions: entry.sessions)
            }
        } else {
            EmptyWidgetView()
        }
    }
}

// MARK: - Empty / Server-down State

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Podium server not running")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Start Podium on localhost:4820.")
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
    let stats: WidgetStats
    let sessions: [WidgetSessionDTO]

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")

        VStack(alignment: .leading, spacing: 4) {
            Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(stats.activeSessions)")
                .font(.system(size: 42, weight: .bold, design: .rounded))

            Text("active sessions")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                Text("\(stats.activeAgents) agents")
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
    let stats: WidgetStats
    let sessions: [WidgetSessionDTO]

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Podium", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(stats.activeSessions) active · \(stats.activeAgents) agents")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            // Last 3 sessions
            let displaySessions = Array(sessions.prefix(3))
            if displaySessions.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 5) {
                    ForEach(displaySessions) { session in
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
// Shows header + last 6 sessions.

struct LargeWidgetView: View {
    let stats: WidgetStats
    let sessions: [WidgetSessionDTO]

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
                    Text("\(stats.activeSessions) active sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(stats.activeAgents) agents")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            // Last 6 sessions
            let displaySessions = Array(sessions.prefix(6))
            if displaySessions.isEmpty {
                Text("No sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(displaySessions) { session in
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
    let session: WidgetSessionDTO

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
    /// Applies `.widgetURL` when the URL is non-nil, otherwise returns the unmodified view.
    @ViewBuilder
    func applyWidgetURL(_ url: URL?) -> some View {
        if let url = url {
            self.widgetURL(url)
        } else {
            self
        }
    }
}
