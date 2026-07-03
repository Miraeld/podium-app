// PricingRouter — port of dashboard/server/routes/pricing.js.
//
// Endpoints: GET / · PUT / · DELETE /:pattern · GET /cost · GET /cost/:sessionId.
//
// Cost math (`calculateCost`/`calculateDailyCosts`) lives in
// PodiumCore/Pricing/CostCalculator.swift; the SQL feeding it lives in
// PodiumCore/Database/PodiumStore+Pricing.swift — this file is HTTP mapping
// only, per the P3.3 fence.

import Foundation
import Hummingbird
import PodiumCore

public enum PricingRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/pricing")

        group.get { req, ctx in try await list(req, ctx, context: context) }
        group.put { req, ctx in try await put(req, ctx, context: context) }
        group.delete("/:pattern") { req, ctx in try await delete(req, ctx, context: context) }
        group.get("/cost") { req, ctx in try await cost(req, ctx, context: context) }
        group.get("/cost/:sessionId") { req, ctx in try await sessionCost(req, ctx, context: context) }
    }

    // MARK: - GET /

    private static func list(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rules = try context.store.listPricing()
        return try JSONResponse(PricingListResponse(pricing: rules))
    }

    // MARK: - PUT /

    /// pricing.js lines 78–99: upserts by `model_pattern`. `model_pattern`
    /// and `display_name` are required (400 `INVALID_INPUT` otherwise); the
    /// 4 rate fields default to `0` when absent — decoded via a permissive
    /// local body (not `PricingPutRequest`, whose rate fields are
    /// non-optional `Double`s and would fail to decode a partial body).
    private static func put(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: PricingPutBody.self)
        guard let modelPattern = body.modelPattern, !modelPattern.isEmpty,
              let displayName = body.displayName, !displayName.isEmpty else {
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(code: "INVALID_INPUT", message: "model_pattern and display_name are required")
            )
        }

        try context.store.upsertPricing(
            PricingPutRequest(
                modelPattern: modelPattern,
                displayName: displayName,
                inputPerMtok: body.inputPerMtok ?? 0,
                outputPerMtok: body.outputPerMtok ?? 0,
                cacheReadPerMtok: body.cacheReadPerMtok ?? 0,
                cacheWritePerMtok: body.cacheWritePerMtok ?? 0
            )
        )

        guard let rule = try context.store.getPricing(pattern: modelPattern) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "pricing upsert did not persist"))
        }
        return try JSONResponse(PricingPutResponse(pricing: rule))
    }

    // MARK: - DELETE /:pattern

    /// pricing.js lines 101–110: 404 if the pattern doesn't exist.
    /// Hummingbird's route parameters are NOT percent-decoded (unlike
    /// Express's `req.params`) — a pattern containing `%` (every real
    /// `model_pattern` does, since `%` is the SQL LIKE wildcard) arrives as
    /// literal `%25` unless decoded explicitly here, matching Node's
    /// explicit `decodeURIComponent(req.params.pattern)`.
    private static func delete(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rawPattern = try ctx.parameters.require("pattern")
        let pattern = rawPattern.removingPercentEncoding ?? rawPattern
        guard try context.store.getPricing(pattern: pattern) != nil else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Pricing rule not found"))
        }
        try context.store.deletePricing(pattern: pattern)
        return try JSONResponse(OkResponse(ok: true))
    }

    // MARK: - GET /cost

    /// pricing.js lines 112–129: global cost summary + per-day costs across
    /// every session, bucketed by the caller's local day via `tz_offset`
    /// (same modifier convention as `AnalyticsRouter`).
    private static func cost(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let rawOffset = req.uri.queryIntOrNil("tz_offset")
        let tzModifier = rawOffset.map { "\(-$0) minutes" } ?? "+0 minutes"

        let store = context.store
        let allTokens = try store.globalTokenTotalsByModel()
        let dailyTokens = try store.dailyTokenTotalsByModel(tzModifier: tzModifier)
        let rules = try store.listPricing()

        let result = CostCalculator.calculate(tokenRows: allTokens, pricingRules: rules)
        let dailyCosts = CostCalculator.dailyCosts(dailyTokens, pricingRules: rules)

        return try JSONResponse(CostResult(totalCost: result.totalCost, breakdown: result.breakdown, dailyCosts: dailyCosts))
    }

    // MARK: - GET /cost/:sessionId

    /// pricing.js lines 131–141: per-session cost. Never 404s on a missing
    /// session — mirrors Node returning an empty breakdown / empty
    /// `daily_costs` when `started` comes back `undefined`.
    private static func sessionCost(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let sessionId = try ctx.parameters.require("sessionId")
        let rawOffset = req.uri.queryIntOrNil("tz_offset")
        let tzModifier = rawOffset.map { "\(-$0) minutes" } ?? "+0 minutes"

        let store = context.store
        let tokenRows = try store.getTokensBySession(sessionId: sessionId).map(CostTokenRow.init)
        let rules = try store.listPricing()
        let result = CostCalculator.calculate(tokenRows: tokenRows, pricingRules: rules)

        let dailyCosts: [DailyCost]
        if let date = try store.sessionStartDate(id: sessionId, tzModifier: tzModifier) {
            dailyCosts = [DailyCost(date: date, cost: result.totalCost)]
        } else {
            dailyCosts = []
        }

        return try JSONResponse(CostResult(totalCost: result.totalCost, breakdown: result.breakdown, dailyCosts: dailyCosts))
    }
}

/// `GET /api/pricing` response envelope (pricing.js line 76).
private struct PricingListResponse: Encodable {
    let pricing: [ModelPricing]
}

/// `PUT /api/pricing` response envelope (pricing.js line 98).
private struct PricingPutResponse: Encodable {
    let pricing: ModelPricing
}

/// `DELETE /api/pricing/:pattern` response (pricing.js line 109).
private struct OkResponse: Encodable {
    let ok: Bool
}

/// Permissive `PUT /api/pricing` request body — see `put(_:_:context:)` for
/// why this isn't `PricingPutRequest` directly.
private struct PricingPutBody: Decodable {
    let modelPattern: String?
    let displayName: String?
    let inputPerMtok: Double?
    let outputPerMtok: Double?
    let cacheReadPerMtok: Double?
    let cacheWritePerMtok: Double?
}
