import Foundation

/// Payload for `update_status` WebSocket messages and
/// `GET /api/updates/status` (routes/updates.js). Matches
/// client/src/lib/types.ts `UpdateStatusPayload`.
public struct UpdateStatusPayload: Codable, Equatable, Sendable {
    public var gitRepo: Bool
    public var updateAvailable: Bool
    public var repoRoot: String?
    public var remoteRef: String?
    /// Remote name compared against — "upstream" if configured (fork
    /// convention), else "origin", else whatever single remote is set up.
    public var canonicalRemote: String?
    /// Local branch HEAD points at. `nil` on detached HEAD.
    public var currentBranch: String?
    /// What the local branch tracks (e.g. "origin/feature/foo"). `nil` when
    /// no upstream is configured for the current branch.
    public var trackingUpstream: String?
    /// True when the local branch's tracked upstream is exactly `remoteRef`
    /// — i.e. a plain `git pull --ff-only` will do the right thing.
    public var tracksCanonical: Bool?
    public var situation: Situation?
    /// Plain-language explanation when the user is *not* on the canonical
    /// default branch, so the manual command makes sense in context.
    public var situationNote: String?
    public var localSha: String?
    public var remoteSha: String?
    public var commitsBehind: Int?
    public var manualCommand: String?
    public var message: String?
    public var fetchError: String?

    public init(
        gitRepo: Bool,
        updateAvailable: Bool,
        repoRoot: String? = nil,
        remoteRef: String? = nil,
        canonicalRemote: String? = nil,
        currentBranch: String? = nil,
        trackingUpstream: String? = nil,
        tracksCanonical: Bool? = nil,
        situation: Situation? = nil,
        situationNote: String? = nil,
        localSha: String? = nil,
        remoteSha: String? = nil,
        commitsBehind: Int? = nil,
        manualCommand: String? = nil,
        message: String? = nil,
        fetchError: String? = nil
    ) {
        self.gitRepo = gitRepo
        self.updateAvailable = updateAvailable
        self.repoRoot = repoRoot
        self.remoteRef = remoteRef
        self.canonicalRemote = canonicalRemote
        self.currentBranch = currentBranch
        self.trackingUpstream = trackingUpstream
        self.tracksCanonical = tracksCanonical
        self.situation = situation
        self.situationNote = situationNote
        self.localSha = localSha
        self.remoteSha = remoteSha
        self.commitsBehind = commitsBehind
        self.manualCommand = manualCommand
        self.message = message
        self.fetchError = fetchError
    }

    /// Categorical hint for the UI, discriminated so callers can branch on
    /// shape (e.g. show "Restart after running" only when the command
    /// actually rewrites the working tree).
    public enum Situation: String, Codable, Equatable, Sendable {
        case trackingCanonical = "tracking_canonical"
        case forkOrDivergedTracking = "fork_or_diverged_tracking"
        case featureBranch = "feature_branch"
        case detachedHead = "detached_head"
    }
}

/// `POST /api/updates/check` response — same shape as the status payload
/// (routes/updates.js triggers a fresh check and returns the result).
public typealias UpdateCheckResponse = UpdateStatusPayload

/// Progress payload for `import.progress` WebSocket messages, emitted while
/// a legacy import / rescan / upload runs (routes/import.js). Matches
/// client/src/lib/types.ts `ImportProgressMessage`.
public struct ImportProgressMessage: Codable, Equatable, Sendable {
    public var importId: String?
    public var phase: Phase
    public var source: Source?
    public var processed: Int?
    public var total: Int?
    public var current: String?
    public var path: String?
    public var error: String?
    public var counters: [String: Int]?

    public init(
        importId: String? = nil,
        phase: Phase,
        source: Source? = nil,
        processed: Int? = nil,
        total: Int? = nil,
        current: String? = nil,
        path: String? = nil,
        error: String? = nil,
        counters: [String: Int]? = nil
    ) {
        self.importId = importId
        self.phase = phase
        self.source = source
        self.processed = processed
        self.total = total
        self.current = current
        self.path = path
        self.error = error
        self.counters = counters
    }

    public enum Phase: String, Codable, Equatable, Sendable {
        case start, scan, extract, parse, complete, error
        case extractError = "extract_error"
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case defaultSource = "default"
        case path
        case upload
    }
}

/// Payload for `cc_config_changed` WebSocket messages (lib/cc-watcher.js /
/// dashboard mutation endpoints). Matches client/src/lib/types.ts
/// `CcConfigChangedPayload`.
public struct CcConfigChangedPayload: Codable, Equatable, Sendable {
    public var source: Source
    public var action: Action?
    public var scope: Scope?
    public var type: String?
    public var name: String?
    public var paths: [String]?

    public init(
        source: Source,
        action: Action? = nil,
        scope: Scope? = nil,
        type: String? = nil,
        name: String? = nil,
        paths: [String]? = nil
    ) {
        self.source = source
        self.action = action
        self.scope = scope
        self.type = type
        self.name = name
        self.paths = paths
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case dashboard, fs
    }

    public enum Action: String, Codable, Equatable, Sendable {
        case write, delete
    }

    public enum Scope: String, Codable, Equatable, Sendable {
        case user, project
    }
}

/// Payload for `run_stream` WebSocket messages (routes/run.js /
/// lib/run-spawner.js) — a single envelope forwarded live from a running
/// `claude` process. Matches client/src/lib/types.ts `RunStreamPayload`.
public struct RunStreamPayload: Codable, Equatable, Sendable {
    public var id: String
    public var envelope: RunEnvelope

    public init(id: String, envelope: RunEnvelope) {
        self.id = id
        self.envelope = envelope
    }
}

/// Payload for `run_status` WebSocket messages. Matches
/// client/src/lib/types.ts `RunStatusPayload`.
public struct RunStatusPayload: Codable, Equatable, Sendable {
    public var id: String
    public var status: RunStatus
    /// Epoch milliseconds, matching `RunHandle`'s numeric timestamps.
    public var at: Double
    public var exitCode: Int?
    public var sessionId: String?
    public var error: String?

    public init(
        id: String,
        status: RunStatus,
        at: Double,
        exitCode: Int? = nil,
        sessionId: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.status = status
        self.at = at
        self.exitCode = exitCode
        self.sessionId = sessionId
        self.error = error
    }
}

/// Payload for `run_input_ack` WebSocket messages — acknowledges a message
/// sent to a conversation-mode run via `POST /api/run/:id/message`. Matches
/// client/src/lib/types.ts `RunInputAckPayload`.
public struct RunInputAckPayload: Codable, Equatable, Sendable {
    public var id: String
    public var messageId: String
    /// Epoch milliseconds.
    public var at: Double

    public init(id: String, messageId: String, at: Double) {
        self.id = id
        self.messageId = messageId
        self.at = at
    }
}
