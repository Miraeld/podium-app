import SwiftUI
import Charts

struct AnalyticsView: View {
    @Environment(AppState.self) var state
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if let analytics = state.analytics {
                LazyVStack(spacing: 20) {
                    // Activity heatmap
                    ActivityHeatmapCard(dailySessions: analytics.dailySessions)

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

// MARK: - Activity Heatmap Card

struct ActivityHeatmapCard: View {
    let dailySessions: [Analytics.DailyCount]

    private var countByDate: [String: Int] {
        Dictionary(dailySessions.map { ($0.date, $0.count) }, uniquingKeysWith: { $1 })
    }

    private var totalSessions: Int {
        dailySessions.map(\.count).reduce(0, +)
    }

    private var weeks: [[Date]] {
        let cal = Calendar.current
        let today = Date()
        let startDate = cal.date(byAdding: .day, value: -363, to: today)!
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startDate)
        comps.weekday = 2 // Monday
        let firstMonday = cal.date(from: comps) ?? startDate

        var result: [[Date]] = []
        var weekStart = firstMonday
        for _ in 0..<52 {
            var week: [Date] = []
            for d in 0..<7 {
                if let day = cal.date(byAdding: .day, value: d, to: weekStart) {
                    week.append(day)
                }
            }
            result.append(week)
            weekStart = cal.date(byAdding: .day, value: 7, to: weekStart)!
        }
        return result
    }

    private var monthLabels: [(index: Int, label: String)] {
        var labels: [(index: Int, label: String)] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        var lastMonth = -1
        for (wIdx, week) in weeks.enumerated() {
            guard let firstDay = week.first else { continue }
            let month = Calendar.current.component(.month, from: firstDay)
            if month != lastMonth {
                labels.append((index: wIdx, label: fmt.string(from: firstDay)))
                lastMonth = month
            }
        }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Activity", trailing: "\(totalSessions) sessions")

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    // Month labels row
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(0..<weeks.count, id: \.self) { wIdx in
                            let label = monthLabels.first(where: { $0.index == wIdx })?.label
                            Text(label ?? " ")
                                .font(.system(size: 9))
                                .foregroundStyle(label != nil ? Color.secondary : Color.clear)
                                .frame(width: 12, alignment: .leading)
                        }
                    }

                    // Day cells grid
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(weeks.indices, id: \.self) { wIdx in
                            VStack(spacing: 3) {
                                ForEach(0..<7, id: \.self) { dIdx in
                                    let date = weeks[wIdx][dIdx]
                                    let key = dateKey(date)
                                    let count = countByDate[key] ?? 0
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(heatColor(count))
                                        .frame(width: 12, height: 12)
                                        .help("\(key): \(count) session\(count == 1 ? "" : "s")")
                                }
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 6) {
                Text("Less").font(.caption2).foregroundStyle(.tertiary)
                ForEach([0, 1, 3, 6, 10], id: \.self) { n in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(n))
                        .frame(width: 12, height: 12)
                }
                Text("More").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    private func heatColor(_ count: Int) -> Color {
        switch count {
        case 0:        return Color.primary.opacity(0.08)
        case 1...2:    return Color.cyan.opacity(0.4)
        case 3...5:    return Color(red: 0.3, green: 0.5, blue: 1).opacity(0.7)
        case 6...9:    return Color(red: 0.5, green: 0.3, blue: 1)
        default:       return Color(red: 0.7, green: 0.2, blue: 1)
        }
    }

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
