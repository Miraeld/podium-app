// WorkflowsRouter — port of dashboard/server/routes/workflows.js.
//
// GET /api/workflows — cross-session aggregate workflow intelligence (stats,
// orchestration graph, tool flow, subagent effectiveness, patterns, model
// delegation, error propagation, concurrency, complexity, compaction
// impact, cooccurrence). Optional `?status=` filter (active/completed/
// error/abandoned, or "all"/omitted for no filter — see
// `PodiumStore.WorkflowStatusFilter`).
//
// GET /api/workflows/session/:id — per-session drill-in: nested agent tree,
// tool-execution timeline, swimlanes (flat agent list, `started_at DESC`
// order — same as `listAgentsBySession`), and the first 500 events
// (ascending `created_at, id` order).
//
// All post-SQL math (rounding, tree building, pattern mining, percentage
// calc) lives in PodiumCore/Workflows/WorkflowAggregator.swift; SQL lives in
// PodiumCore/Database/PodiumStore+Workflows.swift. This file is HTTP
// mapping only, following the same thin-router shape as AnalyticsRouter.

import Foundation
import Hummingbird
import PodiumCore

public enum WorkflowsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/workflows")
        group.get { req, ctx in try await summary(req, ctx, context: context) }
        group.get("/session/:id") { req, ctx in try await sessionDetail(req, ctx, context: context) }
    }

    // MARK: - GET / (workflows.js lines 19–40)

    private static func summary(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let filter = PodiumStore.WorkflowStatusFilter(status: req.uri.queryValue("status"))
        let store = context.store

        let stats = WorkflowAggregator.stats(try store.workflowStats(filter: filter))
        let orchestration = WorkflowAggregator.orchestration(try store.orchestrationData(filter: filter))
        let toolFlow = WorkflowAggregator.toolFlow(
            transitions: try store.toolFlowTransitions(filter: filter),
            toolCounts: try store.toolFlowCounts(filter: filter)
        )
        let effectiveness = try subagentEffectiveness(store: store, filter: filter)
        let patterns = WorkflowAggregator.patterns(
            sequences: try store.workflowPatternSequences(filter: filter),
            totalSessions: try store.totalSessionsCount(filter: filter),
            soloCount: try store.soloSessionCount(filter: filter)
        )
        let modelDelegation = WorkflowAggregator.modelDelegation(
            mainModels: try store.modelDelegationMainModels(filter: filter),
            subagentModels: try store.modelDelegationSubagentModels(filter: filter),
            tokensByModel: try store.modelDelegationTokensByModel(filter: filter)
        )
        let errorPropagation = WorkflowAggregator.errorPropagation(
            byDepthRaw: try store.errorsByDepth(filter: filter),
            sessionErrorsNotInAgents: try store.sessionErrorsNotInAgents(filter: filter),
            byType: try store.errorPropagationByType(filter: filter),
            eventErrors: try store.errorPropagationEventErrors(filter: filter),
            sessionsWithErrors: try store.sessionsWithErrorsCount(filter: filter),
            totalSessions: try store.totalSessionsCount(filter: filter)
        )
        let concurrency = WorkflowAggregator.concurrency(lanes: try store.concurrencyLaneAgents(filter: filter))
        let complexity = WorkflowAggregator.sessionComplexity(
            rows: try store.sessionComplexityRows(filter: filter),
            totalTokens: { sessionId in (try? store.sessionTotalTokens(sessionId: sessionId)) ?? 0 }
        )
        let compaction = WorkflowAggregator.compactionImpact(
            totalCompactions: try store.compactionTotalCount(filter: filter),
            tokensRecovered: try store.compactionTokensRecovered(filter: filter),
            perSession: try store.compactionPerSession(filter: filter),
            sessionsWithCompactions: try store.compactionSessionsWithCompactionsCount(filter: filter),
            totalSessions: try store.totalSessionsCount(filter: filter)
        )
        let cooccurrence = WorkflowAggregator.cooccurrence(try store.agentCooccurrencePairs(filter: filter))

        let response = WorkflowSummary(
            stats: stats,
            orchestration: orchestration,
            toolFlow: toolFlow,
            effectiveness: effectiveness,
            patterns: patterns,
            modelDelegation: modelDelegation,
            errorPropagation: errorPropagation,
            concurrency: concurrency,
            complexity: complexity,
            compaction: compaction,
            cooccurrence: cooccurrence
        )
        return try JSONResponse(response)
    }

    /// workflows.js lines 299–363: `types` base aggregate plus, per type, two
    /// follow-up queries (avg duration, weekly trend) — same N+1 shape as the
    /// Node `.map` with nested `db.prepare(...).get(...)` calls.
    private static func subagentEffectiveness(
        store: PodiumStore, filter: PodiumStore.WorkflowStatusFilter
    ) throws -> [SubagentEffectivenessItem] {
        try store.subagentEffectivenessTypes(filter: filter).map { type in
            let avgDuration = try store.subagentEffectivenessAvgDuration(subagentType: type.subagentType, filter: filter)
            let trend = try store.subagentEffectivenessTrend(subagentType: type.subagentType, filter: filter)
            return WorkflowAggregator.subagentEffectivenessItem(
                subagentType: type.subagentType,
                total: type.total,
                completed: type.completed,
                errors: type.errors,
                sessions: type.sessions,
                avgDuration: avgDuration,
                trend: trend
            )
        }
    }

    // MARK: - GET /session/:id (workflows.js lines 43–85, 734–759)

    private static func sessionDetail(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        let store = context.store
        guard let session = try store.getSession(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let agents = try store.listAgentsBySession(sessionId: id)
        let events = try store.listEventsBySessionAscending(sessionId: id)

        let detail = WorkflowDetail(
            session: session,
            tree: WorkflowAggregator.buildAgentTree(agents),
            toolTimeline: WorkflowAggregator.toolTimeline(events: events),
            swimLanes: WorkflowAggregator.swimLanes(agents: agents),
            events: Array(events.prefix(500))
        )
        return try JSONResponse(detail)
    }
}
