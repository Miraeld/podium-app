// RunRouter.swift — port of dashboard/server/routes/run.js.
//
// Endpoints: GET / (active) · GET /history · GET /cwds · GET /files ·
// GET /binary · POST / (start) · POST /:id/message · GET /:id (+ replay) ·
// DELETE /:id (kill). Broadcasts (`run_status`/`run_stream`/
// `run_input_ack`) happen inside `RunSpawner` itself (PodiumCore/Runs/),
// since they're driven by subprocess I/O events, not just this router's
// request/response cycle — this file is HTTP mapping + validation only.
//
// *** WIRE FORMAT NOTE — read before touching this file ***
// The `/api/run` family (everything except `GET /history`) is genuinely
// camelCase on the wire in the real Node app — `publicHandle()` in
// run-spawner.js and every route handler here build plain JS object
// literals (`permissionMode`, `resumeSessionId`, `exitCode`, `sessionId`,
// `messageId`, …), never passing through a snake_case serializer. Using the
// app's usual `JSONResponse`/`req.decodeJSONBody` (which both hard-code
// `PodiumJSON.encoder`/`.decoder`, i.e. snake_case conversion) against
// `RunHandle`/`RunCreateRequest`-shaped payloads would silently produce the
// WRONG wire keys and fail to decode the client's real camelCase request
// bodies. `PlainJSONResponse` below and the private `RunCreateBody`/
// `RunMessageBody` decode targets exist specifically to avoid that trap —
// see RunSpawner.swift's header comment for the full analysis. `GET
// /history` is the one endpoint that IS snake_case (it mirrors raw
// `dashboard_runs` SQL rows) plus one camelCase exception (`isLive`,
// spliced in after the query) — handled by `DashboardRun.encode(to:)`.
//
// Security model (routes/run.js's `sameOriginGuard`): this is a
// local-first dashboard. To stop a malicious webpage from drive-by
// spawning processes via CSRF, every route here enforces a same-origin /
// loopback-Origin check. Requests with no Origin/Referer (curl, server-to-
// server) are allowed; browser requests must claim a localhost-ish origin.

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import PodiumCore

// MARK: - Broadcaster conformance

// `Broadcaster` (WebSocket/Broadcaster.swift) already implements
// `broadcast(type:data:) async` with this exact signature — this
// conformance is free. See `RunSpawner.Broadcasting`'s doc comment for why
// PodiumCore can't just import `Broadcaster` directly.
extension Broadcaster: Broadcasting {}

// MARK: - Plain (non-snake-case) JSON response

/// Like `JSONResponse`, but encodes with a stock `JSONEncoder` — no
/// `keyEncodingStrategy`. Used for the `/api/run` live-handle family, whose
/// real Node wire format is camelCase (see file header).
private struct PlainJSONResponse: ResponseGenerator {
    let status: HTTPResponse.Status
    private let body: Data

    init<Payload: Encodable>(status: HTTPResponse.Status = .ok, _ payload: Payload) throws {
        self.status = status
        self.body = try JSONEncoder().encode(payload)
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }
}

public enum RunRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/run")

        group.get { req, ctx in try await withOriginGuard(req) { try await listActive(context: context) } }
        group.get("/history") { req, ctx in try await withOriginGuard(req) { try await history(req, context: context) } }
        group.get("/cwds") { req, ctx in try await withOriginGuard(req) { try await cwds(context: context) } }
        group.get("/files") { req, ctx in try await withOriginGuard(req) { try await files(req) } }
        group.get("/binary") { req, ctx in try await withOriginGuard(req) { try await binary() } }
        group.post { req, ctx in try await withOriginGuard(req) { try await create(req, context: context) } }
        group.post("/:id/message") { req, ctx in try await withOriginGuard(req) { try await sendMessage(req, ctx, context: context) } }
        group.get("/:id") { req, ctx in try await withOriginGuard(req) { try await detail(req, ctx, context: context) } }
        group.delete("/:id") { req, ctx in try await withOriginGuard(req) { try await kill(req, ctx, context: context) } }
    }

    // MARK: - Same-origin guard (routes/run.js `sameOriginGuard`)

    private static let allowedOriginHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    private static func hostAllowed(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host else { return false }
        return allowedOriginHosts.contains(host)
    }

    private static func originAllowed(_ req: Request) -> Bool {
        if let origin = req.headers[.origin], !origin.isEmpty {
            return hostAllowed(origin)
        }
        if let referer = req.headers[.referer], !referer.isEmpty {
            return hostAllowed(referer)
        }
        return true
    }

    private static func withOriginGuard(_ req: Request, _ body: () async throws -> JSONResponse) async throws -> JSONResponse {
        guard originAllowed(req) else {
            return try JSONResponse(status: .forbidden, CodedErrorResponse(code: "EBADORIGIN", message: "cross-origin requests are not allowed"))
        }
        return try await body()
    }

    // MARK: - Error mapping

    private static func errorStatus(_ error: RunSpawnerError) -> HTTPResponse.Status {
        switch error {
        case .notFound: return .notFound
        case .concurrency: return .tooManyRequests
        default: return .badRequest
        }
    }

    // MARK: - GET / (active runs)

    private static func listActive(context: ServerContext) async throws -> JSONResponse {
        let spawner = context.runSpawner
        let items = await spawner.listRuns()
        let maxConcurrent = await spawner.maxConcurrent()
        let activeCount = await spawner.liveCount()
        return try JSONResponse(rawJSON: JSONEncoder().encode(RunListResponse(items: items, maxConcurrent: maxConcurrent, activeCount: activeCount)))
    }

    // MARK: - GET /history

    /// `dashboard_runs` rows are snake_case (straight from SQL) with one
    /// camelCase exception: `isLive`, spliced in post-query by cross-
    /// referencing still-live in-memory handles (routes/run.js lines
    /// 114–132). `DashboardRun.encode(to:)` spells out both conventions —
    /// and emits unset columns as explicit `null` — via the `AnyEncodable`
    /// dictionary pattern, so no strategy can mangle the keys.
    private static func history(_ req: Request, context: ServerContext) async throws -> JSONResponse {
        let limit = req.uri.queryInt("limit", fallback: 50, min: 1, max: 500)
        let rows = (try? context.store.listDashboardRuns(limit: limit)) ?? []
        let liveIds = await context.runSpawner.liveRunIds()
        let items = rows.map { row in
            var item = row
            item.isLive = liveIds.contains(row.id)
            return item
        }
        return try JSONResponse(rawJSON: JSONEncoder().encode(RunHistoryResponse(items: items)))
    }

    // MARK: - GET /cwds

    private static func cwds(context: ServerContext) async throws -> JSONResponse {
        var seen = Set<String>()
        var items: [RunCwdSuggestion] = []
        func add(kind: String, path: String?, label: String?) {
            guard let path, !path.isEmpty else { return }
            let abs = (path as NSString).standardizingPath
            guard !seen.contains(abs) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(abs)
            items.append(RunCwdSuggestion(kind: kind, path: abs, label: label ?? (abs as NSString).lastPathComponent))
        }
        add(kind: "dashboard", path: FileManager.default.currentDirectoryPath, label: "Dashboard server")
        add(kind: "home", path: NSHomeDirectory(), label: "Home")
        let recents = (try? context.store.recentSessionCwds(limit: 30)) ?? []
        for recentCwd in recents {
            add(kind: "recent", path: recentCwd, label: (recentCwd as NSString).lastPathComponent)
        }
        return try JSONResponse(rawJSON: JSONEncoder().encode(RunCwdsResponse(items: items)))
    }

    // MARK: - GET /files

    private static func files(_ req: Request) async throws -> JSONResponse {
        let cwdParam = req.uri.queryValue("cwd")
        let cwd: String
        do {
            cwd = try RunPathUtils.sanitiseCwd(cwdParam)
        } catch let err as RunSpawnerError {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: err.code, message: err.message))
        }
        let q = req.uri.queryValue("q")
        let items = RunPathUtils.browseFiles(cwd: cwd, query: q)
        return try JSONResponse(rawJSON: JSONEncoder().encode(RunFilesResponse(items: items)))
    }

    // MARK: - GET /binary

    private static func binary() async throws -> JSONResponse {
        try JSONResponse(rawJSON: JSONEncoder().encode(RunBinaryLocator.locate()))
    }

    // MARK: - POST / (start)

    /// Loosely-typed request body decode, mirroring routes/run.js's manual
    /// `typeof body.X === "string" ? body.X : …` coercions exactly — this
    /// deliberately does NOT decode straight into `RunCreateRequest`
    /// (strict `RunMode`/`RunPermissionMode` enums would reject/normalize
    /// differently than Node's lenient fallbacks).
    private struct RunCreateBody: Decodable {
        let prompt: String?
        let mode: String?
        let cwd: String?
        let model: String?
        let resumeSessionId: String?
        let effort: String?
        let permissionMode: String?
    }

    private static func create(_ req: Request, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let bodyData = try await mutableRequest.collectBody(upTo: jsonBodyLimit)
        let bodyBytes = bodyData.readableBytesView.isEmpty ? Data("{}".utf8) : Data(bodyData.readableBytesView)
        let body = (try? JSONDecoder().decode(RunCreateBody.self, from: bodyBytes)) ?? RunCreateBody(prompt: nil, mode: nil, cwd: nil, model: nil, resumeSessionId: nil, effort: nil, permissionMode: nil)

        let prompt = body.prompt ?? ""
        let mode: RunMode = (body.mode == "headless") ? .headless : .conversation
        let model = (body.model?.isEmpty == false) ? body.model : nil
        let resumeSessionId = (body.resumeSessionId?.isEmpty == false) ? body.resumeSessionId : nil
        let effort = (body.effort?.isEmpty == false) ? body.effort : nil
        let permissionMode = RunPermissionMode(rawValue: body.permissionMode ?? "") ?? .acceptEdits

        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(mode == .conversation && resumeSessionId != nil) {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "EBADPROMPT", message: "prompt is required"))
        }

        let cwd: String
        do {
            cwd = try RunPathUtils.sanitiseCwd(body.cwd)
        } catch let err as RunSpawnerError {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: err.code, message: err.message))
        }

        do {
            let handle = try await context.runSpawner.spawnRun(
                prompt: prompt, mode: mode, cwd: cwd, model: model,
                permissionMode: permissionMode.rawValue, resumeSessionId: resumeSessionId, effort: effort
            )
            // Node's create handler responds with a plain `res.json(handle)`
            // — HTTP 200, not 201 (routes/run.js).
            return try JSONResponse(rawJSON: JSONEncoder().encode(handle))
        } catch let err as RunSpawnerError {
            if case .concurrency(_, let running) = err {
                let wire = RunConcurrencyWire(error: .init(code: err.code, message: err.message), running: running)
                return try JSONResponse(status: .tooManyRequests, rawJSON: JSONEncoder().encode(wire))
            }
            return try JSONResponse(status: errorStatus(err), CodedErrorResponse(code: err.code, message: err.message))
        }
    }

    // MARK: - POST /:id/message

    private struct RunMessageBody: Decodable { let text: String? }

    private static func sendMessage(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        var mutableRequest = req
        let bodyData = try await mutableRequest.collectBody(upTo: jsonBodyLimit)
        let bodyBytes = bodyData.readableBytesView.isEmpty ? Data("{}".utf8) : Data(bodyData.readableBytesView)
        let body = (try? JSONDecoder().decode(RunMessageBody.self, from: bodyBytes)) ?? RunMessageBody(text: nil)
        let text = body.text ?? ""
        guard !text.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "EBADINPUT", message: "text is required"))
        }
        do {
            let messageId = try await context.runSpawner.sendInput(id: id, text: text)
            // Node returns `{ messageId }` verbatim (camelCase) — see file header.
            return try JSONResponse(rawJSON: JSONEncoder().encode(["messageId": messageId]))
        } catch let err as RunSpawnerError {
            return try JSONResponse(status: errorStatus(err), CodedErrorResponse(code: err.code, message: err.message))
        }
    }

    // MARK: - GET /:id

    private static func detail(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        let includeEnvelopes = req.uri.queryValue("envelopes") == "1"
        guard let handle = await context.runSpawner.getRun(id: id, includeEnvelopes: includeEnvelopes) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "ENOTFOUND", message: "run not found"))
        }
        return try JSONResponse(rawJSON: JSONEncoder().encode(handle))
    }

    // MARK: - DELETE /:id

    private static func kill(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        let ok = await context.runSpawner.killRun(id: id)
        guard ok else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "ENOTFOUND", message: "run not found"))
        }
        return try JSONResponse(rawJSON: JSONEncoder().encode(["ok": true]))
    }
}

// MARK: - Wire-only helper types

/// `GET /api/run/history` item wire shape — mixed casing (see file header):
/// every field except `isLive` mirrors the `dashboard_runs` SQL columns
/// (snake_case); `isLive` is a literal camelCase JS field spliced in after
/// the query in routes/run.js. Encoded with a plain `JSONEncoder` (no
/// strategy) since every key is already spelled out explicitly here.
private struct RunConcurrencyWire: Encodable {
    let error: CodedErrorResponse.Body
    let running: [RunConcurrencyEntry]
}
