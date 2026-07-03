// StatsRouter — port of dashboard/server/routes/stats.js.
//
// Single endpoint: GET /api/stats. `tz_offset` (minutes, per
// `Date.getTimezoneOffset()` — e.g. 420 for PDT) selects "today" in the
// client's local timezone rather than UTC.

import Foundation
import Hummingbird
import PodiumCore

public enum StatsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        router.get("/api/stats") { req, ctx in try await get(req, ctx, context: context) }
    }

    /// stats.js lines 12–31: `toLocal`/`toUTC` SQLite modifiers built from
    /// the raw offset — `${-offsetMin} minutes` and `${offsetMin} minutes`
    /// respectively (NOT the same value — see `PodiumStore.countEventsToday`
    /// doc comment), passed straight through to `countEventsToday`.
    private static func get(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let offsetMin = req.uri.queryInt("tz_offset", fallback: 0)
        let toLocal = "\(-offsetMin) minutes"
        let toUTC = "\(offsetMin) minutes"

        let overview = try context.store.stats()
        let agentsByStatus = try context.store.agentStatusCounts()
        let sessionsByStatus = try context.store.sessionStatusCounts()
        let eventsToday = try context.store.countEventsToday(toLocal: toLocal, toUTC: toUTC)
        let wsConnections = await context.broadcaster.connectionCount

        let response = Stats(
            totalSessions: overview.totalSessions,
            activeSessions: overview.activeSessions,
            activeAgents: overview.activeAgents,
            totalAgents: overview.totalAgents,
            totalEvents: overview.totalEvents,
            eventsToday: eventsToday,
            wsConnections: wsConnections,
            agentsByStatus: agentsByStatus,
            sessionsByStatus: sessionsByStatus
        )
        return try JSONResponse(response)
    }
}
