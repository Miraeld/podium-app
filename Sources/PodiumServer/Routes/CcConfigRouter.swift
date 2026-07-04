// CcConfigRouter — port of dashboard/server/routes/cc-config.js.
//
// GET /overview /skills /agents /commands /output-styles /plugins /mcp
// /hooks /settings /memory /marketplaces /keybindings /statusline
// /hook-scripts /backups · GET /file · PUT /file · DELETE /file.
//
// Read-only discovery lives in `PodiumCore/Discovery/CcConfig.swift`;
// mutation (write/delete + backup) lives in `PodiumCore/Discovery/CcMutate.swift`.
// This file is HTTP mapping only: query-param parsing (`scope`/`cwd`),
// `CcMutateError.code` → HTTP status (mirrors cc-config.js's
// `ERR_TO_STATUS` table), and the `cc_config_changed` broadcast on
// successful mutation (cc-config.js's `emitChanged`).

import Foundation
import Hummingbird
import HTTPTypes
import PodiumCore

public enum CcConfigRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/cc-config")

        group.get("/overview") { req, ctx in try overview(req, ctx) }
        group.get("/skills") { req, ctx in try skills(req, ctx) }
        group.get("/agents") { req, ctx in try agentsList(req, ctx) }
        group.get("/commands") { req, ctx in try commands(req, ctx) }
        group.get("/output-styles") { req, ctx in try outputStyles(req, ctx) }
        group.get("/plugins") { req, ctx in try plugins(req, ctx) }
        group.get("/mcp") { req, ctx in try mcp(req, ctx) }
        group.get("/hooks") { req, ctx in try hooks(req, ctx) }
        group.get("/settings") { req, ctx in try settings(req, ctx) }
        group.get("/memory") { req, ctx in try memory(req, ctx) }
        group.get("/marketplaces") { req, ctx in try marketplaces(req, ctx) }
        group.get("/keybindings") { req, ctx in try keybindings(req, ctx) }
        group.get("/statusline") { req, ctx in try statusline(req, ctx) }
        group.get("/hook-scripts") { req, ctx in try hookScripts(req, ctx) }
        group.get("/backups") { req, ctx in try backups(req, ctx) }
        group.get("/file") { req, ctx in try getFile(req, ctx) }
        group.put("/file") { req, ctx in try await putFile(req, ctx, context: context) }
        group.delete("/file") { req, ctx in try await deleteFile(req, ctx, context: context) }
    }

    // MARK: - Query-param helpers (cc-config.js `scopeOf`/`cwdOf`)

    private static func scopeOf(_ req: Request) -> String {
        let s = req.uri.queryValue("scope") ?? "all"
        return (s == "user" || s == "project") ? s : "all"
    }

    private static func cwdOf(_ req: Request) -> String? {
        req.uri.queryValue("cwd")
    }

    // MARK: - GET routes

    private static func overview(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readOverview(cwd: cwdOf(req)))
    }

    private static func skills(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readSkills(scope: scopeOf(req), cwd: cwdOf(req))))
    }

    private static func agentsList(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readAgents(scope: scopeOf(req), cwd: cwdOf(req))))
    }

    private static func commands(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readCommands(scope: scopeOf(req), cwd: cwdOf(req))))
    }

    private static func outputStyles(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readOutputStyles(scope: scopeOf(req), cwd: cwdOf(req))))
    }

    private static func plugins(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readPlugins())
    }

    private static func mcp(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readMcpServers(cwd: cwdOf(req)))
    }

    private static func hooks(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readHooks(cwd: cwdOf(req))))
    }

    private static func settings(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readSettings(cwd: cwdOf(req))))
    }

    private static func memory(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(ItemsEnvelope(items: CcConfig.readMemory(cwd: cwdOf(req))))
    }

    private static func marketplaces(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readMarketplaces())
    }

    private static func keybindings(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readKeybindings())
    }

    private static func statusline(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readStatusline())
    }

    private static func hookScripts(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        try JSONResponse(CcConfig.readHookScripts())
    }

    private static func backups(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        let scope = req.uri.queryValue("scope").flatMap { $0 == "user" || $0 == "project" ? $0 : nil }
        let type = req.uri.queryValue("type")
        return try JSONResponse(ItemsEnvelope(items: CcMutate.listBackups(scope: scope, type: type, cwd: cwdOf(req))))
    }

    // MARK: - GET /file

    private static func getFile(_ req: Request, _ ctx: ServerRequestContext) throws -> JSONResponse {
        guard let path = req.uri.queryValue("path"), !path.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "BAD_PATH", message: "path is required"))
        }
        let result = CcConfig.readFileSafe(path, cwd: cwdOf(req))
        if let error = result.error {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "READ_DENIED", message: error))
        }
        return try JSONResponse(result)
    }

    // MARK: - PUT /file

    private struct MutateFileBody: Decodable {
        let scope: String?
        let type: String?
        let name: String?
        let content: String?
    }

    private static func putFile(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: MutateFileBody.self)
        guard let scope = body.scope, let type = body.type else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "EBADREQ", message: "scope and type are required"))
        }
        do {
            let result = try CcMutate.writeArtifact(scope: scope, type: type, name: body.name, content: body.content ?? "", cwd: cwdOf(req))
            await emitChanged(context: context, action: "write", scope: scope, type: type, name: body.name)
            return try JSONResponse(result)
        } catch let error as CcMutateError {
            return try mutateErrorResponse(error)
        }
    }

    // MARK: - DELETE /file

    private static func deleteFile(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: MutateFileBody.self)
        guard let scope = body.scope, let type = body.type else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "EBADREQ", message: "scope and type are required"))
        }
        do {
            let result = try CcMutate.deleteArtifact(scope: scope, type: type, name: body.name, cwd: cwdOf(req))
            await emitChanged(context: context, action: "delete", scope: scope, type: type, name: body.name)
            return try JSONResponse(result)
        } catch let error as CcMutateError {
            return try mutateErrorResponse(error)
        }
    }

    // MARK: - Helpers

    /// Port of cc-config.js's `emitChanged` — broadcasts `cc_config_changed`
    /// with `{source: "dashboard", action, scope, type, name}` after a
    /// successful mutation.
    private static func emitChanged(context: ServerContext, action: String, scope: String, type: String, name: String?) async {
        let payload = JSONValue.object([
            "source": .string("dashboard"),
            "action": .string(action),
            "scope": .string(scope),
            "type": .string(type),
            "name": name.map(JSONValue.string) ?? .null,
        ])
        await context.broadcaster.broadcast(type: "cc_config_changed", data: payload)
    }

    /// Port of cc-config.js's `ERR_TO_STATUS` map + `mutateError`.
    private static func mutateErrorResponse(_ error: CcMutateError) throws -> JSONResponse {
        let status: HTTPResponse.Status
        switch error.code {
        case .badType, .badScope, .badName, .badContent, .outOfRoot: status = .badRequest
        case .tooLarge: status = .contentTooLarge
        case .notFound: status = .notFound
        case .internalError: status = .internalServerError
        }
        return try JSONResponse(status: status, CodedErrorResponse(code: error.code.rawValue, message: error.message))
    }
}

/// `{"items": [...]}` — the envelope cc-config.js wraps every list endpoint
/// in (`res.json({ items: ... })`).
private struct ItemsEnvelope<Item: Encodable>: Encodable {
    let items: [Item]
}
