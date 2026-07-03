// AnalyticsRouter — port of dashboard/server/routes/analytics.js.
//
// Single endpoint: GET /api/analytics. `tz_offset` (minutes) shifts the
// `daily_events`/`daily_sessions` bucketing into the caller's local
// timezone via a single SQLite modifier (`DATE(created_at, ?)`) — simpler
// than stats.js's two-modifier `countEventsToday`, since here we're just
// re-labeling the DATE() bucket, not computing a UTC boundary.

import Foundation
import Hummingbird
import PodiumCore

public enum AnalyticsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        router.get("/api/analytics") { req, ctx in try await get(req, ctx, context: context) }
    }

    /// analytics.js lines 13–60. `tz_offset` negated into the modifier
    /// exactly like stats.js: `${-offsetMin} minutes`; falls back to
    /// `"+0 minutes"` (not `"0 minutes"` — matches Node's literal string)
    /// when the param is absent/unparseable.
    private static func get(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rawOffset = req.uri.queryIntOrNil("tz_offset")
        let tzModifier = rawOffset.map { "\(-$0) minutes" } ?? "+0 minutes"

        let store = context.store
        let tokenTotals = try store.getTokenTotals()
        let toolUsage = try store.toolUsageCounts()
        let dailyEvents = try store.dailyEventCounts(tzModifier: tzModifier)
        let dailySessions = try store.dailySessionCounts(tzModifier: tzModifier)
        let agentTypes = try store.agentTypeDistribution()
        let overview = try store.stats()
        let agentsByStatus = try store.agentStatusCounts()
        let sessionsByStatus = try store.sessionStatusCounts()
        let totalSubagents = try store.totalSubagentCount()
        let eventTypes = try store.eventTypeCounts()
        let avgEvents = try store.avgEventsPerSession()

        // analytics.js lines 32–39: total cost across every token_usage row
        // (NOT per-session — each row costed independently and summed).
        let pricingRules = try store.listPricing()
        let allTokenUsage = try store.listAllTokenUsage()
        var totalCost = 0.0
        for usage in allTokenUsage {
            totalCost += CostCalculator.totalCost(tokenRows: [CostTokenRow(usage)], pricingRules: pricingRules)
        }

        let response = AnalyticsResponse(
            tokens: Analytics.TokenStats(
                totalInput: tokenTotals.totalInput,
                totalOutput: tokenTotals.totalOutput,
                totalCacheRead: tokenTotals.totalCacheRead,
                totalCacheWrite: tokenTotals.totalCacheWrite
            ),
            totalCost: totalCost,
            toolUsage: toolUsage.map { Analytics.ToolUsageStat(toolName: $0.toolName, count: $0.count) },
            dailyEvents: dailyEvents.map { Analytics.DailyCount(date: $0.date, count: $0.count) },
            dailySessions: dailySessions.map { Analytics.DailyCount(date: $0.date, count: $0.count) },
            agentTypes: agentTypes.map { Analytics.AgentTypeStat(subagentType: $0.subagentType, count: $0.count) },
            eventTypes: eventTypes.map { Analytics.EventTypeStat(eventType: $0.eventType, count: $0.count) },
            avgEventsPerSession: avgEvents,
            totalSubagents: totalSubagents,
            overview: Analytics.Overview(
                totalSessions: overview.totalSessions,
                activeSessions: overview.activeSessions,
                activeAgents: overview.activeAgents,
                totalAgents: overview.totalAgents,
                totalEvents: overview.totalEvents
            ),
            agentsByStatus: agentsByStatus,
            sessionsByStatus: sessionsByStatus
        )
        return try JSONResponse(response)
    }
}

/// `GET /api/analytics` response — `Analytics` plus `total_cost`
/// (analytics.js line 48), which the model doesn't carry (see report
/// deviation note: client/src/lib/types.ts's `Analytics` interface omits
/// `total_cost` even though the server always sends it — kept here as an
/// additive field, harmless for a client that ignores unknown JSON keys).
private struct AnalyticsResponse: Encodable {
    let tokens: Analytics.TokenStats
    let totalCost: Double
    let toolUsage: [Analytics.ToolUsageStat]
    let dailyEvents: [Analytics.DailyCount]
    let dailySessions: [Analytics.DailyCount]
    let agentTypes: [Analytics.AgentTypeStat]
    let eventTypes: [Analytics.EventTypeStat]
    let avgEventsPerSession: Double
    let totalSubagents: Int
    let overview: Analytics.Overview
    let agentsByStatus: [String: Int]
    let sessionsByStatus: [String: Int]
}
