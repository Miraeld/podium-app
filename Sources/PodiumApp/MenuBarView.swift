import SwiftUI

// MARK: - Stat Mini Row

private struct StatMiniRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Menu Bar Content View

struct MenuBarContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Podium")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
                Circle()
                    .fill(state.isServerReachable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Stats 2x2 grid
            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 8) {
                StatMiniRow(
                    label: "Active Sessions",
                    value: "\(state.stats?.activeSessions ?? 0)"
                )
                StatMiniRow(
                    label: "Active Agents",
                    value: "\(state.stats?.activeAgents ?? 0)"
                )
                StatMiniRow(
                    label: "Events Today",
                    value: Theme.formatTokens(state.stats?.eventsToday ?? 0)
                )
                StatMiniRow(
                    label: "Total Cost",
                    value: state.totalCost.map { Theme.formatCost($0.totalCost) } ?? "—"
                )
            }
            .padding(10)
            .glassCard(radius: 10)

            Divider()

            // Recent sessions header
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Recent sessions list
            VStack(spacing: 6) {
                if state.sessions.isEmpty {
                    Text("No sessions")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(state.sessions.prefix(5))) { session in
                        HStack(spacing: 8) {
                            StatusDot(
                                color: Theme.color(session: session.status),
                                active: session.status == .active
                            )
                            Text(Theme.projectName(from: session.cwd))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Theme.shortDate(session.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(10)
            .glassCard(radius: 10)

            Divider()

            // Footer buttons
            HStack {
                Button("Open Podium") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
