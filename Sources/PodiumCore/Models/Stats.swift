import Foundation

/// `GET /api/stats` response (routes/stats.js). Matches
/// client/src/lib/types.ts `Stats`.
public struct Stats: Codable, Equatable, Sendable {
    public var totalSessions: Int
    public var activeSessions: Int
    public var activeAgents: Int
    public var totalAgents: Int
    public var totalEvents: Int
    public var eventsToday: Int
    public var wsConnections: Int
    public var agentsByStatus: [String: Int]
    public var sessionsByStatus: [String: Int]

    public init(
        totalSessions: Int,
        activeSessions: Int,
        activeAgents: Int,
        totalAgents: Int,
        totalEvents: Int,
        eventsToday: Int,
        wsConnections: Int,
        agentsByStatus: [String: Int],
        sessionsByStatus: [String: Int]
    ) {
        self.totalSessions = totalSessions
        self.activeSessions = activeSessions
        self.activeAgents = activeAgents
        self.totalAgents = totalAgents
        self.totalEvents = totalEvents
        self.eventsToday = eventsToday
        self.wsConnections = wsConnections
        self.agentsByStatus = agentsByStatus
        self.sessionsByStatus = sessionsByStatus
    }
}

/// `GET /api/sessions/:id/stats` response (routes/sessions.js). Matches
/// client/src/lib/types.ts `SessionStats`.
public struct SessionStats: Codable, Equatable, Sendable {
    public var sessionId: String
    public var totalEvents: Int
    public var eventsByType: [EventTypeCount]
    public var toolsUsed: [ToolCount]
    public var errorCount: Int
    public var firstEventAt: String?
    public var lastEventAt: String?
    public var agents: AgentCounts
    public var subagentTypes: [SubagentTypeCount]
    public var tokens: TokenCounts

    public init(
        sessionId: String,
        totalEvents: Int,
        eventsByType: [EventTypeCount],
        toolsUsed: [ToolCount],
        errorCount: Int,
        firstEventAt: String? = nil,
        lastEventAt: String? = nil,
        agents: AgentCounts,
        subagentTypes: [SubagentTypeCount] = [],
        tokens: TokenCounts
    ) {
        self.sessionId = sessionId
        self.totalEvents = totalEvents
        self.eventsByType = eventsByType
        self.toolsUsed = toolsUsed
        self.errorCount = errorCount
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.agents = agents
        self.subagentTypes = subagentTypes
        self.tokens = tokens
    }

    public var firstEventAtDate: Date? { firstEventAt.flatMap(PodiumDate.parse) }
    public var lastEventAtDate: Date? { lastEventAt.flatMap(PodiumDate.parse) }

    public struct EventTypeCount: Codable, Identifiable, Equatable, Sendable {
        public var eventType: String
        public var count: Int
        public var id: String { eventType }
        public init(eventType: String, count: Int) {
            self.eventType = eventType
            self.count = count
        }
    }

    public struct ToolCount: Codable, Identifiable, Equatable, Sendable {
        public var toolName: String
        public var count: Int
        public var id: String { toolName }
        public init(toolName: String, count: Int) {
            self.toolName = toolName
            self.count = count
        }
    }

    public struct SubagentTypeCount: Codable, Identifiable, Equatable, Sendable {
        public var subagentType: String
        public var count: Int
        public var id: String { subagentType }
        public init(subagentType: String, count: Int) {
            self.subagentType = subagentType
            self.count = count
        }
    }

    public struct AgentCounts: Codable, Equatable, Sendable {
        public var total: Int
        public var main: Int
        public var subagent: Int
        public var compaction: Int
        public var byStatus: [String: Int]
        public init(total: Int, main: Int, subagent: Int, compaction: Int = 0, byStatus: [String: Int]) {
            self.total = total
            self.main = main
            self.subagent = subagent
            self.compaction = compaction
            self.byStatus = byStatus
        }
    }

    public struct TokenCounts: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
        }
    }
}

/// `GET /api/analytics` response (routes/analytics.js). Matches
/// client/src/lib/types.ts `Analytics`.
public struct Analytics: Codable, Equatable, Sendable {
    public var tokens: TokenStats
    public var toolUsage: [ToolUsageStat]
    public var dailyEvents: [DailyCount]
    public var dailySessions: [DailyCount]
    public var agentTypes: [AgentTypeStat]
    public var eventTypes: [EventTypeStat]
    public var avgEventsPerSession: Double
    public var totalSubagents: Int
    public var overview: Overview
    public var agentsByStatus: [String: Int]
    public var sessionsByStatus: [String: Int]

    public init(
        tokens: TokenStats,
        toolUsage: [ToolUsageStat],
        dailyEvents: [DailyCount],
        dailySessions: [DailyCount],
        agentTypes: [AgentTypeStat],
        eventTypes: [EventTypeStat] = [],
        avgEventsPerSession: Double,
        totalSubagents: Int,
        overview: Overview,
        agentsByStatus: [String: Int],
        sessionsByStatus: [String: Int]
    ) {
        self.tokens = tokens
        self.toolUsage = toolUsage
        self.dailyEvents = dailyEvents
        self.dailySessions = dailySessions
        self.agentTypes = agentTypes
        self.eventTypes = eventTypes
        self.avgEventsPerSession = avgEventsPerSession
        self.totalSubagents = totalSubagents
        self.overview = overview
        self.agentsByStatus = agentsByStatus
        self.sessionsByStatus = sessionsByStatus
    }

    public struct TokenStats: Codable, Equatable, Sendable {
        public var totalInput: Int
        public var totalOutput: Int
        public var totalCacheRead: Int
        public var totalCacheWrite: Int
        public init(totalInput: Int, totalOutput: Int, totalCacheRead: Int, totalCacheWrite: Int) {
            self.totalInput = totalInput
            self.totalOutput = totalOutput
            self.totalCacheRead = totalCacheRead
            self.totalCacheWrite = totalCacheWrite
        }
    }

    public struct ToolUsageStat: Codable, Identifiable, Equatable, Sendable {
        public var toolName: String
        public var count: Int
        public var id: String { toolName }
        public init(toolName: String, count: Int) {
            self.toolName = toolName
            self.count = count
        }
    }

    public struct DailyCount: Codable, Identifiable, Equatable, Sendable {
        public var date: String
        public var count: Int
        public var id: String { date }
        public init(date: String, count: Int) {
            self.date = date
            self.count = count
        }
    }

    public struct AgentTypeStat: Codable, Identifiable, Equatable, Sendable {
        public var subagentType: String?
        public var count: Int
        public var id: String { subagentType ?? "main" }
        public init(subagentType: String?, count: Int) {
            self.subagentType = subagentType
            self.count = count
        }
    }

    public struct EventTypeStat: Codable, Identifiable, Equatable, Sendable {
        public var eventType: String
        public var count: Int
        public var id: String { eventType }
        public init(eventType: String, count: Int) {
            self.eventType = eventType
            self.count = count
        }
    }

    /// Mirrors the top-level counters also exposed individually by
    /// `GET /api/stats` — analytics.js nests them under `overview`.
    public struct Overview: Codable, Equatable, Sendable {
        public var totalSessions: Int
        public var activeSessions: Int
        public var activeAgents: Int
        public var totalAgents: Int
        public var totalEvents: Int
        public init(
            totalSessions: Int,
            activeSessions: Int,
            activeAgents: Int,
            totalAgents: Int,
            totalEvents: Int
        ) {
            self.totalSessions = totalSessions
            self.activeSessions = activeSessions
            self.activeAgents = activeAgents
            self.totalAgents = totalAgents
            self.totalEvents = totalEvents
        }
    }
}
