// SearchRouter — port of dashboard/server/routes/search.js.
//
// Single endpoint: GET /api/search?q=&limit=&offset=. Combines session hits
// (name/cwd LIKE match) and event hits (summary/tool_name/data LIKE match)
// into one recency-sorted array, capped at MAX_PER_TYPE (20) rows per
// entity kind. SQL lives in PodiumStore+Filters.swift (`searchSessions`,
// `searchEvents`); per-session cost for the matched hits uses this file's
// own `searchCosts`/`matchSearchRule` (search.js's cost-matching algorithm
// is a documented exception to `CostCalculator`, see the doc comment on
// `searchCosts` below) — this file is HTTP mapping + highlight-snippet
// building + the final merge-sort, matching search.js's in-process
// (non-SQL) combine step exactly.

import Foundation
import Hummingbird
import PodiumCore

public enum SearchRouterMount: RouterMount {
    private static let maxPerType = 20
    private static let highlightWindow = 100

    public static func mount(on router: PodiumRouter, context: ServerContext) {
        router.get("/api/search") { req, ctx in try await search(req, ctx, context: context) }
    }

    private static func search(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        guard let q = req.uri.queryTrimmed("q") else {
            return try JSONResponse(SearchResponse(results: [], total: 0))
        }

        let limit = min(req.uri.queryInt("limit", fallback: maxPerType), maxPerType)
        let offset = max(0, req.uri.queryInt("offset", fallback: 0))

        let store = context.store
        let (sessionRows, sessionTotal) = try store.searchSessions(query: q, limit: limit, offset: offset)
        let (eventRows, eventTotal) = try store.searchEvents(query: q, limit: limit, offset: offset)

        let sessionCosts = try searchCosts(store: store, sessionIds: sessionRows.map(\.id))

        let sessionHits: [(hit: SearchHit, sortKey: String)] = sessionRows.map { row in
            let highlight = buildHighlight(row.name, q) ?? buildHighlight(row.cwd, q) ?? row.name ?? row.cwd
            let hit = SearchHit(
                type: "session",
                sessionId: row.id,
                sessionName: row.name,
                cwd: row.cwd,
                status: row.status,
                cost: sessionCosts[row.id] ?? 0,
                startedAt: row.startedAt,
                highlight: highlight
            )
            return (hit, row.updatedAt ?? row.startedAt)
        }

        let eventHits: [(hit: SearchHit, sortKey: String)] = eventRows.map { row in
            let hit = SearchHit(
                type: "event",
                sessionId: row.sessionId,
                sessionName: row.sessionName,
                eventId: row.id,
                eventType: row.eventType,
                toolName: row.toolName,
                summary: row.summary,
                createdAt: row.createdAt
            )
            return (hit, row.createdAt)
        }

        var combined = sessionHits + eventHits
        // search.js lines 157–162: descending string comparison on the sort
        // key (ISO8601 timestamps sort correctly as strings), ties broken by
        // stable order (Array.prototype.sort in V8 is stable; Swift's `sort`
        // is not guaranteed stable, so use `sorted(by:)` via index-preserving
        // enumerate to match `combined.sort` semantics exactly on ties).
        combined = combined.enumerated()
            .sorted { a, b in
                if a.element.sortKey != b.element.sortKey {
                    return a.element.sortKey > b.element.sortKey
                }
                return a.offset < b.offset
            }
            .map(\.element)

        let total = sessionTotal + eventTotal
        return try JSONResponse(SearchResponse(results: combined.map(\.hit), total: total))
    }

    /// search.js lines 68–104: bulk per-session cost for the matched session
    /// hits, using search.js's OWN cost-matching algorithm — deliberately
    /// NOT `PodiumStore.costsForSessions`/`CostCalculator`, which sorts
    /// pricing rules longest-pattern-first and treats `%` as a full regex
    /// wildcard (correct for every OTHER endpoint, but not what search.js
    /// does). Confirmed against dashboard/server/routes/search.js lines
    /// 82–103: `rules.find(...)` walks `stmts.listPricing.all()` in its
    /// raw/unsorted order (whatever SQLite returns it in — same order as
    /// `PodiumStore.listPricing()`, `ORDER BY display_name ASC`) and matches
    /// via `model.toLowerCase().startsWith(pattern.replace(/%$/, "").toLowerCase())`
    /// — only a TRAILING `%` is stripped; any other `%` inside the pattern
    /// is left as a literal character for `startsWith` (not converted to a
    /// wildcard). First match in that raw order wins, unlike
    /// `CostCalculator`'s longest-pattern-first preference.
    private static func searchCosts(store: PodiumStore, sessionIds: [String]) throws -> [String: Double] {
        guard !sessionIds.isEmpty else { return [:] }
        let rules = try store.listPricing()
        guard !rules.isEmpty else { return [:] }

        var result: [String: Double] = [:]
        for sessionId in sessionIds {
            let tokenRows = try store.getTokensBySession(sessionId: sessionId).map(CostTokenRow.init)
            guard !tokenRows.isEmpty else { continue }

            var cost = 0.0
            for row in tokenRows {
                guard let rule = matchSearchRule(model: row.model, rules: rules) else { continue }
                cost +=
                    (Double(row.inputTokens) / 1_000_000) * rule.inputPerMtok
                    + (Double(row.outputTokens) / 1_000_000) * rule.outputPerMtok
                    + (Double(row.cacheReadTokens) / 1_000_000) * rule.cacheReadPerMtok
                    + (Double(row.cacheWriteTokens) / 1_000_000) * rule.cacheWritePerMtok
            }
            result[sessionId] = cost
        }
        return result
    }

    /// search.js line 92–94: `rules.find((r) => t.model && t.model.toLowerCase()
    /// .startsWith(r.model_pattern.replace(/%$/, "").toLowerCase()))`.
    private static func matchSearchRule(model: String, rules: [ModelPricing]) -> ModelPricing? {
        let lowerModel = model.lowercased()
        return rules.first { rule in
            var pattern = rule.modelPattern
            if pattern.hasSuffix("%") { pattern.removeLast() }
            return lowerModel.hasPrefix(pattern.lowercased())
        }
    }

    /// search.js `buildHighlight` (lines 25–36): case-insensitive substring
    /// search, ~100-char window centered on the match, ellipsized at either
    /// end if truncated. Returns `nil` if `text` is empty/nil or no match.
    private static func buildHighlight(_ text: String?, _ query: String) -> String? {
        guard let text, !text.isEmpty, !query.isEmpty else { return nil }
        guard let range = text.range(of: query, options: .caseInsensitive) else { return nil }

        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchEnd = text.distance(from: text.startIndex, to: range.upperBound)
        let half = highlightWindow / 2

        let start = max(0, matchStart - half)
        let end = min(text.count, matchEnd + half)

        let startIdx = text.index(text.startIndex, offsetBy: start)
        let endIdx = text.index(text.startIndex, offsetBy: end)
        var snippet = String(text[startIdx..<endIdx])
        if start > 0 { snippet = "…" + snippet }
        if end < text.count { snippet = snippet + "…" }
        return snippet
    }
}
