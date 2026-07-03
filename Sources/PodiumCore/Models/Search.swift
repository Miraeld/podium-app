import Foundation

/// `GET /api/search` response (dashboard/server/routes/search.js lines
/// 39–172) — a single combined, recency-sorted array mixing session and
/// event hits, NOT the `{sessions: [...], events: [...]}` shape the naming
/// might suggest. Each element is tagged with `type` so the client can
/// discriminate. Matches the exact JSON `res.json({ results, total })` the
/// Node router sends (the React client does not yet consume this endpoint —
/// see client/src/lib/types.ts, which has no `SearchResult` entry — so this
/// is modeled directly from the server source, not types.ts).
public struct SearchResponse: Codable, Equatable, Sendable {
    public var results: [SearchHit]
    public var total: Int

    public init(results: [SearchHit], total: Int) {
        self.results = results
        self.total = total
    }
}

/// One row of `GET /api/search` — a session or event hit. Both shapes are
/// folded into one flat JSON object by the Node router (session hits omit
/// `event_id`/`event_type`/`tool_name`/`summary`/`created_at`; event hits
/// omit `cwd`/`cost`/`started_at`), so this type carries the union of both
/// with the irrelevant fields `nil`, discriminated by `type`.
public struct SearchHit: Codable, Equatable, Sendable {
    /// `"session"` or `"event"`.
    public var type: String
    public var sessionId: String
    public var sessionName: String?

    // Session-hit-only fields.
    public var cwd: String?
    public var status: String?
    public var cost: Double?
    public var startedAt: String?

    // Event-hit-only fields.
    public var eventId: Int?
    public var eventType: String?
    public var toolName: String?
    public var summary: String?
    public var createdAt: String?

    /// Present on both — `<mark>...</mark>`-wrapped snippet around the
    /// matched substring, or `nil`/the raw field when no exact substring
    /// match was found (search.js `buildHighlight` semantics).
    public var highlight: String?

    public init(
        type: String,
        sessionId: String,
        sessionName: String? = nil,
        cwd: String? = nil,
        status: String? = nil,
        cost: Double? = nil,
        startedAt: String? = nil,
        eventId: Int? = nil,
        eventType: String? = nil,
        toolName: String? = nil,
        summary: String? = nil,
        createdAt: String? = nil,
        highlight: String? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.cwd = cwd
        self.status = status
        self.cost = cost
        self.startedAt = startedAt
        self.eventId = eventId
        self.eventType = eventType
        self.toolName = toolName
        self.summary = summary
        self.createdAt = createdAt
        self.highlight = highlight
    }
}
