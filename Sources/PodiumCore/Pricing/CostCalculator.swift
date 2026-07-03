// CostCalculator.swift — port of `calculateCost` (dashboard/server/routes/
// pricing.js lines 12–52), shared by the sessions/analytics/search/pricing
// routers. Kept in PodiumCore per the P2.2 fence (routers only do HTTP
// mapping; SQL + cost math live here).

import Foundation

/// Minimal per-model token row needed for cost computation — a subset of
/// `TokenUsage` (or a plain `PodiumStore` aggregate row) with baselines
/// already folded into the current counts, matching how the Node queries
/// pre-add `+ baseline_*` in SQL before handing rows to `calculateCost`.
public struct CostTokenRow: Equatable, Sendable {
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public init(model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    public init(_ usage: TokenUsage) {
        self.model = usage.model
        self.inputTokens = usage.effectiveInputTokens
        self.outputTokens = usage.effectiveOutputTokens
        self.cacheReadTokens = usage.effectiveCacheReadTokens
        self.cacheWriteTokens = usage.effectiveCacheWriteTokens
    }
}

public enum CostCalculator {
    /// Port of `calculateCost(tokenRows, pricingRules)`: matches each row's
    /// `model` against pricing rules by converting the `%`-style SQL LIKE
    /// pattern into a regex (`%` → `.*`), preferring the *longest* pattern
    /// first so specific patterns (`claude-opus-4-5%`) win over catch-alls
    /// (`claude-opus-4%`). Unmatched rows cost 0 but still appear in the
    /// breakdown with `matchedRule == nil`.
    public static func calculate(tokenRows: [CostTokenRow], pricingRules: [ModelPricing]) -> CostResult {
        var totalCost = 0.0
        var breakdown: [CostBreakdownItem] = []

        let sortedRules = pricingRules.sorted { $0.modelPattern.count > $1.modelPattern.count }

        for row in tokenRows {
            let rule = sortedRules.first { matches(pattern: $0.modelPattern, model: row.model) }

            let inputRate = rule?.inputPerMtok ?? 0
            let outputRate = rule?.outputPerMtok ?? 0
            let cacheReadRate = rule?.cacheReadPerMtok ?? 0
            let cacheWriteRate = rule?.cacheWritePerMtok ?? 0

            let cost =
                (Double(row.inputTokens) / 1_000_000) * inputRate
                + (Double(row.outputTokens) / 1_000_000) * outputRate
                + (Double(row.cacheReadTokens) / 1_000_000) * cacheReadRate
                + (Double(row.cacheWriteTokens) / 1_000_000) * cacheWriteRate

            totalCost += cost
            breakdown.append(
                CostBreakdownItem(
                    model: row.model,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    cacheWriteTokens: row.cacheWriteTokens,
                    cost: round4(cost),
                    matchedRule: rule?.modelPattern
                )
            )
        }

        return CostResult(totalCost: round4(totalCost), breakdown: breakdown, dailyCosts: [])
    }

    /// Convenience for the common single-row case (analytics.js totals loop,
    /// search.js per-session cost).
    public static func totalCost(tokenRows: [CostTokenRow], pricingRules: [ModelPricing]) -> Double {
        calculate(tokenRows: tokenRows, pricingRules: pricingRules).totalCost
    }

    /// Port of `calculateDailyCosts(dailyTokenRows, pricingRules)`
    /// (pricing.js lines 54–69): groups `(date, per-model row)` pairs by
    /// date, costs each date's rows independently via `calculate`, and
    /// returns them sorted ascending by date string (matches Node's
    /// `[...rowsByDate.entries()].sort(([a], [b]) => a.localeCompare(b))` —
    /// ISO `YYYY-MM-DD` strings sort identically under plain `Comparable`
    /// and `localeCompare`).
    public static func dailyCosts(_ rows: [DailyCostTokenRow], pricingRules: [ModelPricing]) -> [DailyCost] {
        var byDate: [String: [CostTokenRow]] = [:]
        for entry in rows {
            byDate[entry.date, default: []].append(entry.row)
        }
        return byDate.keys.sorted().map { date in
            DailyCost(date: date, cost: calculate(tokenRows: byDate[date] ?? [], pricingRules: pricingRules).totalCost)
        }
    }

    /// `model_pattern` LIKE pattern → regex, matching Node's
    /// `new RegExp("^" + pattern.replace(/%/g, ".*") + "$")` exactly.
    private static func matches(pattern: String, model: String) -> Bool {
        let regexPattern = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "%", with: ".*") + "$"
        // NSRegularExpression.escapedPattern also escapes the literal `%`
        // characters we just want to turn into `.*` — escape first, then
        // swap the escaped `%` (which stays `%`, `%` needs no escaping in
        // ICU regex) back to `.*`. `%` has no special regex meaning so
        // escaping is a no-op for it; this two-step keeps the rest of the
        // pattern (e.g. `+`, `.` in a real model name) properly escaped.
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return false }
        let range = NSRange(model.startIndex..<model.endIndex, in: model)
        return regex.firstMatch(in: model, range: range) != nil
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }
}
