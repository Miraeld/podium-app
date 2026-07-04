// DiagnosticsView.swift — P4.4 native panel.
//
// Shows: server uptime/platform/memory (reusing the same runtime info
// `SettingsInfoResponse.server` already surfaces), hook health (green/red
// status dot + last-event time + latency), and a scrollable recent-log
// view — all fed by the new `GET /api/diagnostics` endpoint
// (`Sources/PodiumServer/Routes/DiagnosticsRouter.swift`).
//
// NOT WIRED INTO NAVIGATION: this file only defines the view. Hooking it
// into `ContentView`'s sidebar/NavigationSplitView is left to whoever owns
// that file this task (see this task's final report for the one-line note
// on where to add it) since `ContentView.swift`/`SettingsView.swift` may be
// touched by parallel work.
//
// Polling: follows the same convention as the rest of the app's
// "self-contained tab" views (`HooksTab`, `PricingTab` in SettingsView.swift)
// — a `.task` modifier that loads once on appear, plus here a simple
// `Task { while !Task.isCancelled { ... ; sleep } }` loop for periodic
// refresh, mirroring `AppState`'s existing WS-driven-but-poll-fallback
// philosophy without requiring any change to `AppState` itself (this view
// intentionally does its own lightweight networking rather than growing
// the shared app state, since diagnostics data doesn't need to be cached
// or shared across other views).

#if os(macOS)
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppState.self) var state

    @State private var diagnostics: DiagnosticsSnapshot?
    @State private var lastError: String?
    @State private var isInitialLoad = true
    @State private var pollTask: Task<Void, Never>?

    /// How often to re-poll `/api/diagnostics` while this view is visible.
    /// Fast enough to feel "live" without hammering the server — same
    /// order of magnitude as the app's other periodic refreshes.
    private static let pollInterval: Duration = .seconds(5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let diagnostics {
                    HStack(alignment: .top, spacing: 16) {
                        serverCard(diagnostics.server)
                        hookHealthCard(diagnostics.hooks)
                    }
                    logCard(diagnostics.log)
                } else if isInitialLoad {
                    LoadingView()
                        .frame(height: 200)
                } else if let lastError {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Diagnostics unavailable",
                        message: lastError
                    )
                    .frame(height: 200)
                }
            }
            .padding(20)
        }
        .task {
            await loadOnce()
            isInitialLoad = false
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                Text("Hook \u{2192} server pipeline health, at a glance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let diagnostics {
                StatusDot(color: statusColor(diagnostics.hooks.status), active: diagnostics.hooks.status == "ok")
                Text(diagnostics.hooks.status.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(diagnostics.hooks.status))
            }
        }
    }

    // MARK: - Server card

    private func serverCard(_ server: DiagnosticsSnapshot.ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Server")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Uptime").foregroundStyle(.secondary)
                    Text(formatUptime(server.uptimeSeconds)).monospacedDigit()
                }
                GridRow {
                    Text("Platform").foregroundStyle(.secondary)
                    Text("\(server.platform) \u{00b7} \(server.arch)")
                }
                GridRow {
                    Text("CPUs").foregroundStyle(.secondary)
                    Text("\(server.cpuCount)").monospacedDigit()
                }
                GridRow {
                    Text("Memory (RSS)").foregroundStyle(.secondary)
                    Text(formatBytes(server.residentMemoryBytes)).monospacedDigit()
                }
                GridRow {
                    Text("Load avg").foregroundStyle(.secondary)
                    Text(server.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " \u{00b7} "))
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Hook health card

    private func hookHealthCard(_ hooks: DiagnosticsSnapshot.HookHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Hook Ingestion")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        StatusDot(color: statusColor(hooks.status))
                        Text(hooks.status.capitalized)
                    }
                }
                GridRow {
                    Text("Last event").foregroundStyle(.secondary)
                    Text(lastEventDescription(hooks.lastEventAt))
                }
                GridRow {
                    Text("Last latency").foregroundStyle(.secondary)
                    Text(hooks.lastLatencySeconds.map { formatLatency($0) } ?? "\u{2013}")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Avg latency").foregroundStyle(.secondary)
                    Text(hooks.averageLatencySeconds.map { formatLatency($0) } ?? "\u{2013}")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Processed").foregroundStyle(.secondary)
                    Text("\(hooks.totalEventsProcessed)").monospacedDigit()
                }
                GridRow {
                    Text("Failed").foregroundStyle(.secondary)
                    Text("\(hooks.totalEventsFailed)")
                        .monospacedDigit()
                        .foregroundStyle(hooks.totalEventsFailed > 0 ? Theme.color(for: "error") : .primary)
                }
            }
            .font(.callout)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Log card

    private func logCard(_ log: [DiagnosticsSnapshot.LogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent Activity", trailing: "\(log.count) entries")
            if log.isEmpty {
                Text("No hook events recorded yet this session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(log) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(entry.level == "error" ? Theme.color(for: "error") : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(shortTimestamp(entry.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 70, alignment: .leading)
                            Text(entry.message)
                                .font(.caption)
                                .foregroundStyle(entry.level == "error" ? Theme.color(for: "error") : .secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { break }
                await loadOnce()
            }
        }
    }

    private func loadOnce() async {
        do {
            diagnostics = try await fetchDiagnostics(host: state.host, port: state.port)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Formatting helpers

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok": return Theme.color(for: "completed")
        case "stale": return Theme.color(for: "abandoned")
        default: return .secondary
        }
    }

    private func lastEventDescription(_ timestamp: String?) -> String {
        guard let timestamp, let date = PodiumDiagnosticsDate.parse(timestamp) else { return "Never" }
        return Theme.shortDate(date)
    }

    private func shortTimestamp(_ timestamp: String) -> String {
        guard let date = PodiumDiagnosticsDate.parse(timestamp) else { return "\u{2013}" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func formatBytes(_ bytes: Double) -> String {
        let mb = bytes / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }

    private func formatLatency(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.1f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }
}

// MARK: - Wire types (local to this view — no AppState/PodiumAPI change needed)

/// Mirrors `Sources/PodiumCore/Diagnostics/DiagnosticsResponse.swift`'s wire
/// shape. Kept private to this file rather than added to
/// `Sources/PodiumApp/Models.swift` (out of fence for this task) or routed
/// through `PodiumAPI` (also out of fence) — this view fetches directly.
struct DiagnosticsSnapshot: Decodable {
    let server: ServerInfo
    let hooks: HookHealth
    let log: [LogEntry]

    struct ServerInfo: Decodable {
        let uptimeSeconds: Double
        let platform: String
        let arch: String
        let cpuCount: Int
        let loadAverages: [Double]
        let residentMemoryBytes: Double
        let totalMemoryBytes: Double
    }

    struct HookHealth: Decodable {
        let status: String
        let lastEventAt: String?
        let lastLatencySeconds: Double?
        let averageLatencySeconds: Double?
        let totalEventsProcessed: Int
        let totalEventsFailed: Int
    }

    struct LogEntry: Decodable, Identifiable {
        let timestamp: String
        let level: String
        let message: String

        var id: String { timestamp + message }
    }
}

/// Minimal wire-timestamp parser local to this view (mirrors
/// `PodiumCore.PodiumDate.parse` without importing PodiumCore into
/// PodiumApp just for this one helper).
enum PodiumDiagnosticsDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

private func fetchDiagnostics(host: String, port: Int) async throws -> DiagnosticsSnapshot {
    let url = URL(string: "http://\(host):\(port)/api/diagnostics")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(DiagnosticsSnapshot.self, from: data)
}

#endif
