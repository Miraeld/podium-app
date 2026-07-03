import XCTest
@testable import PodiumCore

/// Hand-computed fixtures for `CostCalculator` — the port of pricing.js's
/// `calculateCost`/`calculateDailyCosts` (P3.3).
final class CostCalculatorTests: XCTestCase {
    private func rule(
        _ pattern: String,
        _ name: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double
    ) -> ModelPricing {
        ModelPricing(
            modelPattern: pattern,
            displayName: name,
            inputPerMtok: input,
            outputPerMtok: output,
            cacheReadPerMtok: cacheRead,
            cacheWritePerMtok: cacheWrite,
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    // MARK: - Pattern precedence (longest pattern wins, not registration order)

    /// Two overlapping patterns where the more specific one is registered
    /// *first* in the array — `calculate` must still prefer it by length,
    /// not array order, matching pricing.js's explicit
    /// `.sort((a, b) => b.model_pattern.length - a.model_pattern.length)`.
    func testMoreSpecificPatternWinsRegardlessOfArrayOrder() {
        let specific = rule("claude-opus-4-5%", "Opus 4.5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        let catchAll = rule("claude-opus-4%", "Opus 4.x", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)

        let row = CostTokenRow(
            model: "claude-opus-4-5-20250101",
            inputTokens: 2_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 500_000,
            cacheWriteTokens: 100_000
        )

        // Catch-all listed before the specific rule in the input array.
        let result = CostCalculator.calculate(tokenRows: [row], pricingRules: [catchAll, specific])

        XCTAssertEqual(result.breakdown.count, 1)
        XCTAssertEqual(result.breakdown[0].matchedRule, "claude-opus-4-5%")
        // (2 * 5) + (1 * 25) + (0.5 * 0.5) + (0.1 * 6.25) = 10 + 25 + 0.25 + 0.625 = 35.875
        XCTAssertEqual(result.breakdown[0].cost, 35.875, accuracy: 1e-9)
        XCTAssertEqual(result.totalCost, 35.875, accuracy: 1e-9)
    }

    /// A model that only matches the catch-all pattern (not the specific
    /// one) falls through to it correctly.
    func testCatchAllPatternMatchesWhenSpecificDoesNotApply() {
        let specific = rule("claude-opus-4-5%", "Opus 4.5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        let catchAll = rule("claude-opus-4%", "Opus 4.x", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)

        let row = CostTokenRow(
            model: "claude-opus-4-1-20250101",
            inputTokens: 1_000_000,
            outputTokens: 500_000,
            cacheReadTokens: 200_000,
            cacheWriteTokens: 50_000
        )

        let result = CostCalculator.calculate(tokenRows: [row], pricingRules: [specific, catchAll])

        XCTAssertEqual(result.breakdown[0].matchedRule, "claude-opus-4%")
        // (1 * 15) + (0.5 * 75) + (0.2 * 1.5) + (0.05 * 18.75) = 15 + 37.5 + 0.3 + 0.9375 = 53.7375
        XCTAssertEqual(result.breakdown[0].cost, 53.7375, accuracy: 1e-9)
    }

    // MARK: - Cache read/write pricing folded into the total

    /// Cache tokens are billed at their own (typically much cheaper) rate —
    /// verify they contribute independently, not folded into input/output.
    func testCacheReadAndCacheWriteRatesAppliedIndependently() {
        let pricing = rule("claude-sonnet-4%", "Sonnet 4", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let row = CostTokenRow(
            model: "claude-sonnet-4-6-20260101",
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 10_000_000,
            cacheWriteTokens: 4_000_000
        )

        let result = CostCalculator.calculate(tokenRows: [row], pricingRules: [pricing])

        // (10 * 0.3) + (4 * 3.75) = 3 + 15 = 18
        XCTAssertEqual(result.totalCost, 18.0, accuracy: 1e-9)
    }

    // MARK: - No matching rule

    /// An unmatched model costs 0 but still appears in the breakdown with
    /// `matchedRule == nil` — mirrors pricing.js's `rule || { ...zeros }`.
    func testUnmatchedModelCostsZeroButStillAppearsInBreakdown() {
        let pricing = rule("claude-opus-4%", "Opus 4.x", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        let row = CostTokenRow(model: "some-other-vendor-model", inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0)

        let result = CostCalculator.calculate(tokenRows: [row], pricingRules: [pricing])

        XCTAssertEqual(result.breakdown.count, 1)
        XCTAssertNil(result.breakdown[0].matchedRule)
        XCTAssertEqual(result.breakdown[0].cost, 0)
        XCTAssertEqual(result.totalCost, 0)
    }

    // MARK: - Rounding to 4 decimal places

    /// pricing.js rounds every individual cost AND the total with
    /// `Math.round(cost * 10000) / 10000`. 333,333 input tokens at $3/Mtok =
    /// $0.999999, which must round to $1.0 (9999.99 → 10000 → /10000).
    func testCostIsRoundedToFourDecimalPlaces() {
        let pricing = rule("claude-haiku%", "Haiku", input: 3, output: 0, cacheRead: 0, cacheWrite: 0)
        let row = CostTokenRow(model: "claude-haiku-4-5", inputTokens: 333_333, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        let result = CostCalculator.calculate(tokenRows: [row], pricingRules: [pricing])

        XCTAssertEqual(result.breakdown[0].cost, 1.0, accuracy: 1e-12)
    }

    // MARK: - Multiple rows sum into totalCost

    func testTotalCostSumsAllRowBreakdowns() {
        let opus = rule("claude-opus-4%", "Opus", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        let haiku = rule("claude-haiku%", "Haiku", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)

        let rows = [
            CostTokenRow(model: "claude-opus-4-1", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
            CostTokenRow(model: "claude-haiku-4-5", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]

        let result = CostCalculator.calculate(tokenRows: rows, pricingRules: [opus, haiku])

        XCTAssertEqual(result.totalCost, 16.0, accuracy: 1e-9) // 15 + 1
    }

    // MARK: - Daily cost grouping (calculateDailyCosts)

    /// Rows are grouped by date, each date's rows costed independently, and
    /// the result sorted ascending by ISO date string — mirrors pricing.js's
    /// `[...rowsByDate.entries()].sort(([a], [b]) => a.localeCompare(b))`.
    func testDailyCostsGroupsByDateAndSortsAscending() {
        let pricing = rule("claude-opus-4%", "Opus", input: 15, output: 0, cacheRead: 0, cacheWrite: 0)

        let rows = [
            DailyCostTokenRow(date: "2026-01-02", row: CostTokenRow(model: "claude-opus-4-1", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)),
            DailyCostTokenRow(date: "2026-01-01", row: CostTokenRow(model: "claude-opus-4-1", inputTokens: 2_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)),
            // Second model on the same day as the first entry — costs should sum within the day.
            DailyCostTokenRow(date: "2026-01-02", row: CostTokenRow(model: "claude-opus-4-1", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)),
        ]

        let daily = CostCalculator.dailyCosts(rows, pricingRules: [pricing])

        XCTAssertEqual(daily.map(\.date), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(daily[0].cost, 30.0, accuracy: 1e-9) // 2 * 15
        XCTAssertEqual(daily[1].cost, 30.0, accuracy: 1e-9) // (1 + 1) * 15
    }

    // MARK: - LIKE-pattern → regex translation

    /// `%` becomes `.*`; everything else in the pattern (hyphens, digits)
    /// must still match literally — a regex-special character embedded in a
    /// pattern would otherwise silently change matching semantics.
    func testPercentWildcardTranslatesToRegexDotStar() {
        let pricing = rule("claude-3-5-sonnet%", "Sonnet 3.5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)

        let matching = CostTokenRow(model: "claude-3-5-sonnet-20241022", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        let nonMatching = CostTokenRow(model: "claude-3-7-sonnet-20250219", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        let result = CostCalculator.calculate(tokenRows: [matching, nonMatching], pricingRules: [pricing])

        XCTAssertEqual(result.breakdown[0].matchedRule, "claude-3-5-sonnet%")
        XCTAssertNil(result.breakdown[1].matchedRule)
    }
}
