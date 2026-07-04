import Foundation

/// The full-fidelity per-session export bundle — port of the object literal
/// `routes/export.js`'s `GET /session/:id` builds (`{podium_export_version,
/// exported_at, session, agents, events, token_usage}`) and the same shape
/// `POST /session` accepts back.
///
/// Deviation note: Node's importer defaults missing fields on each `agent`/
/// `event`/`token_usage` row individually (e.g. `agent.type ?? "main"`,
/// `agent.status ?? "completed"`) so a bundle from an older schema version
/// still imports. This port decodes each array element as a full `Agent` /
/// `DashboardEvent` / `TokenUsage` model, which requires that model's
/// required fields to be present — a hand-edited or very old bundle missing
/// a required column fails the whole import instead of defaulting that one
/// field. A bundle produced by this app's own exporter always has every
/// column populated (they come straight from NOT NULL DB columns), so the
/// export→import round trip this app performs on itself is unaffected;
/// only cross-version/hand-edited bundles are stricter than Node.
public struct SessionExportBundle: Codable, Equatable, Sendable {
    /// `EXPORT_VERSION` in export.js. Bumping this is a breaking wire change.
    public static let currentVersion = "1.0"

    public var podiumExportVersion: String
    public var exportedAt: String
    public var session: Session
    public var agents: [Agent]
    public var events: [DashboardEvent]
    public var tokenUsage: [TokenUsage]

    public init(
        session: Session,
        agents: [Agent],
        events: [DashboardEvent],
        tokenUsage: [TokenUsage],
        exportedAt: String = PodiumDate.now()
    ) {
        self.podiumExportVersion = Self.currentVersion
        self.exportedAt = exportedAt
        self.session = session
        self.agents = agents
        self.events = events
        self.tokenUsage = tokenUsage
    }

    private enum CodingKeys: String, CodingKey {
        case podiumExportVersion, exportedAt, session, agents, events, tokenUsage
    }

    /// Custom decode so `agents`/`events`/`tokenUsage` default to `[]` when
    /// absent (export.js's `const { session, agents = [], events = [],
    /// token_usage: tokenUsage = [] } = bundle` destructuring default) and
    /// `podiumExportVersion` defaults to `""` when absent (so a bundle
    /// missing the field entirely compares unequal to `currentVersion`,
    /// matching Node's `undefined !== "1.0"` → `UNSUPPORTED_VERSION`, rather
    /// than throwing a decode error unrelated to the actual problem).
    /// `session` has no default — a bundle without one is truly invalid,
    /// matching export.js's explicit `!session || !session.id` check.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.podiumExportVersion = try container.decodeIfPresent(String.self, forKey: .podiumExportVersion) ?? ""
        self.exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        self.session = try container.decode(Session.self, forKey: .session)
        self.agents = try container.decodeIfPresent([Agent].self, forKey: .agents) ?? []
        self.events = try container.decodeIfPresent([DashboardEvent].self, forKey: .events) ?? []
        self.tokenUsage = try container.decodeIfPresent([TokenUsage].self, forKey: .tokenUsage) ?? []
    }
}

/// `POST /api/import/session` (and `/api/export/session`) success response
/// — export.js's `res.json({ ok: true, session_id: session.id })`.
public struct SessionImportResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var sessionId: String

    public init(ok: Bool = true, sessionId: String) {
        self.ok = ok
        self.sessionId = sessionId
    }
}
