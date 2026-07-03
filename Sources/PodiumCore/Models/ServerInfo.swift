import Foundation

/// `GET /api/health` response (dashboard/server/index.js line 96).
public struct HealthResponse: Codable, Equatable, Sendable {
    public var status: String
    public var timestamp: String

    public init(status: String = "ok", timestamp: String = PodiumDate.now()) {
        self.status = status
        self.timestamp = timestamp
    }

    public var timestampDate: Date? { PodiumDate.parse(timestamp) }
}

/// The WebSocket envelope every broadcast is wrapped in:
/// `{ type, data, timestamp }` (dashboard/server/websocket.js). Matches
/// client/src/lib/types.ts `WSMessage`.
///
/// `data` is kept as `JSONValue` rather than a closed enum over every
/// possible payload type — the Swift server encodes concrete payload structs
/// directly into this envelope (see `PodiumServer`'s broadcaster), and
/// clients decode `data` per `type` themselves. This mirrors the TS client,
/// which also narrows `data`'s union type based on `type` at the call site.
public struct WSMessage: Codable, Equatable, Sendable {
    public var type: String
    public var data: JSONValue
    public var timestamp: String

    public init(type: String, data: JSONValue, timestamp: String = PodiumDate.now()) {
        self.type = type
        self.data = data
        self.timestamp = timestamp
    }

    public var timestampDate: Date? { PodiumDate.parse(timestamp) }
}

/// One entry in the multi-server discovery file
/// `~/.claude/.agent-dashboard.json` (lib/server-info.js). Every running
/// dashboard server writes its own entry; `podium-hook` fans out one POST
/// per live entry so multiple concurrently-running servers (e.g. the macOS
/// app + a `npm run dev` instance) all receive hook events.
public struct ServerInfoEntry: Codable, Equatable, Sendable {
    public var port: Int
    public var pid: Int
    public var startedAt: String

    enum CodingKeys: String, CodingKey {
        case port
        case pid
        case startedAt
    }

    public init(port: Int, pid: Int, startedAt: String) {
        self.port = port
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// The full on-disk shape of `~/.claude/.agent-dashboard.json`
/// (lib/server-info.js `persist`). Carries legacy root-level `port`/`pid`/
/// `startedAt` fields (set to the most-recently-started live server) for
/// backwards compatibility with older hook handlers that predate the
/// multi-server `servers` array, alongside the full list new readers use.
public struct ServerInfo: Codable, Equatable, Sendable {
    /// Legacy single-record fields — most recently started live server.
    public var port: Int
    public var pid: Int
    public var startedAt: String
    /// The full list of live servers.
    public var servers: [ServerInfoEntry]

    enum CodingKeys: String, CodingKey {
        case port
        case pid
        case startedAt
        case servers
    }

    public init(port: Int, pid: Int, startedAt: String, servers: [ServerInfoEntry]) {
        self.port = port
        self.pid = pid
        self.startedAt = startedAt
        self.servers = servers
    }
}
