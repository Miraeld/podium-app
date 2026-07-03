// AgentsRouter — port of dashboard/server/routes/agents.js.
//
// Endpoints: GET / (session_id | status | plain list) · GET /:id · POST / ·
// PATCH /:id. All SQL already existed as typed `PodiumStore` methods from
// P1.1 (listAgentsBySession / listAgentsByStatus / listAgents / getAgent /
// insertAgent / updateAgent) — this router is pure HTTP mapping.

import Foundation
import Hummingbird
import PodiumCore

public enum AgentsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/agents")

        group.get { req, ctx in try await list(req, ctx, context: context) }
        group.get("/:id") { req, ctx in try await detail(req, ctx, context: context) }
        group.post { req, ctx in try await create(req, ctx, context: context) }
        group.patch("/:id") { req, ctx in try await patch(req, ctx, context: context) }
    }

    // MARK: - GET /

    /// agents.js lines 12–29: `session_id` wins over `status`, which wins
    /// over the plain paginated list. Note the Node default limit is 10000
    /// (not 50 like sessions/events) when `limit` is absent or <= 0.
    private static func list(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rawLimit = req.uri.queryIntOrNil("limit")
        let limit = (rawLimit ?? 0) > 0 ? rawLimit! : 10000
        let offset = req.uri.queryInt("offset", fallback: 0, min: 0)
        let status = req.uri.queryValue("status")
        let sessionId = req.uri.queryValue("session_id")

        let agents: [Agent]
        if let sessionId {
            agents = try context.store.listAgentsBySession(sessionId: sessionId)
        } else if let status {
            let parsedStatus = AgentStatus(rawValue: status) ?? .waiting
            agents = try context.store.listAgentsByStatus(status: parsedStatus, limit: limit, offset: offset)
        } else {
            agents = try context.store.listAgents(limit: limit, offset: offset)
        }

        return try JSONResponse(AgentsResponse(agents: agents, limit: limit, offset: offset))
    }

    // MARK: - GET /:id

    private static func detail(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let agent = try context.store.getAgent(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Agent not found"))
        }
        return try JSONResponse(AgentDetailResponse(agent: agent))
    }

    // MARK: - POST /

    /// agents.js lines 39–68: id/session_id/name required, idempotent
    /// create-by-id, broadcasts `agent_created` only on actual insert.
    private static func create(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: AgentCreateRequest.self)
        guard let id = body.id, !id.isEmpty, !body.sessionId.isEmpty, !body.name.isEmpty else {
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(code: "INVALID_INPUT", message: "id, session_id, and name are required")
            )
        }

        if let existing = try context.store.getAgent(id: id) {
            return try JSONResponse(status: .ok, AgentCreateResponse(agent: existing, created: false))
        }

        try context.store.insertAgent(
            id: id, sessionId: body.sessionId, name: body.name, type: body.type ?? .main,
            subagentType: body.subagentType, status: body.status ?? .waiting, task: body.task,
            parentAgentId: body.parentAgentId, metadata: body.metadata
        )
        guard let agent = try context.store.getAgent(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "agent insert did not persist"))
        }
        await context.broadcaster.broadcast(type: "agent_created", data: agent)
        return try JSONResponse(status: .created, AgentCreateResponse(agent: agent, created: true))
    }

    // MARK: - PATCH /:id

    /// agents.js lines 70–89: `current_tool` is passed through even when
    /// `undefined` in the JS body falls back to `existing.current_tool` —
    /// i.e. an explicit `null` DOES clear it, but an *absent* key leaves it
    /// unchanged. `AgentPatchRequest.currentTool` being `nil` covers both
    /// "absent" and "explicit null" cases identically in Swift, so we
    /// preserve Node's "absent leaves unchanged" behavior by falling back to
    /// the existing value whenever the field is `nil`.
    private static func patch(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let existing = try context.store.getAgent(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Agent not found"))
        }

        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: AgentPatchRequest.self)
        let currentTool = body.currentTool ?? existing.currentTool

        try context.store.updateAgent(
            id: id, name: body.name, status: body.status, task: body.task,
            currentTool: currentTool, endedAt: body.endedAt, metadata: body.metadata
        )

        guard let agent = try context.store.getAgent(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "agent update did not persist"))
        }
        await context.broadcaster.broadcast(type: "agent_updated", data: agent)
        return try JSONResponse(AgentDetailResponse(agent: agent))
    }
}

private struct AgentDetailResponse: Encodable {
    let agent: Agent
}

private struct AgentCreateResponse: Encodable {
    let agent: Agent
    let created: Bool
}
