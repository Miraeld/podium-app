// ExportRouter — port of dashboard/server/routes/export.js.
//
// GET  /api/export/session/:id — download a full JSON bundle for one
//   session: session + agents (ASC) + events (ASC) + token_usage.
// POST /api/export/session     — import a bundle (same handler as below).
// POST /api/import/session     — import a bundle. Node mounts `exportRouter`
//   at BOTH `/api/import` and `/api/export` (index.js lines 79 & 83), so the
//   POST /session handler is reachable under either prefix — replicated here
//   by mounting the same routes on both groups.
//
// Deviation from the P4.3 task prompt's paraphrase: the prompt describes
// this as "a zip archive (session JSON + events + transcript files)" and
// that's why ZIPFoundation was added to Package.swift. The actual Node
// reference (routes/export.js, read in full for this port) does no such
// thing — it's a plain `res.json(bundle)` with a `Content-Disposition:
// attachment` header, no zip, no transcript files. Per working agreement
// #3 ("behavioral parity with the Node code beats elegance"), this port
// matches export.js exactly. ZIPFoundation is left in Package.swift
// unused by this router (P4.3's predecessor may have had another use in
// mind for cc-config backups, but cc-mutate.js/CcMutate.swift also don't
// use zip — see this task's final report).
//
// SQL for both directions lives in
// `PodiumCore/Database/PodiumStore+SessionBundle.swift`; this file is HTTP
// mapping only.

import Foundation
import Hummingbird
import HTTPTypes
import PodiumCore

public enum ExportRouterMount: RouterMount {
    /// export.js's `IMPORT_JSON_LIMIT = "50mb"` — session exports can be many
    /// megabytes, well over the global 1 MB cap `RequestDecoding.jsonBodyLimit`
    /// applies to every other route.
    private static let importBodyLimit = 50 * 1024 * 1024

    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let exportGroup = router.group("/api/export")
        exportGroup.get("/session/:id") { req, ctx in try exportSession(req, ctx, context: context) }
        exportGroup.post("/session") { req, ctx in try await importSession(req, ctx, context: context) }

        let importGroup = router.group("/api/import")
        importGroup.post("/session") { req, ctx in try await importSession(req, ctx, context: context) }
    }

    // MARK: - GET /api/export/session/:id

    /// export.js lines 20–51. `Content-Disposition` mirrors Node's
    /// `attachment; filename="podium-session-<first 8 chars of id>.json"`.
    private static func exportSession(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) throws -> JSONResponse {
        let sessionId = try ctx.parameters.require("id")
        let store = context.store

        guard let session = try store.getSession(id: sessionId) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let bundle = SessionExportBundle(
            session: session,
            agents: try store.exportAgentsBySessionAscending(sessionId: sessionId),
            events: try store.exportEventsBySessionAscending(sessionId: sessionId),
            tokenUsage: try store.exportTokenUsageBySession(sessionId: sessionId)
        )

        let shortId = String(sessionId.prefix(8))
        return try JSONResponse(
            bundle,
            extraHeaders: [.contentDisposition: "attachment; filename=\"podium-session-\(shortId).json\""]
        )
    }

    // MARK: - POST /api/export/session · POST /api/import/session

    /// export.js lines 58–177. Validates `podium_export_version` and
    /// `session.id` before running the all-or-nothing import transaction.
    private static func importSession(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let buffer = try await mutableRequest.collectBody(upTo: importBodyLimit)
        let data = buffer.readableBytesView.isEmpty ? Data("{}".utf8) : Data(buffer.readableBytesView)

        let bundle: SessionExportBundle
        do {
            bundle = try PodiumJSON.decoder.decode(SessionExportBundle.self, from: data)
        } catch {
            // Mirrors export.js's `!session || !session.id` INVALID_INPUT
            // path — any decode failure means the body wasn't a usable
            // bundle (missing/malformed `session` is the common case).
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(code: "INVALID_INPUT", message: "bundle.session.id is required")
            )
        }

        guard bundle.podiumExportVersion == SessionExportBundle.currentVersion else {
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(
                    code: "UNSUPPORTED_VERSION",
                    message: "Only podium_export_version \"\(SessionExportBundle.currentVersion)\" is supported"
                )
            )
        }

        do {
            try context.store.importSessionBundle(bundle)
        } catch {
            return try JSONResponse(
                status: .internalServerError,
                CodedErrorResponse(code: "IMPORT_FAILED", message: "\(error)")
            )
        }

        return try JSONResponse(SessionImportResult(sessionId: bundle.session.id))
    }
}
