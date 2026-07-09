// EventsRouter — port of dashboard/server/routes/events.js.
//
// Endpoints: GET / (multi-dimensional filter + pagination) · GET /facets.
// SQL lives in PodiumStore+Filters.swift (`EventFilter`, `listEventsFiltered`,
// `countEventsFiltered`, `eventFacets`) — this file is HTTP mapping only.
//
// B6 (pre-1.0 audit): `GET /:id/full` was removed — not referenced anywhere
// in the vendored client source (no fetch of `/full` in src/**, confirmed
// against both the compiled WebClient bundle and the client TypeScript
// checkout). `PodiumStore.getEventFull` (the backing SQL) was left in place
// since it's harmless, self-contained store surface, not HTTP-reachable
// dead code.

import Foundation
import Hummingbird
import PodiumCore

public enum EventsRouterMount: RouterMount {
    private static let maxLimit = 500
    private static let defaultLimit = 50

    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/events")

        group.get { req, ctx in try await list(req, ctx, context: context) }
        group.get("/facets") { req, ctx in try await facets(req, ctx, context: context) }
    }

    // MARK: - GET /

    /// events.js lines 79–102: `event_type`/`tool_name`/`agent_id`/
    /// `session_id` are CSV lists (IN clauses), `q` is a 3-column LIKE, `from`/
    /// `to` bound `created_at`. `limit` clamped to [1, 500] default 50,
    /// `offset` clamped to [0, MAX_SAFE_INTEGER] default 0.
    private static func list(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let limit = req.uri.queryInt("limit", fallback: defaultLimit, min: 1, max: maxLimit)
        let offset = req.uri.queryInt("offset", fallback: 0, min: 0)

        let filter = PodiumStore.EventFilter(
            eventType: req.uri.queryCSV("event_type"),
            toolName: req.uri.queryCSV("tool_name"),
            agentId: req.uri.queryCSV("agent_id"),
            sessionId: req.uri.queryCSV("session_id"),
            q: req.uri.queryTrimmed("q"),
            from: req.uri.queryDate("from"),
            to: req.uri.queryDate("to")
        )

        let events = try context.store.listEventsFiltered(matching: filter, limit: limit, offset: offset)
        let total = try context.store.countEventsFiltered(matching: filter)

        return try JSONResponse(EventsResponse(events: events, total: total, limit: limit, offset: offset))
    }

    // MARK: - GET /facets

    private static func facets(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let (eventTypes, toolNames) = try context.store.eventFacets()
        return try JSONResponse(EventFacets(eventTypes: eventTypes, toolNames: toolNames))
    }
}
