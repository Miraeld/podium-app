import Foundation

/// Lifecycle status of a spawned `claude` run. Raw values match both the
/// in-memory run-spawner handle and the persisted `dashboard_runs.status`
/// column (lib/run-spawner.js, lib/dashboard-runs.js). The task spec also
/// lists `abandoned` as a possible terminal state for persisted rows whose
/// process disappeared without a clean exit (orphan reconciliation on boot,
/// P4.1) — included here even though the live spawner itself never emits it.
public enum RunStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case spawning
    case running
    case completed
    case error
    case killed
    case abandoned
}

/// Conversation vs one-shot spawn mode (routes/run.js `mode` param).
public enum RunMode: String, Codable, CaseIterable, Equatable, Sendable {
    case headless
    case conversation
}

/// `claude` CLI permission mode, as accepted by `POST /api/run`
/// (routes/run.js `ALLOWED_PERMISSION_MODES`).
public enum RunPermissionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case acceptEdits
    case defaultMode = "default"
    case plan
    case bypassPermissions
}

/// A `dashboard_runs` row (db.js lines 119–135) — the persisted record of a
/// spawned run, independent of the in-memory handle's lifetime (reaped 5 min
/// after exit). Backing store for `GET /api/run/history`.
///
/// Unlike `RunEnvelope`/the live handle (which use epoch-millisecond
/// numbers, matching the JS runtime's `Date.now()`), this type uses wire
/// timestamp strings like every other DB-backed model, matching the
/// `dashboard_runs` table's TEXT columns exactly.
public struct DashboardRun: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionId: String?
    public var mode: LenientRawValue<RunMode>
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var effort: String?
    public var resumeSessionId: String?
    public var promptPreview: String?
    public var status: LenientRawValue<RunStatus>
    public var exitCode: Int?
    public var startedAt: String
    public var endedAt: String?
    /// Populated only by `GET /api/run/history`, which cross-references
    /// persisted rows against still-live in-memory handles.
    public var isLive: Bool?

    public init(
        id: String,
        sessionId: String? = nil,
        mode: RunMode,
        cwd: String,
        model: String? = nil,
        permissionMode: String? = nil,
        effort: String? = nil,
        resumeSessionId: String? = nil,
        promptPreview: String? = nil,
        status: RunStatus,
        exitCode: Int? = nil,
        startedAt: String,
        endedAt: String? = nil,
        isLive: Bool? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.mode = .known(mode)
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.resumeSessionId = resumeSessionId
        self.promptPreview = promptPreview
        self.status = .known(status)
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isLive = isLive
    }

    public var startedAtDate: Date? { PodiumDate.parse(startedAt) }
    public var endedAtDate: Date? { endedAt.flatMap(PodiumDate.parse) }
}

/// `GET /api/run/history` response (routes/run.js).
public struct RunHistoryResponse: Codable, Equatable, Sendable {
    public var items: [DashboardRun]

    public init(items: [DashboardRun]) {
        self.items = items
    }
}

/// The live run handle's public wire shape (`publicHandle` in
/// lib/run-spawner.js) — returned by `GET /api/run`, `GET /api/run/:id`,
/// and the `POST /api/run` creation response. `startedAt`/`endedAt` here are
/// epoch-millisecond numbers (`Date.now()`), NOT wire timestamp strings —
/// this matches the Node in-memory handle exactly, unlike `DashboardRun`
/// (the SQLite-persisted record) which uses TEXT ISO timestamps.
public struct RunHandle: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var pid: Int?
    public var mode: LenientRawValue<RunMode>
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var effort: String?
    public var prompt: String
    public var argv: [String]
    public var resumeSessionId: String?
    public var status: LenientRawValue<RunStatus>
    /// Epoch milliseconds.
    public var startedAt: Double
    /// Epoch milliseconds, `nil` while still running.
    public var endedAt: Double?
    public var exitCode: Int?
    public var signal: String?
    public var error: String?
    public var sessionId: String?
    public var envelopeCount: Int
    public var stdoutTail: String?
    public var stderrTail: String?
    /// Present only when the request opted in via `?envelopes=1`.
    public var envelopes: [RunEnvelope]?

    public init(
        id: String,
        pid: Int? = nil,
        mode: RunMode,
        cwd: String,
        model: String? = nil,
        permissionMode: String? = nil,
        effort: String? = nil,
        prompt: String,
        argv: [String],
        resumeSessionId: String? = nil,
        status: RunStatus,
        startedAt: Double,
        endedAt: Double? = nil,
        exitCode: Int? = nil,
        signal: String? = nil,
        error: String? = nil,
        sessionId: String? = nil,
        envelopeCount: Int = 0,
        stdoutTail: String? = nil,
        stderrTail: String? = nil,
        envelopes: [RunEnvelope]? = nil
    ) {
        self.id = id
        self.pid = pid
        self.mode = .known(mode)
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.prompt = prompt
        self.argv = argv
        self.resumeSessionId = resumeSessionId
        self.status = .known(status)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.signal = signal
        self.error = error
        self.sessionId = sessionId
        self.envelopeCount = envelopeCount
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.envelopes = envelopes
    }
}

/// One structured envelope from `claude --output-format stream-json`
/// (Anthropic Messages API streaming event shape) — opaque here since the
/// task's ingestion boundary treats these as passthrough JSON. Used in
/// `RunHandle.envelopes`, the `run_stream` WS payload, and the replay log.
public struct RunEnvelope: Codable, Equatable, Sendable {
    public var raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode(JSONValue.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// `GET /api/run` response — active runs + concurrency info (routes/run.js).
public struct RunListResponse: Codable, Equatable, Sendable {
    public var items: [RunHandle]
    public var maxConcurrent: Int
    public var activeCount: Int

    public init(items: [RunHandle], maxConcurrent: Int, activeCount: Int) {
        self.items = items
        self.maxConcurrent = maxConcurrent
        self.activeCount = activeCount
    }
}

/// `POST /api/run` request body (routes/run.js).
public struct RunCreateRequest: Codable, Equatable, Sendable {
    public var prompt: String
    public var mode: RunMode
    public var cwd: String?
    public var model: String?
    public var resumeSessionId: String?
    public var effort: String?
    public var permissionMode: RunPermissionMode?

    public init(
        prompt: String,
        mode: RunMode = .conversation,
        cwd: String? = nil,
        model: String? = nil,
        resumeSessionId: String? = nil,
        effort: String? = nil,
        permissionMode: RunPermissionMode? = nil
    ) {
        self.prompt = prompt
        self.mode = mode
        self.cwd = cwd
        self.model = model
        self.resumeSessionId = resumeSessionId
        self.effort = effort
        self.permissionMode = permissionMode
    }
}

/// `POST /api/run/:id/message` request body — send a follow-up message to a
/// live conversation-mode run (routes/run.js).
public struct RunMessageRequest: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// `GET /api/run/cwds` response item (routes/run.js) — a suggested working
/// directory for the Run page's cwd picker.
public struct RunCwdSuggestion: Codable, Identifiable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var label: String

    public var id: String { path }

    public init(kind: String, path: String, label: String) {
        self.kind = kind
        self.path = path
        self.label = label
    }
}

public struct RunCwdsResponse: Codable, Equatable, Sendable {
    public var items: [RunCwdSuggestion]

    public init(items: [RunCwdSuggestion]) {
        self.items = items
    }
}

/// `GET /api/run/files` response — file autocomplete results for the prompt
/// editor's `@` references (routes/run.js).
public struct RunFilesResponse: Codable, Equatable, Sendable {
    public var items: [String]

    public init(items: [String]) {
        self.items = items
    }
}

/// `GET /api/run/binary` response — whether `claude` is on PATH
/// (routes/run.js).
public struct RunBinaryResponse: Codable, Equatable, Sendable {
    public var found: Bool
    public var path: String?

    public init(found: Bool, path: String? = nil) {
        self.found = found
        self.path = path
    }
}
