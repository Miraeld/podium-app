import Foundation

/// `GET /api/search` response (dashboard/server/routes/search.js) —
/// cross-entity search results. Matches client/src/lib/types.ts
/// `SearchResult` naming (the React client's `SearchResult` interface
/// covers sessions + events; see client/src/pages/Search.tsx for how
/// agent hits, if any, are folded into session hits).
public struct SearchResult: Codable, Equatable, Sendable {
    public var sessions: [SessionSearchHit]
    public var events: [EventSearchHit]

    public init(sessions: [SessionSearchHit], events: [EventSearchHit]) {
        self.sessions = sessions
        self.events = events
    }
}

/// A session search hit. `highlight` carries `<mark>...</mark>` tags the
/// server wraps around matched substrings — passed through as-is for the
/// client to render.
public struct SessionSearchHit: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var status: String
    public var cwd: String?
    public var highlight: String?

    public init(id: String, name: String? = nil, status: String, cwd: String? = nil, highlight: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.cwd = cwd
        self.highlight = highlight
    }
}

/// An event search hit.
public struct EventSearchHit: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var sessionId: String
    public var sessionName: String?
    public var eventType: String
    public var toolName: String?
    public var highlight: String?

    public init(
        id: Int,
        sessionId: String,
        sessionName: String? = nil,
        eventType: String,
        toolName: String? = nil,
        highlight: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.eventType = eventType
        self.toolName = toolName
        self.highlight = highlight
    }
}
