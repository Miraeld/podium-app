import SwiftUI
import Charts

struct AnalyticsView: View {
    @Environment(AppState.self) var state
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if let analytics = state.analytics {
                LazyVStack(spacing: 20) {
                    // Token overview
                    TokenOverviewCard(tokens: analytics.tokens)

                    // Two-column: daily sessions + daily events
                    HStack(alignment: .top, spacing: 20) {
                        DailyChartCard(
                            title: "Daily Sessions",
                            data: analytics.dailySessions,
                            color: .cyan
                        )
                        DailyChartCard(
                            title: "Daily Events",
                            data: analytics.dailyEvents,
                            color: Color(red: 0.6, green: 0.4, blue: 1)
                        )
                    }

                    // Tool usage
                    ToolUsageCard(tools: analytics.toolUsage)

                    // Agent types
                    if !analytics.agentTypes.isEmpty {
                        AgentTypesCard(types: analytics.agentTypes)
                    }

                    // Summary stats
                    HStack(spacing: 16) {
                        MiniStat(
                            label: "Avg Events / Session",
                            value: String(format: "%.1f", analytics.avgEventsPerSession),
                            color: .yellow
                        )
                        MiniStat(
                            label: "Total Subagents",
                            value: "\(analytics.totalSubagents)",
                            color: Color(red: 0.6, green: 0.4, blue: 1)
                        )
                    }
                }
                .padding(24)
            } else if state.isLoading {
                LoadingView().frame(maxWidth: .infinity, minHeight: 400)
            } else {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: "No Analytics",
                    message: "Analytics will populate after your first session."
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await state.loadAnalytics()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    loaded = false
                    Task {
                        loaded = true
                        await state.loadAnalytics()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - Token Overview Card

struct TokenOverviewCard: View {
    let tokens: Analytics.TokenStats

    private var total: Int { tokens.totalInput + tokens.totalOutput + tokens.totalCacheRead + tokens.totalCacheWrite }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Token Usage", trailing: "\(Theme.formatTokens(total)) total")

            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 12) {
                TokenStat(label: "Input", value: tokens.totalInput, color: .cyan)
                TokenStat(label: "Output", value: tokens.totalOutput, color: Color(red: 0.6, green: 0.4, blue: 1))
                TokenStat(label: "Cache Read", value: tokens.totalCacheRead, color: .green)
                TokenStat(label: "Cache Write", value: tokens.totalCacheWrite, color: .yellow)
            }

            if total > 0 {
                VStack(spacing: 10) {
                    TokenBar(label: "Input",       value: tokens.totalInput,      max: total, color: .cyan)
                    TokenBar(label: "Output",      value: tokens.totalOutput,     max: total, color: Color(red: 0.6, green: 0.4, blue: 1))
                    TokenBar(label: "Cache Read",  value: tokens.totalCacheRead,  max: total, color: .green)
                    TokenBar(label: "Cache Write", value: tokens.totalCacheWrite, max: total, color: .yellow)
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }
}

struct TokenStat: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Theme.formatTokens(value))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75)
        }
    }
}

// MARK: - Daily Chart Card

struct DailyChartCard: View {
    let title: String
    let data: [Analytics.DailyCount]
    let color: Color

    private var maxCount: Int { data.map(\.count).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, trailing: "\(data.count) days")

            if data.isEmpty {
                Text("No data").font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(data.suffix(30)) { item in
                        AreaMark(
                            x: .value("Date", item.date),
                            y: .value("Count", item.count)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.5), color.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Date", item.date),
                            y: .value("Count", item.count)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisValueLabel().foregroundStyle(Color.secondary)
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                    }
                }
                .frame(height: 160)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}

// MARK: - Tool Usage Card

struct ToolUsageCard: View {
    let tools: [Analytics.ToolUsageStat]
    private var maxCount: Int { tools.map(\.count).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Top Tools Used", trailing: "\(tools.count) tools")

            if tools.isEmpty {
                Text("No data").font(.callout).foregroundStyle(.tertiary)
            } else {
                Chart {
                    ForEach(tools.prefix(12)) { item in
                        BarMark(
                            x: .value("Count", item.count),
                            y: .value("Tool", item.toolName)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.6, green: 0.4, blue: 1), Color(red: 0.3, green: 0.6, blue: 1)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text("\(item.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { v in
                        AxisValueLabel().foregroundStyle(Color.secondary)
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: CGFloat(min(tools.count, 12)) * 32 + 40)
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }
}

// MARK: - Agent Types Card

struct AgentTypesCard: View {
    let types: [Analytics.AgentTypeStat]
    private var total: Int { types.map(\.count).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Agent Types", trailing: "\(total) total")

            Chart {
                ForEach(types.sorted(by: { $0.count > $1.count }).prefix(10)) { item in
                    SectorMark(
                        angle: .value("Count", item.count),
                        innerRadius: .ratio(0.55),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Type", item.subagentType ?? "main"))
                    .cornerRadius(4)
                }
            }
            .frame(height: 200)
            .chartLegend(position: .trailing, alignment: .center)

            // Legend list
            ForEach(types.sorted(by: { $0.count > $1.count }).prefix(8)) { item in
                HStack {
                    Text(item.subagentType ?? "main")
                        .font(.caption)
                    Spacer()
                    Text("\(item.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", Double(item.count) / Double(max(total, 1)) * 100))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }
}
