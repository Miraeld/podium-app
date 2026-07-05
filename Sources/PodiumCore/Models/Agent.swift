import Foundation

/// Whether an `agents` row is the session's synthesized main agent or a
/// spawned subagent. Raw values match the SQLite CHECK constraint
/// (db.js line 63): `main|subagent`.
public enum AgentType: String, Codable, CaseIterable, Equatable, Sendable {
    case main
    case subagent
}

/// Lifecycle status of an `agents` row. Raw values match the current SQLite
/// CHECK constraint (db.js line 66, post-migration — legacy `idle`/
/// `connected` values are rewritten to `waiting`/`working` by the DB layer,
/// never surfaced over the wire): `working|waiting|completed|error`.
public enum AgentStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case working
    case waiting
    case completed
    case error
}

/// An `agents` row (db.js lines 61–76), as returned by the agents API
/// (dashboard/server/routes/agents.js). Matches client/src/lib/types.ts
/// `Agent` field-for-field (snake_case on the wire).
public struct Agent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var name: String
    public var type: LenientRawValue<AgentType>
    public var subagentType: String?
    /// Lenient: unknown status strings from a foreign/old DB decode into
    /// `.unknown(rawString)` instead of throwing.
    public var status: LenientRawValue<AgentStatus>
    public var task: String?
    public var currentTool: String?
    public var startedAt: String
    public var endedAt: String?
    public var updatedAt: String
    public var parentAgentId: String?
    /// Free-form JSON blob (stored as TEXT in SQLite) — not modeled further.
    public var metadata: String?
    /// Mirrors the parent session: ISO timestamp when set, `nil` otherwise.
    public var awaitingInputSince: String?

    public init(
        id: String,
        sessionId: String,
        name: String,
        type: AgentType,
        subagentType: String? = nil,
        status: AgentStatus,
        task: String? = nil,
        currentTool: String? = nil,
        startedAt: String,
        endedAt: String? = nil,
        updatedAt: String,
        parentAgentId: String? = nil,
        metadata: String? = nil,
        awaitingInputSince: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.type = .known(type)
        self.subagentType = subagentType
        self.status = .known(status)
        self.task = task
        self.currentTool = currentTool
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.parentAgentId = parentAgentId
        self.metadata = metadata
        self.awaitingInputSince = awaitingInputSince
    }

    /// Node parity: nullable SQL columns arrive as explicit JSON `null`
    /// (types.ts marks them `X | null`, not optional) — Swift's synthesized
    /// encode would omit them. Only `awaiting_input_since` is a true
    /// optional in the client and stays omit-when-absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(subagentType, forKey: .subagentType)
        try container.encode(status, forKey: .status)
        try container.encode(task, forKey: .task)
        try container.encode(currentTool, forKey: .currentTool)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(parentAgentId, forKey: .parentAgentId)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(awaitingInputSince, forKey: .awaitingInputSince)
    }

    public var startedAtDate: Date? { PodiumDate.parse(startedAt) }
    public var endedAtDate: Date? { endedAt.flatMap(PodiumDate.parse) }
    public var updatedAtDate: Date? { PodiumDate.parse(updatedAt) }
    public var awaitingInputSinceDate: Date? { awaitingInputSince.flatMap(PodiumDate.parse) }

    /// True when this is the agent blocked on user input — mirrors
    /// `isAgentAwaitingInput` in types.ts. Once the agent's lifecycle has
    /// ended, the waiting flag is considered stale.
    public var isAwaitingInput: Bool {
        guard awaitingInputSince != nil else { return false }
        let known = status.knownValue
        return known != .completed && known != .error
    }
}

/// `GET /api/agents` response envelope (routes/agents.js).
public struct AgentsResponse: Codable, Equatable, Sendable {
    public var agents: [Agent]
    public var limit: Int
    public var offset: Int

    public init(agents: [Agent], limit: Int, offset: Int) {
        self.agents = agents
        self.limit = limit
        self.offset = offset
    }
}

/// A node in a session's agent hierarchy tree — used by the workflows API
/// session drill-in (`SessionDrillIn.tree` in types.ts) and by
/// `SessionStats.agents`.
public struct AgentTreeNode: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: LenientRawValue<AgentType>
    public var subagentType: String?
    public var status: LenientRawValue<AgentStatus>
    public var task: String?
    public var startedAt: String
    public var endedAt: String?
    public var children: [AgentTreeNode]

    public init(
        id: String,
        name: String,
        type: AgentType,
        subagentType: String? = nil,
        status: AgentStatus,
        task: String? = nil,
        startedAt: String,
        endedAt: String? = nil,
        children: [AgentTreeNode] = []
    ) {
        self.id = id
        self.name = name
        self.type = .known(type)
        self.subagentType = subagentType
        self.status = .known(status)
        self.task = task
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.children = children
    }
}

/// `POST /api/agents` request body (routes/agents.js).
public struct AgentCreateRequest: Codable, Equatable, Sendable {
    public var id: String?
    public var sessionId: String
    public var name: String
    public var type: AgentType?
    public var subagentType: String?
    public var status: AgentStatus?
    public var task: String?
    public var parentAgentId: String?
    public var metadata: String?

    public init(
        id: String? = nil,
        sessionId: String,
        name: String,
        type: AgentType? = nil,
        subagentType: String? = nil,
        status: AgentStatus? = nil,
        task: String? = nil,
        parentAgentId: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.type = type
        self.subagentType = subagentType
        self.status = status
        self.task = task
        self.parentAgentId = parentAgentId
        self.metadata = metadata
    }
}

/// `PATCH /api/agents/:id` request body (routes/agents.js line 71:
/// `const { name, status, task, current_tool, ended_at, metadata } =
/// req.body`). All fields optional/partial-update.
public struct AgentPatchRequest: Codable, Equatable, Sendable {
    public var name: String?
    public var status: AgentStatus?
    public var task: String?
    public var currentTool: String?
    public var endedAt: String?
    public var metadata: String?

    public init(
        name: String? = nil,
        status: AgentStatus? = nil,
        task: String? = nil,
        currentTool: String? = nil,
        endedAt: String? = nil,
        metadata: String? = nil
    ) {
        self.name = name
        self.status = status
        self.task = task
        self.currentTool = currentTool
        self.endedAt = endedAt
        self.metadata = metadata
    }
}
