import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P4.4 diagnostics endpoint (`GET
/// /api/diagnostics`) and its instrumentation of `POST /api/hooks/event`
/// (`DiagnosticsRecorder.shared`, wired in `HooksRouterMount`).
///
/// `DiagnosticsRecorder.shared` is a process-wide singleton (deliberately —
/// it mirrors `ServerRuntimeInfo`'s process-lifetime scope), so every test
/// resets it in `setUp`/`tearDown` to avoid leaking state across cases in
/// this file or interfering with other suites that boot a server in the
/// same test process.
final class DiagnosticsRouterTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!

    override func setUp() async throws {
        await DiagnosticsRecorder.shared.resetForTesting()
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-diagnostics-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() async throws {
        serverTask?.cancel()
        try? FileManager.default.removeItem(at: tempDir)
        await DiagnosticsRecorder.shared.resetForTesting()
    }

    private func bootServer() async throws {
        let candidatePort = Int.random(in: 21000..<39000)
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)

        app = PodiumServerApp(
            store: store,
            port: candidatePort,
            webDistDirectory: dist.path,
            mounts: [DiagnosticsRouterMount.self, HooksRouterMount.self]
        )
        serverTask = Task { try await app.application.runService() }
        port = try await waitForHealth(startingAt: candidatePort)
    }

    private func waitForHealth(startingAt startPort: Int, timeout: TimeInterval = 5) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy(port: startPort) { return startPort }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("server did not become healthy within \(timeout)s")
        throw URLError(.timedOut)
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response as! HTTPURLResponse)
    }

    private func postHook(hookType: String, data: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)/api/hooks/event")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["hook_type": hookType, "data": data])
        let (respData, response) = try await URLSession.shared.data(for: request)
        return (respData, response as! HTTPURLResponse)
    }

    // MARK: - GET /api/diagnostics — baseline shape

    func testDiagnosticsReturnsServerInfoAndUnknownHookStatusBeforeAnyEvent() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/diagnostics")
        XCTAssertEqual(response.statusCode, 200)

        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)
        XCTAssertGreaterThanOrEqual(decoded.server.uptimeSeconds, 0)
        XCTAssertFalse(decoded.server.platform.isEmpty)
        XCTAssertGreaterThan(decoded.server.cpuCount, 0)
        XCTAssertEqual(decoded.hooks.status, "unknown")
        XCTAssertNil(decoded.hooks.lastEventAt)
        XCTAssertEqual(decoded.hooks.totalEventsProcessed, 0)
        XCTAssertTrue(decoded.log.isEmpty)
    }

    // MARK: - Hook event instrumentation

    func testSuccessfulHookEventUpdatesDiagnosticsHealthAndLog() async throws {
        try await bootServer()

        let (hookRespData, hookResponse) = try await postHook(
            hookType: "SessionStart",
            data: ["session_id": "sess-diag-1", "cwd": "/tmp/project"]
        )
        XCTAssertEqual(hookResponse.statusCode, 200)
        XCTAssertNotNil(hookRespData)

        let (data, response) = try await get("/api/diagnostics")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)

        XCTAssertEqual(decoded.hooks.status, "ok")
        XCTAssertNotNil(decoded.hooks.lastEventAt)
        XCTAssertNotNil(decoded.hooks.lastLatencySeconds)
        XCTAssertEqual(decoded.hooks.totalEventsProcessed, 1)
        XCTAssertEqual(decoded.hooks.totalEventsFailed, 0)
        XCTAssertTrue(decoded.log.contains { $0.message.contains("SessionStart") })
    }

    func testRejectedHookEventIncrementsFailureCounterNotSuccessCounter() async throws {
        try await bootServer()

        // Missing session_id inside `data` — engine no-ops, router returns 400.
        let (_, hookResponse) = try await postHook(hookType: "PostToolUse", data: ["tool_name": "Bash"])
        XCTAssertEqual(hookResponse.statusCode, 400)

        let (data, response) = try await get("/api/diagnostics")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)

        XCTAssertEqual(decoded.hooks.status, "unknown")
        XCTAssertEqual(decoded.hooks.totalEventsProcessed, 0)
        XCTAssertEqual(decoded.hooks.totalEventsFailed, 1)
        XCTAssertTrue(decoded.log.contains { $0.level == "error" })
    }

    func testLogLimitQueryParamCapsReturnedEntries() async throws {
        try await bootServer()
        for i in 0..<5 {
            _ = try await postHook(hookType: "PreToolUse", data: ["session_id": "sess-log-\(i)", "tool_name": "Bash"])
        }

        let (data, response) = try await get("/api/diagnostics?log_limit=2")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)
        XCTAssertEqual(decoded.log.count, 2)
        XCTAssertEqual(decoded.hooks.totalEventsProcessed, 5)
    }

    // MARK: - Regression: negative/zero/huge log_limit must never trap
    // (P4 hardening-gate BLOCKER 1 — `Sequence.prefix(_:)` traps fatally on
    // a negative count; `log_limit=-1` used to kill the whole process).

    func testNegativeLogLimitReturns200NotACrash() async throws {
        try await bootServer()
        _ = try await postHook(hookType: "PreToolUse", data: ["session_id": "sess-neg", "tool_name": "Bash"])

        let (data, response) = try await get("/api/diagnostics?log_limit=-1")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)
        XCTAssertTrue(decoded.log.isEmpty)
    }

    func testZeroLogLimitReturns200WithEmptyLog() async throws {
        try await bootServer()
        _ = try await postHook(hookType: "PreToolUse", data: ["session_id": "sess-zero", "tool_name": "Bash"])

        let (data, response) = try await get("/api/diagnostics?log_limit=0")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)
        XCTAssertTrue(decoded.log.isEmpty)
    }

    func testHugeLogLimitReturns200CappedAtRingBufferCapacity() async throws {
        try await bootServer()
        for i in 0..<5 {
            _ = try await postHook(hookType: "PreToolUse", data: ["session_id": "sess-huge-\(i)", "tool_name": "Bash"])
        }

        let (data, response) = try await get("/api/diagnostics?log_limit=999999999")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(DiagnosticsResponse.self, from: data)
        // Only 5 log lines exist; the huge limit is clamped, not honored
        // literally, but the important assertion is "didn't crash".
        XCTAssertLessThanOrEqual(decoded.log.count, LogRingBuffer.defaultCapacity)
    }
}
