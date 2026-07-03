// EventsRouter — port of dashboard/server/routes/events.js.
//
// Endpoints: GET / (multi-dimensional filter + pagination) · GET /:id/full ·
// GET /facets. SQL lives in PodiumStore+Filters.swift (`EventFilter`,
// `listEventsFiltered`, `countEventsFiltered`, `getEventFull`,
// `eventFacets`) — this file is HTTP mapping only.

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
        group.get("/:id/full") { req, ctx in try await full(req, ctx, context: context) }
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

    // MARK: - GET /:id/full

    /// events.js lines 104–125: single event by integer id, with `data`
    /// left as the raw TEXT column value here — the Node handler attempts
    /// `JSON.parse` and, if it succeeds, replaces `event.data` with the
    /// *parsed object* (not the string) before responding. We replicate
    /// that by re-encoding through `EventFullResponse`, which carries a
    /// `JSONValue?` for `data` so a valid JSON string round-trips as a
    /// structured object on the wire, exactly like Node's `res.json`.
    private static func full(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rawId = try ctx.parameters.require("id")
        guard let id = Int(rawId) else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "id must be an integer"))
        }
        guard let event = try context.store.getEventFull(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Event not found"))
        }

        let parsedData: JSONValue?
        if let raw = event.data, let rawBytes = raw.data(using: .utf8),
           let parsed = try? PodiumJSON.decoder.decode(JSONValue.self, from: rawBytes) {
            parsedData = parsed
        } else if let raw = event.data {
            parsedData = .string(raw)
        } else {
            parsedData = nil
        }

        let full = EventFullResponse.Event(
            id: event.id ?? 0,
            sessionId: event.sessionId,
            agentId: event.agentId,
            eventType: event.eventType,
            toolName: event.toolName,
            summary: event.summary,
            data: parsedData,
            createdAt: event.createdAt
        )
        return try JSONResponse(EventFullResponse(event: full))
    }

    // MARK: - GET /facets

    private static func facets(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let (eventTypes, toolNames) = try context.store.eventFacets()
        return try JSONResponse(EventFacets(eventTypes: eventTypes, toolNames: toolNames))
    }
}

/// `GET /api/events/:id/full` response — `data` is `JSONValue?` rather than
/// `String?` (unlike the plain `DashboardEvent`/`EventFull` models) because
/// Node's handler replaces the string column with its `JSON.parse`d form
/// when parseable (events.js lines 116–123), so the wire shape genuinely
/// differs from the list endpoint's `data: string | null`.
private struct EventFullResponse: Encodable {
    struct Event: Encodable {
        let id: Int
        let sessionId: String
        let agentId: String?
        let eventType: String
        let toolName: String?
        let summary: String?
        let data: JSONValue?
        let createdAt: String
    }
    let event: Event
}
