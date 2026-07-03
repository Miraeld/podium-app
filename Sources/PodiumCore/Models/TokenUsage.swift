import Foundation

/// A `token_usage` row (db.js lines 90–100): per-session, per-model token
/// counters plus compaction baselines (db.js "Migrate: add compaction
/// baseline columns" — lines 383–396).
///
/// When conversation compaction rewrites the transcript JSONL, pre-compaction
/// token counts are no longer derivable from the transcript. The baseline_*
/// columns preserve the last-known counts at the moment compaction was
/// detected, so the *effective* total for cost/analytics purposes is always
/// `current + baseline` (see `effectiveInputTokens` etc. below, and
/// `replaceTokenUsage` semantics ported in PodiumCore/Database).
public struct TokenUsage: Codable, Equatable, Sendable {
    public var sessionId: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var baselineInput: Int
    public var baselineOutput: Int
    public var baselineCacheRead: Int
    public var baselineCacheWrite: Int

    public init(
        sessionId: String,
        model: String = "unknown",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        baselineInput: Int = 0,
        baselineOutput: Int = 0,
        baselineCacheRead: Int = 0,
        baselineCacheWrite: Int = 0
    ) {
        self.sessionId = sessionId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.baselineInput = baselineInput
        self.baselineOutput = baselineOutput
        self.baselineCacheRead = baselineCacheRead
        self.baselineCacheWrite = baselineCacheWrite
    }

    /// Effective (current + baseline) input tokens — the number to use for
    /// cost/analytics display.
    public var effectiveInputTokens: Int { inputTokens + baselineInput }
    public var effectiveOutputTokens: Int { outputTokens + baselineOutput }
    public var effectiveCacheReadTokens: Int { cacheReadTokens + baselineCacheRead }
    public var effectiveCacheWriteTokens: Int { cacheWriteTokens + baselineCacheWrite }
}

/// A `model_pricing` row (db.js lines 102–110). `modelPattern` is a SQL LIKE
/// pattern (e.g. `"claude-opus-4-5%"`) matched against a session/token-usage
/// model string — see `matchPricing` semantics ported in PodiumCore/Pricing.
public struct ModelPricing: Codable, Identifiable, Equatable, Sendable {
    public var modelPattern: String
    public var displayName: String
    public var inputPerMtok: Double
    public var outputPerMtok: Double
    public var cacheReadPerMtok: Double
    public var cacheWritePerMtok: Double
    public var updatedAt: String

    /// `model_pattern` is the table's PRIMARY KEY.
    public var id: String { modelPattern }

    public init(
        modelPattern: String,
        displayName: String,
        inputPerMtok: Double,
        outputPerMtok: Double,
        cacheReadPerMtok: Double,
        cacheWritePerMtok: Double,
        updatedAt: String
    ) {
        self.modelPattern = modelPattern
        self.displayName = displayName
        self.inputPerMtok = inputPerMtok
        self.outputPerMtok = outputPerMtok
        self.cacheReadPerMtok = cacheReadPerMtok
        self.cacheWritePerMtok = cacheWritePerMtok
        self.updatedAt = updatedAt
    }

    public var updatedAtDate: Date? { PodiumDate.parse(updatedAt) }
}

/// `PUT /api/pricing` request body (routes/pricing.js) — upserts one pricing
/// rule by `model_pattern`.
public struct PricingPutRequest: Codable, Equatable, Sendable {
    public var modelPattern: String
    public var displayName: String
    public var inputPerMtok: Double
    public var outputPerMtok: Double
    public var cacheReadPerMtok: Double
    public var cacheWritePerMtok: Double

    public init(
        modelPattern: String,
        displayName: String,
        inputPerMtok: Double,
        outputPerMtok: Double,
        cacheReadPerMtok: Double,
        cacheWritePerMtok: Double
    ) {
        self.modelPattern = modelPattern
        self.displayName = displayName
        self.inputPerMtok = inputPerMtok
        self.outputPerMtok = outputPerMtok
        self.cacheReadPerMtok = cacheReadPerMtok
        self.cacheWritePerMtok = cacheWritePerMtok
    }
}

/// One line item of a cost breakdown — per-model token counts, computed
/// cost, and which pricing pattern matched (or `nil` if none did).
/// Matches client/src/lib/types.ts `CostBreakdown`.
public struct CostBreakdownItem: Codable, Identifiable, Equatable, Sendable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cost: Double
    public var matchedRule: String?

    public var id: String { model }

    public init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cost: Double,
        matchedRule: String? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cost = cost
        self.matchedRule = matchedRule
    }
}

/// A single day's cost — used in `CostResult.dailyCosts`.
public struct DailyCost: Codable, Identifiable, Equatable, Sendable {
    public var date: String
    public var cost: Double

    public var id: String { date }

    public init(date: String, cost: Double) {
        self.date = date
        self.cost = cost
    }
}

/// `GET /api/pricing/cost` and `GET /api/pricing/cost/:sessionId` response
/// (routes/pricing.js). Matches client/src/lib/types.ts `CostResult`.
public struct CostResult: Codable, Equatable, Sendable {
    public var totalCost: Double
    public var breakdown: [CostBreakdownItem]
    public var dailyCosts: [DailyCost]

    public init(totalCost: Double, breakdown: [CostBreakdownItem], dailyCosts: [DailyCost]) {
        self.totalCost = totalCost
        self.breakdown = breakdown
        self.dailyCosts = dailyCosts
    }
}

/// Alias kept for naming parity with the task spec ("CostSummary"). Global
/// cost summary and per-session cost share the exact same wire shape in the
/// Node server (`GET /api/pricing/cost` vs `GET /api/pricing/cost/:sessionId`
/// both return a `CostResult`-shaped body), so this is a typealias rather
/// than a duplicate type.
public typealias CostSummary = CostResult
public typealias SessionCost = CostResult
