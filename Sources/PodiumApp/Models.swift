#if os(macOS)
import Foundation

// MARK: - Session

struct Session: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    var status: SessionStatus
    var cwd: String?
    var model: String?
    let startedAt: Date
    var endedAt: Date?
    var updatedAt: Date
    var agentCount: Int?
    var lastActivity: Date?
    var cost: Double?
    var awaitingInputSince: Date?

    enum SessionStatus: String, Codable, CaseIterable {
        case active, completed, error, abandoned
        var label: String { rawValue.capitalized }
    }
}

struct SessionsResponse: Codable {
    let sessions: [Session]
    let total: Int
    let limit: Int
    let offset: Int
}

struct SessionDetailResponse: Codable {
    var session: Session
    var agents: [Agent]
    var events: [DashboardEvent]
}

// MARK: - Agent

struct Agent: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    var name: String
    var type: AgentType
    var subagentType: String?
    var status: AgentStatus
    var task: String?
    var currentTool: String?
    let startedAt: Date
    var endedAt: Date?
    var parentAgentId: String?
    var updatedAt: Date
    var awaitingInputSince: Date?

    enum AgentType: String, Codable { case main, subagent }
    enum AgentStatus: String, Codable, CaseIterable {
        case working, waiting, completed, error
    }
}

struct AgentsResponse: Codable {
    let agents: [Agent]
    let limit: Int
    let offset: Int
}

// MARK: - Agent Tree

struct AgentTreeNode: Codable, Identifiable {
    let id: String
    let name: String
    let type: Agent.AgentType
    let subagentType: String?
    let status: Agent.AgentStatus
    let task: String?
    let startedAt: Date
    let endedAt: Date?
    var children: [AgentTreeNode]
}

// MARK: - Workflows (GET /api/workflows, GET /api/workflows/session/:id)
//
// Top-level keys of both responses are literal camelCase (server's
// `JSONResponse(fields:)` — see `WorkflowsRouter.swift`/`JSONResponse.swift`
// header comments); nested fields are ordinary snake_case run through
// `PodiumJSON.encoder`. `JSONDecoder.podium`'s `.convertFromSnakeCase`
// leaves already-camelCase keys untouched, so plain `Codable` +
// camelCase Swift property names round-trips correctly for both layers —
// no custom `CodingKeys` needed here, matching `PodiumCore/Models/Workflow.swift`.

struct WorkflowSummary: Codable {
    struct TopFlow: Codable { let source: String; let target: String; let count: Int }
    struct Stats: Codable {
        let totalSessions: Int
        let totalAgents: Int
        let totalSubagents: Int
        let avgSubagents: Double
        let successRate: Double
        let avgDepth: Double
        let avgDurationSec: Double
        let totalCompactions: Int
        let avgCompactions: Double
        let topFlow: TopFlow?
    }

    struct OrchestrationEdge: Codable { let source: String; let target: String; let weight: Int }
    struct Orchestration: Codable {
        struct SubagentTypeOutcome: Codable, Identifiable {
            let subagentType: String
            let count: Int
            let completed: Int
            let errors: Int
            var id: String { subagentType }
        }
        struct StatusCount: Codable, Identifiable {
            let status: String
            let count: Int
            var id: String { status }
        }
        struct Compactions: Codable { let total: Int; let sessions: Int }

        let sessionCount: Int
        let mainCount: Int
        let subagentTypes: [SubagentTypeOutcome]
        let edges: [OrchestrationEdge]
        let outcomes: [StatusCount]
        let compactions: Compactions
    }

    struct ToolFlow: Codable {
        struct Transition: Codable { let source: String; let target: String; let value: Int }
        struct ToolCount: Codable, Identifiable {
            let toolName: String
            let count: Int
            var id: String { toolName }
        }
        let transitions: [Transition]
        let toolCounts: [ToolCount]
    }

    struct Effectiveness: Codable, Identifiable {
        let subagentType: String
        let total: Int
        let completed: Int
        let errors: Int
        let sessions: Int
        let successRate: Double
        let avgDuration: Double?
        let trend: [Double]
        var id: String { subagentType }
    }

    struct Patterns: Codable {
        struct Pattern: Codable { let steps: [String]; let count: Int; let percentage: Double }
        let patterns: [Pattern]
        let soloSessionCount: Int
        let soloPercentage: Double
    }

    struct ModelDelegation: Codable {
        struct MainModelCount: Codable, Identifiable {
            let model: String
            let agentCount: Int
            let sessionCount: Int
            var id: String { model }
        }
        struct SubagentModelCount: Codable, Identifiable {
            let model: String
            let agentCount: Int
            var id: String { model }
        }
        struct ModelTokens: Codable, Identifiable {
            let model: String
            let inputTokens: Int
            let outputTokens: Int
            let cacheReadTokens: Int
            let cacheWriteTokens: Int
            var id: String { model }
        }
        let mainModels: [MainModelCount]
        let subagentModels: [SubagentModelCount]
        let tokensByModel: [ModelTokens]
    }

    struct ErrorPropagation: Codable {
        struct DepthCount: Codable, Identifiable { let depth: Int; let count: Int; var id: Int { depth } }
        struct TypeCount: Codable, Identifiable {
            let subagentType: String
            let count: Int
            var id: String { subagentType }
        }
        struct EventErrorCount: Codable, Identifiable {
            let summary: String
            let count: Int
            var id: String { summary }
        }
        let byDepth: [DepthCount]
        let byType: [TypeCount]
        let eventErrors: [EventErrorCount]
        let sessionsWithErrors: Int
        let totalSessions: Int
        let errorRate: Double
    }

    struct Concurrency: Codable {
        struct Lane: Codable, Identifiable {
            let name: String
            let avgStart: Double
            let avgEnd: Double
            let count: Int
            var id: String { name }
        }
        let aggregateLanes: [Lane]
    }

    struct ComplexityItem: Codable, Identifiable {
        let id: String
        let name: String?
        let status: String
        let duration: Double
        let agentCount: Int
        let subagentCount: Int
        let totalTokens: Int
        let model: String?
    }

    struct Compaction: Codable {
        struct PerSession: Codable, Identifiable {
            let sessionId: String
            let compactions: Int
            var id: String { sessionId }
        }
        let totalCompactions: Int
        let tokensRecovered: Int
        let perSession: [PerSession]
        let sessionsWithCompactions: Int
        let totalSessions: Int
    }

    struct CooccurrenceEdge: Codable { let source: String; let target: String; let weight: Int }

    let stats: Stats
    let orchestration: Orchestration
    let toolFlow: ToolFlow
    let effectiveness: [Effectiveness]
    let patterns: Patterns
    let modelDelegation: ModelDelegation
    let errorPropagation: ErrorPropagation
    let concurrency: Concurrency
    let complexity: [ComplexityItem]
    let compaction: Compaction
    let cooccurrence: [CooccurrenceEdge]
}

/// `GET /api/workflows/session/:id` — full per-session drill-in (agent tree,
/// tool timeline, swimlanes, first 500 events). Supersedes the old
/// `WorkflowSessionRaw` (session + tree only) used by `PodiumAPI.workflowSession`.
struct WorkflowDetail: Codable {
    struct ToolTimelineEntry: Codable, Identifiable {
        let id: Int
        let toolName: String?
        let eventType: String
        let agentId: String?
        let createdAt: String
        let summary: String?
    }

    struct SwimLane: Codable, Identifiable {
        let id: String
        let name: String
        let type: Agent.AgentType
        let subagentType: String?
        let status: Agent.AgentStatus
        let startedAt: String
        let endedAt: String?
        let parentAgentId: String?
    }

    let session: Session
    let tree: [AgentTreeNode]
    let toolTimeline: [ToolTimelineEntry]
    let swimLanes: [SwimLane]
    let events: [DashboardEvent]
}

// MARK: - Event

struct DashboardEvent: Codable, Identifiable, Equatable {
    let id: Int?
    let sessionId: String
    let agentId: String?
    let eventType: String
    let toolName: String?
    let summary: String?
    let createdAt: Date
}

struct EventsResponse: Codable {
    let events: [DashboardEvent]
    let total: Int
    let limit: Int
    let offset: Int
}

// MARK: - Stats

struct Stats: Codable {
    let totalSessions: Int
    let activeSessions: Int
    let activeAgents: Int
    let totalAgents: Int
    let totalEvents: Int
    let eventsToday: Int
    let wsConnections: Int
    let agentsByStatus: [String: Int]
    let sessionsByStatus: [String: Int]
}

// MARK: - Analytics

struct Analytics: Codable {
    let tokens: TokenStats
    let toolUsage: [ToolUsageStat]
    let dailyEvents: [DailyCount]
    let dailySessions: [DailyCount]
    let agentTypes: [AgentTypeStat]
    let avgEventsPerSession: Double
    let totalSubagents: Int

    struct TokenStats: Codable {
        let totalInput: Int
        let totalOutput: Int
        let totalCacheRead: Int
        let totalCacheWrite: Int
    }

    struct ToolUsageStat: Codable, Identifiable {
        var id: String { toolName }
        let toolName: String
        let count: Int
    }

    struct DailyCount: Codable, Identifiable {
        var id: String { date }
        let date: String
        let count: Int
    }

    struct AgentTypeStat: Codable, Identifiable {
        var id: String { subagentType ?? "main" }
        let subagentType: String?
        let count: Int
    }
}

// MARK: - Cost

struct CostResult: Codable {
    let totalCost: Double
    let breakdown: [CostBreakdown]
    let dailyCosts: [DailyCost]

    struct CostBreakdown: Codable, Identifiable {
        var id: String { model }
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let cost: Double
        let matchedRule: String?
    }

    struct DailyCost: Codable, Identifiable {
        var id: String { date }
        let date: String
        let cost: Double
    }
}

// MARK: - Session Stats

struct SessionStats: Codable {
    let sessionId: String
    let totalEvents: Int
    let eventsByType: [EventTypeCount]
    let toolsUsed: [ToolCount]
    let errorCount: Int
    let firstEventAt: Date?
    let lastEventAt: Date?
    let agents: AgentCounts
    let tokens: TokenCounts

    struct EventTypeCount: Codable, Identifiable {
        var id: String { eventType }
        let eventType: String
        let count: Int
    }

    struct ToolCount: Codable, Identifiable {
        var id: String { toolName }
        let toolName: String
        let count: Int
    }

    struct AgentCounts: Codable {
        let total: Int
        let main: Int
        let subagent: Int
        let byStatus: [String: Int]
    }

    struct TokenCounts: Codable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
    }
}

// MARK: - WebSocket

struct WSMessage {
    let type: String
    let rawData: Data
    let timestamp: String
}

// MARK: - Pricing

struct PricingRule: Identifiable, Codable {
    let id: String
    var model: String
    var inputPer1M: Double
    var outputPer1M: Double
}

// MARK: - Transcript
// API shape: { "type": "user"|"assistant", "timestamp": "...", "content": [...] }
// Note: no `id` or `role` field — the field is `type`. Not Identifiable; use enumerated() in ForEach.

struct TranscriptMessage: Decodable {
    let type: String        // "user" | "assistant"
    let timestamp: Date?
    let content: [TranscriptContent]
    let model: String?      // only present on assistant messages
    let usage: TranscriptUsage?  // per-message token usage (assistant messages)
}

/// Per-message token usage as recorded in the transcript JSONL.
/// The per-session `/stats` endpoint currently reports 0 for token totals,
/// so the Overview tab aggregates these instead.
struct TranscriptUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    // NOTE: the shared decoder uses `.convertFromSnakeCase`, which transforms
    // incoming keys (`cache_read_input_tokens` → `cacheReadInputTokens`) BEFORE
    // matching against these raw values. So the raw values must be the
    // already-camelCased forms, not the original snake_case.
    enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case cacheReadTokens = "cacheReadInputTokens"
        case cacheWriteTokens = "cacheCreationInputTokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens      = (try? c.decodeIfPresent(Int.self, forKey: .inputTokens)) .flatMap { $0 } ?? 0
        outputTokens     = (try? c.decodeIfPresent(Int.self, forKey: .outputTokens)).flatMap { $0 } ?? 0
        cacheReadTokens  = (try? c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)).flatMap { $0 } ?? 0
        cacheWriteTokens = (try? c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)).flatMap { $0 } ?? 0
    }
}

struct TranscriptContent: Decodable {
    let type: String
    let text: String?
    let name: String?       // tool name for tool_use
    var toolInput: String?  // formatted from JSON object
    let output: String?     // tool_result output
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, name, input, output
        case isError = "is_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type    = try  c.decode(String.self, forKey: .type)
        text    = try? c.decodeIfPresent(String.self, forKey: .text)
        name    = try? c.decodeIfPresent(String.self, forKey: .name)
        output  = try? c.decodeIfPresent(String.self, forKey: .output)
        isError = try? c.decodeIfPresent(Bool.self,   forKey: .isError)
        // `input` is a JSON object — decode it as a string dict and format for display
        if let dict = try? c.decodeIfPresent([String: String].self, forKey: .input) {
            toolInput = dict.sorted(by: { $0.key < $1.key })
                           .map { "\($0.key): \($0.value)" }
                           .joined(separator: "\n")
        } else {
            toolInput = nil
        }
    }
}

struct TranscriptResponse: Decodable {
    let messages: [TranscriptMessage]
    let hasMore: Bool
    let firstLine: Int?     // use as `before` cursor to load earlier messages
    let lastLine: Int?
    let total: Int?
}

// MARK: - Search

struct SearchResult: Decodable {
    let sessions: [SessionHit]
    let events: [EventHit]
}

struct SessionHit: Decodable, Identifiable {
    let id: String
    let name: String?
    let status: String
    let cwd: String?
    let highlight: String?  // server sends <mark>...</mark> tags
}

struct EventHit: Decodable, Identifiable {
    let id: Int
    let sessionId: String
    let sessionName: String?
    let eventType: String
    let toolName: String?
    let highlight: String?  // server sends <mark>...</mark> tags
}

#endif
