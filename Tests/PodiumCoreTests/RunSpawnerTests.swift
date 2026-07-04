import XCTest
@testable import PodiumCore

/// Records every broadcast for assertions — a fake `Broadcasting` conformer,
/// since `PodiumServer.Broadcaster` isn't visible from `PodiumCoreTests`.
private actor RecordingBroadcaster: Broadcasting {
    private(set) var events: [(type: String, data: JSONValue)] = []

    func broadcast(type: String, data: JSONValue) async {
        events.append((type, data))
    }

    func events(ofType type: String) -> [JSONValue] {
        events.filter { $0.type == type }.map(\.data)
    }
}

/// HTTP-level coverage of `RunSpawner` — the P4.1 process supervisor. Uses
/// tiny POSIX shell fixture scripts as the fake "claude" binary (a shell
/// script ignores unrecognized argv entirely, unlike a real binary with
/// strict flag parsing, so it tolerates the full `buildArgv` output without
/// any special-casing). Never spawns the real `claude` CLI.
final class RunSpawnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-run-spawner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes an executable shell script and returns its path. The script
    /// body may reference `$@`/`$1` etc, but a POSIX shell never validates
    /// unknown flags the way a real CLI's argument parser would, so
    /// `buildArgv`'s full flag set (`--output-format`, `--permission-mode`,
    /// …) is always safely ignorable.
    private func writeFixtureScript(_ body: String) throws -> String {
        let path = tempDir.appendingPathComponent("fake-claude-\(UUID().uuidString).sh").path
        let script = "#!/bin/sh\n" + body
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeStore() throws -> PodiumStore {
        try PodiumStore(path: tempDir.appendingPathComponent("dashboard-\(UUID().uuidString).db").path)
    }

    private func poll(timeout: TimeInterval = 5, interval: UInt64 = 20_000_000, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    // MARK: - Headless mode

    func testHeadlessRunParsesEnvelopesAndCompletesSuccessfully() async throws {
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"abcdef1234"}'
        echo '{"type":"result","subtype":"success"}'
        exit 0
        """)
        let broadcaster = RecordingBroadcaster()
        let store = try makeStore()
        let spawner = RunSpawner(store: store, broadcaster: broadcaster, claudeBinary: script)

        let handle = try await spawner.spawnRun(
            prompt: "hello", mode: .headless, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        XCTAssertEqual(handle.status.rawValue, "spawning")

        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.status.rawValue == "completed" }

        let final = await spawner.getRun(id: handle.id, includeEnvelopes: true)
        XCTAssertEqual(final?.status.rawValue, "completed")
        XCTAssertEqual(final?.exitCode, 0)
        XCTAssertEqual(final?.sessionId, "abcdef1234")
        XCTAssertEqual(final?.envelopeCount, 2)
        XCTAssertEqual(final?.envelopes?.count, 2)

        // Persisted to dashboard_runs.
        let persisted = try store.getDashboardRun(id: handle.id)
        XCTAssertEqual(persisted?.status.rawValue, "completed")
        XCTAssertEqual(persisted?.sessionId, "abcdef1234")
        XCTAssertEqual(persisted?.exitCode, 0)

        // Broadcasts fired in order: spawning, running, then completed.
        let statuses = await broadcaster.events(ofType: "run_status").compactMap { $0.objectValue?["status"]?.stringValue }
        XCTAssertEqual(statuses, ["spawning", "running", "completed"])
        let streamed = await broadcaster.events(ofType: "run_stream")
        XCTAssertEqual(streamed.count, 2)
    }

    func testHeadlessRunSurfacesNonZeroExitAsError() async throws {
        let script = try writeFixtureScript("""
        echo '{"type":"result","subtype":"error_during_execution"}'
        exit 1
        """)
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script)
        let handle = try await spawner.spawnRun(
            prompt: "hello", mode: .headless, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.status.rawValue == "error" }
        let final = await spawner.getRun(id: handle.id, includeEnvelopes: false)
        XCTAssertEqual(final?.status.rawValue, "error")
        XCTAssertEqual(final?.exitCode, 1)
    }

    // MARK: - Conversation mode

    func testConversationModeEchoesFollowUpInputAndSessionIdIsCaptured() async throws {
        // A plain `cat`-style script: prints one init envelope up front,
        // then echoes every stdin line straight back to stdout.
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"conv-session-id"}'
        while IFS= read -r line; do
          echo "$line"
        done
        """)
        let store = try makeStore()
        let spawner = RunSpawner(store: store, broadcaster: RecordingBroadcaster(), claudeBinary: script)

        let handle = try await spawner.spawnRun(
            prompt: "first turn", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )

        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.sessionId == "conv-session-id" }
        let afterInit = await spawner.getRun(id: handle.id, includeEnvelopes: false)
        XCTAssertEqual(afterInit?.status.rawValue, "running")

        // The echoed initial prompt envelope should also have arrived by now.
        await poll { ((await spawner.getRun(id: handle.id, includeEnvelopes: false)?.envelopeCount) ?? 0) >= 2 }

        let messageId = try await spawner.sendInput(id: handle.id, text: "follow up")
        XCTAssertFalse(messageId.isEmpty)

        await poll { ((await spawner.getRun(id: handle.id, includeEnvelopes: false)?.envelopeCount) ?? 0) >= 3 }
        let withFollowUp = await spawner.getRun(id: handle.id, includeEnvelopes: true)
        XCTAssertGreaterThanOrEqual(withFollowUp?.envelopeCount ?? 0, 3)
        let lastEnvelope = withFollowUp?.envelopes?.last?.raw
        XCTAssertEqual(lastEnvelope?.objectValue?["message"]?.objectValue?["content"]?.stringValue, "follow up")

        let killed = await spawner.killRun(id: handle.id)
        XCTAssertTrue(killed)
        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.status.rawValue == "killed" }
    }

    /// `sendInput` broadcasts `run_input_ack` (run-spawner.js's `sendInput`,
    /// which fires `broadcast("run_input_ack", { id, messageId, at })` right
    /// after the stdin write) — distinct from the `run_status`/`run_stream`
    /// coverage above.
    func testSendInputBroadcastsRunInputAckWithMatchingMessageId() async throws {
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"ack-session-id"}'
        cat > /dev/null
        """)
        let broadcaster = RecordingBroadcaster()
        let spawner = RunSpawner(store: nil, broadcaster: broadcaster, claudeBinary: script)
        let handle = try await spawner.spawnRun(
            prompt: "first turn", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.sessionId == "ack-session-id" }

        let messageId = try await spawner.sendInput(id: handle.id, text: "follow up")

        let acks = await broadcaster.events(ofType: "run_input_ack")
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks[0].objectValue?["id"]?.stringValue, handle.id)
        XCTAssertEqual(acks[0].objectValue?["messageId"]?.stringValue, messageId)
        XCTAssertNotNil(acks[0].objectValue?["at"])

        _ = await spawner.killRun(id: handle.id)
    }

    func testSendInputToUnknownRunThrowsNotFound() async {
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster())
        do {
            _ = try await spawner.sendInput(id: "does-not-exist", text: "hi")
            XCTFail("expected notFound")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "ENOTFOUND")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSendInputInHeadlessModeThrowsWrongMode() async throws {
        let script = try writeFixtureScript("exit 0\n")
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script)
        let handle = try await spawner.spawnRun(
            prompt: "hi", mode: .headless, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        do {
            _ = try await spawner.sendInput(id: handle.id, text: "nope")
            XCTFail("expected wrongMode")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "EWRONGMODE")
        }
    }

    // MARK: - Validation

    func testSpawnRunRejectsEmptyPromptOutsideResume() async {
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: "/bin/true")
        do {
            _ = try await spawner.spawnRun(prompt: "   ", mode: .conversation, cwd: NSTemporaryDirectory(), model: nil, permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil)
            XCTFail("expected badPrompt")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "EBADPROMPT")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSpawnRunAllowsEmptyPromptWhenResumingConversation() async throws {
        let script = try writeFixtureScript("exit 0\n")
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script)
        let handle = try await spawner.spawnRun(
            prompt: "  ", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: "abcdef1234", effort: nil
        )
        XCTAssertEqual(handle.resumeSessionId, "abcdef1234")
        XCTAssertEqual(handle.sessionId, "abcdef1234") // optimistic assignment
    }

    func testSpawnRunRejectsInvalidEffortLevel() async {
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: "/bin/true")
        do {
            _ = try await spawner.spawnRun(prompt: "hi", mode: .headless, cwd: NSTemporaryDirectory(), model: nil, permissionMode: "acceptEdits", resumeSessionId: nil, effort: "ultra")
            XCTFail("expected badEffort")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "EBADEFFORT")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSpawnRunRejectsResumeSessionIdInHeadlessMode() async {
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: "/bin/true")
        do {
            _ = try await spawner.spawnRun(prompt: "hi", mode: .headless, cwd: NSTemporaryDirectory(), model: nil, permissionMode: "acceptEdits", resumeSessionId: "abcdef1234", effort: nil)
            XCTFail("expected badMode")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "EBADMODE")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Concurrency cap

    func testConcurrencyCapRejectsSpawnOverLimit() async throws {
        setenv("RUN_MAX_CONCURRENT", "1", 1)
        defer { unsetenv("RUN_MAX_CONCURRENT") }

        // A script that blocks reading stdin forever (conversation mode
        // leaves stdin open), keeping the first run "running" for the
        // duration of the test.
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"blocker-session"}'
        cat > /dev/null
        """)
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script)
        let first = try await spawner.spawnRun(
            prompt: "block", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        await poll { await spawner.getRun(id: first.id, includeEnvelopes: false)?.status.rawValue == "running" }

        do {
            _ = try await spawner.spawnRun(prompt: "second", mode: .headless, cwd: tempDir.path, model: nil, permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil)
            XCTFail("expected concurrency error")
        } catch let error as RunSpawnerError {
            XCTAssertEqual(error.code, "ECONCURRENCY")
            if case .concurrency(let limit, let running) = error {
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(running.map(\.id), [first.id])
            } else {
                XCTFail("expected .concurrency case")
            }
        }

        _ = await spawner.killRun(id: first.id)
    }

    // MARK: - Replay log bound

    func testEnvelopeReplayLogIsBoundedTo500() async throws {
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"bound-session"}'
        while IFS= read -r line; do
          echo "$line"
        done
        """)
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script)
        let handle = try await spawner.spawnRun(
            prompt: "seed", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        // init envelope (1) + echoed seed prompt (1) = 2 so far; send enough
        // follow-ups to push the total well past the 500 cap.
        for i in 0..<520 {
            _ = try await spawner.sendInput(id: handle.id, text: "line-\(i)")
        }
        await poll(timeout: 15) { ((await spawner.getRun(id: handle.id, includeEnvelopes: false)?.envelopeCount) ?? 0) >= 522 }

        let final = await spawner.getRun(id: handle.id, includeEnvelopes: true)
        XCTAssertEqual(final?.envelopeCount, 522)
        XCTAssertEqual(final?.envelopes?.count, 500)

        _ = await spawner.killRun(id: handle.id)
    }

    // MARK: - Reap after exit

    /// run-spawner.js keeps a finished handle around for `REAP_AFTER_MS`
    /// (5 min in production) so late clients can still read its final
    /// status/envelopes, then drops it. `reapDelayNanoseconds` is injectable
    /// so this test doesn't need to wait 5 real minutes to exercise it.
    func testFinishedHandleIsReapedAfterTheConfiguredDelay() async throws {
        let script = try writeFixtureScript("exit 0\n")
        // 2s (not 50ms): on slow CI runners the completion-poll itself can
        // outlast a tiny reap delay, making the "still present" check flake.
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script, reapDelayNanoseconds: 2_000_000_000)
        let handle = try await spawner.spawnRun(
            prompt: "hi", mode: .headless, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.status.rawValue == "completed" }

        // Still present immediately after completion — reap hasn't fired yet.
        let stillPresent = await spawner.getRun(id: handle.id, includeEnvelopes: false)
        XCTAssertNotNil(stillPresent)

        await poll(timeout: 10) { await spawner.getRun(id: handle.id, includeEnvelopes: false) == nil }
        let afterReap = await spawner.getRun(id: handle.id, includeEnvelopes: false)
        XCTAssertNil(afterReap)
    }

    /// Killing a handle also schedules a reap (run-spawner.js's `killRun`
    /// calls `scheduleReap` too, not just the natural-exit path).
    func testKilledHandleIsReapedAfterTheConfiguredDelay() async throws {
        let script = try writeFixtureScript("""
        echo '{"type":"system","subtype":"init","session_id":"reap-kill-session"}'
        cat > /dev/null
        """)
        let spawner = RunSpawner(store: nil, broadcaster: RecordingBroadcaster(), claudeBinary: script, reapDelayNanoseconds: 50_000_000 /* 50ms */)
        let handle = try await spawner.spawnRun(
            prompt: "hi", mode: .conversation, cwd: tempDir.path, model: nil,
            permissionMode: "acceptEdits", resumeSessionId: nil, effort: nil
        )
        await poll { await spawner.getRun(id: handle.id, includeEnvelopes: false)?.status.rawValue == "running" }
        _ = await spawner.killRun(id: handle.id)

        await poll(timeout: 2) { await spawner.getRun(id: handle.id, includeEnvelopes: false) == nil }
        let afterReap = await spawner.getRun(id: handle.id, includeEnvelopes: false)
        XCTAssertNil(afterReap)
    }
}
