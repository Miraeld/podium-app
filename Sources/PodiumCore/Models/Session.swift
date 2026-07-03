import Foundation

/// Lifecycle status of a `sessions` row. Raw values match the SQLite CHECK
/// constraint exactly: `active|completed|error|abandoned` (db.js lines 52–58).
public enum SessionStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case completed
    case error
    case abandoned
}

/// A `sessions` row (db.js lines 49–58), as returned by the sessions API
/// (dashboard/server/routes/sessions.js). JSON keys are snake_case to match
/// the Node server / React client exactly (client/src/lib/types.ts `Session`).
///
/// Timestamps are kept as wire-format strings (not `Date`) so decode→encode
/// round-trips byte-for-byte with whatever SQLite produced. Use
/// `startedAtDate` / `endedAtDate` / etc. for a parsed `Date`.
public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    /// Lenient: unknown status strings from a foreign/old DB decode into
    /// `.unknown(rawString)` instead of throwing.
    public var status: LenientRawValue<SessionStatus>
    public var cwd: String?
    public var model: String?
    public var startedAt: String
    public var endedAt: String?
    /// Free-form JSON blob (stored as TEXT in SQLite) — not modeled further.
    public var metadata: String?
    /// Present on list/detail responses; absent on write bodies.
    public var agentCount: Int?
    public var lastActivity: String?
    public var cost: Double?
    /// ISO timestamp set when Claude Code is blocked waiting for user input
    /// (permission prompt / "waiting for your input"). `nil` when not
    /// waiting. Cleared on the next non-Notification hook event.
    public var awaitingInputSince: String?
    public var transcriptPath: String?
    public var githubPrUrl: String?
    public var updatedAt: String?

    public init(
        id: String,
        name: String? = nil,
        status: SessionStatus,
        cwd: String? = nil,
        model: String? = nil,
        startedAt: String,
        endedAt: String? = nil,
        metadata: String? = nil,
        agentCount: Int? = nil,
        lastActivity: String? = nil,
        cost: Double? = nil,
        awaitingInputSince: String? = nil,
        transcriptPath: String? = nil,
        githubPrUrl: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = .known(status)
        self.cwd = cwd
        self.model = model
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.metadata = metadata
        self.agentCount = agentCount
        self.lastActivity = lastActivity
        self.cost = cost
        self.awaitingInputSince = awaitingInputSince
        self.transcriptPath = transcriptPath
        self.githubPrUrl = githubPrUrl
        self.updatedAt = updatedAt
    }

    public var startedAtDate: Date? { PodiumDate.parse(startedAt) }
    public var endedAtDate: Date? { endedAt.flatMap(PodiumDate.parse) }
    public var updatedAtDate: Date? { updatedAt.flatMap(PodiumDate.parse) }
    public var awaitingInputSinceDate: Date? { awaitingInputSince.flatMap(PodiumDate.parse) }

    /// True when the session is paused on a permission prompt or input
    /// request — mirrors `isSessionAwaitingInput` in types.ts.
    public var isAwaitingInput: Bool {
        awaitingInputSince != nil && status.knownValue == .active
    }
}

/// `GET /api/sessions` response envelope (routes/sessions.js).
public struct SessionsResponse: Codable, Equatable, Sendable {
    public var sessions: [Session]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(sessions: [Session], total: Int, limit: Int, offset: Int) {
        self.sessions = sessions
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

/// `GET /api/sessions/:id` response — session + its agents + its events.
public struct SessionDetailResponse: Codable, Equatable, Sendable {
    public var session: Session
    public var agents: [Agent]
    public var events: [DashboardEvent]

    public init(session: Session, agents: [Agent], events: [DashboardEvent]) {
        self.session = session
        self.agents = agents
        self.events = events
    }
}

/// `POST /api/sessions` request body (routes/sessions.js).
public struct SessionCreateRequest: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var status: SessionStatus?
    public var cwd: String?
    public var model: String?
    public var metadata: String?

    public init(
        id: String? = nil,
        name: String? = nil,
        status: SessionStatus? = nil,
        cwd: String? = nil,
        model: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.cwd = cwd
        self.model = model
        self.metadata = metadata
    }
}

/// `PATCH /api/sessions/:id` request body — name and/or status only
/// (routes/sessions.js PATCH handler).
public struct SessionPatchRequest: Codable, Equatable, Sendable {
    public var name: String?
    public var status: SessionStatus?

    public init(name: String? = nil, status: SessionStatus? = nil) {
        self.name = name
        self.status = status
    }
}
