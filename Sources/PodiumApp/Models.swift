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
