// RunSpawner.swift — port of lib/run-spawner.js.
//
// Spawns and supervises `claude` subprocesses for the dashboard's Run page.
// Two modes:
//   - headless     — single-shot. Stdin is closed after spawn; the prompt
//                     lives in argv via `-p`. Process exits when the model
//                     finishes the turn.
//   - conversation — multi-turn. Stdin stays open; follow-up turns are
//                     delivered via JSON envelopes through stdin.
//
// Output is always `--output-format stream-json --verbose
// --include-partial-messages` so `StreamJSONLineParser` can deliver
// structured envelopes. Each envelope is broadcast as `run_stream`; status
// changes (spawning → running → completed/error/killed) broadcast as
// `run_status`.
//
// *** WIRE FORMAT NOTE (parity finding, binding for this whole file) ***
// Unlike the rest of the Podium API (which is snake_case because it mirrors
// raw SQL row shapes), `publicHandle()` in run-spawner.js and every
// `broadcast("run_status"/"run_stream"/"run_input_ack", {...})` call site
// build their payloads as hand-written JS object literals — so the REAL
// wire format for this family is camelCase (`permissionMode`,
// `resumeSessionId`, `exitCode`, `sessionId`, `messageId`, `stdoutTail`, …),
// not snake_case. `RunHandle`/`RunListResponse`/etc. (PodiumCore/Models/
// Run.swift) already use camelCase Swift property names for exactly this
// reason — they must be encoded/decoded with a PLAIN JSONEncoder/JSONDecoder
// (no key-conversion strategy), never `PodiumJSON.encoder`/`.decoder`, or
// the wire keys silently come out wrong. `DashboardRun` (the SQL-backed
// `dashboard_runs` row, used by `GET /api/run/history`) is the one
// genuinely snake_case type in this family — see PodiumStore+Runs.swift and
// RunRouter.swift's `DashboardRunWire`, which also special-cases `isLive`
// (added post-query as a literal camelCase JS field, not a DB column).
//
// Concurrency is capped (`RUN_MAX_CONCURRENT`, default 10000) — over the cap
// `spawnRun` throws `.concurrency` so the router can return 429.
//
// Each handle keeps a bounded in-memory envelope log (cap 500) so a client
// that attaches late can replay what it missed. Completed handles are
// reaped 5 min after exit — the underlying transcript persists via the
// normal hook ingestion pipeline (every spawned `claude` fires hooks like
// any other session).

import Foundation
import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

/// Mirrors the `err.code`/`err.message` pairs thrown throughout
/// run-spawner.js/run.js, so the router can reproduce the exact same
/// `{"error":{"code","message"}}` bodies and HTTP status mapping.
public enum RunSpawnerError: Error, Equatable, Sendable {
    case badPrompt
    case badMode
    case badEffort(allowed: String)
    case badSession
    case concurrency(limit: Int, running: [RunConcurrencyEntry])
    case notFound
    case wrongMode
    case notRunning(status: String)
    case badInput
    case stdinClosed
    case badCwd(String)

    public var code: String {
        switch self {
        case .badPrompt: return "EBADPROMPT"
        case .badMode: return "EBADMODE"
        case .badEffort: return "EBADEFFORT"
        case .badSession: return "EBADSESSION"
        case .concurrency: return "ECONCURRENCY"
        case .notFound: return "ENOTFOUND"
        case .wrongMode: return "EWRONGMODE"
        case .notRunning: return "ENOTRUNNING"
        case .badInput: return "EBADINPUT"
        case .stdinClosed: return "ESTDINCLOSED"
        case .badCwd: return "EBADCWD"
        }
    }

    public var message: String {
        switch self {
        case .badPrompt: return "prompt is required"
        case .badMode: return "mode must be \"headless\" or \"conversation\""
        case .badEffort(let allowed): return "effort must be one of: \(allowed)"
        case .badSession: return "resumeSessionId is not a valid session id"
        case .concurrency(let limit, _): return "concurrency limit \(limit) reached"
        case .notFound: return "run not found"
        case .wrongMode: return "only conversation mode accepts follow-up input"
        case .notRunning(let status): return "run is \(status)"
        case .badInput: return "text is required"
        case .stdinClosed: return "stdin is not writable"
        case .badCwd(let detail): return detail
        }
    }
}

/// One entry of the `running` array attached to a 429 `ECONCURRENCY`
/// response (run-spawner.js `spawnRun`'s `err.running`). Fields are already
/// camelCase Swift property names matching the real (camelCase) Node wire
/// shape verbatim — `Encodable` is declared here (not via an extension in
/// another module) so the compiler can synthesize `encode(to:)` with no
/// `CodingKeys` needed. Always encode with a plain `JSONEncoder` — see
/// RunSpawner's header comment.
public struct RunConcurrencyEntry: Equatable, Encodable, Sendable {
    public let id: String
    public let pid: Int?
    public let startedAt: Double
    public let mode: String
}

// MARK: - Broadcasting seam

/// Minimal seam `RunSpawner` (PodiumCore) uses to fan out live events
/// without depending on `PodiumServer` — dependencies only flow the other
/// way (`PodiumServer` depends on `PodiumCore`, never the reverse), so
/// `RunSpawner` cannot import `Broadcaster` directly. `PodiumServer.
/// Broadcaster` already implements this exact `broadcast(type:data:)`
/// signature; `RunRouter.swift` declares the (zero-cost) conformance.
public protocol Broadcasting: Sendable {
    func broadcast(type: String, data: JSONValue) async
}

// MARK: - RunSpawner

public actor RunSpawner {
    static let maxConcurrentDefault = 10_000
    public static let reapAfterNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    static let stdoutTailChars = 4096
    static let stderrTailChars = 4096
    static let maxEnvelopesPerHandle = 500
    static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    private var handles: [String: LiveRun] = [:]
    private var reapTasks: [String: Task<Void, Never>] = [:]

    private let store: PodiumStore?
    private let broadcaster: Broadcasting
    private let claudeBinary: String
    private let reapDelayNanoseconds: UInt64

    /// - Parameters:
    ///   - store: Persistence target for `dashboard_runs`. Optional and
    ///     best-effort, exactly like the Node module's lazy `require("./
    ///     dashboard-runs")` — a `nil` store just means every persistence
    ///     call is skipped (useful for unit tests that don't need a DB).
    ///   - broadcaster: WS fan-out target for `run_status`/`run_stream`/
    ///     `run_input_ack`.
    ///   - claudeBinary: The executable to spawn. Defaults to `"claude"`
    ///     (resolved via `PATH` through `/usr/bin/env`, matching Node's
    ///     `spawn("claude", …)`). Tests inject an absolute path to a fixture
    ///     script here instead of spawning the real CLI.
    ///   - reapDelayNanoseconds: How long a finished handle stays queryable
    ///     before `reap` drops it (run-spawner.js's `REAP_AFTER_MS`, 5 min).
    ///     Overridable so tests can exercise reap behavior without an
    ///     actual 5-minute wait; production always uses the default.
    public init(store: PodiumStore?, broadcaster: Broadcasting, claudeBinary: String = "claude", reapDelayNanoseconds: UInt64 = RunSpawner.reapAfterNanoseconds) {
        self.store = store
        self.broadcaster = broadcaster
        self.claudeBinary = claudeBinary
        self.reapDelayNanoseconds = reapDelayNanoseconds
        // Subprocess stdin writes (sendInput) can hit a broken pipe if the
        // child already exited; without this the default SIGPIPE action
        // (terminate the whole server process) would take Podium down.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Spawn

    public func spawnRun(
        prompt: String,
        mode: RunMode,
        cwd: String,
        model: String?,
        permissionMode: String,
        resumeSessionId: String?,
        effort: String?
    ) async throws -> RunHandle {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resumingEmptyConversation = mode == .conversation && resumeSessionId != nil
        if trimmedPrompt.isEmpty && !resumingEmptyConversation {
            throw RunSpawnerError.badPrompt
        }
        if let effort, !effort.isEmpty, !Self.effortLevels.contains(effort) {
            throw RunSpawnerError.badEffort(allowed: Self.effortLevels.sorted().joined(separator: ", "))
        }
        if let resumeSessionId {
            guard Self.isValidSessionId(resumeSessionId) else { throw RunSpawnerError.badSession }
            guard mode == .conversation else { throw RunSpawnerError.badMode }
        }

        let maxConcurrentNow = maxConcurrent()
        if liveCount() >= maxConcurrentNow {
            let running = handles.values
                .filter { $0.status == .running || $0.status == .spawning }
                .map { RunConcurrencyEntry(id: $0.id, pid: $0.pid.map(Int.init), startedAt: $0.startedAt, mode: $0.mode.rawValue) }
            throw RunSpawnerError.concurrency(limit: maxConcurrentNow, running: running)
        }

        let id = UUID().uuidString.lowercased()
        let argv = buildArgv(prompt: prompt, mode: mode, model: model, permissionMode: permissionMode, resumeSessionId: resumeSessionId, effort: effort)

        let process = Process()
        if claudeBinary.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: claudeBinary)
            process.arguments = argv
        } else {
            // Let PATH resolve the binary, mirroring Node's `spawn("claude",
            // argv)` — Foundation's `Process` (unlike Node's child_process)
            // does not search PATH itself.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [claudeBinary] + argv
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = cleanSpawnEnv()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Self.nowMs()
        let normalizedEffort = (effort?.isEmpty == false) ? effort : nil
        let stdinWriter = StdinWriter(
            fileDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
            queue: DispatchQueue(label: "podium.run.\(id).stdin")
        )
        let live = LiveRun(
            id: id, mode: mode, cwd: cwd, model: model, permissionMode: permissionMode,
            effort: normalizedEffort, prompt: prompt, argv: argv, resumeSessionId: resumeSessionId,
            startedAt: startedAt, process: process, stdinPipe: stdinPipe, stdinWriter: stdinWriter
        )
        // Optimistic; confirmed (or corrected) by the system/init envelope.
        live.sessionId = resumeSessionId

        process.terminationHandler = { [weak self] proc in
            let reason = proc.terminationReason
            let status = proc.terminationStatus
            let code: Int32? = (reason == .exit) ? status : nil
            let signalDescription: String? = (reason == .uncaughtSignal) ? "\(status)" : nil
            Task { await self?.onProcessTerminated(id: id, code: code, signalDescription: signalDescription) }
        }

        do {
            try process.run()
        } catch {
            throw RunSpawnerError.badCwd("failed to spawn \(claudeBinary): \(error.localizedDescription)")
        }
        live.pid = process.processIdentifier

        handles[id] = live
        persistRecord(live)
        attachIO(id: id, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        if mode == .headless {
            try? stdinPipe.fileHandleForWriting.close()
            live.stdinClosed = true
        } else if !trimmedPrompt.isEmpty {
            do {
                try await stdinWriter.write(Self.userEnvelopeLine(text: prompt))
            } catch {
                live.stderrBuffer += "[stdin-write-error] \(String(describing: error))\n"
            }
        }
        // Conversation with an empty prompt (resume scenarios): leave stdin
        // open; claude idles on the resumed transcript until sendInput.

        await broadcaster.broadcast(type: "run_status", data: jsonObject(["id": .string(id), "status": .string(RunStatus.spawning.rawValue), "at": .number(startedAt)]))

        return snapshot(live, includeEnvelopes: false)
    }

    // MARK: - Send follow-up input (conversation mode)

    @discardableResult
    public func sendInput(id: String, text: String) async throws -> String {
        guard let live = handles[id] else { throw RunSpawnerError.notFound }
        guard live.mode == .conversation else { throw RunSpawnerError.wrongMode }
        guard live.status == .running || live.status == .spawning else { throw RunSpawnerError.notRunning(status: live.status.rawValue) }
        guard !text.isEmpty else { throw RunSpawnerError.badInput }
        guard !live.stdinClosed else { throw RunSpawnerError.stdinClosed }

        let messageId = UUID().uuidString.lowercased()
        do {
            try await live.stdinWriter.write(Self.userEnvelopeLine(text: text, id: messageId))
        } catch {
            live.stdinClosed = true
            throw RunSpawnerError.stdinClosed
        }
        await broadcaster.broadcast(type: "run_input_ack", data: jsonObject(["id": .string(id), "messageId": .string(messageId), "at": .number(Self.nowMs())]))
        return messageId
    }

    // MARK: - Kill

    @discardableResult
    public func killRun(id: String) async -> Bool {
        guard let live = handles[id] else { return false }
        if live.status == .completed || live.status == .error || live.status == .killed {
            return true
        }
        if live.process.isRunning {
            live.process.terminate()
            let pid = live.process.processIdentifier
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                // ESRCH (no such process) means it already exited; kill(0)
                // is the POSIX "is it still alive" probe.
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        live.status = .killed
        live.endedAt = Self.nowMs()
        await broadcaster.broadcast(type: "run_status", data: jsonObject(["id": .string(id), "status": .string(RunStatus.killed.rawValue), "at": .number(live.endedAt!)]))
        persistPatch(id: id, sessionId: nil, status: .killed, exitCode: nil, endedAt: live.endedAt)
        scheduleReap(id: id)
        return true
    }

    // MARK: - Reads

    public func getRun(id: String, includeEnvelopes: Bool) -> RunHandle? {
        guard let live = handles[id] else { return nil }
        return snapshot(live, includeEnvelopes: includeEnvelopes)
    }

    public func listRuns() -> [RunHandle] {
        handles.values.sorted { $0.startedAt > $1.startedAt }.map { snapshot($0, includeEnvelopes: false) }
    }

    public func liveCount() -> Int {
        handles.values.filter { $0.status == .spawning || $0.status == .running }.count
    }

    public func liveRunIds() -> Set<String> {
        Set(handles.values.filter { $0.status == .spawning || $0.status == .running }.map(\.id))
    }

    public func maxConcurrent() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["RUN_MAX_CONCURRENT"],
              let n = Int(raw), n > 0 else {
            return Self.maxConcurrentDefault
        }
        return n
    }

    /// Test-only: drops every tracked handle without touching the DB or
    /// killing anything. Callers are responsible for having already
    /// killed/awaited any live processes.
    func resetForTesting() {
        for task in reapTasks.values { task.cancel() }
        reapTasks.removeAll()
        handles.removeAll()
    }

    // MARK: - IO plumbing

    private func attachIO(id: String, stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.onStdoutData(id: id, data: data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.onStderrData(id: id, data: data) }
        }
    }

    private func onStdoutData(id: String, data: Data) async {
        guard let live = handles[id] else { return }
        guard !data.isEmpty else {
            live.stdoutClosed = true
            await maybeFinalize(id: id)
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        live.stdoutBuffer = Self.tail(live.stdoutBuffer + text, Self.stdoutTailChars)
        let results = live.parser.push(text)
        for result in results {
            switch result {
            case .success(let envelope):
                await handleEnvelope(id: id, live: live, envelope: envelope)
            case .failure(let err):
                live.stderrBuffer += "[parse-error] \(err.message): \(err.raw)\n"
            }
        }
    }

    private func onStderrData(id: String, data: Data) async {
        guard let live = handles[id] else { return }
        guard !data.isEmpty else {
            live.stderrClosed = true
            await maybeFinalize(id: id)
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        live.stderrBuffer = Self.tail(live.stderrBuffer + text, Self.stderrTailChars)
    }

    private func handleEnvelope(id: String, live: LiveRun, envelope: JSONValue) async {
        // First parsed envelope means the child is producing output → "running".
        if live.status == .spawning {
            live.status = .running
            await broadcaster.broadcast(type: "run_status", data: jsonObject(["id": .string(id), "status": .string(RunStatus.running.rawValue), "at": .number(Self.nowMs())]))
            persistPatch(id: id, sessionId: nil, status: .running, exitCode: nil, endedAt: nil)
        }
        // Capture session_id off the system/init envelope.
        if let obj = envelope.objectValue,
           obj["type"]?.stringValue == "system",
           obj["subtype"]?.stringValue == "init",
           let sessionId = obj["session_id"]?.stringValue {
            let wasNil = live.sessionId == nil
            live.sessionId = sessionId
            if wasNil {
                persistPatch(id: id, sessionId: sessionId, status: nil, exitCode: nil, endedAt: nil)
            }
        }
        live.envelopeCount += 1
        live.envelopes.append(RunEnvelope(raw: envelope))
        if live.envelopes.count > Self.maxEnvelopesPerHandle {
            live.envelopes.removeFirst(live.envelopes.count - Self.maxEnvelopesPerHandle)
        }
        await broadcaster.broadcast(type: "run_stream", data: jsonObject(["id": .string(id), "envelope": envelope]))
    }

    private func onProcessTerminated(id: String, code: Int32?, signalDescription: String?) async {
        guard let live = handles[id] else { return }
        live.pendingExit = (code: code, signal: signalDescription)
        await maybeFinalize(id: id)
    }

    /// Only finalizes once stdout AND stderr have both reported EOF *and*
    /// the termination handler has fired — avoids racing a still-draining
    /// pipe against the exit event (both Foundation callbacks can arrive in
    /// either order).
    private func maybeFinalize(id: String) async {
        guard let live = handles[id], !live.finalized else { return }
        guard live.stdoutClosed, live.stderrClosed, let pending = live.pendingExit else { return }
        live.finalized = true

        if let flushed = live.parser.flush() {
            switch flushed {
            case .success(let envelope):
                await handleEnvelope(id: id, live: live, envelope: envelope)
            case .failure(let err):
                live.stderrBuffer += "[parse-error] \(err.message): \(err.raw)\n"
            }
        }

        if live.status != .killed {
            live.status = (pending.code == 0) ? .completed : .error
            live.exitCode = pending.code.map(Int.init)
            live.signal = pending.signal
            live.endedAt = Self.nowMs()
            var payload: [String: JSONValue] = [
                "id": .string(id),
                "status": .string(live.status.rawValue),
                "at": .number(live.endedAt!),
            ]
            if let exitCode = live.exitCode { payload["exitCode"] = .number(Double(exitCode)) }
            if let sessionId = live.sessionId { payload["sessionId"] = .string(sessionId) }
            await broadcaster.broadcast(type: "run_status", data: .object(payload))
            persistPatch(id: id, sessionId: live.sessionId, status: live.status, exitCode: live.exitCode, endedAt: live.endedAt)
        }
        scheduleReap(id: id)
    }

    private func scheduleReap(id: String) {
        reapTasks[id]?.cancel()
        let delay = reapDelayNanoseconds
        reapTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.reap(id: id)
        }
    }

    private func reap(id: String) {
        handles[id]?.stdinWriter.close()
        handles.removeValue(forKey: id)
        reapTasks.removeValue(forKey: id)
    }

    // MARK: - Persistence (best-effort — matches dashboard-runs.js's blanket try/catch)

    private func persistRecord(_ live: LiveRun) {
        guard let store else { return }
        let promptPreview = String(live.prompt.prefix(500))
        try? store.recordDashboardRun(
            id: live.id, sessionId: live.sessionId, mode: live.mode, cwd: live.cwd, model: live.model,
            permissionMode: live.permissionMode, effort: live.effort, resumeSessionId: live.resumeSessionId,
            promptPreview: promptPreview.isEmpty ? nil : promptPreview, status: live.status, exitCode: live.exitCode,
            startedAt: Self.wireTimestamp(msEpoch: live.startedAt), endedAt: live.endedAt.map(Self.wireTimestamp)
        )
    }

    private func persistPatch(id: String, sessionId: String?, status: RunStatus?, exitCode: Int?, endedAt: Double?) {
        guard let store else { return }
        try? store.patchDashboardRun(
            id: id, sessionId: sessionId, status: status, exitCode: exitCode,
            endedAt: endedAt.map(Self.wireTimestamp)
        )
    }

    // MARK: - Helpers

    private static func wireTimestamp(msEpoch: Double) -> String {
        PodiumDate.format(Date(timeIntervalSince1970: msEpoch / 1000))
    }

    private func snapshot(_ live: LiveRun, includeEnvelopes: Bool) -> RunHandle {
        RunHandle(
            id: live.id,
            pid: live.pid.map(Int.init),
            mode: live.mode,
            cwd: live.cwd,
            model: live.model,
            permissionMode: live.permissionMode,
            effort: live.effort,
            prompt: live.prompt,
            argv: live.argv,
            resumeSessionId: live.resumeSessionId,
            status: live.status,
            startedAt: live.startedAt,
            endedAt: live.endedAt,
            exitCode: live.exitCode,
            signal: live.signal,
            error: live.error,
            sessionId: live.sessionId,
            envelopeCount: live.envelopeCount,
            stdoutTail: live.stdoutBuffer,
            stderrTail: live.stderrBuffer,
            envelopes: includeEnvelopes ? live.envelopes : nil
        )
    }

    private func jsonObject(_ pairs: [String: JSONValue]) -> JSONValue {
        .object(pairs)
    }

    private func cleanSpawnEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST")
        return env
    }

    /// Builds argv for the `claude` invocation (run-spawner.js `buildArgv`).
    private func buildArgv(prompt: String, mode: RunMode, model: String?, permissionMode: String, resumeSessionId: String?, effort: String?) -> [String] {
        var argv: [String] = ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        argv.append(contentsOf: ["--permission-mode", permissionMode.isEmpty ? "acceptEdits" : permissionMode])
        if mode == .headless {
            argv.append(contentsOf: ["-p", prompt])
        } else {
            argv.append("--input-format")
            argv.append("stream-json")
        }
        if let model, !model.isEmpty {
            argv.append(contentsOf: ["--model", model])
        }
        if let effort, Self.effortLevels.contains(effort) {
            argv.append(contentsOf: ["--effort", effort])
        }
        if let resumeSessionId {
            argv.append(contentsOf: ["--resume", resumeSessionId])
        }
        return argv
    }

    private static func isValidSessionId(_ value: String) -> Bool {
        guard value.utf8.count >= 8 else { return false }
        for scalar in value.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-": continue
            default: return false
            }
        }
        return true
    }

    private static func tail(_ s: String, _ maxChars: Int) -> String {
        guard s.count > maxChars else { return s }
        return String(s.suffix(maxChars))
    }

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private struct UserEnvelopeMessage: Encodable { let role = "user"; let content: String }
    private struct UserEnvelopeWire: Encodable { let type = "user"; let message: UserEnvelopeMessage; let id: String? }

    /// Frames a stream-json user envelope for stdin, used both for the
    /// initial conversation-mode prompt and follow-up turns via `sendInput`.
    private static func userEnvelopeLine(text: String, id: String? = nil) -> Data {
        let wire = UserEnvelopeWire(message: UserEnvelopeMessage(content: text), id: id)
        var data = (try? JSONEncoder().encode(wire)) ?? Data()
        data.append(0x0A)
        return data
    }
}

// MARK: - StdinWriter

/// Errors surfaced by `StdinWriter.write`.
enum StdinWriteError: Error, Sendable {
    /// The write did not complete within the deadline — defensive backstop
    /// only (see header comment on `StdinWriter`); should not fire under
    /// normal operation now that writes are off the actor's executor.
    case timedOut
    /// The kernel reported a write error (POSIX errno), most commonly
    /// EPIPE because the child already exited without reading stdin.
    case posix(Int32)
}

/// Writes to a child process's stdin pipe **without blocking the calling
/// actor's executor thread**.
///
/// `RunSpawner.sendInput`/`spawnRun` used to call
/// `FileHandle.write(contentsOf:)` directly on the actor. `Pipe` write ends
/// are backed by a real OS pipe with a bounded kernel buffer (64KB on both
/// Darwin and Linux); once that buffer is full, `write(2)` blocks the
/// calling thread until the reader drains it. Because `RunSpawner` is an
/// `actor`, that thread *is* the actor's executor — a single blocked
/// `write()` therefore freezes the entire actor, including the
/// `readabilityHandler`-dispatched `Task { await self.onStdoutData(...) }`
/// calls that would otherwise drain the child's stdout and unblock things.
/// A child that pauses reading stdin (slow model turn, backpressure from a
/// full terminal, or — as in the CI repro — 520 rapid-fire writes outrunning
/// a shell `read` loop) can deadlock the actor forever; this is a real
/// production hazard for the run-spawner feature, not just a test artifact.
///
/// The fix: hand the write to `DispatchIO`, which performs the actual
/// `write(2)` syscall(s) on a GCD I/O queue and chunks around backpressure
/// internally, then resumes a continuation from its completion handler.
/// The actor `await`s the continuation — it never blocks its own thread, so
/// stdout keeps draining concurrently and the pipe never deadlocks.
///
/// A deadline is layered on top as defense-in-depth: if some future kernel
/// or platform quirk still stalls the write, the call fails loudly (visible
/// error, `sendInput` returns `.stdinClosed`) instead of hanging the run —
/// and, in tests, instead of hanging the whole CI job.
final class StdinWriter: @unchecked Sendable {
    private let channel: DispatchIO
    private let queue: DispatchQueue

    init(fileDescriptor: Int32, queue: DispatchQueue) {
        self.queue = queue
        self.channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            // Cleanup handler intentionally empty — the pipe's FileHandle
            // owns closing the descriptor.
        }
        channel.setLimit(lowWater: 1)
    }

    /// Writes `data` and resumes once the kernel has accepted all of it (or
    /// reports an error). Never blocks the calling thread.
    func write(_ data: Data, timeout: TimeInterval = 10) async throws {
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            channel.write(offset: 0, data: dispatchData, queue: queue) { done, _, errno in
                guard done else { return }
                if errno == 0 {
                    box.resume(())
                } else {
                    box.resumeThrowing(StdinWriteError.posix(errno))
                }
            }
            // Defensive timeout: fires only if DispatchIO's completion
            // handler never runs (see class doc). Racing against the box's
            // "already resumed" guard makes this safe to fire alongside a
            // legitimate completion without double-resuming.
            queue.asyncAfter(deadline: .now() + timeout) {
                box.resumeThrowing(StdinWriteError.timedOut)
            }
        }
    }

    func close() {
        channel.close(flags: .stop)
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once even though both
/// the `DispatchIO` completion handler and the defensive timeout can race to
/// resume it. Not `Sendable`-checked by the compiler (continuations aren't
/// `Sendable` pre-6.0 in all contexts), so this box takes the unchecked
/// escape hatch and enforces single-resume itself via a lock.
private final class ContinuationBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var resolved = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ value: Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: value)
    }

    func resumeThrowing(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(throwing: error)
    }
}

// MARK: - LiveRun (internal mutable state)

/// The mutable, non-Codable internal record for one spawned process. Mapped
/// to the public `RunHandle` wire shape via `RunSpawner.snapshot`. A class
/// (not a struct) so actor methods can mutate fields in place without
/// re-inserting into the `handles` dictionary on every update.
private final class LiveRun {
    let id: String
    var pid: Int32?
    let mode: RunMode
    let cwd: String
    let model: String?
    let permissionMode: String
    let effort: String?
    let prompt: String
    let argv: [String]
    let resumeSessionId: String?
    var status: RunStatus = .spawning
    let startedAt: Double
    var endedAt: Double?
    var exitCode: Int?
    var signal: String?
    var error: String?
    var sessionId: String?
    var envelopeCount: Int = 0
    var envelopes: [RunEnvelope] = []
    var stdoutBuffer: String = ""
    var stderrBuffer: String = ""
    var parser = StreamJSONLineParser()

    let process: Process
    let stdinPipe: Pipe
    /// Non-blocking writer for `stdinPipe.fileHandleForWriting` — see
    /// `StdinWriter`'s doc comment for why a plain `FileHandle.write` on
    /// this actor would be a deadlock hazard.
    let stdinWriter: StdinWriter
    var stdinClosed = false
    var stdoutClosed = false
    var stderrClosed = false
    var pendingExit: (code: Int32?, signal: String?)?
    var finalized = false

    init(
        id: String, mode: RunMode, cwd: String, model: String?, permissionMode: String, effort: String?,
        prompt: String, argv: [String], resumeSessionId: String?, startedAt: Double,
        process: Process, stdinPipe: Pipe, stdinWriter: StdinWriter
    ) {
        self.id = id
        self.mode = mode
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.prompt = prompt
        self.argv = argv
        self.resumeSessionId = resumeSessionId
        self.startedAt = startedAt
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdinWriter = stdinWriter
    }
}
