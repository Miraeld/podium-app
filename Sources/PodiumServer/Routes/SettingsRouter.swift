// SettingsRouter — port of dashboard/server/routes/settings.js.
//
// Endpoints: GET /info · POST /clear-data · POST /reimport ·
// POST /reinstall-hooks · POST /reset-pricing · GET /export ·
// GET/PUT /claude-home · POST /cleanup.
//
// DB/table diagnostics, destructive maintenance ops, and export row dumps
// live in `PodiumCore/Database/PodiumStore+Pricing.swift` (P3.3 fence); hook
// install/status logic lives in `PodiumCore/Hooks/HookInstaller.swift`; the
// legacy-import seam is `Routes/ReimportRunner.swift`. This file is HTTP
// mapping only.

import Foundation
import Hummingbird
import HTTPTypes
import PodiumCore

public enum SettingsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/settings")

        group.get("/info") { req, ctx in try await info(req, ctx, context: context) }
        group.post("/clear-data") { req, ctx in try await clearData(req, ctx, context: context) }
        group.post("/reimport") { req, ctx in try await reimport(req, ctx, context: context) }
        group.post("/reinstall-hooks") { req, ctx in try await reinstallHooks(req, ctx, context: context) }
        group.post("/reset-pricing") { req, ctx in try await resetPricing(req, ctx, context: context) }
        group.get("/export") { req, ctx in try await export(req, ctx, context: context) }
        group.get("/claude-home") { req, ctx in try await getClaudeHome(req, ctx, context: context) }
        group.put("/claude-home") { req, ctx in try await putClaudeHome(req, ctx, context: context) }
        group.post("/cleanup") { req, ctx in try await cleanup(req, ctx, context: context) }
    }

    // MARK: - GET /info

    /// settings.js lines 74–125. `path` in `hooks` uses the *Claude-Home-
    /// aware* settings path (`ClaudeHome.settingsPath()`, which resolves an
    /// override / `CLAUDE_HOME` env var same as Node's module-level
    /// `CLAUDE_SETTINGS_PATH = getSettingsPath()`), NOT
    /// `HookInstaller.defaultSettingsPath()` (which is hardcoded to
    /// `~/.claude/settings.json` and ignores the override).
    private static func info(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let store = context.store
        let settingsPath = ClaudeHome.settingsPath()

        let dbSize = fileSize(atPath: store.db.path)
        let counts = try store.settingsTableCounts()
        let pragmas = try store.readDbPragmas()
        let (installed, hookMap) = HookInstaller.hookStatus(settingsPath: settingsPath)

        let loadStats = SettingsInfoResponse.DbInfo.LoadStats(
            m5: try store.eventCount(sinceMinutesAgo: 5),
            m15: try store.eventCount(sinceMinutesAgo: 15),
            h1: try store.eventCount(sinceMinutesAgo: 60)
        )

        let wsConnections = await context.broadcaster.connectionCount
        let cacheStats = TranscriptCache.shared.stats()

        let response = SettingsInfoResponse(
            db: SettingsInfoResponse.DbInfo(
                path: store.db.path,
                size: dbSize,
                counts: counts,
                pragmas: pragmas,
                loadStats: loadStats
            ),
            hooks: SettingsInfoResponse.HookStatus(installed: installed, path: settingsPath, hooks: hookMap),
            server: SettingsInfoResponse.ServerRuntimeInfo(
                uptime: ServerRuntimeInfo.uptimeSeconds,
                nodeVersion: ServerRuntimeInfo.runtimeVersion,
                platform: ServerRuntimeInfo.platform,
                wsConnections: wsConnections,
                memory: SettingsInfoResponse.ServerRuntimeInfo.MemoryUsage(
                    rss: ServerRuntimeInfo.residentMemoryBytes,
                    heapTotal: ServerRuntimeInfo.residentMemoryBytes,
                    heapUsed: ServerRuntimeInfo.residentMemoryBytes,
                    external: 0,
                    arrayBuffers: nil
                ),
                cpuLoad: ServerRuntimeInfo.loadAverages,
                arch: ServerRuntimeInfo.arch,
                totalMem: ServerRuntimeInfo.totalMemoryBytes,
                freeMem: ServerRuntimeInfo.freeMemoryBytes,
                cpus: ServerRuntimeInfo.cpuCount
            ),
            transcriptCache: SettingsInfoResponse.TranscriptCacheStats(
                size: cacheStats.size,
                maxSize: cacheStats.maxSize,
                hits: cacheStats.hits,
                misses: cacheStats.misses,
                keys: cacheStats.keys
            )
        )
        return try JSONResponse(response)
    }

    private static func fileSize(atPath path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    // MARK: - POST /clear-data

    /// settings.js lines 128–137.
    private static func clearData(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let cleared = try context.store.clearAllSessionData()
        return try JSONResponse(ClearDataResponse(ok: true, cleared: cleared))
    }

    // MARK: - POST /reimport

    /// settings.js lines 140–151. Legacy-import logic is owned by the
    /// parallel P3.2 task — see `Routes/ReimportRunner.swift`. Until the
    /// orchestrator wires a concrete `ServerContext.reimportRunner`, this
    /// responds `503` instead of guessing at import semantics.
    ///
    /// B6 (pre-1.0 audit): flagged as a removal candidate — the vendored
    /// client has no live caller of this route today (only `KanbanBoard`/
    /// `Dashboard`-style UI calls were checked; none hit `/reimport`).
    /// KEPT anyway per the audit's own rule: the client's `api.ts` still
    /// defines a `settings.reimport()` wrapper
    /// (`dashboard/client/src/lib/api.ts:215-217` in the reference
    /// checkout) that constructs this exact path — a dead *helper*, not a
    /// dead *endpoint*. Per the audit task's decision rule ("if ANYTHING
    /// references it, even a helper function that's itself unused, KEEP
    /// the endpoint"), removing the route here would leave that client
    /// helper pointing at a 404 if it's ever wired up. The `api.ts`
    /// wrapper itself is a follow-up cleanup in the *other* (client) repo,
    /// out of scope here.
    private static func reimport(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        guard let runner = context.reimportRunner else {
            return try JSONResponse(
                status: .serviceUnavailable,
                CodedErrorResponse(code: "NOT_IMPLEMENTED", message: "Legacy re-import is not configured on this server")
            )
        }
        do {
            let result = try await runner.run()
            return try JSONResponse(ReimportResponse(ok: true, imported: result.imported, skipped: result.skipped, errors: result.errors))
        } catch {
            return try JSONResponse(
                status: .internalServerError,
                CodedErrorResponse(code: "IMPORT_FAILED", message: "\(error)")
            )
        }
    }

    // MARK: - POST /reinstall-hooks

    /// settings.js lines 154–166: Node shells out to `install-hooks.js`. We
    /// call `HookInstaller.install` directly instead (no subprocess needed —
    /// it's a native Swift function in this same process), against the same
    /// Claude-Home-aware settings path used by `GET /info`.
    private static func reinstallHooks(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let settingsPath = ClaudeHome.settingsPath()
        do {
            _ = try HookInstaller.install(settingsPath: settingsPath)
            let (installed, hookMap) = HookInstaller.hookStatus(settingsPath: settingsPath)
            let hooks = SettingsInfoResponse.HookStatus(installed: installed, path: settingsPath, hooks: hookMap)
            return try JSONResponse(ReinstallHooksResponse(ok: true, hooks: hooks))
        } catch {
            return try JSONResponse(
                status: .internalServerError,
                CodedErrorResponse(code: "HOOK_INSTALL_FAILED", message: "\(error)")
            )
        }
    }

    // MARK: - POST /reset-pricing

    /// settings.js lines 169–181.
    private static func resetPricing(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let pricing = try context.store.resetPricingToDefaults()
        return try JSONResponse(ResetPricingResponse(ok: true, pricing: pricing))
    }

    // MARK: - GET /export

    /// settings.js lines 184–204. `Content-Disposition` mirrors Node's
    /// `attachment; filename="podium-export-YYYY-MM-DD.json"` naming.
    private static func export(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let store = context.store
        let response = ExportResponse(
            exportedAt: PodiumDate.format(Date()),
            sessions: try store.exportSessions(),
            agents: try store.exportAgents(),
            events: try store.exportEvents(),
            tokenUsage: try store.exportTokenUsage(),
            modelPricing: try store.listPricing()
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let filename = "podium-export-\(dateFormatter.string(from: Date())).json"

        return try JSONResponse(
            response,
            extraHeaders: [.contentDisposition: "attachment; filename=\"\(filename)\""]
        )
    }

    // MARK: - GET /claude-home

    /// settings.js lines 207–209.
    private static func getClaudeHome(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        try JSONResponse(ClaudeHomeResponse(claudeHome: ClaudeHome.current()))
    }

    // MARK: - PUT /claude-home

    /// settings.js lines 212–227.
    private static func putClaudeHome(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: ClaudeHomePutBody.self)
        guard let path = body.path, !path.isEmpty else {
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(code: "INVALID_PATH", message: "path is required and must be a string")
            )
        }
        do {
            let resolved = try ClaudeHome.setClaudeHome(path)
            return try JSONResponse(ClaudeHomePutResponse(ok: true, claudeHome: resolved))
        } catch {
            let message = (error as? ClaudeHomeError)?.description ?? "\(error)"
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_PATH", message: message))
        }
    }

    // MARK: - POST /cleanup

    /// settings.js lines 230–286.
    private static func cleanup(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: CleanupRequest.self)
        let result = try context.store.cleanup(abandonHours: body.abandonHours, purgeDays: body.purgeDays)
        return try JSONResponse(
            CleanupResponse(
                ok: true,
                abandoned: result.abandoned,
                purgedSessions: result.purgedSessions,
                purgedEvents: result.purgedEvents,
                purgedAgents: result.purgedAgents
            )
        )
    }
}

/// `POST /api/settings/reimport` success response (settings.js line 145:
/// `res.json({ ok: true, ...result })`).
private struct ReimportResponse: Encodable {
    let ok: Bool
    let imported: Int
    let skipped: Int
    let errors: Int
}

/// Permissive `PUT /api/settings/claude-home` request body — mirrors the
/// `PricingPutBody` pattern in `PricingRouter.swift` (the strict
/// `ClaudeHomePutRequest` model has a non-optional `path`, which would fail
/// to decode a missing/blank field instead of surfacing the 400 Node sends).
private struct ClaudeHomePutBody: Decodable {
    let path: String?
}
