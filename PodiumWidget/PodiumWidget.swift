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
    let eventsToday: Int
}

/// One agent from GET /api/agents?status=working,waiting
struct WidgetAgent: Decodable, Identifiable {
    let id: String
    let sessionId: String
    let name: String
    let subagentType: String?
    let status: String           // "working" | "waiting"
    let currentTool: String?     // tool in use right now, may be nil
    let task: String?
    let startedAt: String        // ISO8601 string — decoded as String to avoid date strategy conflicts
}

/// Wrapper for GET /api/agents response
struct WidgetAgentsResponse: Decodable {
    let agents: [WidgetAgent]
}

// MARK: - Shared decoder

private let podiumDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

// MARK: - Date parsing helper

/// Parse an ISO8601 started_at string into a Date.
/// Tries fractional-seconds first, then plain ISO8601, so both
/// "2026-06-25T03:18:00.000Z" and "2026-06-25T03:18:00Z" work.
func parseISO8601(_ string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}

// MARK: - Network helpers

/// Base URL for the Podium server. Change only this constant if your server runs on a different port.
private let podiumBaseURL = "http://localhost:4820"

private func fetchStats() async -> WidgetStats? {
    guard let url = URL(string: "\(podiumBaseURL)/api/stats") else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    return try? podiumDecoder.decode(WidgetStats.self, from: data)
}

private func fetchAgents() async -> [WidgetAgent] {
    guard let url = URL(string: "\(podiumBaseURL)/api/agents?status=working,waiting") else { return [] }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
    guard let response = try? podiumDecoder.decode(WidgetAgentsResponse.self, from: data) else { return [] }
    return response.agents
}

// MARK: - Timeline Entry

struct PodiumEntry: TimelineEntry {
    let date: Date
    /// nil means the server could not be reached.
    let stats: WidgetStats?
    let agents: [WidgetAgent]
    /// true when the server responded (even if no agents are active); false when both fetches failed.
    let reachable: Bool
}

// MARK: - Timeline Provider

struct PodiumProvider: TimelineProvider {

    func placeholder(in context: Context) -> PodiumEntry {
        PodiumEntry(date: .now, stats: nil, agents: [], reachable: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PodiumEntry) -> Void) {
        Task {
            let stats = await fetchStats()
            let agents = await fetchAgents()
            let reachable = stats != nil
            completion(PodiumEntry(date: .now, stats: stats, agents: agents, reachable: reachable))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PodiumEntry>) -> Void) {
        Task {
            let stats = await fetchStats()
            let agents = await fetchAgents()
            let reachable = stats != nil
            let entry = PodiumEntry(date: .now, stats: stats, agents: agents, reachable: reachable)
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
        .description("Live Claude Code agent activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Top-level Widget View

struct PodiumWidgetView: View {
    let entry: PodiumEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.reachable {
            ServerDownView()
        } else {
            switch family {
            case .systemSmall:
                SmallWidgetView(entry: entry)
            case .systemMedium:
                MediumWidgetView(entry: entry)
            case .systemLarge:
                LargeWidgetView(entry: entry)
            default:
                SmallWidgetView(entry: entry)
            }
        }
    }
}

// MARK: - Server-down state (distinct from Idle)

struct ServerDownView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "network.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Podium server not running")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Start it on localhost:4820")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Idle state (server up, nothing active)

struct IdleView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Idle — nothing running")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared header row

struct PodiumHeader: View {
    let workingCount: Int
    let totalAgents: Int
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("◉ Podium")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(workingCount) working · \(totalAgents) agents")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("updated ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            + Text(date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Agent Row

struct AgentRowView: View {
    let agent: WidgetAgent

    var displayName: String {
        agent.subagentType ?? agent.name
    }

    var statusColor: Color {
        agent.status == "working" ? .green : .yellow
    }

    var startedDate: Date? {
        parseISO8601(agent.startedAt)
    }

    var body: some View {
        let sessionURL = URL(string: "podium://session/\(agent.sessionId)")

        let rowContent = HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let tool = agent.currentTool {
                Text(tool)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }

            if let started = startedDate {
                Text(started, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
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
}

// MARK: - Small Widget  (systemSmall)
//
// Glanceable pulse: big active-agent count + events today.

struct SmallWidgetView: View {
    let entry: PodiumEntry

    var waitingCount: Int {
        entry.agents.filter { $0.status == "waiting" }.count
    }

    var body: some View {
        let dashboardURL = URL(string: "podium://dashboard")
        let agentCount = entry.stats?.activeAgents ?? 0
        let eventsToday = entry.stats?.eventsToday ?? 0

        VStack(alignment: .leading, spacing: 4) {
            Text("◉ Podium")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(agentCount)")
                .font(.system(size: 42, weight: .bold, design: .rounded))

            Text(agentCount == 1 ? "active agent" : "active agents")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if waitingCount > 0 {
                Text("⏸ \(waitingCount) waiting")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.yellow)
            }

            Text("\(eventsToday) events today")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .applyWidgetURL(dashboardURL)
    }
}

// MARK: - Medium Widget  (systemMedium)
//
// What's running now: header + up to 3 agent rows (waiting first).

struct MediumWidgetView: View {
    let entry: PodiumEntry

    var sortedAgents: [WidgetAgent] {
        // Waiting agents first so they're visible
        entry.agents.sorted { a, _ in a.status == "waiting" }
    }

    var workingCount: Int {
        entry.agents.filter { $0.status == "working" }.count
    }

    var body: some View {
        let totalAgents = entry.stats?.activeAgents ?? entry.agents.count
        let displayAgents = Array(sortedAgents.prefix(3))

        VStack(alignment: .leading, spacing: 0) {
            PodiumHeader(workingCount: workingCount, totalAgents: totalAgents, date: entry.date)
                .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            if displayAgents.isEmpty {
                IdleView()
            } else {
                VStack(spacing: 6) {
                    ForEach(displayAgents) { agent in
                        AgentRowView(agent: agent)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Large Widget  (systemLarge)
//
// Full live view: header + up to 7 agent rows + footer.

struct LargeWidgetView: View {
    let entry: PodiumEntry

    var sortedAgents: [WidgetAgent] {
        entry.agents.sorted { a, _ in a.status == "waiting" }
    }

    var workingCount: Int {
        entry.agents.filter { $0.status == "working" }.count
    }

    var body: some View {
        let totalAgents = entry.stats?.activeAgents ?? entry.agents.count
        let activeSessions = entry.stats?.activeSessions ?? 0
        let eventsToday = entry.stats?.eventsToday ?? 0
        let displayAgents = Array(sortedAgents.prefix(7))

        VStack(alignment: .leading, spacing: 0) {
            PodiumHeader(workingCount: workingCount, totalAgents: totalAgents, date: entry.date)
                .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 6)

            if displayAgents.isEmpty {
                IdleView()
            } else {
                VStack(spacing: 6) {
                    ForEach(displayAgents) { agent in
                        AgentRowView(agent: agent)
                    }
                }
            }

            Spacer(minLength: 0)

            Divider()
                .padding(.top, 6)

            Text("\(activeSessions) active sessions · \(eventsToday) events today")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
