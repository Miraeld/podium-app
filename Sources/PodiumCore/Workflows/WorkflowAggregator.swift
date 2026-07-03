// WorkflowAggregator.swift — pure functions turning PodiumStore query rows
// into the wire-format WorkflowSummary/WorkflowDetail structs (Models/
// Workflow.swift). Ports the post-SQL JS logic of
// dashboard/server/routes/workflows.js (rounding, percentage math, tree/
// swimlane building) 1:1 so `WorkflowsRouter` stays a thin HTTP shim.
//
// Rounding convention: JS's `+(x).toFixed(1)` / `.toFixed(1)` = round-half-
// away-from-zero to 1 decimal place. All aggregate values here are
// non-negative, so `roundedTo1Decimal` uses plain `.rounded()` (round-half-
// to-even is irrelevant at these magnitudes/precision — verified against
// spot values that sit exactly on a .x5 boundary would differ, but workflow
// aggregates are ratios/durations that don't land there in practice; see
// WorkflowAggregatorTests for boundary-value coverage).

import Foundation

public enum WorkflowAggregator {
    /// `+(x).toFixed(1)` — rounds to 1 decimal place, half-away-from-zero.
    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - stats

    public static func stats(_ row: PodiumStore.WorkflowStatsRow) -> WorkflowStats {
        let avgSubagents = row.totalSessions > 0 ? round1(Double(row.totalSubagents) / Double(row.totalSessions)) : 0
        let finishedAgents = row.completedAgents + row.errorAgents
        let successRate = finishedAgents > 0 ? round1((Double(row.completedAgents) / Double(finishedAgents)) * 100) : 100
        let avgDepth = row.depthRows.isEmpty
            ? 0
            : round1(Double(row.depthRows.reduce(0) { $0 + $1.maxDepth }) / Double(row.depthRows.count))

        let totalDuration = row.finishedSessionDurations.reduce(0.0) {
            $0 + PodiumStore.durationSec(startedAt: $1.startedAt, endedAt: $1.endedAt)
        }
        let avgDurationSec = row.finishedSessionDurations.isEmpty
            ? 0
            : (totalDuration / Double(row.finishedSessionDurations.count)).rounded()

        let avgCompactions = row.totalSessions > 0 ? round1(Double(row.totalCompactions) / Double(row.totalSessions)) : 0

        return WorkflowStats(
            totalSessions: row.totalSessions,
            totalAgents: row.totalAgents,
            totalSubagents: row.totalSubagents,
            avgSubagents: avgSubagents,
            successRate: successRate,
            avgDepth: avgDepth,
            avgDurationSec: avgDurationSec,
            totalCompactions: row.totalCompactions,
            avgCompactions: avgCompactions,
            topFlow: row.topFlow.map { WorkflowStats.TopFlow(source: $0.source, target: $0.target, count: $0.count) }
        )
    }

    // MARK: - orchestration

    public static func orchestration(_ row: PodiumStore.OrchestrationRow) -> OrchestrationData {
        let totalCompactions = row.compactionsBySession.reduce(0) { $0 + $1.count }
        return OrchestrationData(
            sessionCount: row.sessionCount,
            mainCount: row.mainCount,
            subagentTypes: row.subagentTypes.map {
                OrchestrationData.SubagentTypeOutcome(subagentType: $0.subagentType, count: $0.count, completed: $0.completed, errors: $0.errors)
            },
            edges: row.edges.map { OrchestrationEdge(source: $0.source, target: $0.target, weight: $0.weight) },
            outcomes: row.outcomes.map { OrchestrationData.StatusCount(status: $0.status, count: $0.count) },
            compactions: OrchestrationData.Compactions(total: totalCompactions, sessions: row.compactionsBySession.count)
        )
    }

    // MARK: - tool flow

    public static func toolFlow(
        transitions: [(source: String, target: String, value: Int)],
        toolCounts: [(toolName: String, count: Int)]
    ) -> ToolFlowData {
        ToolFlowData(
            transitions: transitions.map { ToolFlowTransition(source: $0.source, target: $0.target, value: $0.value) },
            toolCounts: toolCounts.map { ToolFlowData.ToolCount(toolName: $0.toolName, count: $0.count) }
        )
    }

    // MARK: - subagent effectiveness

    /// `successRate` per type + `avgDuration` rounded to nearest whole second
    /// (`Math.round`) + trend, matching workflows.js lines 351–359. Callers
    /// (the router) supply `avgDuration`/`trend` per type since those need a
    /// follow-up query per subagent_type (mirrors the Node `.map` with
    /// nested `db.prepare(...).get(...)` calls).
    public static func subagentEffectivenessItem(
        subagentType: String, total: Int, completed: Int, errors: Int, sessions: Int,
        avgDuration: Double?, trend: [Int]
    ) -> SubagentEffectivenessItem {
        let successRate = (completed + errors) > 0 ? round1((Double(completed) / Double(completed + errors)) * 100) : 100
        return SubagentEffectivenessItem(
            subagentType: subagentType,
            total: total,
            completed: completed,
            errors: errors,
            sessions: sessions,
            successRate: successRate,
            avgDuration: avgDuration.map { $0.rounded() },
            trend: trend.map(Double.init)
        )
    }

    // MARK: - patterns

    /// Ports workflows.js lines 384–433: full-sequence + 2-step + 3-step
    /// sliding-window pattern counts, deduped by requiring count >= 2, top 10
    /// by frequency, plus solo-session stats.
    public static func patterns(
        sequences: [(sessionId: String, sequence: String)],
        totalSessions: Int,
        soloCount: Int
    ) -> WorkflowPatternsData {
        var patternCounts: [String: Int] = [:]
        // Pass 1: full sequence counts (workflows.js lines 389–392).
        for row in sequences {
            patternCounts[row.sequence, default: 0] += 1
        }
        // Pass 2: 2-step and 3-step sliding windows (lines 395–407).
        for row in sequences {
            let steps = row.sequence.components(separatedBy: "→")
            if steps.count >= 2 {
                for i in 0...(steps.count - 2) {
                    let sub = steps[i...(i + 1)].joined(separator: "→")
                    patternCounts[sub, default: 0] += 1
                }
            }
            if steps.count >= 3 {
                for i in 0...(steps.count - 3) {
                    let sub = steps[i...(i + 2)].joined(separator: "→")
                    patternCounts[sub, default: 0] += 1
                }
            }
        }

        // Sort by count DESC. JS `Object.entries(...).sort((a,b) => b[1]-a[1])`
        // is not stable-by-key beyond that comparator, but V8's Array#sort is
        // stable (insertion order preserved for ties) — Swift's `sorted` is
        // also stable, and `patternCounts` iteration order in JS is
        // insertion order (first-seen sequence/window), which we replicate
        // by tracking first-seen order explicitly since Swift Dictionary
        // iteration order is NOT insertion order.
        var firstSeenOrder: [String] = []
        var seen = Set<String>()
        for row in sequences {
            if seen.insert(row.sequence).inserted { firstSeenOrder.append(row.sequence) }
            let steps = row.sequence.components(separatedBy: "→")
            if steps.count >= 2 {
                for i in 0...(steps.count - 2) {
                    let sub = steps[i...(i + 1)].joined(separator: "→")
                    if seen.insert(sub).inserted { firstSeenOrder.append(sub) }
                }
            }
            if steps.count >= 3 {
                for i in 0...(steps.count - 3) {
                    let sub = steps[i...(i + 2)].joined(separator: "→")
                    if seen.insert(sub).inserted { firstSeenOrder.append(sub) }
                }
            }
        }

        let sortedPatterns = firstSeenOrder
            .compactMap { key -> (String, Int)? in
                guard let count = patternCounts[key], count >= 2 else { return nil }
                return (key, count)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map { (pattern, count) -> WorkflowPattern in
                let pct = totalSessions > 0 ? round1((Double(count) / Double(totalSessions)) * 100) : 0
                return WorkflowPattern(steps: pattern.components(separatedBy: "→"), count: count, percentage: pct)
            }

        let soloPercentage = totalSessions > 0 ? round1((Double(soloCount) / Double(totalSessions)) * 100) : 0

        return WorkflowPatternsData(patterns: Array(sortedPatterns), soloSessionCount: soloCount, soloPercentage: soloPercentage)
    }

    // MARK: - model delegation

    public static func modelDelegation(
        mainModels: [(model: String, agentCount: Int, sessionCount: Int)],
        subagentModels: [(model: String, agentCount: Int)],
        tokensByModel: [(model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int)]
    ) -> ModelDelegationData {
        ModelDelegationData(
            mainModels: mainModels.map { ModelDelegationData.MainModelCount(model: $0.model, agentCount: $0.agentCount, sessionCount: $0.sessionCount) },
            subagentModels: subagentModels.map { ModelDelegationData.SubagentModelCount(model: $0.model, agentCount: $0.agentCount) },
            tokensByModel: tokensByModel.map {
                ModelDelegationData.ModelTokens(
                    model: $0.model, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                    cacheReadTokens: $0.cacheReadTokens, cacheWriteTokens: $0.cacheWriteTokens
                )
            }
        )
    }

    // MARK: - error propagation

    /// Folds `sessionErrorsNotInAgents` into depth 0 (workflows.js lines
    /// 509–516): adds to the existing depth-0 row if present, else prepends
    /// a new depth-0 row (JS `.unshift`).
    public static func errorPropagation(
        byDepthRaw: [(depth: Int, count: Int)],
        sessionErrorsNotInAgents: Int,
        byType: [(subagentType: String, count: Int)],
        eventErrors: [(summary: String, count: Int)],
        sessionsWithErrors: Int,
        totalSessions: Int
    ) -> ErrorPropagationData {
        var byDepth = byDepthRaw
        if sessionErrorsNotInAgents > 0 {
            if let idx = byDepth.firstIndex(where: { $0.depth == 0 }) {
                byDepth[idx].count += sessionErrorsNotInAgents
            } else {
                byDepth.insert((depth: 0, count: sessionErrorsNotInAgents), at: 0)
            }
        }

        let errorRate = totalSessions > 0 ? round1((Double(sessionsWithErrors) / Double(totalSessions)) * 100) : 0

        return ErrorPropagationData(
            byDepth: byDepth.map { ErrorPropagationData.DepthCount(depth: $0.depth, count: $0.count) },
            byType: byType.map { ErrorPropagationData.TypeCount(subagentType: $0.subagentType, count: $0.count) },
            eventErrors: eventErrors.map { ErrorPropagationData.EventErrorCount(summary: $0.summary, count: $0.count) },
            sessionsWithErrors: sessionsWithErrors,
            totalSessions: totalSessions,
            errorRate: errorRate
        )
    }

    // MARK: - concurrency

    /// Ports workflows.js lines 585–615: per-agent start%/end% within its
    /// session's duration, averaged per "type" key (`"Main Agent"` for main
    /// agents, else `subagent_type ?? "unknown"`), sorted by avgStart ASC.
    /// Rows whose session has zero/negative duration are skipped (line 591
    /// `if (sessDur <= 0) continue`).
    public static func concurrency(
        lanes: [(type: String, subagentType: String?, name: String, status: String, startedAt: String?, endedAt: String?, sessionStart: String?, sessionEnd: String?)]
    ) -> ConcurrencyData {
        struct Agg { var starts: [Double] = []; var ends: [Double] = [] }
        var typeAgg: [String: Agg] = [:]
        var keyOrder: [String] = []

        for lane in lanes {
            guard let sessStartDate = lane.sessionStart.flatMap(PodiumDate.parse),
                  let sessEndDate = lane.sessionEnd.flatMap(PodiumDate.parse) else { continue }
            let sessStart = sessStartDate.timeIntervalSince1970
            let sessEnd = sessEndDate.timeIntervalSince1970
            let sessDur = sessEnd - sessStart
            guard sessDur > 0 else { continue }

            guard let agStartDate = lane.startedAt.flatMap(PodiumDate.parse) else { continue }
            let agStart = agStartDate.timeIntervalSince1970
            let agEnd = lane.endedAt.flatMap(PodiumDate.parse)?.timeIntervalSince1970 ?? sessEnd

            let startPct = max(0, min(1, (agStart - sessStart) / sessDur))
            let endPct = max(0, min(1, (agEnd - sessStart) / sessDur))

            let key = lane.type == "main" ? "Main Agent" : (lane.subagentType ?? "unknown")
            if typeAgg[key] == nil {
                typeAgg[key] = Agg()
                keyOrder.append(key)
            }
            typeAgg[key]?.starts.append(startPct)
            typeAgg[key]?.ends.append(endPct)
        }

        let aggregateLanes = keyOrder.compactMap { key -> ConcurrencyLane? in
            guard let agg = typeAgg[key], !agg.starts.isEmpty else { return nil }
            let avgStart = (agg.starts.reduce(0, +) / Double(agg.starts.count) * 1000).rounded() / 1000
            let avgEnd = (agg.ends.reduce(0, +) / Double(agg.ends.count) * 1000).rounded() / 1000
            return ConcurrencyLane(name: key, avgStart: avgStart, avgEnd: avgEnd, count: agg.starts.count)
        }.sorted { $0.avgStart < $1.avgStart }

        return ConcurrencyData(aggregateLanes: aggregateLanes)
    }

    // MARK: - session complexity

    public static func sessionComplexity(
        rows: [(id: String, name: String?, status: String, startedAt: String?, endedAt: String?, agentCount: Int, subagentCount: Int, model: String?)],
        totalTokens: (String) -> Int
    ) -> [SessionComplexityItem] {
        rows.map { r in
            let dur = PodiumStore.durationSec(startedAt: r.startedAt, endedAt: r.endedAt)
            return SessionComplexityItem(
                id: r.id,
                name: r.name,
                status: r.status,
                duration: dur.rounded(),
                agentCount: r.agentCount,
                subagentCount: r.subagentCount,
                totalTokens: totalTokens(r.id),
                model: r.model
            )
        }
    }

    // MARK: - compaction impact

    public static func compactionImpact(
        totalCompactions: Int,
        tokensRecovered: Int,
        perSession: [(sessionId: String, compactions: Int)],
        sessionsWithCompactions: Int,
        totalSessions: Int
    ) -> CompactionImpactData {
        CompactionImpactData(
            totalCompactions: totalCompactions,
            tokensRecovered: tokensRecovered,
            perSession: perSession.map { CompactionImpactData.PerSessionCompactions(sessionId: $0.sessionId, compactions: $0.compactions) },
            sessionsWithCompactions: sessionsWithCompactions,
            totalSessions: totalSessions
        )
    }

    // MARK: - cooccurrence

    public static func cooccurrence(_ pairs: [(source: String, target: String, weight: Int)]) -> [CooccurrenceEdge] {
        pairs.map { CooccurrenceEdge(source: $0.source, target: $0.target, weight: $0.weight) }
    }

    // MARK: - session drill-in: agent tree (workflows.js lines 734–759)

    /// Builds a nested tree from a flat agent list, root = agents with no
    /// parent (or whose parent id isn't present in this session's list —
    /// same `map[a.parent_agent_id]` guard as the JS). Preserves the
    /// caller's row order among siblings (JS object insertion order === the
    /// `agents` array order from `listAgentsBySession`).
    public static func buildAgentTree(_ agents: [Agent]) -> [AgentTreeNode] {
        var nodes: [String: AgentTreeNode] = [:]
        var order: [String] = []
        for a in agents {
            nodes[a.id] = AgentTreeNode(
                id: a.id, name: a.name, type: a.type.knownValue ?? .subagent, subagentType: a.subagentType,
                status: a.status.knownValue ?? .waiting, task: a.task, startedAt: a.startedAt, endedAt: a.endedAt, children: []
            )
            order.append(a.id)
        }

        var childrenOf: [String: [String]] = [:]
        var roots: [String] = []
        for a in agents {
            if let parentId = a.parentAgentId, nodes[parentId] != nil {
                childrenOf[parentId, default: []].append(a.id)
            } else {
                roots.append(a.id)
            }
        }

        func attach(_ id: String) -> AgentTreeNode {
            var node = nodes[id]!
            node.children = (childrenOf[id] ?? []).map(attach)
            return node
        }

        return roots.map(attach)
    }

    public static func toolTimeline(events: [DashboardEvent]) -> [WorkflowDetail.ToolTimelineEntry] {
        events.filter { $0.toolName != nil }.map {
            WorkflowDetail.ToolTimelineEntry(
                id: $0.id ?? 0, toolName: $0.toolName, eventType: $0.eventType, agentId: $0.agentId,
                createdAt: $0.createdAt, summary: $0.summary
            )
        }
    }

    public static func swimLanes(agents: [Agent]) -> [WorkflowDetail.SwimLane] {
        agents.map {
            WorkflowDetail.SwimLane(
                id: $0.id, name: $0.name, type: $0.type.knownValue ?? .subagent, subagentType: $0.subagentType,
                status: $0.status.knownValue ?? .waiting, startedAt: $0.startedAt, endedAt: $0.endedAt,
                parentAgentId: $0.parentAgentId
            )
        }
    }
}
