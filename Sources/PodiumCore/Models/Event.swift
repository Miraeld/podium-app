import Foundation

/// An `events` row (db.js lines 78–88), as returned by the events API
/// (dashboard/server/routes/events.js). Matches client/src/lib/types.ts
/// `DashboardEvent`.
///
/// Note: `id` is `Int?` because write bodies (broadcast payloads assembled
/// before the autoincrement insert returns, if ever needed) may omit it;
/// every row read back from the DB always has one.
public struct DashboardEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: Int?
    public var sessionId: String
    public var agentId: String?
    public var eventType: String
    public var toolName: String?
    public var summary: String?
    /// JSON blob stored as TEXT — present here only on the `/full` endpoint
    /// response; the list endpoint omits it for payload size (see
    /// `EventFull` below, which is `DashboardEvent` + always-present `data`).
    public var data: String?
    public var createdAt: String

    public init(
        id: Int? = nil,
        sessionId: String,
        agentId: String? = nil,
        eventType: String,
        toolName: String? = nil,
        summary: String? = nil,
        data: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentId = agentId
        self.eventType = eventType
        self.toolName = toolName
        self.summary = summary
        self.data = data
        self.createdAt = createdAt
    }

    public var createdAtDate: Date? { PodiumDate.parse(createdAt) }
}

/// `GET /api/events/:id/full` response — same shape as `DashboardEvent`,
/// but `data` is always populated with the full raw JSON column (the list
/// endpoint may omit/truncate it). Kept as a distinct type per the task spec
/// even though the wire shape is currently identical, so routers have an
/// explicit "this always has full data" contract to code against.
public struct EventFull: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var sessionId: String
    public var agentId: String?
    public var eventType: String
    public var toolName: String?
    public var summary: String?
    public var data: String?
    public var createdAt: String

    public init(
        id: Int,
        sessionId: String,
        agentId: String? = nil,
        eventType: String,
        toolName: String? = nil,
        summary: String? = nil,
        data: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.agentId = agentId
        self.eventType = eventType
        self.toolName = toolName
        self.summary = summary
        self.data = data
        self.createdAt = createdAt
    }

    public var createdAtDate: Date? { PodiumDate.parse(createdAt) }
}

/// `GET /api/events` response envelope (routes/events.js).
public struct EventsResponse: Codable, Equatable, Sendable {
    public var events: [DashboardEvent]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(events: [DashboardEvent], total: Int, limit: Int, offset: Int) {
        self.events = events
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

/// `GET /api/events/facets` response — distinct `event_type` / `tool_name`
/// values currently in the DB, for populating filter dropdowns
/// (routes/events.js facets handler).
public struct EventFacets: Codable, Equatable, Sendable {
    public var eventTypes: [String]
    public var toolNames: [String]

    public init(eventTypes: [String], toolNames: [String]) {
        self.eventTypes = eventTypes
        self.toolNames = toolNames
    }
}
