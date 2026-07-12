// UpdatesRouter — port of dashboard/server/routes/updates.js, adapted per
// the P4.3 task spec: the Node original's `getUpdatesStatus()` is a stub
// (Podium-inside-Maestro has no standalone upstream to check — see
// update-check.js's header). This standalone app has one real repo worth
// checking instead: the app's own repo (once it has a GitHub remote —
// see `PodiumCore/Discovery/UpdateCheck.swift`'s `appRepoSlug()` doc for
// the `PODIUM_APP_GITHUB_REPO` env var). PRE-1.0 audit C2 dropped the
// former `wp-media/podium` reference-repo half — plugin-era leftover with
// no meaning for a standalone app. The response shape
// (`UpdatesStatusResponse`) is a superset-compatible extension of the
// pre-fork `UpdateStatusPayload` client/src/lib/types.ts still declares —
// `update_available`/`current_sha`/`latest_sha` are the fields
// `UpdateNotifier.tsx` reads.
//
// GET /api/updates/status  — read-only status check.
// POST /api/updates/check  — same check, but also broadcasts
//                            `update_status` over the WS hub (updates.js
//                            lines 23–37).

import Foundation
import Hummingbird
import HTTPTypes
import PodiumCore

public enum UpdatesRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/updates")
        group.get("/status") { req, ctx in try await status(req, ctx, context: context) }
        group.post("/check") { req, ctx in try await check(req, ctx, context: context) }
    }

    private static func status(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let result = await UpdateCheck.status()
        return try JSONResponse(result)
    }

    private static func check(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let result = await UpdateCheck.status()
        await context.broadcaster.broadcast(type: "update_status", data: result)
        return try JSONResponse(result)
    }
}
