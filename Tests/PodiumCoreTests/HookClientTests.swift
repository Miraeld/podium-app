import XCTest
@testable import PodiumCore

final class HookClientTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-hook-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFixture(_ json: String, name: String = ".agent-dashboard.json") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try json.data(using: .utf8)?.write(to: url)
        return url
    }

    // MARK: - Env override

    func testEnvOverrideWinsOutright() throws {
        let ports = HookPortDiscovery.resolvePorts(
            environment: ["CLAUDE_DASHBOARD_PORT": "9999"],
            infoPath: tempDir.appendingPathComponent("does-not-exist.json")
        )
        XCTAssertEqual(ports, [9999])
    }

    func testEnvOverrideIgnoredWhenNotPositiveInteger() throws {
        let fixture = try writeFixture(#"{"port": 4820, "pid": null}"#)
        let ports = HookPortDiscovery.resolvePorts(
            environment: ["CLAUDE_DASHBOARD_PORT": "not-a-number"],
            infoPath: fixture
        )
        XCTAssertEqual(ports, [4820])
    }

    // MARK: - Missing file fallback

    func testFallbackWhenInfoFileMissing() throws {
        let ports = HookPortDiscovery.resolvePorts(
            environment: [:],
            infoPath: tempDir.appendingPathComponent("nope.json")
        )
        XCTAssertEqual(ports, HookPortDiscovery.fallbackPorts)
    }

    func testFallbackWhenInfoFileUnparsable() throws {
        let fixture = try writeFixture("not valid json{{{")
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, HookPortDiscovery.fallbackPorts)
    }

    // MARK: - Legacy single-server format

    func testLegacySingleFormatNoPidAssumedAlive() throws {
        let fixture = try writeFixture(#"{"port": 4821}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, [4821])
    }

    func testLegacySingleFormatWithLivePid() throws {
        // Our own process is definitely alive.
        let myPid = ProcessInfo.processInfo.processIdentifier
        let fixture = try writeFixture(#"{"port": 4822, "pid": \#(myPid)}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, [4822])
    }

    func testLegacySingleFormatWithDeadPidFallsBack() throws {
        let deadPid = findUnusedPid()
        let fixture = try writeFixture(#"{"port": 4823, "pid": \#(deadPid)}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, HookPortDiscovery.fallbackPorts)
    }

    // MARK: - Multi-server format

    func testMultiServerFormatFiltersDeadPidsAndKeepsLive() throws {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let deadPid = findUnusedPid()
        let fixture = try writeFixture("""
        {"servers": [
          {"port": 4820, "pid": \(deadPid)},
          {"port": 4830, "pid": \(myPid)},
          {"port": 4840}
        ]}
        """)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, [4830, 4840])
    }

    func testMultiServerFormatAllDeadFallsBackToConventional() throws {
        let deadPid = findUnusedPid()
        let fixture = try writeFixture(#"{"servers": [{"port": 4820, "pid": \#(deadPid)}]}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, HookPortDiscovery.fallbackPorts)
    }

    func testMultiServerFormatDeduplicatesPorts() throws {
        let fixture = try writeFixture(#"{"servers": [{"port": 4820}, {"port": 4820}, {"port": 4821}]}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, [4820, 4821])
    }

    func testMultiServerFormatIgnoresEntriesWithoutIntegerPort() throws {
        let fixture = try writeFixture(#"{"servers": [{"pid": 123}, {"port": "not-a-number"}, {"port": 4825}]}"#)
        let ports = HookPortDiscovery.resolvePorts(environment: [:], infoPath: fixture)
        XCTAssertEqual(ports, [4825])
    }

    // MARK: - isProcessAlive

    func testIsProcessAliveTrueForSelf() {
        XCTAssertTrue(HookPortDiscovery.isProcessAlive(pid: Int(ProcessInfo.processInfo.processIdentifier)))
    }

    func testIsProcessAliveFalseForNonPositivePidTreatedAsAliveByCaller() {
        // pid <= 0 has no kill(2) meaning; resolvePorts treats "no pid" as
        // alive at a higher layer rather than calling isProcessAlive at all,
        // but isProcessAlive itself should not crash for edge values.
        XCTAssertTrue(HookPortDiscovery.isProcessAlive(pid: 0))
    }

    // MARK: - parseServerEntries

    func testParseServerEntriesMultiFormat() throws {
        let data = try XCTUnwrap(#"{"servers":[{"port":1,"pid":2},{"port":3}]}"#.data(using: .utf8))
        let entries = HookPortDiscovery.parseServerEntries(from: data)
        XCTAssertEqual(entries, [
            DashboardServerEntry(port: 1, pid: 2),
            DashboardServerEntry(port: 3, pid: nil),
        ])
    }

    func testParseServerEntriesLegacyFormat() throws {
        let data = try XCTUnwrap(#"{"port":4820,"pid":99}"#.data(using: .utf8))
        let entries = HookPortDiscovery.parseServerEntries(from: data)
        XCTAssertEqual(entries, [DashboardServerEntry(port: 4820, pid: 99)])
    }

    func testParseServerEntriesEmptyOnGarbage() throws {
        let data = try XCTUnwrap(#"{"foo": "bar"}"#.data(using: .utf8))
        XCTAssertEqual(HookPortDiscovery.parseServerEntries(from: data), [])
    }

    // MARK: - HookEventBuilder

    func testBuildReturnsNilForMissingHookEventName() {
        XCTAssertNil(HookEventBuilder.build(from: ["session_id": "abc"]))
    }

    func testBuildReturnsNilForMissingSessionId() {
        XCTAssertNil(HookEventBuilder.build(from: ["hook_event_name": "PreToolUse"]))
    }

    func testBuildReturnsNilForEmptySessionId() {
        XCTAssertNil(HookEventBuilder.build(from: ["hook_event_name": "PreToolUse", "session_id": ""]))
    }

    func testBuildReturnsNilForUnhandledEvent() {
        XCTAssertNil(HookEventBuilder.build(from: ["hook_event_name": "Notification", "session_id": "abc"]))
    }

    func testBuildReturnsHookTypeAndRawPayloadForHandledEvent() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "abc-123",
            "tool_name": "Bash",
            "tool_input": ["command": "ls -la"],
        ]
        let result = try XCTUnwrap(HookEventBuilder.build(from: payload))
        XCTAssertEqual(result.hookType, "PreToolUse")
        // data is the raw payload verbatim (not a synthesized event).
        XCTAssertEqual(result.data["session_id"] as? String, "abc-123")
        XCTAssertEqual(result.data["tool_name"] as? String, "Bash")
    }

    func testBuildHandlesAllEightRegisteredEvents() {
        for event in HookInstaller.hookEvents {
            let result = HookEventBuilder.build(from: ["hook_event_name": event, "session_id": "s1"])
            XCTAssertNotNil(result, "expected \(event) to be handled")
            XCTAssertEqual(result?.hookType, event)
        }
    }

    // MARK: - Payload building

    func testBuildPayloadProducesExpectedEnvelope() throws {
        let data = try XCTUnwrap(HookClient.buildPayload(hookType: "PreToolUse", data: ["session_id": "s1", "tool_name": "Bash"]))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["hook_type"] as? String, "PreToolUse")
        let inner = try XCTUnwrap(obj["data"] as? [String: Any])
        XCTAssertEqual(inner["session_id"] as? String, "s1")
        XCTAssertEqual(inner["tool_name"] as? String, "Bash")
    }

    // MARK: - postToAllServers with no live ports

    func testPostToAllServersCompletesImmediatelyWithNoPorts() {
        let expectation = expectation(description: "completion called")
        HookClient.postToAllServers(hookType: "SessionStart", data: ["session_id": "s1"], ports: []) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testPostToAllServersCompletesWhenNoServerListening() {
        // Nothing is listening on this port — the request should fail fast
        // and completion should still fire (never throws/hangs).
        let expectation = expectation(description: "completion called")
        HookClient.postToAllServers(hookType: "SessionStart", data: ["session_id": "s1"], ports: [65533]) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Helpers

    /// Finds a pid that (almost certainly) does not correspond to a live
    /// process, for exercising the "dead pid" branch deterministically.
    private func findUnusedPid() -> Int {
        // PID 2^31-1 is out of range for real processes on both Linux and
        // macOS and reliably yields ESRCH from kill(2).
        Int(Int32.max) - 1
    }
}
