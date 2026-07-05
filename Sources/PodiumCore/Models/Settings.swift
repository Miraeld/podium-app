import Foundation

/// `GET /api/settings/info` response (routes/settings.js) — server + DB
/// diagnostics shown on the Settings page.
public struct SettingsInfoResponse: Codable, Equatable, Sendable {
    public var db: DbInfo
    public var hooks: HookStatus
    public var server: ServerRuntimeInfo
    public var transcriptCache: TranscriptCacheStats

    public init(db: DbInfo, hooks: HookStatus, server: ServerRuntimeInfo, transcriptCache: TranscriptCacheStats) {
        self.db = db
        self.hooks = hooks
        self.server = server
        self.transcriptCache = transcriptCache
    }

    public struct DbInfo: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int
        public var counts: [String: Int]
        public var pragmas: Pragmas
        public var loadStats: LoadStats

        public init(path: String, size: Int, counts: [String: Int], pragmas: Pragmas, loadStats: LoadStats) {
            self.path = path
            self.size = size
            self.counts = counts
            self.pragmas = pragmas
            self.loadStats = loadStats
        }

        public struct Pragmas: Codable, Equatable, Sendable {
            public var journalMode: String
            public var synchronous: Int
            public var autoVacuum: Int
            public var encoding: String
            public var foreignKeys: Int
            public var busyTimeout: Int

            public init(
                journalMode: String,
                synchronous: Int,
                autoVacuum: Int,
                encoding: String,
                foreignKeys: Int,
                busyTimeout: Int
            ) {
                self.journalMode = journalMode
                self.synchronous = synchronous
                self.autoVacuum = autoVacuum
                self.encoding = encoding
                self.foreignKeys = foreignKeys
                self.busyTimeout = busyTimeout
            }
        }

        /// Event counts over the last 5 / 15 / 60 minutes.
        public struct LoadStats: Codable, Equatable, Sendable {
            public var m5: Int
            public var m15: Int
            public var h1: Int

            public init(m5: Int, m15: Int, h1: Int) {
                self.m5 = m5
                self.m15 = m15
                self.h1 = h1
            }
        }
    }

    /// Whether the Claude Code hooks required for ingestion are installed in
    /// `~/.claude/settings.json`, per hook type (routes/settings.js
    /// `getHookStatus`).
    public struct HookStatus: Codable, Equatable, Sendable {
        public var installed: Bool
        public var path: String
        public var hooks: [String: Bool]

        public init(installed: Bool, path: String, hooks: [String: Bool]) {
            self.installed = installed
            self.path = path
            self.hooks = hooks
        }
    }

    public struct ServerRuntimeInfo: Codable, Equatable, Sendable {
        public var uptime: Double
        public var nodeVersion: String
        public var platform: String
        public var wsConnections: Int
        public var memory: MemoryUsage
        public var cpuLoad: [Double]
        public var arch: String
        public var totalMem: Double
        public var freeMem: Double
        public var cpus: Int

        public init(
            uptime: Double,
            nodeVersion: String,
            platform: String,
            wsConnections: Int,
            memory: MemoryUsage,
            cpuLoad: [Double],
            arch: String,
            totalMem: Double,
            freeMem: Double,
            cpus: Int
        ) {
            self.uptime = uptime
            self.nodeVersion = nodeVersion
            self.platform = platform
            self.wsConnections = wsConnections
            self.memory = memory
            self.cpuLoad = cpuLoad
            self.arch = arch
            self.totalMem = totalMem
            self.freeMem = freeMem
            self.cpus = cpus
        }

        public struct MemoryUsage: Codable, Equatable, Sendable {
            public var rss: Double
            public var heapTotal: Double
            public var heapUsed: Double
            public var external: Double
            public var arrayBuffers: Double?

            public init(
                rss: Double,
                heapTotal: Double,
                heapUsed: Double,
                external: Double,
                arrayBuffers: Double? = nil
            ) {
                self.rss = rss
                self.heapTotal = heapTotal
                self.heapUsed = heapUsed
                self.external = external
                self.arrayBuffers = arrayBuffers
            }

            // Node's `process.memoryUsage()` keys are camelCase literals and
            // the client destructures them verbatim (api.ts line 188) — see
            // `AnyEncodable`'s doc comment.
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode([
                    "rss": AnyEncodable(rss),
                    "heapTotal": AnyEncodable(heapTotal),
                    "heapUsed": AnyEncodable(heapUsed),
                    "external": AnyEncodable(external),
                    "arrayBuffers": AnyEncodable(arrayBuffers),
                ])
            }
        }
    }

    public struct TranscriptCacheStats: Codable, Equatable, Sendable {
        public var size: Int
        public var maxSize: Int
        public var hits: Int
        public var misses: Int
        public var keys: [String]

        public init(size: Int, maxSize: Int, hits: Int, misses: Int, keys: [String]) {
            self.size = size
            self.maxSize = maxSize
            self.hits = hits
            self.misses = misses
            self.keys = keys
        }

        // Node's `cache.stats()` literal (api.ts lines 195–201): the
        // container key `transcript_cache` stays snake_case but `maxSize`
        // inside is a camelCase literal — see `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "size": AnyEncodable(size),
                "maxSize": AnyEncodable(maxSize),
                "hits": AnyEncodable(hits),
                "misses": AnyEncodable(misses),
                "keys": AnyEncodable(keys),
            ])
        }
    }
}

/// `POST /api/settings/clear-data` response.
public struct ClearDataResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var cleared: [String: Int]

    public init(ok: Bool, cleared: [String: Int]) {
        self.ok = ok
        self.cleared = cleared
    }
}

/// `POST /api/settings/reset-pricing` response.
public struct ResetPricingResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var pricing: [ModelPricing]

    public init(ok: Bool, pricing: [ModelPricing]) {
        self.ok = ok
        self.pricing = pricing
    }
}

/// `POST /api/settings/reinstall-hooks` response.
public struct ReinstallHooksResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var hooks: SettingsInfoResponse.HookStatus

    public init(ok: Bool, hooks: SettingsInfoResponse.HookStatus) {
        self.ok = ok
        self.hooks = hooks
    }
}

/// `GET /api/settings/claude-home` response.
public struct ClaudeHomeResponse: Codable, Equatable, Sendable {
    public var claudeHome: String

    public init(claudeHome: String) {
        self.claudeHome = claudeHome
    }
}

/// `PUT /api/settings/claude-home` request body.
public struct ClaudeHomePutRequest: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

/// `PUT /api/settings/claude-home` response.
public struct ClaudeHomePutResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var claudeHome: String

    public init(ok: Bool, claudeHome: String) {
        self.ok = ok
        self.claudeHome = claudeHome
    }
}

/// `POST /api/settings/cleanup` request body.
public struct CleanupRequest: Codable, Equatable, Sendable {
    public var abandonHours: Double?
    public var purgeDays: Double?

    public init(abandonHours: Double? = nil, purgeDays: Double? = nil) {
        self.abandonHours = abandonHours
        self.purgeDays = purgeDays
    }
}

/// `POST /api/settings/cleanup` response.
public struct CleanupResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var abandoned: Int
    public var purgedSessions: Int
    public var purgedEvents: Int
    public var purgedAgents: Int

    public init(ok: Bool, abandoned: Int, purgedSessions: Int, purgedEvents: Int, purgedAgents: Int) {
        self.ok = ok
        self.abandoned = abandoned
        self.purgedSessions = purgedSessions
        self.purgedEvents = purgedEvents
        self.purgedAgents = purgedAgents
    }
}

/// `GET /api/settings/export` response — full DB export as JSON
/// (routes/settings.js). Row shapes are the raw SQLite columns (snake_case
/// already, `SELECT *`), so reuse the existing row models directly.
public struct ExportResponse: Codable, Equatable, Sendable {
    public var exportedAt: String
    public var sessions: [Session]
    public var agents: [Agent]
    public var events: [DashboardEvent]
    public var tokenUsage: [TokenUsage]
    public var modelPricing: [ModelPricing]

    public init(
        exportedAt: String,
        sessions: [Session],
        agents: [Agent],
        events: [DashboardEvent],
        tokenUsage: [TokenUsage],
        modelPricing: [ModelPricing]
    ) {
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.agents = agents
        self.events = events
        self.tokenUsage = tokenUsage
        self.modelPricing = modelPricing
    }
}
