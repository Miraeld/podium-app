import SwiftUI
import Charts

// MARK: - Status Dot

struct StatusDot: View {
    let color: Color
    var active: Bool = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulsing ? 1.8 : 1)
                    .opacity(pulsing ? 0 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            guard active else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .white
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Glass Section Header

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Live Badge

struct LiveBadge: View {
    @State private var opacity = 1.0

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                        opacity = 0.2
                    }
                }
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.red.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    let isConnected: Bool

    var body: some View {
        Image(systemName: isConnected ? "wifi" : "wifi.slash")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isConnected ? .green : .red)
            .help(isConnected ? "Connected to Podium" : "Podium server unreachable")
    }
}

// MARK: - Token Bar

struct TokenBar: View {
    let label: String
    let value: Int
    let max: Int
    let color: Color

    private var fraction: Double { max > 0 ? Double(value) / Double(max) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Theme.formatTokens(value)).font(.caption.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading Spinner

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Agent type icon

func agentIcon(_ type: Agent.AgentType, subtype: String?) -> String {
    if type == .main { return "brain.head.profile" }
    let t = subtype?.lowercased() ?? ""
    if t.contains("backend") { return "server.rack" }
    if t.contains("frontend") { return "macwindow" }
    if t.contains("qa") || t.contains("test") { return "checkmark.shield" }
    if t.contains("review") { return "magnifyingglass" }
    if t.contains("groom") { return "doc.text.magnifyingglass" }
    if t.contains("release") { return "tag" }
    if t.contains("orchestr") { return "network" }
    return "person.crop.circle"
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    var color: Color = .secondary
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? color.opacity(0.22) : Color.primary.opacity(0.06))
                .foregroundStyle(active ? color : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        active ? color.opacity(0.4) : Color.primary.opacity(0.10),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mini Bar Chart (Charts-free fallback for tool usage)

struct MiniBarChart: View {
    let items: [(String, Int)]
    var color: Color = .cyan

    private var maxVal: Int { items.map(\.1).max() ?? 1 }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items.prefix(8), id: \.0) { name, count in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: geo.size.width * (Double(count) / Double(maxVal)))
                    }
                    .frame(height: 14)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                }
            }
        }
    }
}
