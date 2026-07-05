import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P3.4 workflows router (`GET /api/workflows`,
/// `GET /api/workflows/session/:id`): boots a real `PodiumServerApp` against
/// a temp DB and asserts tree nesting, swimlane ordering, and duration math
/// (including the negative-duration guard for a session containing a
/// compaction agent). Follows the same pattern as `ReadRoutersTests` (P2.2).
final class WorkflowsRouterTests: XCTestCase {
    // Dedicated per-instance session rather than `URLSession.shared`: on
    // Linux (FoundationNetworking/libcurl) the shared session is a
    // process-wide singleton whose connection pool/multi-handle persists
    // across every suite in the same `swift test` binary — suspected
    // culprit for the "server did not become healthy" CI failures that
    // start at DiagnosticsRouterTests (alphabetically the first suite to
    // use URLSession at all in the whole test process) and affect every
    // subsequent server-booting suite. An ephemeral, per-instance session
    // avoids depending on `.shared`'s cross-suite state entirely.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()
    private var tempDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-workflows-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() async throws {
        serverTask?.cancel()
        _ = await serverTask?.result
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func bootServer() async throws {
        let candidatePort = Int.random(in: 21000..<39000)
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)

        app = PodiumServerApp(
            store: store,
            port: candidatePort,
            webDistDirectory: dist.path,
            mounts: [WorkflowsRouterMount.self]
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
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        let (data, response) = try await session.data(from: url)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - GET /session/:id: 3-level tree + swimlane ordering + tool timeline

    /// Seeds main -> subagent -> sub-subagent (3 levels), with `started_at`
    /// set so that `listAgentsBySession`'s `ORDER BY started_at DESC` (same
    /// order Node's `stmts.listAgentsBySession` uses) puts the deepest/most
    /// recently started agent first in both `swimLanes` and the flat
    /// ordering `buildAgentTree` reads from.
    func testSessionDrillInBuildsThreeLevelTreeAndOrdersSwimLanesByStartedAtDesc() async throws {
        try store.insertSession(id: "s1", name: "Tree session", status: .completed, cwd: nil, model: nil, metadata: nil)
        try store.updateSession(id: "s1", endedAt: "2024-01-01T01:00:00.000Z")
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-01T00:00:00.000Z' WHERE id = 's1';")

        try store.insertAgent(id: "main", sessionId: "s1", name: "Main", type: .main, subagentType: nil, status: .completed, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertAgent(id: "sub-a", sessionId: "s1", name: "SubA", type: .subagent, subagentType: "worker", status: .completed, task: nil, parentAgentId: "main", metadata: nil)
        try store.insertAgent(id: "sub-b", sessionId: "s1", name: "SubB", type: .subagent, subagentType: "worker", status: .completed, task: nil, parentAgentId: "sub-a", metadata: nil)

        // Distinct started_at values, deepest agent started last (latest
        // timestamp) so DESC order is deterministic: sub-b, sub-a, main.
        try store.db.exec("UPDATE agents SET started_at = '2024-01-01T00:00:05.000Z' WHERE id = 'main';")
        try store.db.exec("UPDATE agents SET started_at = '2024-01-01T00:10:00.000Z' WHERE id = 'sub-a';")
        try store.db.exec("UPDATE agents SET started_at = '2024-01-01T00:20:00.000Z' WHERE id = 'sub-b';")

        try store.insertEvent(sessionId: "s1", agentId: "sub-b", eventType: "PostToolUse", toolName: "Bash", summary: "ran a command", data: nil)
        try store.insertEvent(sessionId: "s1", agentId: "main", eventType: "SessionStart", toolName: nil, summary: nil, data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/workflows/session/s1")
        XCTAssertEqual(response.statusCode, 200)

        let detail = try PodiumJSON.decoder.decode(WorkflowDetail.self, from: data)

        // Tree nesting: main -> sub-a -> sub-b, 3 levels deep.
        XCTAssertEqual(detail.tree.count, 1)
        let mainNode = detail.tree[0]
        XCTAssertEqual(mainNode.id, "main")
        XCTAssertEqual(mainNode.children.map(\.id), ["sub-a"])
        XCTAssertEqual(mainNode.children[0].children.map(\.id), ["sub-b"])
        XCTAssertEqual(mainNode.children[0].children[0].children, [])

        // Swimlanes follow `listAgentsBySession`'s `started_at DESC` order.
        XCTAssertEqual(detail.swimLanes.map(\.id), ["sub-b", "sub-a", "main"])

        // Tool timeline only includes the event with a tool_name.
        XCTAssertEqual(detail.toolTimeline.count, 1)
        XCTAssertEqual(detail.toolTimeline[0].toolName, "Bash")
    }

    func testSessionDrillInReturns404ForUnknownSession() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/workflows/session/does-not-exist")
        XCTAssertEqual(response.statusCode, 404)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "NOT_FOUND")
    }

    // MARK: - GET /: duration math + negative-duration guard for compaction sessions

    /// Data-corruption edge case (the kind the P1.1 "compaction started_at
    /// repair" migration exists to clean up): a session whose `ended_at`
    /// predates its `started_at`. `PodiumStore.durationSec`'s
    /// `max(0, end - start)` guard (workflows.js's `durationSec`, line 15)
    /// must clamp this to zero rather than letting it drag the aggregate
    /// negative, for both `WorkflowStats.avgDurationSec` and
    /// `SessionComplexityItem.duration`.
    func testWorkflowStatsAndComplexityClampNegativeDurationForCompactionSession() async throws {
        try store.insertSession(id: "s-normal", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-01T00:00:00.000Z' WHERE id = 's-normal';")
        try store.updateSession(id: "s-normal", endedAt: "2024-01-01T00:01:40.000Z") // 100s duration

        try store.insertSession(id: "s-negative", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        // started_at AFTER ended_at — the corrupted-clock scenario.
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-01T00:30:00.000Z' WHERE id = 's-negative';")
        try store.updateSession(id: "s-negative", endedAt: "2024-01-01T00:29:00.000Z")
        try store.insertAgent(id: "compaction-1", sessionId: "s-negative", name: "Compaction", type: .subagent, subagentType: "compaction", status: .completed, task: nil, parentAgentId: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await get("/api/workflows")
        XCTAssertEqual(response.statusCode, 200)
        let summary = try PodiumJSON.decoder.decode(WorkflowSummary.self, from: data)

        // avgDurationSec averages the two sessions' clamped durations:
        // (100 + 0) / 2 = 50, never negative.
        XCTAssertEqual(summary.stats.avgDurationSec, 50)
        XCTAssertGreaterThanOrEqual(summary.stats.avgDurationSec, 0)

        let negativeItem = summary.complexity.first { $0.id == "s-negative" }
        XCTAssertNotNil(negativeItem)
        XCTAssertEqual(negativeItem?.duration, 0)
        XCTAssertGreaterThanOrEqual(negativeItem?.duration ?? -1, 0)

        let normalItem = summary.complexity.first { $0.id == "s-normal" }
        XCTAssertEqual(normalItem?.duration, 100)

        XCTAssertEqual(summary.stats.totalCompactions, 1)
    }

    func testWorkflowsStatusFilterExcludesOtherStatuses() async throws {
        try store.insertSession(id: "s-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s-completed", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await get("/api/workflows?status=active")
        XCTAssertEqual(response.statusCode, 200)
        let summary = try PodiumJSON.decoder.decode(WorkflowSummary.self, from: data)
        XCTAssertEqual(summary.stats.totalSessions, 1)
    }

    // MARK: - Bug 1 regression: top-level keys must stay literal camelCase

    /// workflows.js lines 23–35: `res.json({ stats, orchestration, toolFlow,
    /// effectiveness, patterns, modelDelegation, errorPropagation,
    /// concurrency, complexity, compaction, cooccurrence })` — an
    /// intentional camelCase exception to the rest of the snake_case API.
    /// Decodes the raw wire body with `JSONSerialization` (NOT the
    /// `WorkflowSummary` Codable type) so a regression to
    /// `PodiumJSON.encoder`'s uniform `.convertToSnakeCase` (which would
    /// silently rename these to `tool_flow`/`model_delegation`/
    /// `error_propagation`) is actually caught, rather than round-tripped
    /// through the same buggy encoder on both sides.
    func testWorkflowsSummaryTopLevelKeysAreLiteralCamelCase() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await get("/api/workflows")
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["stats", "orchestration", "toolFlow", "effectiveness", "patterns", "modelDelegation", "errorPropagation", "concurrency", "complexity", "compaction", "cooccurrence"] {
            XCTAssertNotNil(json[key], "expected literal camelCase top-level key \"\(key)\" in /api/workflows response")
        }
        // The buggy snake_case renderings must NOT be present.
        for badKey in ["tool_flow", "model_delegation", "error_propagation"] {
            XCTAssertNil(json[badKey], "wire response must not contain snake_case key \"\(badKey)\"")
        }
    }

    /// workflows.js line 81: `res.json({ session, tree, toolTimeline,
    /// swimLanes, events })`. Nested per-item fields inside `toolTimeline`/
    /// `swimLanes` (e.g. `tool_name`, `started_at`, `parent_agent_id`) ARE
    /// snake_case in Node (literal DB row field copies) and must stay that
    /// way — only the two CONTAINER keys are camelCase.
    func testWorkflowsSessionDetailTopLevelKeysAreLiteralCamelCase() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "main", sessionId: "s1", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: "main", eventType: "PostToolUse", toolName: "Bash", summary: nil, data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/workflows/session/s1")
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["session", "tree", "toolTimeline", "swimLanes", "events"] {
            XCTAssertNotNil(json[key], "expected literal camelCase top-level key \"\(key)\" in /api/workflows/session/:id response")
        }
        for badKey in ["tool_timeline", "swim_lanes"] {
            XCTAssertNil(json[badKey], "wire response must not contain snake_case key \"\(badKey)\"")
        }

        // Nested per-item fields inside toolTimeline/swimLanes stay snake_case.
        let toolTimeline = json["toolTimeline"] as! [[String: Any]]
        XCTAssertEqual(toolTimeline.count, 1)
        XCTAssertNotNil(toolTimeline[0]["tool_name"])
        XCTAssertNil(toolTimeline[0]["toolName"])

        let swimLanes = json["swimLanes"] as! [[String: Any]]
        XCTAssertEqual(swimLanes.count, 1)
        XCTAssertNotNil(swimLanes[0]["started_at"])
        XCTAssertNil(swimLanes[0]["startedAt"])
    }
}
