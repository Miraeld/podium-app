import Foundation

/// `GET /api/workflows` cross-session aggregate response
/// (dashboard/server/routes/workflows.js). Matches client/src/lib/types.ts
/// `WorkflowData` — consumed by client/src/pages/Workflows.tsx's 12 d3
/// visualizations.
public struct WorkflowSummary: Codable, Equatable, Sendable {
    public var stats: WorkflowStats
    public var orchestration: OrchestrationData
    public var toolFlow: ToolFlowData
    public var effectiveness: [SubagentEffectivenessItem]
    public var patterns: WorkflowPatternsData
    public var modelDelegation: ModelDelegationData
    public var errorPropagation: ErrorPropagationData
    public var concurrency: ConcurrencyData
    public var complexity: [SessionComplexityItem]
    public var compaction: CompactionImpactData
    public var cooccurrence: [CooccurrenceEdge]

    public init(
        stats: WorkflowStats,
        orchestration: OrchestrationData,
        toolFlow: ToolFlowData,
        effectiveness: [SubagentEffectivenessItem],
        patterns: WorkflowPatternsData,
        modelDelegation: ModelDelegationData,
        errorPropagation: ErrorPropagationData,
        concurrency: ConcurrencyData,
        complexity: [SessionComplexityItem],
        compaction: CompactionImpactData,
        cooccurrence: [CooccurrenceEdge]
    ) {
        self.stats = stats
        self.orchestration = orchestration
        self.toolFlow = toolFlow
        self.effectiveness = effectiveness
        self.patterns = patterns
        self.modelDelegation = modelDelegation
        self.errorPropagation = errorPropagation
        self.concurrency = concurrency
        self.complexity = complexity
        self.compaction = compaction
        self.cooccurrence = cooccurrence
    }
}

public struct WorkflowStats: Codable, Equatable, Sendable {
    public var totalSessions: Int
    public var totalAgents: Int
    public var totalSubagents: Int
    public var avgSubagents: Double
    public var successRate: Double
    public var avgDepth: Double
    public var avgDurationSec: Double
    public var totalCompactions: Int
    public var avgCompactions: Double
    public var topFlow: TopFlow?

    public init(
        totalSessions: Int,
        totalAgents: Int,
        totalSubagents: Int,
        avgSubagents: Double,
        successRate: Double,
        avgDepth: Double,
        avgDurationSec: Double,
        totalCompactions: Int,
        avgCompactions: Double,
        topFlow: TopFlow? = nil
    ) {
        self.totalSessions = totalSessions
        self.totalAgents = totalAgents
        self.totalSubagents = totalSubagents
        self.avgSubagents = avgSubagents
        self.successRate = successRate
        self.avgDepth = avgDepth
        self.avgDurationSec = avgDurationSec
        self.totalCompactions = totalCompactions
        self.avgCompactions = avgCompactions
        self.topFlow = topFlow
    }

    public struct TopFlow: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
        public var count: Int
        public init(source: String, target: String, count: Int) {
            self.source = source
            self.target = target
            self.count = count
        }
    }

    // All keys are literal camelCase and `topFlow` is `{...} | null` in the
    // client's `WorkflowStats` (types.ts) — see `AnyEncodable`'s doc comment.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "totalSessions": AnyEncodable(totalSessions),
            "totalAgents": AnyEncodable(totalAgents),
            "totalSubagents": AnyEncodable(totalSubagents),
            "avgSubagents": AnyEncodable(avgSubagents),
            "successRate": AnyEncodable(successRate),
            "avgDepth": AnyEncodable(avgDepth),
            "avgDurationSec": AnyEncodable(avgDurationSec),
            "totalCompactions": AnyEncodable(totalCompactions),
            "avgCompactions": AnyEncodable(avgCompactions),
            "topFlow": AnyEncodable(topFlow),
        ])
    }
}

public struct OrchestrationEdge: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var weight: Int
    public init(source: String, target: String, weight: Int) {
        self.source = source
        self.target = target
        self.weight = weight
    }
}

public struct OrchestrationData: Codable, Equatable, Sendable {
    public var sessionCount: Int
    public var mainCount: Int
    public var subagentTypes: [SubagentTypeOutcome]
    public var edges: [OrchestrationEdge]
    public var outcomes: [StatusCount]
    public var compactions: Compactions

    public init(
        sessionCount: Int,
        mainCount: Int,
        subagentTypes: [SubagentTypeOutcome],
        edges: [OrchestrationEdge],
        outcomes: [StatusCount],
        compactions: Compactions
    ) {
        self.sessionCount = sessionCount
        self.mainCount = mainCount
        self.subagentTypes = subagentTypes
        self.edges = edges
        self.outcomes = outcomes
        self.compactions = compactions
    }

    public struct SubagentTypeOutcome: Codable, Equatable, Sendable {
        public var subagentType: String
        public var count: Int
        public var completed: Int
        public var errors: Int
        public init(subagentType: String, count: Int, completed: Int, errors: Int) {
            self.subagentType = subagentType
            self.count = count
            self.completed = completed
            self.errors = errors
        }
    }

    public struct StatusCount: Codable, Equatable, Sendable {
        public var status: String
        public var count: Int
        public init(status: String, count: Int) {
            self.status = status
            self.count = count
        }
    }

    public struct Compactions: Codable, Equatable, Sendable {
        public var total: Int
        public var sessions: Int
        public init(total: Int, sessions: Int) {
            self.total = total
            self.sessions = sessions
        }
    }

    // Container keys are literal camelCase in the client's
    // `OrchestrationData` (types.ts) while `subagentTypes` ROWS stay
    // snake_case (`subagent_type` — SQL column pass-through) via their own
    // default encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "sessionCount": AnyEncodable(sessionCount),
            "mainCount": AnyEncodable(mainCount),
            "subagentTypes": AnyEncodable(subagentTypes),
            "edges": AnyEncodable(edges),
            "outcomes": AnyEncodable(outcomes),
            "compactions": AnyEncodable(compactions),
        ])
    }
}

public struct ToolFlowTransition: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var value: Int
    public init(source: String, target: String, value: Int) {
        self.source = source
        self.target = target
        self.value = value
    }
}

public struct ToolFlowData: Codable, Equatable, Sendable {
    public var transitions: [ToolFlowTransition]
    public var toolCounts: [ToolCount]

    public init(transitions: [ToolFlowTransition], toolCounts: [ToolCount]) {
        self.transitions = transitions
        self.toolCounts = toolCounts
    }

    public struct ToolCount: Codable, Equatable, Sendable {
        public var toolName: String
        public var count: Int
        public init(toolName: String, count: Int) {
            self.toolName = toolName
            self.count = count
        }
    }

    // `toolCounts` is literal camelCase in the client's `ToolFlowData`
    // (types.ts); its rows keep snake_case `tool_name` via default encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "transitions": AnyEncodable(transitions),
            "toolCounts": AnyEncodable(toolCounts),
        ])
    }
}

public struct SubagentEffectivenessItem: Codable, Identifiable, Equatable, Sendable {
    public var subagentType: String
    public var total: Int
    public var completed: Int
    public var errors: Int
    public var sessions: Int
    public var successRate: Double
    public var avgDuration: Double?
    public var trend: [Double]

    public var id: String { subagentType }

    public init(
        subagentType: String,
        total: Int,
        completed: Int,
        errors: Int,
        sessions: Int,
        successRate: Double,
        avgDuration: Double? = nil,
        trend: [Double] = []
    ) {
        self.subagentType = subagentType
        self.total = total
        self.completed = completed
        self.errors = errors
        self.sessions = sessions
        self.successRate = successRate
        self.avgDuration = avgDuration
        self.trend = trend
    }

    // Mixed casing within ONE object (types.ts `SubagentEffectivenessItem`):
    // `subagent_type` is a SQL pass-through, `successRate`/`avgDuration` are
    // Node-computed camelCase literals, and `avgDuration` is `number | null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "subagent_type": AnyEncodable(subagentType),
            "total": AnyEncodable(total),
            "completed": AnyEncodable(completed),
            "errors": AnyEncodable(errors),
            "sessions": AnyEncodable(sessions),
            "successRate": AnyEncodable(successRate),
            "avgDuration": AnyEncodable(avgDuration),
            "trend": AnyEncodable(trend),
        ])
    }
}

public struct WorkflowPattern: Codable, Equatable, Sendable {
    public var steps: [String]
    public var count: Int
    public var percentage: Double
    public init(steps: [String], count: Int, percentage: Double) {
        self.steps = steps
        self.count = count
        self.percentage = percentage
    }
}

public struct WorkflowPatternsData: Codable, Equatable, Sendable {
    public var patterns: [WorkflowPattern]
    public var soloSessionCount: Int
    public var soloPercentage: Double
    public init(patterns: [WorkflowPattern], soloSessionCount: Int, soloPercentage: Double) {
        self.patterns = patterns
        self.soloSessionCount = soloSessionCount
        self.soloPercentage = soloPercentage
    }

    // Literal camelCase keys (types.ts `WorkflowPatternsData`).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "patterns": AnyEncodable(patterns),
            "soloSessionCount": AnyEncodable(soloSessionCount),
            "soloPercentage": AnyEncodable(soloPercentage),
        ])
    }
}

public struct ModelDelegationData: Codable, Equatable, Sendable {
    public var mainModels: [MainModelCount]
    public var subagentModels: [SubagentModelCount]
    public var tokensByModel: [ModelTokens]

    public init(
        mainModels: [MainModelCount],
        subagentModels: [SubagentModelCount],
        tokensByModel: [ModelTokens]
    ) {
        self.mainModels = mainModels
        self.subagentModels = subagentModels
        self.tokensByModel = tokensByModel
    }

    // Container keys are literal camelCase in the client's
    // `ModelDelegationData` (types.ts); all rows keep snake_case fields
    // (`agent_count`, `input_tokens`, …) via their default encodes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "mainModels": AnyEncodable(mainModels),
            "subagentModels": AnyEncodable(subagentModels),
            "tokensByModel": AnyEncodable(tokensByModel),
        ])
    }

    public struct MainModelCount: Codable, Equatable, Sendable {
        public var model: String
        public var agentCount: Int
        public var sessionCount: Int
        public init(model: String, agentCount: Int, sessionCount: Int) {
            self.model = model
            self.agentCount = agentCount
            self.sessionCount = sessionCount
        }
    }

    public struct SubagentModelCount: Codable, Equatable, Sendable {
        public var model: String
        public var agentCount: Int
        public init(model: String, agentCount: Int) {
            self.model = model
            self.agentCount = agentCount
        }
    }

    public struct ModelTokens: Codable, Equatable, Sendable {
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public init(
            model: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int
        ) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
        }
    }
}

public struct ErrorPropagationData: Codable, Equatable, Sendable {
    public var byDepth: [DepthCount]
    public var byType: [TypeCount]
    public var eventErrors: [EventErrorCount]
    public var sessionsWithErrors: Int
    public var totalSessions: Int
    public var errorRate: Double

    public init(
        byDepth: [DepthCount],
        byType: [TypeCount],
        eventErrors: [EventErrorCount],
        sessionsWithErrors: Int,
        totalSessions: Int,
        errorRate: Double
    ) {
        self.byDepth = byDepth
        self.byType = byType
        self.eventErrors = eventErrors
        self.sessionsWithErrors = sessionsWithErrors
        self.totalSessions = totalSessions
        self.errorRate = errorRate
    }

    public struct DepthCount: Codable, Equatable, Sendable {
        public var depth: Int
        public var count: Int
        public init(depth: Int, count: Int) {
            self.depth = depth
            self.count = count
        }
    }

    public struct TypeCount: Codable, Equatable, Sendable {
        public var subagentType: String
        public var count: Int
        public init(subagentType: String, count: Int) {
            self.subagentType = subagentType
            self.count = count
        }
    }

    public struct EventErrorCount: Codable, Equatable, Sendable {
        public var summary: String
        public var count: Int
        public init(summary: String, count: Int) {
            self.summary = summary
            self.count = count
        }
    }

    // Container keys are literal camelCase in the client's
    // `ErrorPropagationData` (types.ts); `byType` rows keep snake_case
    // `subagent_type` via their default encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "byDepth": AnyEncodable(byDepth),
            "byType": AnyEncodable(byType),
            "eventErrors": AnyEncodable(eventErrors),
            "sessionsWithErrors": AnyEncodable(sessionsWithErrors),
            "totalSessions": AnyEncodable(totalSessions),
            "errorRate": AnyEncodable(errorRate),
        ])
    }
}

public struct ConcurrencyLane: Codable, Equatable, Sendable {
    public var name: String
    public var avgStart: Double
    public var avgEnd: Double
    public var count: Int
    public init(name: String, avgStart: Double, avgEnd: Double, count: Int) {
        self.name = name
        self.avgStart = avgStart
        self.avgEnd = avgEnd
        self.count = count
    }

    // Lane rows themselves are camelCase in the client's `ConcurrencyLane`
    // (types.ts: `avgStart`/`avgEnd` — Node-computed literals, not SQL).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "name": AnyEncodable(name),
            "avgStart": AnyEncodable(avgStart),
            "avgEnd": AnyEncodable(avgEnd),
            "count": AnyEncodable(count),
        ])
    }
}

public struct ConcurrencyData: Codable, Equatable, Sendable {
    public var aggregateLanes: [ConcurrencyLane]
    public init(aggregateLanes: [ConcurrencyLane]) {
        self.aggregateLanes = aggregateLanes
    }

    // `aggregateLanes` is literal camelCase (types.ts `ConcurrencyData`).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(["aggregateLanes": AnyEncodable(aggregateLanes)])
    }
}

public struct SessionComplexityItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var status: String
    public var duration: Double
    public var agentCount: Int
    public var subagentCount: Int
    public var totalTokens: Int
    public var model: String?

    public init(
        id: String,
        name: String? = nil,
        status: String,
        duration: Double,
        agentCount: Int,
        subagentCount: Int,
        totalTokens: Int,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.duration = duration
        self.agentCount = agentCount
        self.subagentCount = subagentCount
        self.totalTokens = totalTokens
        self.model = model
    }
}

public struct CompactionImpactData: Codable, Equatable, Sendable {
    public var totalCompactions: Int
    public var tokensRecovered: Int
    public var perSession: [PerSessionCompactions]
    public var sessionsWithCompactions: Int
    public var totalSessions: Int

    public init(
        totalCompactions: Int,
        tokensRecovered: Int,
        perSession: [PerSessionCompactions],
        sessionsWithCompactions: Int,
        totalSessions: Int
    ) {
        self.totalCompactions = totalCompactions
        self.tokensRecovered = tokensRecovered
        self.perSession = perSession
        self.sessionsWithCompactions = sessionsWithCompactions
        self.totalSessions = totalSessions
    }

    public struct PerSessionCompactions: Codable, Equatable, Sendable {
        public var sessionId: String
        public var compactions: Int
        public init(sessionId: String, compactions: Int) {
            self.sessionId = sessionId
            self.compactions = compactions
        }
    }
}

public struct CooccurrenceEdge: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var weight: Int
    public init(source: String, target: String, weight: Int) {
        self.source = source
        self.target = target
        self.weight = weight
    }
}

// MARK: - Per-session workflow detail (drill-in)

/// `GET /api/workflows/session/:id` response — per-session agent tree,
/// tool-execution timeline, and swimlanes. Matches client/src/lib/types.ts
/// `SessionDrillIn`.
public struct WorkflowDetail: Codable, Equatable, Sendable {
    public var session: Session
    public var tree: [AgentTreeNode]
    public var toolTimeline: [ToolTimelineEntry]
    public var swimLanes: [SwimLane]
    public var events: [DashboardEvent]

    public init(
        session: Session,
        tree: [AgentTreeNode],
        toolTimeline: [ToolTimelineEntry],
        swimLanes: [SwimLane],
        events: [DashboardEvent]
    ) {
        self.session = session
        self.tree = tree
        self.toolTimeline = toolTimeline
        self.swimLanes = swimLanes
        self.events = events
    }

    public struct ToolTimelineEntry: Codable, Identifiable, Equatable, Sendable {
        public var id: Int
        public var toolName: String?
        public var eventType: String
        public var agentId: String?
        public var createdAt: String
        public var summary: String?

        public init(
            id: Int,
            toolName: String? = nil,
            eventType: String,
            agentId: String? = nil,
            createdAt: String,
            summary: String? = nil
        ) {
            self.id = id
            self.toolName = toolName
            self.eventType = eventType
            self.agentId = agentId
            self.createdAt = createdAt
            self.summary = summary
        }
    }

    /// A single row in the swimlane timeline view — a flattened (non-nested)
    /// version of the agent, with `parentAgentId` kept so the UI can draw
    /// hierarchy connectors without re-walking `tree`.
    public struct SwimLane: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var type: LenientRawValue<AgentType>
        public var subagentType: String?
        public var status: LenientRawValue<AgentStatus>
        public var startedAt: String
        public var endedAt: String?
        public var parentAgentId: String?

        public init(
            id: String,
            name: String,
            type: AgentType,
            subagentType: String? = nil,
            status: AgentStatus,
            startedAt: String,
            endedAt: String? = nil,
            parentAgentId: String? = nil
        ) {
            self.id = id
            self.name = name
            self.type = .known(type)
            self.subagentType = subagentType
            self.status = .known(status)
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.parentAgentId = parentAgentId
        }
    }
}
