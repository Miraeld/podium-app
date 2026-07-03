// SessionsRouter — port of dashboard/server/routes/sessions.js.
//
// Endpoints: GET / · GET /facets · GET /:id · GET /:id/stats · POST / ·
// PATCH /:id · GET /:id/transcripts (501 — see below) · GET /:id/transcript
// (501, explicitly required by the task spec).
//
// DEVIATION from a full 1:1 port (see final task report): `/:id/transcripts`
// (the transcript *listing* endpoint, sessions.js lines 300–489) walks
// `~/.claude/projects/**` via `lib/claude-home.js`'s `getTranscriptPath` /
// `findSubagentTranscriptPath` / snapshot-fallback helpers. None of that
// filesystem-discovery machinery exists yet in PodiumCore (P3.1 "Transcript
// engine" — plan §5 — is still ⬜, and P2.2's fence is Routes/ + Database/
// only). Stubbing `/:id/transcripts` with 501 rather than a shallow partial
// port keeps this router's *other* endpoints fully correct instead of
// half-porting a filesystem walk with no backing engine. `/:id/transcript`
// (singular, full JSONL parse) was already explicitly scoped to 501 by the
// task prompt for the same reason (P3.1 dependency).
//
// SQL/filter logic lives in PodiumCore/Database/PodiumStore+Filters.swift
// (`SessionFilter`, `listSessionsFiltered`, `countSessions`,
// `sessionCwdFacets`) — this file is HTTP mapping only.

import Foundation
import Hummingbird
import PodiumCore

public enum SessionsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/sessions")

        group.get { req, ctx in try await list(req, ctx, context: context) }
        group.get("/facets") { req, ctx in try await facets(req, ctx, context: context) }
        group.get("/:id") { req, ctx in try await detail(req, ctx, context: context) }
        group.get("/:id/stats") { req, ctx in try await stats(req, ctx, context: context) }
        // Task spec (P2.2) mandates this EXACT flat-string error body —
        // `{"error": "transcript parsing lands in P3.1"}` — not the
        // `{code, message}` object shape used by every other error response
        // in this file, so `ErrorResponse` (not `CodedErrorResponse`) is
        // deliberate here.
        group.get("/:id/transcripts") { _, _ in
            try JSONResponse(status: .notImplemented, ErrorResponse("transcript parsing lands in P3.1"))
        }
        group.get("/:id/transcript") { _, _ in
            try JSONResponse(status: .notImplemented, ErrorResponse("transcript parsing lands in P3.1"))
        }
        group.post { req, ctx in try await create(req, ctx, context: context) }
        group.patch("/:id") { req, ctx in try await patch(req, ctx, context: context) }
    }

    // MARK: - GET /

    /// sessions.js lines 43–171: dynamic-WHERE list with search/status/cwd
    /// filters, three sort modes (`time` default, `duration`, `price`), and
    /// per-row cost attached from `token_usage` + `model_pricing`.
    private static func list(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let limit = min(req.uri.queryInt("limit", fallback: 50, min: 0), 10000)
        let offset = req.uri.queryInt("offset", fallback: 0, min: 0)
        let filter = PodiumStore.SessionFilter(
            q: req.uri.queryTrimmed("q"),
            status: req.uri.queryValue("status"),
            cwd: req.uri.queryValue("cwd"),
            sortBy: req.uri.queryValue("sort_by") ?? "time",
            sortDesc: req.uri.queryValue("sort_desc") != "false"
        )

        let total = try context.store.countSessions(matching: filter)
        let sessions = try context.store.listSessionsFiltered(matching: filter, limit: limit, offset: offset)

        return try JSONResponse(SessionsResponse(sessions: sessions, total: total, limit: limit, offset: offset))
    }

    // MARK: - GET /facets

    private static func facets(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let cwds = try context.store.sessionCwdFacets()
        return try JSONResponse(SessionFacets(cwds: cwds))
    }

    // MARK: - GET /:id

    private static func detail(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }
        let agents = try context.store.listAgentsBySession(sessionId: id)
        let events = try context.store.listEventsBySession(sessionId: id)
        return try JSONResponse(SessionDetailResponse(session: session, agents: agents, events: events))
    }

    // MARK: - GET /:id/stats

    /// sessions.js lines 196–253: aggregated counts for the SessionOverview
    /// panel, all computed in SQL.
    private static func stats(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard try context.store.getSession(id: id) != nil else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let store = context.store
        let totalEvents = try store.sessionEventCount(sessionId: id)
        let eventsByType = try store.sessionEventTypeCounts(sessionId: id)
            .map { SessionStats.EventTypeCount(eventType: $0.eventType, count: $0.count) }
        let tools = try store.sessionToolUsageCounts(sessionId: id)
            .map { SessionStats.ToolCount(toolName: $0.toolName, count: $0.count) }
        let errors = try store.sessionErrorCount(sessionId: id)
        let timeRange = try store.sessionEventTimeRange(sessionId: id)
        let subagentTypeRows = try store.sessionAgentTypeCounts(sessionId: id)
        let agentStatusRows = try store.sessionAgentStatusCounts(sessionId: id)
        let tokenTotals = try store.sessionTokenTotals(sessionId: id)

        // Aggregate agent counts by category (sessions.js lines 218–239).
        var byStatus: [String: Int] = [:]
        var total = 0
        for row in agentStatusRows {
            total += row.count
            byStatus[row.status] = row.count
        }
        let compactionCount = subagentTypeRows.first { $0.subagentType == "compaction" }?.count ?? 0
        let mainSubCounts = try store.sessionAgentTypeCountsByType(sessionId: id)
        let mainCount = mainSubCounts["main"] ?? 0
        let subagentCount = mainSubCounts["subagent"] ?? 0

        let agentCounts = SessionStats.AgentCounts(
            total: total, main: mainCount, subagent: subagentCount, compaction: compactionCount, byStatus: byStatus
        )
        let subagentTypes = subagentTypeRows
            .filter { $0.subagentType != "compaction" }
            .map { SessionStats.SubagentTypeCount(subagentType: $0.subagentType, count: $0.count) }

        let sessionStats = SessionStats(
            sessionId: id,
            totalEvents: totalEvents,
            eventsByType: eventsByType,
            toolsUsed: tools,
            errorCount: errors,
            firstEventAt: timeRange.firstAt,
            lastEventAt: timeRange.lastAt,
            agents: agentCounts,
            subagentTypes: subagentTypes,
            tokens: SessionStats.TokenCounts(
                inputTokens: tokenTotals.totalInput,
                outputTokens: tokenTotals.totalOutput,
                cacheReadTokens: tokenTotals.totalCacheRead,
                cacheWriteTokens: tokenTotals.totalCacheWrite
            )
        )
        return try JSONResponse(sessionStats)
    }

    // MARK: - POST /

    /// sessions.js lines 255–277: idempotent create-by-id (returns the
    /// existing row with `created: false` if the id already exists),
    /// broadcasts `session_created` only on actual insert.
    private static func create(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: SessionCreateRequest.self)
        guard let id = body.id, !id.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "id is required"))
        }

        if let existing = try context.store.getSession(id: id) {
            return try JSONResponse(status: .ok, SessionCreateResponse(session: existing, created: false))
        }

        try context.store.insertSession(
            id: id, name: body.name, status: .active, cwd: body.cwd, model: body.model, metadata: body.metadata
        )
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "session insert did not persist"))
        }
        await context.broadcaster.broadcast(type: "session_created", data: session)
        return try JSONResponse(status: .created, SessionCreateResponse(session: session, created: true))
    }

    // MARK: - PATCH /:id

    /// sessions.js lines 279–297: partial update (name/status/ended_at/
    /// metadata — the task spec calls out name/status but the Node body
    /// also accepts `ended_at`; `PodiumStore.updateSession` already exposes
    /// that fourth field, wired through here for full parity).
    private static func patch(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard try context.store.getSession(id: id) != nil else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: SessionPatchRequestExtended.self)
        try context.store.updateSession(id: id, name: body.name, status: body.status, endedAt: body.endedAt, metadata: body.metadata)

        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "session update did not persist"))
        }
        await context.broadcaster.broadcast(type: "session_updated", data: session)
        return try JSONResponse(SessionDetailPatchResponse(session: session))
    }
}

/// `POST /api/sessions` response envelope (sessions.js lines 263, 276).
private struct SessionCreateResponse: Encodable {
    let session: Session
    let created: Bool
}

/// `PATCH /api/sessions/:id` response envelope (sessions.js line 296).
private struct SessionDetailPatchResponse: Encodable {
    let session: Session
}

/// `PATCH /api/sessions/:id` request body, extended with `ended_at` /
/// `metadata` beyond the task-spec-named name/status — sessions.js's actual
/// handler (line 280) destructures all four from `req.body`.
private struct SessionPatchRequestExtended: Decodable {
    let name: String?
    let status: SessionStatus?
    let endedAt: String?
    let metadata: String?
}
