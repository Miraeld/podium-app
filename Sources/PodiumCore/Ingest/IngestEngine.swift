// IngestEngine.swift — port of dashboard/server/routes/hooks.js's
// `processEvent` (lines 216–1012), the ingestion state machine that turns
// raw Claude Code hook payloads into session/agent/event rows and WS
// broadcasts. Behavioral parity with the Node code beats elegance — every
// branch below is commented with the hooks.js line range it ports so a
// future diff against upstream stays tractable.
//
// Deviations from Node (documented per STANDALONE_PLAN.md §4.7 working
// agreement):
//   - Transcript token/compaction/error/turn-duration extraction is behind
//     the `TranscriptTokenSource` seam (IngestSeams.swift) rather than a
//     concrete JSONL parser — P3.1 owns that parser. The no-op default makes
//     every code path *reachable* and testable via a stub source; only the
//     literal bytes-on-disk parsing is deferred.
//   - Session-metadata enrichment (`usage_extras`, `thinking_blocks`,
//     `turn_count`) from transcript-cache.js's extras is NOT ported — it's
//     display-only enrichment that depends entirely on P3.1's richer
//     extraction result, which `TranscriptExtractResult` deliberately omits
//     (see that type's doc comment). Token totals, compaction, API errors,
//     and turn durations — the parts with behavioral consequences (cost,
//     status transitions, event timeline) — ARE fully wired.
//   - `scanAndImportSubagents` (hooks.js lines 1031–1054, subagent JSONL
//     sweep after SubagentStop) is NOT ported here — it's transcript/JSONL
//     work squarely in P3.1/P3.2's territory (import-history.js). The route
//     layer (HooksRouter) is where that would be triggered post-response,
//     same as Node; left as a TODO there.
//   - The watchdog (API-error polling every 15s) and stuck-agent checker
//     (every 60s) are periodic background loops, not part of the per-event
//     state machine `process(hookType:data:)` — they belong with the other
//     ServicesRunner periodic services (P3.2), not this route's engine.
//
// Concurrency / transactions: `PodiumStore.db` confines all access to a
// private serial `DispatchQueue`. `Database.transaction(_:)` hands its body
// a raw `OpaquePointer` specifically so the body can issue further
// statements *without* re-entering `Database.sync` — but every `PodiumStore`
// method (which is all this engine calls) re-enters `sync` itself, so using
// `Database.transaction` here would deadlock (`DispatchQueue.sync` is not
// reentrant). Instead, `process(hookType:data:)` brackets the whole event
// with plain `db.exec("BEGIN")` / `db.exec("COMMIT")` calls — each is its
// own top-level hop onto the serial queue, so every `PodiumStore` call in
// between is *also* its own serialized hop, with no other caller able to
// interleave a write in between (same queue, strictly FIFO). This gives the
// same all-or-nothing durability as Node's `db.transaction(...)` without the
// nested-sync deadlock. Broadcasts are collected and returned only after
// COMMIT succeeds, so nothing is ever broadcast for a write that then rolled
// back (Node broadcasts mid-transaction since better-sqlite3 is fully
// synchronous; queuing until commit here is strictly safer). Notifier events
// (push notifications) follow the exact same discipline: `process(...)`
// collects them into `pendingNotifications` inside `processTransactionBody`
// and only spawns the actual `notifier.notify(...)` `Task`s after `COMMIT`
// succeeds — a rolled-back transaction must never cause a real, irreversible
// OS push notification to fire.

import Foundation

/// Session-level in-memory alert state hooks.js keeps at module scope
/// (`costSpikeAlertsSet`, `stuckAgentAlertsSet` — lines 134–138). Scoped to
/// one `IngestEngine` instance (one process, same as Node's single module
/// instance) rather than static state, so tests get a fresh engine per case.
private final class AlertTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var costSpikeAlerted: Set<String> = []
    private var stuckAlerted: Set<String> = []

    func hasCostSpikeAlert(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return costSpikeAlerted.contains(sessionId)
    }

    func markCostSpikeAlerted(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        costSpikeAlerted.insert(sessionId)
    }

    func clearCostSpikeAlert(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        costSpikeAlerted.remove(sessionId)
    }

    func clearStuckAlert(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        stuckAlerted.remove(sessionId)
    }

    func hasStuckAlert(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stuckAlerted.contains(sessionId)
    }

    func markStuckAlerted(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        stuckAlerted.insert(sessionId)
    }
}

/// Port of hooks.js's `processEvent` — the ingestion state machine. One
/// instance is safe to share across concurrent hook POSTs (all DB access is
/// already serialized by `PodiumStore.db`; `AlertTracker` is lock-protected).
public final class IngestEngine: @unchecked Sendable {
    public let store: PodiumStore
    private let transcriptSource: TranscriptTokenSource
    private let notifier: Notifier
    private let alerts = AlertTracker()

    /// Stale-session threshold for SessionStart cleanup + the periodic sweep
    /// (hooks.js lines 180–186): `DASHBOARD_STALE_MINUTES` env, default 180.
    public let staleMinutes: Int

    public init(
        store: PodiumStore,
        transcriptSource: TranscriptTokenSource = NoOpTranscriptTokenSource(),
        notifier: Notifier = NoOpNotifier(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.transcriptSource = transcriptSource
        self.notifier = notifier
        if let raw = environment["DASHBOARD_STALE_MINUTES"], let parsed = Int(raw), parsed > 0 {
            self.staleMinutes = parsed
        } else {
            self.staleMinutes = 180
        }
    }

    /// Processes one hook event end-to-end: DB writes happen bracketed by a
    /// single `BEGIN`/`COMMIT` (rolled back atomically on any thrown error,
    /// matching Node's `db.transaction`), and the ordered list of broadcasts
    /// produced is returned for the caller to fan out over `/ws` once the
    /// transaction has safely committed.
    ///
    /// Never throws for garbage/malformed payloads — returns `[]` when
    /// `session_id` is missing (hooks.js: `if (!sessionId) return null`) or
    /// when anything inside the transaction throws (garbage payload shapes,
    /// e.g. `tool_input` being a string instead of an object, must not 500
    /// the route or crash Claude Code).
    @discardableResult
    public func process(hookType: String, data: JSONValue) -> [Broadcast] {
        guard let sessionId = data.nonEmptyString("session_id") else { return [] }

        do {
            try store.db.exec("BEGIN;")
        } catch {
            return []
        }

        do {
            var pendingNotifications: [NotifierEvent] = []
            let broadcasts = try processTransactionBody(hookType: hookType, sessionId: sessionId, data: data, pendingNotifications: &pendingNotifications)
            try store.db.exec("COMMIT;")
            // Only fire notifier events once COMMIT has actually succeeded —
            // mirrors the broadcasts discipline above (see file header
            // comment): nothing observable outside the DB should escape for
            // a write that later rolled back, including OS push
            // notifications, which are irreversible once sent.
            let notifier = self.notifier
            for event in pendingNotifications {
                Task { await notifier.notify(event) }
            }
            return broadcasts
        } catch {
            try? store.db.exec("ROLLBACK;")
            return []
        }
    }

    // MARK: - Transaction body

    private func processTransactionBody(hookType: String, sessionId: String, data: JSONValue, pendingNotifications: inout [NotifierEvent]) throws -> [Broadcast] {
        var broadcasts: [Broadcast] = []

        // ── ensureSession (hooks.js lines 216–261) ──────────────────────
        guard var session = try ensureSession(sessionId: sessionId, data: data, broadcasts: &broadcasts) else {
            return []
        }
        var mainAgent = try store.getAgent(id: mainAgentId(sessionId))
        let mainAgentId = mainAgent?.id

        // ── Reactivation (hooks.js lines 275–301) ───────────────────────
        let isUserAction = hookType == "UserPromptSubmit" || hookType == "PreToolUse"
        let isNonTerminalEvent = hookType != "SessionEnd"
        let isStopLike = hookType == "Stop" || hookType == "SubagentStop"
        let statusKnown = session.status.knownValue
        let isImportedOrAbandoned = statusKnown == .completed || statusKnown == .abandoned
        let needsReactivation =
            statusKnown != .active && isNonTerminalEvent
            && (isUserAction
                || (!isStopLike && statusKnown != .error)
                || (isStopLike && isImportedOrAbandoned))

        if needsReactivation {
            try store.reactivateSession(id: sessionId)
            if let refreshed = try store.getSession(id: sessionId) {
                session = refreshed
                broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
            }
            if let agent = mainAgent, agent.status.knownValue != .working {
                try store.reactivateAgent(id: agent.id)
                if let refreshedAgent = try store.getAgent(id: agent.id) {
                    mainAgent = refreshedAgent
                    broadcasts.append(Broadcast(type: "agent_updated", agent: refreshedAgent))
                }
            }
        }

        var eventType = hookType
        let toolName = data.string("tool_name")
        var summary: String? = nil
        var agentId: String? = mainAgentId
        var mutableData = data

        // ── Per-hook-type switch (hooks.js lines 316–766) ───────────────
        switch hookType {
        case "PreToolUse":
            try handlePreToolUse(
                sessionId: sessionId, data: data, toolName: toolName,
                mainAgent: &mainAgent, agentId: &agentId, summary: &summary, broadcasts: &broadcasts
            )

        case "PostToolUse":
            try handlePostToolUse(
                sessionId: sessionId, data: &mutableData, toolName: toolName,
                mainAgent: mainAgent, agentId: &agentId, summary: &summary, broadcasts: &broadcasts
            )

        case "Stop":
            try handleStop(sessionId: sessionId, data: data, mainAgent: mainAgent, mainAgentId: mainAgentId, summary: &summary, broadcasts: &broadcasts)

        case "SubagentStop":
            try handleSubagentStop(sessionId: sessionId, data: data, agentId: &agentId, summary: &summary, broadcasts: &broadcasts)

        case "SessionStart":
            try handleSessionStart(
                sessionId: sessionId, data: data, mainAgent: mainAgent, mainAgentId: mainAgentId,
                summary: &summary, broadcasts: &broadcasts
            )

        case "SessionEnd":
            try handleSessionEnd(sessionId: sessionId, mainAgentId: mainAgentId, summary: &summary, broadcasts: &broadcasts, pendingNotifications: &pendingNotifications)

        case "UserPromptSubmit":
            try handleUserPromptSubmit(
                sessionId: sessionId, data: data, mainAgent: mainAgent, mainAgentId: mainAgentId,
                summary: &summary, broadcasts: &broadcasts
            )

        case "Notification":
            try handleNotification(sessionId: sessionId, data: data, mainAgentId: mainAgentId, eventType: &eventType, summary: &summary, broadcasts: &broadcasts)

        default:
            summary = "Event: \(hookType)"
        }

        // ── Transcript token/compaction/error extraction (hooks.js 768–977) ─
        if let transcriptPath = mutableData.nonEmptyString("transcript_path") {
            try extractTranscriptSignals(
                sessionId: sessionId, mainAgentId: mainAgentId, mainAgent: mainAgent,
                transcriptPath: transcriptPath, broadcasts: &broadcasts, pendingNotifications: &pendingNotifications
            )
        }

        // Evict transcript from cache on SessionEnd (hooks.js lines 981–983).
        if hookType == "SessionEnd", let transcriptPath = mutableData.nonEmptyString("transcript_path") {
            transcriptSource.invalidate(path: transcriptPath)
        }

        // Any new event clears stuck-agent tracking (hooks.js line 987, and
        // also line 498 inside the Stop case — the Stop-case clear is
        // redundant with this blanket one, kept here to match the *timing*
        // Node applies it: after the transcript scan, before the insert).
        alerts.clearStuckAlert(sessionId)

        // ── touchSession + insertEvent + final broadcast (hooks.js 990–1011) ─
        try store.touchSession(id: sessionId)

        let dataJSON = try jsonString(mutableData)
        try store.insertEvent(
            sessionId: sessionId, agentId: agentId, eventType: eventType,
            toolName: toolName, summary: summary, data: dataJSON
        )

        let eventPayload: JSONValue = .object([
            "session_id": .string(sessionId),
            "agent_id": agentId.map(JSONValue.string) ?? .null,
            "event_type": .string(eventType),
            "tool_name": toolName.map(JSONValue.string) ?? .null,
            "summary": summary.map(JSONValue.string) ?? .null,
            "created_at": .string(PodiumDate.now()),
        ])
        broadcasts.append(Broadcast(type: "new_event", data: eventPayload))

        return broadcasts
    }

    // MARK: - ensureSession (hooks.js lines 216–261)

    private func ensureSession(sessionId: String, data: JSONValue, broadcasts: inout [Broadcast]) throws -> Session? {
        if let existing = try store.getSession(id: sessionId) {
            try stampTranscriptPathIfNeeded(sessionId: sessionId, data: data)
            return existing
        }

        let cwd = data.nonEmptyString("cwd")
        let cwdBasename = cwd.map(Self.basename)
        let name = data.nonEmptyString("session_name")
            ?? cwdBasename
            ?? "Session \(String(sessionId.prefix(8)))"
        let model = data.nonEmptyString("model")

        try store.insertSession(id: sessionId, name: name, status: .active, cwd: cwd, model: model, metadata: nil)
        guard let session = try store.getSession(id: sessionId) else {
            // Mirrors hooks.js: "insert returned no row" — log-and-bail, not
            // a thrown error (the enclosing process() call already treats a
            // nil ensureSession result as "no-op this event").
            return nil
        }
        broadcasts.append(Broadcast(type: "session_created", session: session))

        // Main agent synthesis (hooks.js lines 234–249).
        let mainId = mainAgentId(sessionId)
        let sessionLabel = session.name ?? cwdBasename ?? "Session \(String(sessionId.prefix(8)))"
        try store.insertAgent(
            id: mainId, sessionId: sessionId, name: "Main Agent — \(sessionLabel)",
            type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil
        )
        if let mainAgent = try store.getAgent(id: mainId) {
            broadcasts.append(Broadcast(type: "agent_created", agent: mainAgent))
        }

        try stampTranscriptPathIfNeeded(sessionId: sessionId, data: data)
        return session
    }

    /// hooks.js lines 252–259: first-seen transcript_path one-shot stamp.
    /// The SQL guard (NULL/'' check) makes this idempotent, so it's safe to
    /// call on every event, not just session creation.
    private func stampTranscriptPathIfNeeded(sessionId: String, data: JSONValue) throws {
        guard let transcriptPath = data.nonEmptyString("transcript_path") else { return }
        try store.setSessionTranscriptPath(id: sessionId, transcriptPath: transcriptPath)
    }

    // MARK: - PreToolUse (hooks.js lines 317–402)

    private func handlePreToolUse(
        sessionId: String, data: JSONValue, toolName: String?,
        mainAgent: inout Agent?, agentId: inout String?, summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        summary = "Using tool: \(toolName ?? "unknown")"
        let mainAgentId = mainAgent?.id

        try clearAwaitingInput(sessionId: sessionId, mainAgentId: mainAgentId, broadcastUpdates: true, broadcasts: &broadcasts)

        if toolName == "Agent" {
            let input = data["tool_input"] ?? .object([:])
            let subId = UUID().uuidString.lowercased()
            let rawName = input.nonEmptyString("description")
                ?? input.nonEmptyString("subagent_type")
                ?? firstLine(input.nonEmptyString("prompt"), maxLength: 60)
                ?? "Subagent"
            let subName = rawName.count > 60 ? String(rawName.prefix(57)) + "..." : rawName

            // Heuristic parent inference (hooks.js lines 338–350).
            var parentId = mainAgentId
            if let main = mainAgent, main.status.knownValue != .working {
                if let deepest = try store.findDeepestWorkingAgent(sessionId: sessionId) {
                    parentId = deepest.id
                }
            }

            let promptTask = input.nonEmptyString("prompt").map { String($0.prefix(500)) }
            var metadata: [String: JSONValue] = input["metadata"]?.objectValue ?? [:]
            metadata["spawn_tool_use_id"] = data["tool_use_id"] ?? .null
            metadata["model"] = input["model"] ?? .null

            try store.insertAgent(
                id: subId, sessionId: sessionId, name: subName, type: .subagent,
                subagentType: input.nonEmptyString("subagent_type"), status: .working,
                task: promptTask, parentAgentId: parentId, metadata: try jsonString(.object(metadata))
            )
            if let created = try store.getAgent(id: subId) {
                broadcasts.append(Broadcast(type: "agent_created", agent: created))
            }
            agentId = subId
            summary = "Subagent spawned: \(subName)"
        }

        // Actor attribution heuristic (hooks.js lines 385–400).
        let deepestWorking: PodiumStore.DeepestAgent? = (mainAgent?.status.knownValue == .waiting)
            ? try store.findDeepestWorkingAgent(sessionId: sessionId)
            : nil
        let subagentIsActor = deepestWorking != nil
        if subagentIsActor, toolName != "Agent", let deepest = deepestWorking {
            agentId = deepest.id
        }
        if let main = mainAgent, !subagentIsActor,
           (main.status.knownValue == .working || main.status.knownValue == .waiting) {
            try store.updateAgent(id: main.id, status: .working, currentTool: toolName)
            if let refreshed = try store.getAgent(id: main.id) {
                mainAgent = refreshed
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
        }
    }

    // MARK: - PostToolUse (hooks.js lines 404–486)

    private func handlePostToolUse(
        sessionId: String, data: inout JSONValue, toolName: String?,
        mainAgent: Agent?, agentId: inout String?, summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        summary = "Tool completed: \(toolName ?? "unknown")"
        let mainAgentId = mainAgent?.id

        try clearAwaitingInput(sessionId: sessionId, mainAgentId: mainAgentId, broadcastUpdates: true, broadcasts: &broadcasts)

        if mainAgent?.status.knownValue == .waiting, toolName != "Agent" {
            if let deepest = try store.findDeepestWorkingAgent(sessionId: sessionId) {
                agentId = deepest.id
            }
        }

        // hooks.js line 428–429: only clear current_tool while the main
        // agent is actively working. `PodiumStore.updateAgent`'s
        // `currentTool` parameter maps straight to `current_tool = ?` with
        // NO COALESCE (see PodiumStore.swift's updateAgent SQL) — passing
        // `nil` here therefore force-clears the column, matching Node's
        // unconditional `current_tool = ?` with a `null` bind exactly.
        if let main = mainAgent, main.status.knownValue == .working {
            try store.updateAgent(id: main.id, currentTool: nil)
            if let refreshed = try store.getAgent(id: main.id) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
        }

        // Structured Bash output parsing (hooks.js lines 437–473).
        if toolName == "Bash", let toolResponse = data.string("tool_response") {
            var parsed: [String: JSONValue] = [:]

            if toolResponse.count > 2000 {
                data = data.settingObject("output_preview", to: .string(String(toolResponse.prefix(2000))))
            }

            if let phpunit = BashOutputParsers.parsePhpUnit(toolResponse) {
                parsed["phpunit"] = .object([
                    "type": .string("phpunit"),
                    "tests": .number(Double(phpunit.tests)),
                    "assertions": .number(Double(phpunit.assertions)),
                    "failures": .number(Double(phpunit.failures)),
                    "errors": .number(Double(phpunit.errors)),
                    "passed": .bool(phpunit.passed),
                ])
            }
            if let phpcs = BashOutputParsers.parsePhpcs(toolResponse) {
                parsed["phpcs"] = .object([
                    "type": .string("phpcs"),
                    "errors": .number(Double(phpcs.errors)),
                    "warnings": .number(Double(phpcs.warnings)),
                ])
            }
            if let prUrl = BashOutputParsers.extractPrUrl(toolResponse) {
                parsed["github_pr_url"] = .string(prUrl)
                try store.setGithubPrUrlIfUnset(sessionId: sessionId, url: prUrl)
            }
            if let gitStat = BashOutputParsers.parseGitStat(toolResponse) {
                parsed["git_stat"] = .object([
                    "type": .string("git_stat"),
                    "files_changed": .number(Double(gitStat.filesChanged)),
                    "insertions": .number(Double(gitStat.insertions)),
                    "deletions": .number(Double(gitStat.deletions)),
                ])
            }

            if !parsed.isEmpty {
                data = data.settingObject("bash_parsed", to: .object(parsed))
            }
        }

        // Richer summary from tool_response (hooks.js lines 475–484).
        if let responseText = data.string("tool_response")?.trimmingCharacters(in: .whitespacesAndNewlines), !responseText.isEmpty {
            let firstLine = responseText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if let firstLine, !firstLine.isEmpty {
                summary = "Tool completed: \(toolName ?? "unknown") — \(String(firstLine.prefix(500)))"
            }
        }
    }

    // MARK: - Stop (hooks.js lines 488–539)

    private func handleStop(
        sessionId: String, data: JSONValue, mainAgent: Agent?, mainAgentId: String?,
        summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        let session = try store.getSession(id: sessionId)
        let sessionLabel = session?.name ?? "Session \(String(sessionId.prefix(8)))"
        let stopReason = data.string("stop_reason")
        summary = stopReason == "error" ? "Error in \(sessionLabel)" : "\(sessionLabel) — ready for input"

        alerts.clearStuckAlert(sessionId)

        let agentMutable = mainAgent != nil && mainAgent?.status.knownValue != .completed && mainAgent?.status.knownValue != .error
        let now = PodiumDate.now()

        if stopReason == "error" {
            if agentMutable, let id = mainAgentId {
                try store.updateAgent(id: id, status: .error)
            }
            try store.updateSession(id: sessionId, status: .error, endedAt: now)
            try clearAwaitingInput(sessionId: sessionId, mainAgentId: mainAgentId, broadcastUpdates: false, broadcasts: &broadcasts)
        } else {
            if agentMutable, let id = mainAgentId {
                try store.updateAgent(id: id, status: .waiting)
            }
            try store.setSessionAwaitingInput(id: sessionId, since: now)
            if let id = mainAgentId {
                try store.setAgentAwaitingInput(id: id, since: now)
            }
        }

        if let refreshed = try store.getSession(id: sessionId) {
            broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
        }
        if let id = mainAgentId, let refreshed = try store.getAgent(id: id) {
            broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
        }
    }

    // MARK: - SubagentStop (hooks.js lines 541–597)

    private func handleSubagentStop(
        sessionId: String, data: JSONValue, agentId: inout String?,
        summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        summary = "Subagent completed"
        let subagents = try store.listAgentsBySession(sessionId: sessionId)
        var matching: Agent? = nil

        let subDesc = data.nonEmptyString("description") ?? data.nonEmptyString("agent_type") ?? data.nonEmptyString("subagent_type")
        if let subDesc {
            let prefix = subDesc.count > 57 ? String(subDesc.prefix(57)) : subDesc
            matching = subagents.first { $0.type.knownValue == .subagent && $0.status.knownValue == .working && $0.name.hasPrefix(prefix) }
        }

        if matching == nil, let agentType = data.nonEmptyString("agent_type") {
            matching = subagents.first { $0.type.knownValue == .subagent && $0.status.knownValue == .working && $0.subagentType == agentType }
        }

        if matching == nil, let prompt = data.nonEmptyString("prompt") {
            let truncated = String(prompt.prefix(500))
            matching = subagents.first { $0.type.knownValue == .subagent && $0.status.knownValue == .working && $0.task == truncated }
        }

        if matching == nil {
            matching = subagents.first { $0.type.knownValue == .subagent && $0.status.knownValue == .working }
        }

        if let matching {
            try store.updateAgent(id: matching.id, status: .completed, endedAt: PodiumDate.now())
            if let refreshed = try store.getAgent(id: matching.id) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
            agentId = matching.id
            summary = "Subagent completed: \(matching.name)"
        }
    }

    // MARK: - SessionStart (hooks.js lines 599–641)

    private func handleSessionStart(
        sessionId: String, data: JSONValue, mainAgent: Agent?, mainAgentId: String?,
        summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        summary = data.string("source") == "resume" ? "Session resumed" : "Session started"

        if mainAgent?.status.knownValue == .waiting, let id = mainAgentId {
            try store.updateAgent(id: id, status: .working)
        }

        let ts = PodiumDate.now()
        try store.setSessionAwaitingInput(id: sessionId, since: ts)
        if let id = mainAgentId {
            try store.setAgentAwaitingInput(id: id, since: ts)
        }

        if let refreshed = try store.getSession(id: sessionId) {
            broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
        }
        if let id = mainAgentId, let refreshed = try store.getAgent(id: id) {
            broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
        }

        // Stale-session cleanup (hooks.js lines 624–639).
        let staleIds = try store.findStaleSessions(excludingId: sessionId, minutes: staleMinutes)
        let now = PodiumDate.now()
        for staleId in staleIds {
            let staleAgents = try store.listAgentsBySession(sessionId: staleId)
            for agent in staleAgents where agent.status.knownValue != .completed && agent.status.knownValue != .error {
                try store.updateAgent(id: agent.id, status: .completed, endedAt: now)
                if let refreshed = try store.getAgent(id: agent.id) {
                    broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
                }
            }
            try store.updateSession(id: staleId, status: .abandoned, endedAt: now)
            if let refreshed = try store.getSession(id: staleId) {
                broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
            }
        }
    }

    // MARK: - SessionEnd (hooks.js lines 643–673)

    private func handleSessionEnd(
        sessionId: String, mainAgentId: String?, summary: inout String?, broadcasts: inout [Broadcast],
        pendingNotifications: inout [NotifierEvent]
    ) throws {
        let endSession = try store.getSession(id: sessionId)
        let endLabel = endSession?.name ?? "Session \(String(sessionId.prefix(8)))"
        summary = "Session closed: \(endLabel)"

        try clearAwaitingInput(sessionId: sessionId, mainAgentId: mainAgentId, broadcastUpdates: false, broadcasts: &broadcasts)
        alerts.clearCostSpikeAlert(sessionId)
        alerts.clearStuckAlert(sessionId)

        let finalStatus: SessionStatus = endSession?.status.knownValue == .error ? .error : .completed
        let allAgents = try store.listAgentsBySession(sessionId: sessionId)
        let now = PodiumDate.now()
        for agent in allAgents where agent.status.knownValue != .completed && agent.status.knownValue != .error {
            let agentFinal: AgentStatus = finalStatus == .error ? .error : .completed
            try store.updateAgent(id: agent.id, status: agentFinal, endedAt: now)
            if let refreshed = try store.getAgent(id: agent.id) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
        }
        try store.updateSession(id: sessionId, status: finalStatus, endedAt: now)
        if let refreshed = try store.getSession(id: sessionId) {
            broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
        }

        if finalStatus == .error {
            pendingNotifications.append(.sessionError(sessionId: sessionId, sessionName: endSession?.name))
        } else {
            pendingNotifications.append(.sessionCompleted(sessionId: sessionId, sessionName: endSession?.name))
        }
    }

    // MARK: - UserPromptSubmit (hooks.js lines 675–735)

    private func handleUserPromptSubmit(
        sessionId: String, data: JSONValue, mainAgent: Agent?, mainAgentId: String?,
        summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        summary = "User prompt submitted"
        try clearAwaitingInput(sessionId: sessionId, mainAgentId: mainAgentId, broadcastUpdates: true, broadcasts: &broadcasts)

        let promptText = data.nonEmptyString("message") ?? data.nonEmptyString("prompt") ?? data.nonEmptyString("prompt_preview")
        if let promptText {
            let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let taskLabel = String(trimmed.prefix(80))
                if let main = mainAgent, (main.task == nil || main.task == "") {
                    try store.setMainAgentTaskIfUnset(sessionId: sessionId, task: taskLabel)
                }

                let nameLabel = String(trimmed.prefix(60))
                if let curSession = try store.getSession(id: sessionId) {
                    let cwdBasename = curSession.cwd.map(Self.basename)
                    let defaultName = "Session \(String(sessionId.prefix(8)))"
                    let looksAutoGenerated = (curSession.name?.isEmpty ?? true)
                        || curSession.name == defaultName
                        || (cwdBasename != nil && curSession.name == cwdBasename)
                    if looksAutoGenerated {
                        try store.updateSession(id: sessionId, name: nameLabel)
                        if let refreshed = try store.getSession(id: sessionId) {
                            broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
                        }
                    }
                }
            }
        }

        if let main = mainAgent, main.status.knownValue != .completed, main.status.knownValue != .error, let id = mainAgentId {
            try store.updateAgent(id: id, status: .working)
        }
        // Re-read + broadcast final state (hooks.js lines 726–733 — Node
        // broadcasts twice here; the second read reflects the freshly-set
        // task/name from above, so both broadcasts are preserved for parity
        // even though they may carry the same payload when nothing changed
        // between them).
        if let id = mainAgentId {
            if let refreshed = try store.getAgent(id: id) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
            if let refreshed = try store.getAgent(id: id) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
        }
    }

    // MARK: - Notification (hooks.js lines 737–761)

    private func handleNotification(
        sessionId: String, data: JSONValue, mainAgentId: String?,
        eventType: inout String, summary: inout String?, broadcasts: inout [Broadcast]
    ) throws {
        let msg = data.nonEmptyString("message") ?? "Notification received"

        if NotificationClassifier.isCompactionRelated(msg) {
            eventType = "Compaction"
            summary = msg
        } else if NotificationClassifier.isWaitingForUser(msg) {
            let ts = PodiumDate.now()
            try store.setSessionAwaitingInput(id: sessionId, since: ts)
            if let refreshed = try store.getSession(id: sessionId) {
                broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
            }
            if let id = mainAgentId {
                try store.updateAgent(id: id, status: .waiting)
                try store.setAgentAwaitingInput(id: id, since: ts)
                if let refreshed = try store.getAgent(id: id) {
                    broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
                }
            }
            summary = msg
        } else {
            summary = msg
        }
    }

    // MARK: - Transcript signal extraction (hooks.js lines 768–977)

    private func extractTranscriptSignals(
        sessionId: String, mainAgentId: String?, mainAgent: Agent?,
        transcriptPath: String, broadcasts: inout [Broadcast], pendingNotifications: inout [NotifierEvent]
    ) throws {
        guard let result = transcriptSource.extract(path: transcriptPath) else { return }

        // Keep session.model in sync with the transcript's latest model.
        if let latestModel = result.latestModel {
            let changed = try store.updateSessionModel(id: sessionId, model: latestModel)
            if changed > 0, let refreshed = try store.getSession(id: sessionId) {
                broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
            }
        }

        // Compaction agents + events (hooks.js lines 798–848).
        for (offset, entry) in result.compactionEntries.enumerated() {
            guard let uuid = entry.uuid else { continue }
            let compactId = "\(sessionId)-compact-\(uuid)"
            if try store.getAgent(id: compactId) != nil { continue }

            let ts = entry.timestamp ?? PodiumDate.now()
            try store.insertAgent(
                id: compactId, sessionId: sessionId, name: "Context Compaction", type: .subagent,
                subagentType: "compaction", status: .completed,
                task: "Automatic conversation context compression", parentAgentId: mainAgentId, metadata: nil
            )
            try store.stampCompactionTimestamps(agentId: compactId, timestamp: ts)
            if let created = try store.getAgent(id: compactId) {
                broadcasts.append(Broadcast(type: "agent_created", agent: created))
            }

            let index = offset + 1
            let compactSummary = "Context compacted — conversation history compressed (#\(index))"
            let eventData: JSONValue = .object([
                "uuid": .string(uuid),
                "timestamp": .string(ts),
                "compaction_number": .number(Double(index)),
                "total_compactions": .number(Double(result.compactionEntries.count)),
            ])
            try store.insertEvent(sessionId: sessionId, agentId: compactId, eventType: "Compaction", toolName: nil, summary: compactSummary, data: try jsonString(eventData))
            broadcasts.append(Broadcast(type: "new_event", data: .object([
                "session_id": .string(sessionId),
                "agent_id": .string(compactId),
                "event_type": .string("Compaction"),
                "tool_name": .null,
                "summary": .string(compactSummary),
                "created_at": .string(ts),
            ])))
        }

        // Token usage + cost-spike detection (hooks.js lines 850–872).
        if !result.tokensByModel.isEmpty {
            for (model, tokens) in result.tokensByModel {
                try store.replaceTokenUsage(
                    sessionId: sessionId, model: model, inputTokens: tokens.inputTokens,
                    outputTokens: tokens.outputTokens, cacheReadTokens: tokens.cacheReadTokens,
                    cacheWriteTokens: tokens.cacheWriteTokens
                )
            }

            if !alerts.hasCostSpikeAlert(sessionId) {
                let cost = try calculateSessionCost(sessionId: sessionId)
                if cost > 1.0 {
                    alerts.markCostSpikeAlerted(sessionId)
                    broadcasts.append(Broadcast(type: "cost_spike", data: .object([
                        "session_id": .string(sessionId),
                        "cost": .number(cost),
                    ])))
                    pendingNotifications.append(.costSpike(sessionId: sessionId, cost: cost))
                }
            }
        }

        // API errors (hooks.js lines 874–923).
        if !result.errors.isEmpty {
            var newErrorRecorded = false
            for apiErr in result.errors {
                let summaryText = "\(apiErr.type): \(apiErr.message)"
                if try store.hasExistingAPIError(sessionId: sessionId, summary: summaryText) { continue }

                try store.insertEvent(
                    sessionId: sessionId, agentId: mainAgentId, eventType: "APIError", toolName: nil,
                    summary: summaryText, data: try jsonString(apiErr.raw)
                )
                broadcasts.append(Broadcast(type: "new_event", data: .object([
                    "session_id": .string(sessionId),
                    "agent_id": mainAgentId.map(JSONValue.string) ?? .null,
                    "event_type": .string("APIError"),
                    "tool_name": .null,
                    "summary": .string(summaryText),
                    "created_at": .string(apiErr.timestamp ?? PodiumDate.now()),
                ])))
                newErrorRecorded = true
            }

            if newErrorRecorded {
                if let curSession = try store.getSession(id: sessionId), curSession.status.knownValue == .active {
                    try store.updateSession(id: sessionId, status: .error)
                    if let refreshed = try store.getSession(id: sessionId) {
                        broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
                    }
                }
                if let main = mainAgent, main.status.knownValue != .completed, main.status.knownValue != .error, let id = mainAgentId {
                    try store.updateAgent(id: id, status: .error)
                    try clearAwaitingInput(sessionId: sessionId, mainAgentId: id, broadcastUpdates: false, broadcasts: &broadcasts)
                    if let refreshed = try store.getAgent(id: id) {
                        broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
                    }
                }
            }
        }

        // Turn duration events (hooks.js lines 925–955).
        for td in result.turnDurations {
            let tdTs = td.timestamp ?? PodiumDate.now()
            if try store.hasExistingTurnDuration(sessionId: sessionId, createdAt: tdTs) { continue }
            let tdSummary = "Turn completed in \(String(format: "%.1f", Double(td.durationMs) / 1000.0))s"
            let eventData: JSONValue = .object(["duration_ms": .number(Double(td.durationMs))])
            try store.insertEvent(sessionId: sessionId, agentId: mainAgentId, eventType: "TurnDuration", toolName: nil, summary: tdSummary, data: try jsonString(eventData))
            broadcasts.append(Broadcast(type: "new_event", data: .object([
                "session_id": .string(sessionId),
                "agent_id": mainAgentId.map(JSONValue.string) ?? .null,
                "event_type": .string("TurnDuration"),
                "tool_name": .null,
                "summary": .string(tdSummary),
                "created_at": .string(tdTs),
            ])))
        }
    }

    // MARK: - Cost calculation (hooks.js lines 145–175)

    private func calculateSessionCost(sessionId: String) throws -> Double {
        let tokenRows = try store.getTokensBySession(sessionId: sessionId)
        guard !tokenRows.isEmpty else { return 0 }
        let rules = try store.listPricing()
        var total = 0.0
        for row in tokenRows {
            guard let rule = rules.first(where: { matchesPricingPattern(model: row.model, pattern: $0.modelPattern) }) else { continue }
            total += (Double(row.inputTokens) / 1_000_000) * rule.inputPerMtok
            total += (Double(row.outputTokens) / 1_000_000) * rule.outputPerMtok
            total += (Double(row.cacheReadTokens) / 1_000_000) * rule.cacheReadPerMtok
            total += (Double(row.cacheWriteTokens) / 1_000_000) * rule.cacheWritePerMtok
        }
        return total
    }

    /// hooks.js line 163: `t.model.toLowerCase().startsWith(r.model_pattern.replace(/%$/, "").toLowerCase())`.
    private func matchesPricingPattern(model: String, pattern: String) -> Bool {
        let trimmedPattern = pattern.hasSuffix("%") ? String(pattern.dropLast()) : pattern
        return model.lowercased().hasPrefix(trimmedPattern.lowercased())
    }

    // MARK: - clearAwaitingInput (hooks.js lines 200–214)

    private func clearAwaitingInput(
        sessionId: String, mainAgentId: String?, broadcastUpdates: Bool, broadcasts: inout [Broadcast]
    ) throws {
        let agentsChanged = try store.clearSessionAgentsAwaitingInput(sessionId: sessionId)
        let sessionChanged = try store.clearSessionAwaitingInput(id: sessionId)
        if broadcastUpdates, agentsChanged > 0, let mainAgentId {
            if let refreshed = try store.getAgent(id: mainAgentId) {
                broadcasts.append(Broadcast(type: "agent_updated", agent: refreshed))
            }
        }
        if broadcastUpdates, sessionChanged > 0 {
            if let refreshed = try store.getSession(id: sessionId) {
                broadcasts.append(Broadcast(type: "session_updated", session: refreshed))
            }
        }
    }

    // MARK: - Small helpers

    /// The synthesized main-agent id for a session: `"<session>-main"`.
    public func mainAgentId(_ sessionId: String) -> String { "\(sessionId)-main" }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func firstLine(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        return String(line.prefix(maxLength))
    }

    private func jsonString(_ value: JSONValue) throws -> String {
        let data = try PodiumJSON.encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
