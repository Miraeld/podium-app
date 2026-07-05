import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P2.2 read routers (Sessions/Agents/Events/
/// Stats/Analytics/Search): boots a real `PodiumServerApp` against a temp DB
/// and hits the endpoints with `URLSession`, asserting status codes,
/// envelope shapes, filter behavior, and WS broadcasts. Follows the same
/// pattern as `PodiumServerAppTests` (P2.1).
final class ReadRoutersTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-read-routers-tests-\(UUID().uuidString)", isDirectory: true)
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
            mounts: [
                SessionsRouterMount.self,
                AgentsRouterMount.self,
                EventsRouterMount.self,
                StatsRouterMount.self,
                AnalyticsRouterMount.self,
                SearchRouterMount.self,
            ]
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

    private func send(_ method: String, _ path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - Sessions: list filters incl. error-but-running-as-active

    func testSessionsListStatusActiveIncludesErrorSessionsStillRunning() async throws {
        try store.insertSession(id: "s-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s-error-running", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s-error-ended", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)
        try store.updateSession(id: "s-error-ended", endedAt: PodiumDate.now())

        try await bootServer()
        let (data, response) = try await get("/api/sessions?status=active")
        XCTAssertEqual(response.statusCode, 200)

        let decoded = try PodiumJSON.decoder.decode(SessionsResponse.self, from: data)
        let ids = Set(decoded.sessions.map(\.id))
        XCTAssertTrue(ids.contains("s-active"))
        XCTAssertTrue(ids.contains("s-error-running"))
        XCTAssertFalse(ids.contains("s-error-ended"))
        XCTAssertEqual(decoded.total, 2)
    }

    func testSessionsFacetsReturnsDistinctCwds() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: "/a", model: nil, metadata: nil)
        try store.insertSession(id: "s2", name: nil, status: .active, cwd: "/b", model: nil, metadata: nil)
        try store.insertSession(id: "s3", name: nil, status: .active, cwd: "/a", model: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await get("/api/sessions/facets")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(SessionFacets.self, from: data)
        XCTAssertEqual(decoded.cwds, ["/a", "/b"])
    }

    func testSessionDetailReturns404ForUnknownId() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/sessions/does-not-exist")
        XCTAssertEqual(response.statusCode, 404)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "NOT_FOUND")
    }

    // P3.1 landed real transcript endpoints — a session with no cwd (so no
    // `~/.claude/projects` path can be resolved) and no on-disk JSONL files
    // returns the same empty-result shape Node returns when nothing is
    // found, not a 404/501. Full JSONL-parsing coverage lives in
    // TranscriptRouterTests.swift (fixture files under a fake CLAUDE_HOME).
    func testSessionTranscriptEndpointsReturnEmptyResultsWhenNoFilesResolve() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try await bootServer()

        let (data1, response1) = try await get("/api/sessions/s1/transcript")
        XCTAssertEqual(response1.statusCode, 200)
        let body1 = try PodiumJSON.decoder.decode(TranscriptResult.self, from: data1)
        XCTAssertEqual(body1.messages, [])
        XCTAssertEqual(body1.total, 0)
        XCTAssertFalse(body1.hasMore)

        let (data2, response2) = try await get("/api/sessions/s1/transcripts")
        XCTAssertEqual(response2.statusCode, 200)
        let body2 = try PodiumJSON.decoder.decode(TranscriptListResult.self, from: data2)
        XCTAssertEqual(body2.transcripts, [])
    }

    // MARK: - Sessions: PATCH broadcasts session_updated

    func testSessionPatchBroadcastsSessionUpdated() async throws {
        try store.insertSession(id: "s1", name: "Old Name", status: .active, cwd: nil, model: nil, metadata: nil)
        try await bootServer()

        let received = expectation(description: "session_updated broadcast received")
        let connection = BroadcastConnection { text in
            if text.contains("\"session_updated\"") && text.contains("New Name") {
                received.fulfill()
            }
            return true
        }
        await app.broadcaster.add(connection)

        let body = try JSONSerialization.data(withJSONObject: ["name": "New Name", "status": "completed"])
        let (data, response) = try await send("PATCH", "/api/sessions/s1", body: body)
        XCTAssertEqual(response.statusCode, 200)

        struct PatchResponse: Decodable { let session: Session }
        let decoded = try PodiumJSON.decoder.decode(PatchResponse.self, from: data)
        XCTAssertEqual(decoded.session.name, "New Name")
        XCTAssertEqual(decoded.session.status.knownValue, .completed)

        await fulfillment(of: [received], timeout: 3)
    }

    // MARK: - Agents: PATCH broadcasts agent_updated

    func testAgentPatchBroadcastsAgentUpdated() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try await bootServer()

        let received = expectation(description: "agent_updated broadcast received")
        let connection = BroadcastConnection { text in
            if text.contains("\"agent_updated\"") && text.contains("\"completed\"") {
                received.fulfill()
            }
            return true
        }
        await app.broadcaster.add(connection)

        let body = try JSONSerialization.data(withJSONObject: ["status": "completed"])
        let (data, response) = try await send("PATCH", "/api/agents/a1", body: body)
        XCTAssertEqual(response.statusCode, 200)

        struct PatchResponse: Decodable { let agent: Agent }
        let decoded = try PodiumJSON.decoder.decode(PatchResponse.self, from: data)
        XCTAssertEqual(decoded.agent.status.knownValue, .completed)

        await fulfillment(of: [received], timeout: 3)
    }

    func testAgentPatchReturns404ForUnknownId() async throws {
        try await bootServer()
        let body = try JSONSerialization.data(withJSONObject: ["status": "completed"])
        let (_, response) = try await send("PATCH", "/api/agents/nope", body: body)
        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Events: facets shape + filters

    func testEventsFacetsShape() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: nil, data: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PreToolUse", toolName: "Read", summary: nil, data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/events/facets")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(EventFacets.self, from: data)
        XCTAssertEqual(decoded.eventTypes, ["PostToolUse", "PreToolUse"])
        XCTAssertEqual(decoded.toolNames, ["Bash", "Read"])
    }

    func testEventsFullParsesJSONDataColumn() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        let rowId = try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: nil, data: "{\"command\":\"ls\"}")

        try await bootServer()
        let (data, response) = try await get("/api/events/\(rowId)/full")
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = json["event"] as! [String: Any]
        let eventData = event["data"] as! [String: Any]
        XCTAssertEqual(eventData["command"] as? String, "ls")
    }

    func testEventsFullReturns404ForUnknownId() async throws {
        try await bootServer()
        let (_, response) = try await get("/api/events/99999/full")
        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Stats

    func testStatsIncludesEventsTodayAndWsConnections() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: nil, summary: nil, data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/stats?tz_offset=0")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(Stats.self, from: data)
        XCTAssertEqual(decoded.totalSessions, 1)
        XCTAssertEqual(decoded.totalEvents, 1)
        XCTAssertGreaterThanOrEqual(decoded.eventsToday, 1)
    }

    // MARK: - Analytics with non-UTC offset

    func testAnalyticsWithNonUTCOffsetBucketsIntoLocalDay() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: nil, data: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 100, outputTokens: 100, cacheReadTokens: 0, cacheWriteTokens: 0)

        try await bootServer()
        // 420 == PDT's getTimezoneOffset() value.
        let (data, response) = try await get("/api/analytics?tz_offset=420")
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["daily_events"])
        XCTAssertNotNil(json["total_cost"])
        let dailyEvents = json["daily_events"] as! [[String: Any]]
        XCTAssertEqual(dailyEvents.count, 1)
        let overview = json["overview"] as! [String: Any]
        XCTAssertEqual(overview["total_sessions"] as? Int, 1)
    }

    // MARK: - Search returns each entity kind

    func testSearchReturnsBothSessionAndEventHits() async throws {
        try store.insertSession(id: "s1", name: "Refactor payments", status: .active, cwd: "/tmp", model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: "payments test passed", data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/search?q=payments")
        XCTAssertEqual(response.statusCode, 200)

        let decoded = try PodiumJSON.decoder.decode(SearchResponse.self, from: data)
        XCTAssertEqual(decoded.total, 2)
        let types = Set(decoded.results.map(\.type))
        XCTAssertEqual(types, ["session", "event"])
    }

    func testSearchWithEmptyQueryReturnsEmptyResults() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/search?q=")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(SearchResponse.self, from: data)
        XCTAssertEqual(decoded.results.count, 0)
        XCTAssertEqual(decoded.total, 0)
    }

    // MARK: - Bug 3: negative `limit` means unbounded, not zero rows

    /// sessions.js line 44: `Math.min(parseInt(req.query.limit) || 50, 10000)`
    /// has no lower clamp. A negative `limit` reaches SQLite's `LIMIT ?`
    /// directly for the default "time" sort, where SQLite treats a negative
    /// LIMIT as "no limit" — Swift's router-level `min: 0` clamp used to
    /// force this to zero rows instead.
    func testSessionsListWithNegativeLimitReturnsAllRowsNotZero() async throws {
        for i in 0..<5 {
            try store.insertSession(id: "s\(i)", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        }

        try await bootServer()
        let (data, response) = try await get("/api/sessions?limit=-1")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(SessionsResponse.self, from: data)
        XCTAssertGreaterThan(decoded.sessions.count, 0)
        XCTAssertEqual(decoded.sessions.count, 5)
    }

    // MARK: - Bug 4: unknown ?status= returns [], not .waiting agents

    /// agents.js line 23: `stmts.listAgentsByStatus.all(status, limit,
    /// offset)` binds the raw literal string — a value with no matching rows
    /// (typo'd/future status) returns `[]`. Swift used to silently
    /// substitute `AgentStatus.waiting` via `?? .waiting`, wrongly returning
    /// real waiting agents for a bogus filter value.
    func testAgentsListWithUnknownStatusReturnsEmptyArrayNotWaitingAgents() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "Main", type: .main, subagentType: nil, status: .waiting, task: nil, parentAgentId: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await get("/api/agents?status=bogus")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(AgentsResponse.self, from: data)
        XCTAssertEqual(decoded.agents.count, 0)
    }

    // MARK: - Bug 5: empty string body fields preserve existing values

    /// sessions.js lines 286–290: `name || null` collapses an empty string
    /// to `null` before `stmts.updateSession.run(...)`, which then
    /// `COALESCE`s into "leave column unchanged". Swift used to pass the
    /// empty string straight through, blanking the name.
    func testSessionPatchWithEmptyNameLeavesExistingNameUnchanged() async throws {
        try store.insertSession(id: "s1", name: "Original Name", status: .active, cwd: nil, model: nil, metadata: nil)
        try await bootServer()

        let body = try JSONSerialization.data(withJSONObject: ["name": ""])
        let (data, response) = try await send("PATCH", "/api/sessions/s1", body: body)
        XCTAssertEqual(response.statusCode, 200)

        struct PatchResponse: Decodable { let session: Session }
        let decoded = try PodiumJSON.decoder.decode(PatchResponse.self, from: data)
        XCTAssertEqual(decoded.session.name, "Original Name")
    }

    /// agents.js lines 77–83: same `name || null` collapse-to-null-first
    /// pattern for the agents PATCH handler.
    func testAgentPatchWithEmptyNameLeavesExistingNameUnchanged() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertAgent(id: "a1", sessionId: "s1", name: "Original Agent Name", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)
        try await bootServer()

        let body = try JSONSerialization.data(withJSONObject: ["name": ""])
        let (data, response) = try await send("PATCH", "/api/agents/a1", body: body)
        XCTAssertEqual(response.statusCode, 200)

        struct PatchResponse: Decodable { let agent: Agent }
        let decoded = try PodiumJSON.decoder.decode(PatchResponse.self, from: data)
        XCTAssertEqual(decoded.agent.name, "Original Agent Name")
    }

    // MARK: - Bug 6: search cost uses its own startsWith-on-raw-order algorithm

    /// search.js lines 89–104: `rules.find(r => model.toLowerCase()
    /// .startsWith(r.model_pattern.replace(/%$/, "").toLowerCase()))` — a
    /// `startsWith` match walking pricing rules in their raw/unsorted order
    /// (here, `listPricing`'s `ORDER BY display_name ASC`), NOT
    /// `CostCalculator`'s longest-pattern-first regex matcher. Seeds two
    /// overlapping pricing rules ("claude-opus-4" ordered by display_name
    /// BEFORE the longer/more-specific "claude-opus-4-5") so the two
    /// algorithms disagree: `CostCalculator` would prefer the longer
    /// pattern; search.js's raw-order `find` hits the shorter one first.
    func testSearchCostUsesNodeStartsWithAlgorithmNotCostCalculatorOrdering() async throws {
        try store.insertSession(id: "s1", name: "Search cost session", status: .active, cwd: nil, model: nil, metadata: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5-20250101", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        // "AAA..." display_name sorts first alphabetically so listPricing()
        // returns the short/catch-all pattern before the longer one —
        // display_name is otherwise irrelevant to matching.
        try store.upsertPricing(PricingPutRequest(
            modelPattern: "claude-opus-4%", displayName: "AAA Catch-all Opus 4",
            inputPerMtok: 1.0, outputPerMtok: 1.0, cacheReadPerMtok: 0, cacheWritePerMtok: 0
        ))
        try store.upsertPricing(PricingPutRequest(
            modelPattern: "claude-opus-4-5%", displayName: "ZZZ Specific Opus 4.5",
            inputPerMtok: 9.0, outputPerMtok: 9.0, cacheReadPerMtok: 0, cacheWritePerMtok: 0
        ))

        try await bootServer()
        let (data, response) = try await get("/api/search?q=Search cost session")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(SearchResponse.self, from: data)
        let hit = try XCTUnwrap(decoded.results.first { $0.sessionId == "s1" })
        // Raw-order startsWith hits "claude-opus-4%" first (rate 1.0/Mtok),
        // NOT the longest-pattern-first "claude-opus-4-5%" (rate 9.0/Mtok)
        // that CostCalculator would have chosen.
        XCTAssertEqual(hit.cost ?? -1, 1.0, accuracy: 0.0001)
    }
}
