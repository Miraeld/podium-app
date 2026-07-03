// PushRouter — port of dashboard/server/routes/push.js.
//
// Endpoints: GET /vapid-public-key · POST /subscribe · DELETE /subscribe ·
// POST /send.
//
// VAPID/encryption/native-notification logic lives in
// PodiumCore/Push/PushService.swift; subscription CRUD SQL lives in
// PodiumCore/Database/PodiumStore+Push.swift — this file is HTTP mapping
// only, matching the P3.3 pricing/settings router precedent.

import Foundation
import Hummingbird
import PodiumCore

public enum PushRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/push")

        group.get("/vapid-public-key") { req, ctx in try await vapidPublicKey(req, ctx, context: context) }
        group.post("/subscribe") { req, ctx in try await subscribe(req, ctx, context: context) }
        group.delete("/subscribe") { req, ctx in try await unsubscribe(req, ctx, context: context) }
        group.post("/send") { req, ctx in try await send(req, ctx, context: context) }
    }

    // MARK: - GET /vapid-public-key

    private static func vapidPublicKey(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let publicKey = try await context.pushService.publicKey()
        return try JSONResponse(VapidPublicKeyResponse(publicKey: publicKey))
    }

    // MARK: - POST /subscribe

    /// push.js lines 16–25: 400 when `endpoint`/`keys.p256dh`/`keys.auth`
    /// are missing; otherwise `INSERT OR REPLACE` and `{ ok: true }`.
    private static func subscribe(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: PushSubscribeBody.self)
        guard let endpoint = body.endpoint, !endpoint.isEmpty,
              let p256dh = body.keys?.p256dh, !p256dh.isEmpty,
              let auth = body.keys?.auth, !auth.isEmpty
        else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "Missing required fields"))
        }
        try context.store.upsertPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth)
        return try JSONResponse(PushOkResponse(ok: true))
    }

    // MARK: - DELETE /subscribe

    /// push.js lines 27–34: 400 when `endpoint` is missing.
    private static func unsubscribe(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: PushUnsubscribeBody.self)
        guard let endpoint = body.endpoint, !endpoint.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "Missing endpoint"))
        }
        try context.store.deletePushSubscription(endpoint: endpoint)
        return try JSONResponse(PushOkResponse(ok: true))
    }

    // MARK: - POST /send

    /// push.js lines 36–51: 400 when `title`/`body` are missing; otherwise
    /// fans out to every subscription (+ the native-notifier leg) and
    /// reports what actually happened (`{ ok: true, native, pushed,
    /// failed }`) rather than a blanket success.
    private static func send(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: PushSendBody.self)
        guard let title = body.title, !title.isEmpty,
              let messageBody = body.body, !messageBody.isEmpty
        else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "Missing title or body"))
        }
        do {
            let result = try await context.pushService.sendToAll(title: title, body: messageBody)
            return try JSONResponse(PushSendResult(ok: true, native: result.native, pushed: result.pushed, failed: result.failed))
        } catch {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "\(error)"))
        }
    }
}

/// `{ ok: true }` — used by both `/subscribe` (POST/DELETE) responses.
private struct PushOkResponse: Encodable {
    let ok: Bool
}

/// Permissive `POST /subscribe` body — mirrors the browser's
/// `PushSubscription.toJSON()` shape (`PushSubscribeRequest`), but with
/// every field optional so a request missing pieces decodes instead of
/// 400ing at the JSON layer (we want our own `INVALID_INPUT` message, not a
/// decode error).
private struct PushSubscribeBody: Decodable {
    struct Keys: Decodable {
        let p256dh: String?
        let auth: String?
    }
    let endpoint: String?
    let keys: Keys?
}

private struct PushUnsubscribeBody: Decodable {
    let endpoint: String?
}

private struct PushSendBody: Decodable {
    let title: String?
    let body: String?
}
