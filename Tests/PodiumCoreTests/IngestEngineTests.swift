import XCTest
@testable import PodiumCore

/// Test-double `TranscriptTokenSource` — lets tests script exactly what the
/// (not-yet-built, P3.1) transcript parser would have extracted for a given
/// path, without touching disk. `extract(path:)` pops the next queued result
/// for that path (FIFO), so a test can simulate a transcript growing across
/// several hook events (e.g. token counts increasing, then a compaction
/// dropping them).
final class StubTranscriptTokenSource: TranscriptTokenSource, @unchecked Sendable {
    private var queued: [String: [TranscriptExtractResult]] = [:]
    private(set) var invalidatedPaths: [String] = []

    func enqueue(_ result: TranscriptExtractResult, for path: String) {
        queued[path, default: []].append(result)
    }

    func extract(path: String) -> TranscriptExtractResult? {
        guard var list = queued[path], !list.isEmpty else { return nil }
        let next = list.removeFirst()
        queued[path] = list
        return next
    }

    func invalidate(path: String) {
        invalidatedPaths.append(path)
    }
}

/// Builds `JSONValue` hook payloads shaped like hook.mjs's raw `p` object
/// (the same object it posts verbatim as `data` — see hook.mjs `run()`
/// returning `{ hookType: hook_event_name, data: p }`). Field names below
/// match hook.mjs's stdin schema (`session_id`, `tool_name`, `tool_input`,
/// `tool_response`, `tool_use_id`, `hook_event_name`, etc.) — hooks.js reads
/// straight off these.
enum HookFixture {
    static func payload(_ fields: [String: JSONValue]) -> JSONValue {
        .object(fields)
    }

    static func sessionStart(sessionId: String, cwd: String = "/Users/dev/project", model: String = "claude-sonnet-4-5", transcriptPath: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "cwd": .string(cwd),
            "model": .string(model),
        ]
        if let transcriptPath { fields["transcript_path"] = .string(transcriptPath) }
        return payload(fields)
    }

    static func userPromptSubmit(sessionId: String, message: String) -> JSONValue {
        payload(["session_id": .string(sessionId), "message": .string(message)])
    }

    static func preToolUse(sessionId: String, toolName: String, toolUseId: String? = nil, toolInput: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "tool_name": .string(toolName),
            "tool_input": .object(toolInput),
        ]
        if let toolUseId { fields["tool_use_id"] = .string(toolUseId) }
        return payload(fields)
    }

    static func postToolUse(sessionId: String, toolName: String, toolUseId: String? = nil, toolResponse: JSONValue = .string("done")) -> JSONValue {
        var fields: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "tool_name": .string(toolName),
            "tool_response": toolResponse,
        ]
        if let toolUseId { fields["tool_use_id"] = .string(toolUseId) }
        return payload(fields)
    }

    static func stop(sessionId: String, stopReason: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["session_id": .string(sessionId)]
        if let stopReason { fields["stop_reason"] = .string(stopReason) }
        return payload(fields)
    }

    static func subagentStop(sessionId: String, description: String? = nil, agentType: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["session_id": .string(sessionId)]
        if let description { fields["description"] = .string(description) }
        if let agentType { fields["agent_type"] = .string(agentType) }
        return payload(fields)
    }

    static func sessionEnd(sessionId: String) -> JSONValue {
        payload(["session_id": .string(sessionId)])
    }

    static func notification(sessionId: String, message: String) -> JSONValue {
        payload(["session_id": .string(sessionId), "message": .string(message)])
    }
}

final class IngestEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-ingest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeEngine(transcriptSource: TranscriptTokenSource = NoOpTranscriptTokenSource()) throws -> IngestEngine {
        let path = tempDir.appendingPathComponent("dashboard-\(UUID().uuidString).db").path
        let store = try PodiumStore(path: path)
        return IngestEngine(store: store, transcriptSource: transcriptSource)
    }

    // MARK: - Session created -> active, main agent synthesized and working

    func testSessionStartCreatesActiveSessionAndWorkingMainAgent() throws {
        let engine = try makeEngine()
        let sessionId = "sess-1"

        let broadcasts = engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        // SessionStart stamps awaiting_input (a fresh session sits at a
        // prompt) so the sequence is: session_created, agent_created,
        // session_updated, agent_updated, new_event.
        XCTAssertEqual(broadcasts.map(\.type), [
            "session_created", "agent_created", "session_updated", "agent_updated", "new_event",
        ])

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.status.knownValue, .active)
        XCTAssertNotNil(session?.awaitingInputSince, "fresh session should be awaiting input until the user submits a prompt")

        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertNotNil(mainAgent)
        XCTAssertEqual(mainAgent?.type.knownValue, .main)
        // SessionStart only promotes waiting -> working; a brand-new main
        // agent is inserted as "working" by ensureSession itself.
        XCTAssertEqual(mainAgent?.status.knownValue, .working)
        XCTAssertNotNil(mainAgent?.awaitingInputSince)
    }

    func testUserPromptSubmitClearsWaitingAndSetsTaskAndSessionName() throws {
        let engine = try makeEngine()
        let sessionId = "sess-2"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let broadcasts = engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "Fix the login bug in AuthController"))
        XCTAssertFalse(broadcasts.isEmpty)

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertNil(session?.awaitingInputSince, "UserPromptSubmit must clear the waiting flag")
        XCTAssertEqual(session?.name, "Fix the login bug in AuthController")

        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.status.knownValue, .working)
        XCTAssertEqual(mainAgent?.task, "Fix the login bug in AuthController")
        XCTAssertNil(mainAgent?.awaitingInputSince)
    }

    func testSecondUserPromptDoesNotOverwriteFirstTaskOrSessionName() throws {
        let engine = try makeEngine()
        let sessionId = "sess-2b"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "First task"))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "Second, unrelated task"))

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.name, "First task", "session name should be seeded once, from the first prompt")

        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.task, "First task", "task label should be seeded once")
    }

    // MARK: - 3-level subagent tree via tool_use_id matching

    func testThreeLevelSubagentTreeBuiltViaAgentToolUse() throws {
        let engine = try makeEngine()
        let sessionId = "sess-tree"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "Build a feature"))

        // Main agent spawns a level-1 subagent via the Agent tool.
        let broadcasts1 = engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "tu-1",
            toolInput: ["description": .string("Explore the codebase"), "subagent_type": .string("Explore"), "prompt": .string("Find the auth module")]
        ))
        XCTAssertTrue(broadcasts1.contains { $0.type == "agent_created" })

        let mainAgent = try XCTUnwrap(engine.store.getAgent(id: engine.mainAgentId(sessionId)))
        let level1 = try XCTUnwrap(engine.store.listAgentsBySession(sessionId: sessionId).first { $0.subagentType == "Explore" })
        XCTAssertEqual(level1.parentAgentId, mainAgent.id, "level-1 subagent should parent to the main agent (main was working)")
        XCTAssertEqual(level1.status.knownValue, .working)
        XCTAssertEqual(level1.name, "Explore the codebase")

        // Main agent is now "waiting" implicitly? No — PreToolUse for the
        // Agent tool itself doesn't touch main's status (only non-Agent
        // tools do, per hooks.js's `toolName !== "Agent"` guards). Force
        // main into "waiting" the way Node does in practice: a PostToolUse
        // for the Agent tool fires when the subagent is backgrounded.
        engine.process(hookType: "PostToolUse", data: HookFixture.postToolUse(sessionId: sessionId, toolName: "Agent", toolUseId: "tu-1"))
        let mainAfterBackground = try XCTUnwrap(engine.store.getAgent(id: mainAgent.id))
        XCTAssertEqual(mainAfterBackground.status.knownValue, .working, "PostToolUse for Agent must NOT complete/park main — only SubagentStop does")

        // To exercise the findDeepestWorkingAgent fallback, put main into
        // "waiting" explicitly (simulating: main is blocked on subagent
        // results) via a Stop with no error, then have the level-1 subagent
        // spawn a level-2 subagent — its PreToolUse should parent under
        // level-1 (the deepest working agent), not main.
        engine.process(hookType: "Stop", data: HookFixture.stop(sessionId: sessionId))
        let mainWaiting = try XCTUnwrap(engine.store.getAgent(id: mainAgent.id))
        XCTAssertEqual(mainWaiting.status.knownValue, .waiting)

        let broadcasts2 = engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "tu-2",
            toolInput: ["description": .string("Write the tests"), "subagent_type": .string("test-engineer"), "prompt": .string("Cover AuthController")]
        ))
        XCTAssertTrue(broadcasts2.contains { $0.type == "agent_created" })

        let level2 = try XCTUnwrap(engine.store.listAgentsBySession(sessionId: sessionId).first { $0.subagentType == "test-engineer" })
        XCTAssertEqual(level2.parentAgentId, level1.id, "level-2 subagent must parent to the deepest WORKING agent (level-1), via findDeepestWorkingAgent fallback — main is waiting")

        // Sanity: findDeepestWorkingAgent directly returns level-2 (deepest
        // working leaf) once it exists.
        let deepest = try engine.store.findDeepestWorkingAgent(sessionId: sessionId)
        XCTAssertEqual(deepest?.id, level2.id)
        XCTAssertEqual(deepest?.depth, 2, "depth is measured from the root (parent_agent_id IS NULL) agent — that's the synthesized MAIN agent itself (depth 0), so level-1 (parented under main) is depth 1, and level-2 (parented under level-1) is depth 2")
    }

    func testSubagentStopMatchesByDescriptionPrefixThenCompletes() throws {
        let engine = try makeEngine()
        let sessionId = "sess-substop"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "tu-1",
            toolInput: ["description": .string("Investigate the flaky test"), "subagent_type": .string("Explore")]
        ))

        let broadcasts = engine.process(hookType: "SubagentStop", data: HookFixture.subagentStop(sessionId: sessionId, description: "Investigate the flaky test"))
        XCTAssertTrue(broadcasts.contains { $0.type == "agent_updated" })

        let subagent = try XCTUnwrap(engine.store.listAgentsBySession(sessionId: sessionId).first { $0.subagentType == "Explore" })
        XCTAssertEqual(subagent.status.knownValue, .completed)
        XCTAssertNotNil(subagent.endedAt)
    }

    func testSubagentStopFallsBackToOldestWorkingWhenNoIdentifyingFieldsMatch() throws {
        let engine = try makeEngine()
        let sessionId = "sess-substop-fallback"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "tu-1",
            toolInput: ["description": .string("Some subagent"), "subagent_type": .string("generic")]
        ))

        // SubagentStop with NO identifying fields at all — must fall back to
        // "oldest working subagent" (hooks.js lines 574–577) rather than
        // leaving the subagent stuck in "working" forever.
        let broadcasts = engine.process(hookType: "SubagentStop", data: HookFixture.payload(["session_id": .string(sessionId)]))
        XCTAssertTrue(broadcasts.contains { $0.type == "agent_updated" })

        let subagent = try XCTUnwrap(engine.store.listAgentsBySession(sessionId: sessionId).first { $0.subagentType == "generic" })
        XCTAssertEqual(subagent.status.knownValue, .completed, "fallback match must still complete the only working subagent")
    }

    // MARK: - Tool events recorded with correct summaries; failure path

    func testPreAndPostToolUseRecordEventsWithSummaries() throws {
        let engine = try makeEngine()
        let sessionId = "sess-events"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(sessionId: sessionId, toolName: "Bash", toolInput: ["command": .string("ls -la")]))
        engine.process(hookType: "PostToolUse", data: HookFixture.postToolUse(sessionId: sessionId, toolName: "Bash", toolResponse: .string("total 42\nfile1.txt\nfile2.txt")))

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        let preEvent = try XCTUnwrap(events.first { $0.eventType == "PreToolUse" })
        XCTAssertEqual(preEvent.summary, "Using tool: Bash")

        let postEvent = try XCTUnwrap(events.first { $0.eventType == "PostToolUse" })
        XCTAssertEqual(postEvent.summary, "Tool completed: Bash — total 42")
        XCTAssertEqual(postEvent.toolName, "Bash")
    }

    func testBashOutputParsingExtractsPrUrlOntoSession() throws {
        let engine = try makeEngine()
        let sessionId = "sess-prurl"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        engine.process(hookType: "PostToolUse", data: HookFixture.postToolUse(
            sessionId: sessionId, toolName: "Bash",
            toolResponse: .string("Created pull request: https://github.com/acme/widgets/pull/42")
        ))

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.githubPrUrl, "https://github.com/acme/widgets/pull/42")
    }

    func testPostToolUseFailureRecordsEventWithoutCrashing() throws {
        // PostToolUseFailure isn't one of hooks.js's explicit switch cases —
        // it falls through to `default: summary = "Event: ${hookType}"` —
        // but it must still be recorded as an event and never throw.
        let engine = try makeEngine()
        let sessionId = "sess-failure"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let broadcasts = engine.process(hookType: "PostToolUseFailure", data: HookFixture.payload([
            "session_id": .string(sessionId),
            "tool_name": .string("Bash"),
            "error": .string("command not found"),
        ]))
        XCTAssertTrue(broadcasts.contains { $0.type == "new_event" })

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.eventType == "PostToolUseFailure" && $0.summary == "Event: PostToolUseFailure" })
    }

    // MARK: - Awaiting-input set on Notification, cleared on next activity

    func testNotificationWaitingForUserSetsAwaitingInput() throws {
        let engine = try makeEngine()
        let sessionId = "sess-notif"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "do a thing"))

        let broadcasts = engine.process(hookType: "Notification", data: HookFixture.notification(sessionId: sessionId, message: "Claude needs your permission to run this command"))
        XCTAssertTrue(broadcasts.contains { $0.type == "session_updated" })
        XCTAssertTrue(broadcasts.contains { $0.type == "agent_updated" })

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertNotNil(session?.awaitingInputSince)

        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.status.knownValue, .waiting)
        XCTAssertNotNil(mainAgent?.awaitingInputSince)

        // Cleared on next activity (PreToolUse).
        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(sessionId: sessionId, toolName: "Read", toolInput: ["file_path": .string("/tmp/x")]))
        let sessionAfter = try engine.store.getSession(id: sessionId)
        XCTAssertNil(sessionAfter?.awaitingInputSince)
        let mainAgentAfter = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertNil(mainAgentAfter?.awaitingInputSince)
    }

    func testIdleNotificationDoesNotSetAwaitingInput() throws {
        let engine = try makeEngine()
        let sessionId = "sess-notif-idle"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "do a thing"))

        engine.process(hookType: "Notification", data: HookFixture.notification(sessionId: sessionId, message: "Claude has finished responding"))

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertNil(session?.awaitingInputSince, "idle/informational notifications must not set the waiting flag")
    }

    func testCompactionNotificationTaggedAsCompactionEventType() throws {
        let engine = try makeEngine()
        let sessionId = "sess-notif-compact"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        engine.process(hookType: "Notification", data: HookFixture.notification(sessionId: sessionId, message: "Compacting conversation history to reduce context size"))

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.eventType == "Compaction" })
    }

    // MARK: - SessionEnd completes session + agents; events after end reactivate

    func testSessionEndCompletesSessionAndAllOpenAgents() throws {
        let engine = try makeEngine()
        let sessionId = "sess-end"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolInput: ["description": .string("Helper task")]
        ))

        let broadcasts = engine.process(hookType: "SessionEnd", data: HookFixture.sessionEnd(sessionId: sessionId))
        XCTAssertTrue(broadcasts.contains { $0.type == "session_updated" })

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.status.knownValue, .completed)
        XCTAssertNotNil(session?.endedAt)
        XCTAssertNil(session?.awaitingInputSince, "SessionEnd must drop any leftover waiting flag")

        let agents = try engine.store.listAgentsBySession(sessionId: sessionId)
        XCTAssertFalse(agents.isEmpty)
        for agent in agents {
            XCTAssertEqual(agent.status.knownValue, .completed, "every open agent must be force-completed on SessionEnd")
            XCTAssertNotNil(agent.endedAt)
        }
    }

    func testSessionEndKeepsErrorStatusInsteadOfOverwritingToCompleted() throws {
        let engine = try makeEngine()
        let sessionId = "sess-end-error"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "Stop", data: HookFixture.stop(sessionId: sessionId, stopReason: "error"))

        let mid = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(mid?.status.knownValue, .error)

        engine.process(hookType: "SessionEnd", data: HookFixture.sessionEnd(sessionId: sessionId))
        let final = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(final?.status.knownValue, .error, "SessionEnd must preserve error status rather than force-completing")
    }

    func testEventsAfterSessionEndReactivateTheSession() throws {
        let engine = try makeEngine()
        let sessionId = "sess-reactivate"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "SessionEnd", data: HookFixture.sessionEnd(sessionId: sessionId))

        let completed = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(completed?.status.knownValue, .completed)

        // A later UserPromptSubmit (e.g. `claude --resume`) must reactivate.
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "one more thing"))
        let reactivated = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(reactivated?.status.knownValue, .active)

        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.status.knownValue, .working, "main agent must also reactivate to working")
    }

    func testStopDoesNotReactivateAnErrorSession() throws {
        // hooks.js lines 284–291: Stop/SubagentStop only reactivate
        // completed/abandoned sessions, NEVER error sessions — a bare Stop
        // arriving after an error must not silently clear the error state.
        let engine = try makeEngine()
        let sessionId = "sess-noreact-error"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "Stop", data: HookFixture.stop(sessionId: sessionId, stopReason: "error"))

        XCTAssertEqual(try engine.store.getSession(id: sessionId)?.status.knownValue, .error)

        engine.process(hookType: "Stop", data: HookFixture.stop(sessionId: sessionId))
        XCTAssertEqual(try engine.store.getSession(id: sessionId)?.status.knownValue, .error, "a plain Stop must not reactivate an error session")
    }

    // MARK: - Token baselines survive a simulated compaction (counts drop)

    func testTokenBaselinesSurviveSimulatedCompaction() throws {
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-compact-tokens"
        let transcriptPath = "/fake/transcript.jsonl"

        // First event: 1000 input / 500 output tokens recorded.
        stub.enqueue(TranscriptExtractResult(tokensByModel: [
            "claude-sonnet-4-5": TranscriptTokens(inputTokens: 1000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]), for: transcriptPath)
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId, transcriptPath: transcriptPath))

        let before = try engine.store.getTokensBySession(sessionId: sessionId).first
        XCTAssertEqual(before?.inputTokens, 1000)
        XCTAssertEqual(before?.outputTokens, 500)

        // Compaction rewrote the transcript — the JSONL now reports LOWER
        // counts (200/100) because history before the compaction marker is
        // gone. replaceTokenUsage must fold the old 1000/500 into baseline_*
        // so the effective total never regresses.
        stub.enqueue(TranscriptExtractResult(tokensByModel: [
            "claude-sonnet-4-5": TranscriptTokens(inputTokens: 200, outputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"),
            "tool_input": .object(["file_path": .string("/tmp/x")]),
            "transcript_path": .string(transcriptPath),
        ]))

        let raw = try engine.store.getTokensBySession(sessionId: sessionId).first
        // getTokensBySession already folds baseline into the returned
        // current-token fields (see PodiumStore doc comment), so the
        // effective total should be baseline(1000) + new(200) = 1200, never
        // just 200.
        XCTAssertEqual(raw?.inputTokens, 1200, "effective input tokens must never regress across a compaction")
        XCTAssertEqual(raw?.outputTokens, 600, "effective output tokens must never regress across a compaction")
    }

    func testCompactionMarkerCreatesCompactionAgentAndEvent() throws {
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-compact-marker"
        let transcriptPath = "/fake/transcript2.jsonl"

        stub.enqueue(TranscriptExtractResult(
            compactionEntries: [TranscriptCompactionEntry(uuid: "compact-uuid-1", timestamp: "2024-01-01T00:00:00.000Z")]
        ), for: transcriptPath)
        let broadcasts = engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId, transcriptPath: transcriptPath))
        XCTAssertTrue(broadcasts.contains { $0.type == "agent_created" && $0.data["subagent_type"]?.asString == "compaction" })

        let compactAgent = try engine.store.getAgent(id: "\(sessionId)-compact-compact-uuid-1")
        XCTAssertNotNil(compactAgent)
        XCTAssertEqual(compactAgent?.status.knownValue, .completed)
        XCTAssertEqual(compactAgent?.startedAt, compactAgent?.endedAt, "compaction is instantaneous: started_at must equal ended_at")

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.eventType == "Compaction" })

        // Re-processing the SAME transcript state (e.g. another hook event
        // reading the same compaction marker) must NOT create a duplicate
        // compaction agent — dedup by uuid.
        stub.enqueue(TranscriptExtractResult(
            compactionEntries: [TranscriptCompactionEntry(uuid: "compact-uuid-1", timestamp: "2024-01-01T00:00:00.000Z")]
        ), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"),
            "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))
        let agentsAfter = try engine.store.listAgentsBySession(sessionId: sessionId)
        XCTAssertEqual(agentsAfter.filter { $0.subagentType == "compaction" }.count, 1, "compaction agents must be deduplicated by uuid")
    }

    // MARK: - Cost spike + API errors from transcript

    func testCostSpikeBroadcastFiresOnceWhenCrossingDollarThreshold() throws {
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-cost-spike"
        let transcriptPath = "/fake/cost.jsonl"

        // claude-opus-4-5 pricing (seeded default): $5/mtok input. 1M tokens
        // of input alone = $5.00, comfortably over the $1 threshold.
        stub.enqueue(TranscriptExtractResult(tokensByModel: [
            "claude-opus-4-5-20250101": TranscriptTokens(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]), for: transcriptPath)
        let broadcasts = engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId, model: "claude-opus-4-5-20250101", transcriptPath: transcriptPath))
        XCTAssertTrue(broadcasts.contains { $0.type == "cost_spike" })

        // A second event that would ALSO cross the threshold must not
        // re-fire — alert is per-session, one-shot until SessionEnd clears it.
        stub.enqueue(TranscriptExtractResult(tokensByModel: [
            "claude-opus-4-5-20250101": TranscriptTokens(inputTokens: 2_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
        ]), for: transcriptPath)
        let broadcasts2 = engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"),
            "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))
        XCTAssertFalse(broadcasts2.contains { $0.type == "cost_spike" }, "cost_spike must only fire once per session")
    }

    func testAPIErrorFromTranscriptFlipsSessionAndAgentToError() throws {
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-api-error"
        let transcriptPath = "/fake/apierror.jsonl"

        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        stub.enqueue(TranscriptExtractResult(errors: [
            TranscriptAPIError(type: "rate_limit_error", message: "Rate limit exceeded", timestamp: nil, raw: .object(["type": .string("rate_limit_error")])),
        ]), for: transcriptPath)
        let broadcasts = engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"),
            "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))
        XCTAssertTrue(broadcasts.contains { $0.type == "session_updated" })

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.status.knownValue, .error)
        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.status.knownValue, .error)

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.eventType == "APIError" && $0.summary == "rate_limit_error: Rate limit exceeded" })
    }

    func testDuplicateAPIErrorIsNotRecordedTwice() throws {
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-api-error-dedup"
        let transcriptPath = "/fake/apierror2.jsonl"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let error = TranscriptAPIError(type: "overloaded_error", message: "Servers overloaded", timestamp: nil, raw: .object([:]))
        stub.enqueue(TranscriptExtractResult(errors: [error]), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"), "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))

        // Same error re-read from the transcript on a later event (e.g. the
        // watchdog would do this) — must not duplicate the event row.
        stub.enqueue(TranscriptExtractResult(errors: [error]), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Write"), "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertEqual(events.filter { $0.eventType == "APIError" }.count, 1)
    }

    func testPreExistingErrorDoesNotOverwriteAlreadyRecoveredSession() throws {
        // hooks.js lines 907–911: only flip to error when a NEW error was
        // recorded this call — re-reading the same (already-recorded) error
        // from the transcript must not yank a user-recovered session back
        // into error state.
        let stub = StubTranscriptTokenSource()
        let engine = try makeEngine(transcriptSource: stub)
        let sessionId = "sess-recovered"
        let transcriptPath = "/fake/recovered.jsonl"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let error = TranscriptAPIError(type: "api_error", message: "transient", timestamp: nil, raw: .object([:]))
        stub.enqueue(TranscriptExtractResult(errors: [error]), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Read"), "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))
        XCTAssertEqual(try engine.store.getSession(id: sessionId)?.status.knownValue, .error)

        // User retries — UserPromptSubmit reactivates to active.
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "try again"))
        XCTAssertEqual(try engine.store.getSession(id: sessionId)?.status.knownValue, .active)

        // The SAME stale error is still sitting in the transcript and gets
        // re-read — must NOT flip the recovered session back to error.
        stub.enqueue(TranscriptExtractResult(errors: [error]), for: transcriptPath)
        engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId), "tool_name": .string("Write"), "tool_input": .object([:]), "transcript_path": .string(transcriptPath),
        ]))
        XCTAssertEqual(try engine.store.getSession(id: sessionId)?.status.knownValue, .active, "a pre-existing (already-recorded) transcript error must not re-flip a recovered session to error")
    }

    // MARK: - Garbage / malformed payloads: engine no-ops without throwing

    func testMissingSessionIdIsANoOp() throws {
        let engine = try makeEngine()
        let broadcasts = engine.process(hookType: "PreToolUse", data: HookFixture.payload(["tool_name": .string("Bash")]))
        XCTAssertTrue(broadcasts.isEmpty)
    }

    func testEmptySessionIdIsANoOp() throws {
        let engine = try makeEngine()
        let broadcasts = engine.process(hookType: "SessionStart", data: HookFixture.payload(["session_id": .string("")]))
        XCTAssertTrue(broadcasts.isEmpty)
    }

    func testNullDataIsANoOp() throws {
        let engine = try makeEngine()
        let broadcasts = engine.process(hookType: "PreToolUse", data: .null)
        XCTAssertTrue(broadcasts.isEmpty)
    }

    func testToolInputAsWrongTypeDoesNotCrash() throws {
        // Garbage payload: tool_input is a string instead of an object (a
        // malformed/adversarial client). The `Agent` branch reads fields off
        // `tool_input` via JSONValue subscripting, which returns nil for any
        // non-.object case rather than throwing.
        let engine = try makeEngine()
        let sessionId = "sess-garbage-1"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let broadcasts = engine.process(hookType: "PreToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId),
            "tool_name": .string("Agent"),
            "tool_input": .string("not an object"),
        ]))
        XCTAssertFalse(broadcasts.isEmpty, "must still process the event, falling back to defaults for the malformed tool_input")

        let subagent = try engine.store.listAgentsBySession(sessionId: sessionId).first { $0.type.knownValue == .subagent }
        XCTAssertNotNil(subagent)
        XCTAssertEqual(subagent?.name, "Subagent", "falls back to the generic name when description/subagent_type/prompt are all unavailable")
    }

    func testToolResponseAsNumberDoesNotCrashBashParsing() throws {
        // tool_response is normally a string; a garbage/adversarial payload
        // could send a number instead. Bash-output parsing must just skip
        // (no summary enrichment), never throw.
        let engine = try makeEngine()
        let sessionId = "sess-garbage-2"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let broadcasts = engine.process(hookType: "PostToolUse", data: HookFixture.payload([
            "session_id": .string(sessionId),
            "tool_name": .string("Bash"),
            "tool_response": .number(42),
        ]))
        XCTAssertTrue(broadcasts.contains { $0.type == "new_event" })
    }

    func testUnknownHookTypeRecordsGenericEventWithoutThrowing() throws {
        let engine = try makeEngine()
        let sessionId = "sess-unknown-hook"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        let broadcasts = engine.process(hookType: "SomeFutureHookType", data: HookFixture.payload(["session_id": .string(sessionId)]))
        XCTAssertTrue(broadcasts.contains { $0.type == "new_event" })

        let events = try engine.store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.eventType == "SomeFutureHookType" && $0.summary == "Event: SomeFutureHookType" })
    }

    func testDuplicateToolUseIdOnAgentSpawnCreatesIndependentSubagents() throws {
        // Duplicate tool_use_id across two Agent spawns (e.g. a client bug,
        // or two genuinely-concurrent subagent launches that happen to reuse
        // an id) must not corrupt state — each PreToolUse still creates its
        // own subagent row (agent id is always a fresh UUID, independent of
        // tool_use_id, which is only stored as metadata for later JSONL
        // linkage — see hooks.js line 367).
        let engine = try makeEngine()
        let sessionId = "sess-dup-tool-use-id"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))

        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "dup-id",
            toolInput: ["description": .string("First spawn")]
        ))
        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(
            sessionId: sessionId, toolName: "Agent", toolUseId: "dup-id",
            toolInput: ["description": .string("Second spawn")]
        ))

        let subagents = try engine.store.listAgentsBySession(sessionId: sessionId).filter { $0.type.knownValue == .subagent }
        XCTAssertEqual(subagents.count, 2, "duplicate tool_use_id must not prevent or merge independent subagent rows")
        XCTAssertEqual(Set(subagents.map(\.id)).count, 2, "each subagent must have its own unique id")
    }

    // MARK: - Broadcast ordering

    func testBroadcastOrderForSimpleToolEventMatchesNodeOrdering() throws {
        let engine = try makeEngine()
        let sessionId = "sess-order"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        engine.process(hookType: "UserPromptSubmit", data: HookFixture.userPromptSubmit(sessionId: sessionId, message: "go"))

        // PreToolUse for a non-Agent tool while main is working: hooks.js
        // clears awaiting (no-op here, already clear) then broadcasts
        // agent_updated for main going to "working" (with current_tool set),
        // then the trailing new_event. No agent_created since it's not the
        // Agent tool.
        let broadcasts = engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(sessionId: sessionId, toolName: "Read", toolInput: ["file_path": .string("/tmp/a")]))
        XCTAssertEqual(broadcasts.map(\.type), ["agent_updated", "new_event"])
    }

    // MARK: - Reactivation heuristics

    func testPreToolUseReactivatesAnAbandonedSession() throws {
        let engine = try makeEngine()
        let sessionId = "sess-reactivate-abandoned"
        engine.process(hookType: "SessionStart", data: HookFixture.sessionStart(sessionId: sessionId))
        try engine.store.updateSession(id: sessionId, status: .abandoned, endedAt: PodiumDate.now())
        try engine.store.updateAgent(id: engine.mainAgentId(sessionId), status: .completed, endedAt: PodiumDate.now())

        engine.process(hookType: "PreToolUse", data: HookFixture.preToolUse(sessionId: sessionId, toolName: "Bash", toolInput: ["command": .string("echo hi")]))

        let session = try engine.store.getSession(id: sessionId)
        XCTAssertEqual(session?.status.knownValue, .active)
        let mainAgent = try engine.store.getAgent(id: engine.mainAgentId(sessionId))
        XCTAssertEqual(mainAgent?.status.knownValue, .working)
    }
}
