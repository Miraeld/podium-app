import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// P6.2a — Contract E2E suite: proves the vendored React client's API
/// expectations (dashboard/client/src/lib/types.ts + api.ts, plus the
/// page-local shapes in pages/Search.tsx and lib/push.ts) hold against the
/// Swift server's real wire output.
///
/// Methodology (deliberate, see STANDALONE_PLAN.md §4):
///   * The server is booted in-process with EVERY production router mounted
///     (same `PodiumServerApp` + `mounts:` pattern as ReadRoutersTests).
///   * Data is seeded through `POST /api/hooks/event` with a recorded-style
///     hook sequence (SessionStart → PreToolUse/PostToolUse → Agent spawn →
///     SubagentStop → Stop → SessionEnd, plus a second session left active),
///     exercising the REAL ingestion path — no direct store writes.
///   * Every assertion runs on raw response bytes via `JSONSerialization`,
///     NOT through Codable — a Codable round trip applies the same symmetric
///     snake_case transform on both sides and therefore masks exactly the
///     key-casing bugs this suite exists to catch (three separate
///     camelCase/snake_case incidents made it past unit tests before).
///   * For each multi-word key the *wrong-casing twin* is literally asserted
///     absent (`session_id` present AND `sessionId` absent for snake_case
///     endpoints; the inverse for the two deliberate camelCase families:
///     the run-spawner "live" family and the hand-assembled Workflows /
///     cc-config keys).
final class ContractTests: XCTestCase {
    private var tempDir: URL!
    private var claudeHome: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!

    // Seeded session ids (session A completes; session B stays active).
    private let sessionA = "sess-contract-a"
    private let sessionB = "sess-contract-b"
    private let cwdA = "/tmp/contract-proj-a"
    private let cwdB = "/tmp/contract-proj-b"
    private var transcriptPathA: String { mainTranscriptURL.path }
    private var mainTranscriptURL: URL {
        claudeHome
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeHome.encodeCwd(cwdA), isDirectory: true)
            .appendingPathComponent("\(sessionA).jsonl")
    }

    override func setUp() async throws {
        await DiagnosticsRecorder.shared.resetForTesting()
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-contract-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)

        claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        originalClaudeEnv = ClaudeHome.environment
        ClaudeHome.environment = ["CLAUDE_HOME": claudeHome.path]
        // HOME too: `~/.claude.json` (cc-config MCP user scope) resolves via
        // `PodiumPaths.homeDirectory()`, NOT CLAUDE_HOME — without this the
        // server reads the developer's real ~/.claude.json into /api/cc-config/mcp.
        originalPathsEnv = PodiumPaths.environment
        PodiumPaths.environment = ["HOME": tempDir.path]
        try seedClaudeHomeFixture()
    }

    override func tearDown() async throws {
        serverTask?.cancel()
        _ = await serverTask?.result
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        try? FileManager.default.removeItem(at: tempDir)
        await DiagnosticsRecorder.shared.resetForTesting()
    }

    // MARK: - Fixtures

    /// A sandboxed fake CLAUDE_HOME: one skill, one agent, a settings.json
    /// carrying hooks + an MCP server, and a main-session transcript JSONL
    /// (with usage entries) that hook events reference via transcript_path —
    /// tokens/cost flow through the real transcript-extraction path.
    private func seedClaudeHomeFixture() throws {
        let fm = FileManager.default

        let skillDir = claudeHome.appendingPathComponent("skills/demo-skill", isDirectory: true)
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\ndescription: Demo skill\n---\nDemo body.\n"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let agentsDir = claudeHome.appendingPathComponent("agents", isDirectory: true)
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try "---\ndescription: Reviews code\n---\nReviewer body.\n"
            .write(to: agentsDir.appendingPathComponent("reviewer.md"), atomically: true, encoding: .utf8)

        let settings = """
        {
          "hooks": {
            "PreToolUse": [
              {"matcher": "*", "hooks": [{"type": "command", "command": "echo hi", "timeout": 5}]}
            ]
          },
          "mcpServers": {
            "demo-mcp": {"command": "npx", "args": ["demo-server"]}
          }
        }
        """
        try settings.write(to: claudeHome.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let projectDir = mainTranscriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcriptLines = [
            #"{"type":"user","timestamp":"2026-07-03T10:00:00.000Z","message":{"content":"Fix the flaky test"}}"#,
            """
            {"type":"assistant","timestamp":"2026-07-03T10:00:05.000Z","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"Looking at it."},{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"/tmp/test.swift"}}],"usage":{"input_tokens":500,"output_tokens":80,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}
            """,
            #"{"type":"user","timestamp":"2026-07-03T10:00:06.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file contents","is_error":false}]}}"#,
        ]
        try (transcriptLines.joined(separator: "\n") + "\n")
            .write(to: mainTranscriptURL, atomically: true, encoding: .utf8)

        // Subagent sidechain transcript so /:id/transcripts lists a subagent.
        let subDir = projectDir
            .appendingPathComponent(sessionA, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try #"{"type":"user","timestamp":"2026-07-03T10:01:00.000Z","message":{"content":"Investigate flaky test"}}"#
            .appending("\n")
            .write(to: subDir.appendingPathComponent("agent-contractsub1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"agentType":"general-purpose","description":"Investigate flaky test"}"#
            .write(to: subDir.appendingPathComponent("agent-contractsub1.meta.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Boot + seed (same pattern as ReadRoutersTests / RunRouterTests / PushRouterTests)

    private func bootServer() async throws {
        let candidatePort = Int.random(in: 21000..<39000)
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)

        let broadcaster = Broadcaster()
        // /usr/bin/true, NOT /bin/true — modern macOS (Darwin 25+) has no
        // /bin/true, and Linux is usr-merged; /usr/bin/true exists on both.
        let spawner = RunSpawner(store: store, broadcaster: broadcaster, claudeBinary: "/usr/bin/true")
        let pushService = PushService(
            store: store,
            keysPath: tempDir.appendingPathComponent("vapid-keys.json"),
            subject: "mailto:test@example.com",
            nativeNotifier: NoOpNativeNotifier()
        )

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
                PricingRouterMount.self,
                WorkflowsRouterMount.self,
                HooksRouterMount.self,
                SettingsRouterMount.self,
                DiagnosticsRouterMount.self,
                UpdatesRouterMount.self,
                PushRouterMount.self,
                RunRouterMount.self,
                ImportRouterMount.self,
                ExportRouterMount.self,
                CcConfigRouterMount.self,
            ],
            runSpawner: spawner,
            pushService: pushService
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
        #if os(Linux)
        // Same GitHub-Actions-only skip as DiagnosticsRouterTests (see the
        // long comment there): on GH-hosted runners the swift:6.1 container's
        // networking intermittently refuses every HTTP request to an
        // in-process server that IS listening. Not reproducible in local
        // docker with the identical image — local Linux still enforces this
        // suite for real.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("server did not become healthy within \(timeout)s — known GitHub Actions Linux container networking issue; see DiagnosticsRouterTests")
        }
        #endif
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

    @discardableResult
    private func postHook(_ hookType: String, _ data: [String: Any]) async throws -> HTTPURLResponse {
        let body = try JSONSerialization.data(withJSONObject: ["hook_type": hookType, "data": data])
        let (_, response) = try await send("POST", "/api/hooks/event", body: body)
        XCTAssertEqual(response.statusCode, 200, "hook \(hookType) should be accepted")
        return response
    }

    /// The canonical recorded-style hook sequence. Mirrors what podium-hook
    /// (hook.mjs) actually POSTs: `{hook_type, data}` with data carrying
    /// session_id/cwd/tool_name/tool_input/tool_response/transcript_path.
    /// Session A runs a full lifecycle and completes; session B stays active.
    private func seedViaHooks() async throws {
        let tp = transcriptPathA
        try await postHook("SessionStart", [
            "session_id": sessionA, "cwd": cwdA, "model": "claude-sonnet-4-5", "transcript_path": tp,
        ])
        try await postHook("UserPromptSubmit", [
            "session_id": sessionA, "prompt": "Fix the flaky test", "transcript_path": tp,
        ])
        try await postHook("PreToolUse", [
            "session_id": sessionA, "tool_name": "Bash",
            "tool_input": ["command": "swift test"], "tool_use_id": "tu-bash-1", "transcript_path": tp,
        ])
        try await postHook("PostToolUse", [
            "session_id": sessionA, "tool_name": "Bash",
            "tool_input": ["command": "swift test"], "tool_response": "All tests passed",
            "tool_use_id": "tu-bash-1", "transcript_path": tp,
        ])
        // Subagent spawn via the Agent tool (hooks.js lines 317–402).
        try await postHook("PreToolUse", [
            "session_id": sessionA, "tool_name": "Agent",
            "tool_input": [
                "description": "Investigate flaky test",
                "subagent_type": "general-purpose",
                "prompt": "Investigate the flaky test root cause",
            ],
            "tool_use_id": "tu-agent-1", "transcript_path": tp,
        ])
        try await postHook("SubagentStop", [
            "session_id": sessionA, "agent_type": "general-purpose",
            "description": "Investigate flaky test", "transcript_path": tp,
        ])
        try await postHook("Stop", ["session_id": sessionA, "transcript_path": tp])
        try await postHook("SessionEnd", ["session_id": sessionA, "transcript_path": tp])

        // Second session, left active mid-tool-use.
        try await postHook("SessionStart", ["session_id": sessionB, "cwd": cwdB])
        try await postHook("PreToolUse", [
            "session_id": sessionB, "tool_name": "Read", "tool_input": ["file_path": "/tmp/x"],
        ])
    }

    private func bootAndSeed() async throws {
        try await bootServer()
        try await seedViaHooks()
    }

    // MARK: - Raw-JSON assertion helpers

    private enum JSONKind: String, CaseIterable {
        case string, number, bool, object, array, null
    }

    private func kind(of value: Any) -> JSONKind? {
        if value is NSNull { return .null }
        #if canImport(Darwin)
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool : .number
        }
        #else
        if value is Bool { return .bool }
        if value is NSNumber || value is Int || value is Double { return .number }
        #endif
        if value is String { return .string }
        if value is [Any] { return .array }
        if value is [String: Any] { return .object }
        return nil
    }

    /// "session_id" → "sessionId"
    private func camelTwin(_ snakeKey: String) -> String {
        let parts = snakeKey.split(separator: "_").map(String.init)
        guard parts.count > 1 else { return snakeKey }
        return parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// "swimLanes" → "swim_lanes"
    private func snakeTwin(_ camelKey: String) -> String {
        var out = ""
        for ch in camelKey {
            if ch.isUppercase {
                out.append("_")
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Asserts `key` exists with one of the allowed JSON kinds.
    private func assertField(
        _ json: [String: Any], _ key: String, _ kinds: JSONKind...,
        endpoint: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let value = json[key] else {
            XCTFail("\(endpoint): missing key '\(key)' (present keys: \(json.keys.sorted()))", file: file, line: line)
            return
        }
        guard let actual = kind(of: value) else {
            XCTFail("\(endpoint): key '\(key)' has unclassifiable value \(value)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            kinds.contains(actual),
            "\(endpoint): key '\(key)' is \(actual.rawValue), expected one of \(kinds.map(\.rawValue))",
            file: file, line: line
        )
    }

    /// Asserts `key` is NOT present at all (the wrong-casing twin check).
    private func assertAbsent(
        _ json: [String: Any], _ key: String,
        endpoint: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(json[key], "\(endpoint): key '\(key)' must NOT exist (wrong casing family)", file: file, line: line)
    }

    /// snake_case contract field: present under the snake key with an allowed
    /// kind AND its camelCase twin literally absent.
    private func snake(
        _ json: [String: Any], _ key: String, _ kinds: JSONKind...,
        endpoint: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let value = json[key] else {
            XCTFail("\(endpoint): missing snake_case key '\(key)' (present keys: \(json.keys.sorted()))", file: file, line: line)
            return
        }
        if let actual = kind(of: value) {
            XCTAssertTrue(
                kinds.contains(actual),
                "\(endpoint): key '\(key)' is \(actual.rawValue), expected one of \(kinds.map(\.rawValue))",
                file: file, line: line
            )
        }
        let twin = camelTwin(key)
        if twin != key {
            assertAbsent(json, twin, endpoint: endpoint, file: file, line: line)
        }
    }

    /// Optional snake_case field: camel twin must never exist; the type is
    /// only checked when the key is present (client marks it `?`).
    private func optionalSnake(
        _ json: [String: Any], _ key: String, _ kinds: JSONKind...,
        endpoint: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        if let value = json[key], let actual = kind(of: value) {
            XCTAssertTrue(
                kinds.contains(actual),
                "\(endpoint): optional key '\(key)' is \(actual.rawValue), expected one of \(kinds.map(\.rawValue))",
                file: file, line: line
            )
        }
        let twin = camelTwin(key)
        if twin != key {
            assertAbsent(json, twin, endpoint: endpoint, file: file, line: line)
        }
    }

    /// camelCase contract field (the deliberate exception families): present
    /// under the camel key AND its snake_case twin literally absent.
    private func camel(
        _ json: [String: Any], _ key: String, _ kinds: JSONKind...,
        endpoint: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let value = json[key] else {
            XCTFail("\(endpoint): missing camelCase key '\(key)' (present keys: \(json.keys.sorted()))", file: file, line: line)
            return
        }
        if let actual = kind(of: value) {
            XCTAssertTrue(
                kinds.contains(actual),
                "\(endpoint): key '\(key)' is \(actual.rawValue), expected one of \(kinds.map(\.rawValue))",
                file: file, line: line
            )
        }
        let twin = snakeTwin(key)
        if twin != key {
            assertAbsent(json, twin, endpoint: endpoint, file: file, line: line)
        }
    }

    private func getJSONObject(
        _ path: String, expectedStatus: Int = 200,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String: Any] {
        let (data, response) = try await get(path)
        XCTAssertEqual(response.statusCode, expectedStatus, "GET \(path)", file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "GET \(path): body is not a JSON object", file: file, line: line)
    }

    private func firstObject(
        _ json: [String: Any], _ key: String, endpoint: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let array = try XCTUnwrap(json[key] as? [[String: Any]], "\(endpoint): '\(key)' is not an array of objects", file: file, line: line)
        return try XCTUnwrap(array.first, "\(endpoint): '\(key)' is empty — seeding should have produced rows", file: file, line: line)
    }

    // MARK: - Shared object-shape assertions (client types.ts)

    /// types.ts `Session` (lines 21–37).
    private func assertSessionShape(_ session: [String: Any], endpoint: String) {
        assertField(session, "id", .string, endpoint: endpoint)
        assertField(session, "name", .string, .null, endpoint: endpoint)
        assertField(session, "status", .string, endpoint: endpoint)
        assertField(session, "cwd", .string, .null, endpoint: endpoint)
        assertField(session, "model", .string, .null, endpoint: endpoint)
        snake(session, "started_at", .string, endpoint: endpoint)
        snake(session, "ended_at", .string, .null, endpoint: endpoint)
        assertField(session, "metadata", .string, .null, endpoint: endpoint)
        optionalSnake(session, "agent_count", .number, endpoint: endpoint)
        optionalSnake(session, "last_activity", .string, .null, endpoint: endpoint)
        optionalSnake(session, "awaiting_input_since", .string, .null, endpoint: endpoint)
    }

    /// types.ts `Agent` (lines 39–55).
    private func assertAgentShape(_ agent: [String: Any], endpoint: String) {
        assertField(agent, "id", .string, endpoint: endpoint)
        snake(agent, "session_id", .string, endpoint: endpoint)
        assertField(agent, "name", .string, endpoint: endpoint)
        assertField(agent, "type", .string, endpoint: endpoint)
        snake(agent, "subagent_type", .string, .null, endpoint: endpoint)
        assertField(agent, "status", .string, endpoint: endpoint)
        assertField(agent, "task", .string, .null, endpoint: endpoint)
        snake(agent, "current_tool", .string, .null, endpoint: endpoint)
        snake(agent, "started_at", .string, endpoint: endpoint)
        snake(agent, "ended_at", .string, .null, endpoint: endpoint)
        snake(agent, "updated_at", .string, endpoint: endpoint)
        snake(agent, "parent_agent_id", .string, .null, endpoint: endpoint)
        assertField(agent, "metadata", .string, .null, endpoint: endpoint)
        optionalSnake(agent, "awaiting_input_since", .string, .null, endpoint: endpoint)
    }

    /// types.ts `DashboardEvent` (lines 77–86).
    private func assertEventShape(_ event: [String: Any], endpoint: String) {
        assertField(event, "id", .number, endpoint: endpoint)
        snake(event, "session_id", .string, endpoint: endpoint)
        snake(event, "agent_id", .string, .null, endpoint: endpoint)
        snake(event, "event_type", .string, endpoint: endpoint)
        snake(event, "tool_name", .string, .null, endpoint: endpoint)
        assertField(event, "summary", .string, .null, endpoint: endpoint)
        assertField(event, "data", .string, .null, endpoint: endpoint)
        snake(event, "created_at", .string, endpoint: endpoint)
    }

    /// types.ts `CostResult` (lines 145–149) + `CostBreakdown` (135–143).
    private func assertCostResultShape(_ json: [String: Any], endpoint: String) throws {
        snake(json, "total_cost", .number, endpoint: endpoint)
        assertField(json, "breakdown", .array, endpoint: endpoint)
        snake(json, "daily_costs", .array, endpoint: endpoint)
        if let row = (json["breakdown"] as? [[String: Any]])?.first {
            assertField(row, "model", .string, endpoint: endpoint)
            snake(row, "input_tokens", .number, endpoint: endpoint)
            snake(row, "output_tokens", .number, endpoint: endpoint)
            snake(row, "cache_read_tokens", .number, endpoint: endpoint)
            snake(row, "cache_write_tokens", .number, endpoint: endpoint)
            assertField(row, "cost", .number, endpoint: endpoint)
            snake(row, "matched_rule", .string, .null, endpoint: endpoint)
        }
        if let day = (json["daily_costs"] as? [[String: Any]])?.first {
            assertField(day, "date", .string, endpoint: endpoint)
            assertField(day, "cost", .number, endpoint: endpoint)
        }
    }

    // MARK: - /api/health

    func testHealthContract() async throws {
        try await bootServer()
        let json = try await getJSONObject("/api/health")
        assertField(json, "status", .string, endpoint: "/api/health")
        assertField(json, "timestamp", .string, endpoint: "/api/health")
        // ISO8601 with milliseconds + Z (plan §4).
        let ts = try XCTUnwrap(json["timestamp"] as? String)
        XCTAssertTrue(
            ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil,
            "/api/health timestamp must be ISO8601 with milliseconds + 'Z', got \(ts)"
        )
    }

    // MARK: - Error envelope

    func testErrorEnvelopeContract() async throws {
        try await bootServer()
        // api.ts request() line 32 reads `body?.error?.message`.
        let json = try await getJSONObject("/api/sessions/does-not-exist", expectedStatus: 404)
        let error = try XCTUnwrap(json["error"] as? [String: Any], "error envelope must be {error:{code,message}}")
        assertField(error, "code", .string, endpoint: "404 error envelope")
        assertField(error, "message", .string, endpoint: "404 error envelope")
    }

    // MARK: - /api/stats

    func testStatsContract() async throws {
        try await bootAndSeed()
        let e = "/api/stats"
        let json = try await getJSONObject("/api/stats?tz_offset=0")
        snake(json, "total_sessions", .number, endpoint: e)
        snake(json, "active_sessions", .number, endpoint: e)
        snake(json, "active_agents", .number, endpoint: e)
        snake(json, "total_agents", .number, endpoint: e)
        snake(json, "total_events", .number, endpoint: e)
        snake(json, "events_today", .number, endpoint: e)
        snake(json, "ws_connections", .number, endpoint: e)
        snake(json, "agents_by_status", .object, endpoint: e)
        snake(json, "sessions_by_status", .object, endpoint: e)
        XCTAssertEqual(json["total_sessions"] as? Int, 2)
    }

    // MARK: - /api/sessions family

    func testSessionsListContract() async throws {
        try await bootAndSeed()
        let e = "/api/sessions"
        let json = try await getJSONObject("/api/sessions?limit=10&sort_by=time&sort_desc=true")
        assertField(json, "sessions", .array, endpoint: e)
        assertField(json, "total", .number, endpoint: e)
        assertField(json, "limit", .number, endpoint: e)
        assertField(json, "offset", .number, endpoint: e)
        let session = try firstObject(json, "sessions", endpoint: e)
        assertSessionShape(session, endpoint: e)
    }

    func testSessionsFacetsContract() async throws {
        try await bootAndSeed()
        let json = try await getJSONObject("/api/sessions/facets")
        assertField(json, "cwds", .array, endpoint: "/api/sessions/facets")
        XCTAssertEqual(Set(json["cwds"] as? [String] ?? []), [cwdA, cwdB])
    }

    func testSessionDetailContract() async throws {
        try await bootAndSeed()
        let e = "/api/sessions/:id"
        let json = try await getJSONObject("/api/sessions/\(sessionA)")
        let session = try XCTUnwrap(json["session"] as? [String: Any], "\(e): missing 'session'")
        assertSessionShape(session, endpoint: e)
        XCTAssertEqual(session["status"] as? String, "completed", "SessionEnd hook should complete session A")
        let agent = try firstObject(json, "agents", endpoint: e)
        assertAgentShape(agent, endpoint: e)
        let event = try firstObject(json, "events", endpoint: e)
        assertEventShape(event, endpoint: e)
        // The Agent-tool PreToolUse must have synthesized a subagent row.
        let agents = json["agents"] as? [[String: Any]] ?? []
        XCTAssertTrue(agents.contains { ($0["type"] as? String) == "subagent" }, "\(e): subagent from Agent tool_use missing")
    }

    func testSessionStatsContract() async throws {
        try await bootAndSeed()
        let e = "/api/sessions/:id/stats"
        let json = try await getJSONObject("/api/sessions/\(sessionA)/stats")
        snake(json, "session_id", .string, endpoint: e)
        snake(json, "total_events", .number, endpoint: e)
        snake(json, "events_by_type", .array, endpoint: e)
        snake(json, "tools_used", .array, endpoint: e)
        snake(json, "error_count", .number, endpoint: e)
        snake(json, "first_event_at", .string, .null, endpoint: e)
        snake(json, "last_event_at", .string, .null, endpoint: e)
        let agents = try XCTUnwrap(json["agents"] as? [String: Any], "\(e): missing 'agents'")
        assertField(agents, "total", .number, endpoint: e)
        assertField(agents, "main", .number, endpoint: e)
        assertField(agents, "subagent", .number, endpoint: e)
        assertField(agents, "compaction", .number, endpoint: e)
        snake(agents, "by_status", .object, endpoint: e)
        snake(json, "subagent_types", .array, endpoint: e)
        let tokens = try XCTUnwrap(json["tokens"] as? [String: Any], "\(e): missing 'tokens'")
        snake(tokens, "input_tokens", .number, endpoint: e)
        snake(tokens, "output_tokens", .number, endpoint: e)
        snake(tokens, "cache_read_tokens", .number, endpoint: e)
        snake(tokens, "cache_write_tokens", .number, endpoint: e)
        if let byType = (json["events_by_type"] as? [[String: Any]])?.first {
            snake(byType, "event_type", .string, endpoint: e)
            assertField(byType, "count", .number, endpoint: e)
        }
        if let tool = (json["tools_used"] as? [[String: Any]])?.first {
            snake(tool, "tool_name", .string, endpoint: e)
            assertField(tool, "count", .number, endpoint: e)
        }
    }

    func testSessionTranscriptsListContract() async throws {
        try await bootAndSeed()
        let e = "/api/sessions/:id/transcripts"
        let json = try await getJSONObject("/api/sessions/\(sessionA)/transcripts")
        let entry = try firstObject(json, "transcripts", endpoint: e)
        assertField(entry, "id", .string, endpoint: e)
        assertField(entry, "name", .string, endpoint: e)
        assertField(entry, "type", .string, endpoint: e)
        optionalSnake(entry, "subagent_type", .string, .null, endpoint: e)
        snake(entry, "has_transcript", .bool, endpoint: e)
        optionalSnake(entry, "db_agent_id", .string, .null, endpoint: e)
        let entries = json["transcripts"] as? [[String: Any]] ?? []
        XCTAssertTrue(entries.contains { ($0["type"] as? String) == "main" }, "\(e): main transcript missing")
        XCTAssertTrue(entries.contains { ($0["type"] as? String) == "subagent" }, "\(e): subagent transcript missing")
    }

    func testSessionTranscriptContract() async throws {
        try await bootAndSeed()
        let e = "/api/sessions/:id/transcript"
        let json = try await getJSONObject("/api/sessions/\(sessionA)/transcript")
        assertField(json, "messages", .array, endpoint: e)
        assertField(json, "total", .number, endpoint: e)
        snake(json, "has_more", .bool, endpoint: e)
        snake(json, "last_line", .number, endpoint: e)
        snake(json, "first_line", .number, endpoint: e)
        let message = try firstObject(json, "messages", endpoint: e)
        assertField(message, "type", .string, endpoint: e)
        assertField(message, "timestamp", .string, .null, endpoint: e)
        assertField(message, "content", .array, endpoint: e)
        if let content = (message["content"] as? [[String: Any]])?.first {
            assertField(content, "type", .string, endpoint: e)
        }
        // Assistant message carries usage with the client's exact key names
        // (types.ts TranscriptMessage.usage, lines 488–493).
        let messages = json["messages"] as? [[String: Any]] ?? []
        if let assistant = messages.first(where: { ($0["type"] as? String) == "assistant" }),
           let usage = assistant["usage"] as? [String: Any] {
            snake(usage, "input_tokens", .number, endpoint: e)
            snake(usage, "output_tokens", .number, endpoint: e)
            optionalSnake(usage, "cache_read_input_tokens", .number, endpoint: e)
            optionalSnake(usage, "cache_creation_input_tokens", .number, endpoint: e)
        }
    }

    // MARK: - /api/agents family

    func testAgentsListContract() async throws {
        try await bootAndSeed()
        let e = "/api/agents"
        let json = try await getJSONObject("/api/agents?session_id=\(sessionA)")
        let agent = try firstObject(json, "agents", endpoint: e)
        assertAgentShape(agent, endpoint: e)
    }

    /// GET /api/agents/:id — not called by the vendored client (api.ts's
    /// `agents` group only exposes `list`), covered lightly for parity with
    /// the Node router surface.
    func testAgentDetailContract() async throws {
        try await bootAndSeed()
        let e = "/api/agents/:id"
        let json = try await getJSONObject("/api/agents/\(sessionA)-main")
        let agent = try XCTUnwrap(json["agent"] as? [String: Any], "\(e): missing 'agent'")
        assertAgentShape(agent, endpoint: e)
    }

    // MARK: - /api/events family

    func testEventsListContract() async throws {
        try await bootAndSeed()
        let e = "/api/events"
        let json = try await getJSONObject("/api/events?session_id=\(sessionA)&limit=50")
        assertField(json, "events", .array, endpoint: e)
        assertField(json, "limit", .number, endpoint: e)
        assertField(json, "offset", .number, endpoint: e)
        assertField(json, "total", .number, endpoint: e)
        let event = try firstObject(json, "events", endpoint: e)
        assertEventShape(event, endpoint: e)
    }

    func testEventsFacetsContract() async throws {
        try await bootAndSeed()
        let e = "/api/events/facets"
        let json = try await getJSONObject("/api/events/facets")
        snake(json, "event_types", .array, endpoint: e)
        snake(json, "tool_names", .array, endpoint: e)
        XCTAssertTrue((json["event_types"] as? [String] ?? []).contains("SessionStart"))
    }

    /// GET /api/events/:id/full — not referenced anywhere in the vendored
    /// client source (no fetch of `/full` in src/**), covered lightly for
    /// parity with the Node router surface.
    func testEventFullContract() async throws {
        try await bootAndSeed()
        let e = "/api/events/:id/full"
        let (listData, _) = try await get("/api/events?session_id=\(sessionA)&limit=1")
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let first = try firstObject(list, "events", endpoint: e)
        let id = try XCTUnwrap(first["id"] as? Int)
        let json = try await getJSONObject("/api/events/\(id)/full")
        let event = try XCTUnwrap(json["event"] as? [String: Any], "\(e): missing 'event'")
        snake(event, "session_id", .string, endpoint: e)
        snake(event, "event_type", .string, endpoint: e)
        // /full parses the JSON `data` column into an object (vs string in list).
        assertField(event, "data", .object, .null, endpoint: e)
    }

    // MARK: - /api/analytics

    func testAnalyticsContract() async throws {
        try await bootAndSeed()
        let e = "/api/analytics"
        let json = try await getJSONObject("/api/analytics?tz_offset=0")
        let tokens = try XCTUnwrap(json["tokens"] as? [String: Any], "\(e): missing 'tokens'")
        snake(tokens, "total_input", .number, endpoint: e)
        snake(tokens, "total_output", .number, endpoint: e)
        snake(tokens, "total_cache_read", .number, endpoint: e)
        snake(tokens, "total_cache_write", .number, endpoint: e)
        snake(json, "tool_usage", .array, endpoint: e)
        snake(json, "daily_events", .array, endpoint: e)
        snake(json, "daily_sessions", .array, endpoint: e)
        snake(json, "agent_types", .array, endpoint: e)
        snake(json, "event_types", .array, endpoint: e)
        snake(json, "avg_events_per_session", .number, endpoint: e)
        snake(json, "total_subagents", .number, endpoint: e)
        snake(json, "agents_by_status", .object, endpoint: e)
        snake(json, "sessions_by_status", .object, endpoint: e)
        let overview = try XCTUnwrap(json["overview"] as? [String: Any], "\(e): missing 'overview'")
        snake(overview, "total_sessions", .number, endpoint: e)
        snake(overview, "active_sessions", .number, endpoint: e)
        snake(overview, "active_agents", .number, endpoint: e)
        snake(overview, "total_agents", .number, endpoint: e)
        snake(overview, "total_events", .number, endpoint: e)
        // Tokens flowed through the real transcript-extraction path.
        XCTAssertGreaterThan((tokens["total_input"] as? Int) ?? 0, 0, "\(e): transcript token extraction produced no tokens")
        if let tool = (json["tool_usage"] as? [[String: Any]])?.first {
            snake(tool, "tool_name", .string, endpoint: e)
            assertField(tool, "count", .number, endpoint: e)
        }
        if let day = (json["daily_events"] as? [[String: Any]])?.first {
            assertField(day, "date", .string, endpoint: e)
            assertField(day, "count", .number, endpoint: e)
        }
        if let at = (json["agent_types"] as? [[String: Any]])?.first {
            snake(at, "subagent_type", .string, .null, endpoint: e)
            assertField(at, "count", .number, endpoint: e)
        }
    }

    // MARK: - /api/search (pages/Search.tsx lines 23–49)

    func testSearchContract() async throws {
        try await bootAndSeed()
        let e = "/api/search"
        let json = try await getJSONObject("/api/search?q=flaky&limit=20&offset=0")
        assertField(json, "results", .array, endpoint: e)
        assertField(json, "total", .number, endpoint: e)
        let results = json["results"] as? [[String: Any]] ?? []
        XCTAssertFalse(results.isEmpty, "\(e): expected hits for 'flaky' (session name + event summaries)")
        if let sessionHit = results.first(where: { ($0["type"] as? String) == "session" }) {
            snake(sessionHit, "session_id", .string, endpoint: e)
            snake(sessionHit, "session_name", .string, .null, endpoint: e)
            assertField(sessionHit, "cwd", .string, .null, endpoint: e)
            assertField(sessionHit, "status", .string, .null, endpoint: e)
            snake(sessionHit, "started_at", .string, .null, endpoint: e)
        }
        if let eventHit = results.first(where: { ($0["type"] as? String) == "event" }) {
            snake(eventHit, "session_id", .string, endpoint: e)
            snake(eventHit, "event_id", .number, endpoint: e)
            snake(eventHit, "event_type", .string, .null, endpoint: e)
            snake(eventHit, "tool_name", .string, .null, endpoint: e)
            assertField(eventHit, "summary", .string, .null, endpoint: e)
            snake(eventHit, "created_at", .string, .null, endpoint: e)
        }
    }

    // MARK: - /api/pricing family

    func testPricingListContract() async throws {
        try await bootServer()
        let e = "/api/pricing"
        let json = try await getJSONObject("/api/pricing")
        let rule = try firstObject(json, "pricing", endpoint: e) // default seed is never empty
        snake(rule, "model_pattern", .string, endpoint: e)
        snake(rule, "display_name", .string, endpoint: e)
        snake(rule, "input_per_mtok", .number, endpoint: e)
        snake(rule, "output_per_mtok", .number, endpoint: e)
        snake(rule, "cache_read_per_mtok", .number, endpoint: e)
        snake(rule, "cache_write_per_mtok", .number, endpoint: e)
        snake(rule, "updated_at", .string, endpoint: e)
    }

    func testPricingCostContract() async throws {
        try await bootAndSeed()
        let total = try await getJSONObject("/api/pricing/cost?tz_offset=0")
        try assertCostResultShape(total, endpoint: "/api/pricing/cost")
        XCTAssertFalse((total["breakdown"] as? [Any] ?? []).isEmpty, "/api/pricing/cost: seeded tokens should yield a breakdown row")

        let perSession = try await getJSONObject("/api/pricing/cost/\(sessionA)?tz_offset=0")
        try assertCostResultShape(perSession, endpoint: "/api/pricing/cost/:sessionId")
    }

    // MARK: - /api/settings/info (api.ts lines 166–202 — mixed-casing literals!)

    func testSettingsInfoContract() async throws {
        try await bootAndSeed()
        let e = "/api/settings/info"
        let json = try await getJSONObject("/api/settings/info")

        let db = try XCTUnwrap(json["db"] as? [String: Any], "\(e): missing 'db'")
        assertField(db, "path", .string, endpoint: e)
        assertField(db, "size", .number, endpoint: e)
        assertField(db, "counts", .object, endpoint: e)
        let pragmas = try XCTUnwrap(db["pragmas"] as? [String: Any], "\(e): missing db.pragmas")
        snake(pragmas, "journal_mode", .string, endpoint: e)
        assertField(pragmas, "synchronous", .number, endpoint: e)
        snake(pragmas, "auto_vacuum", .number, endpoint: e)
        assertField(pragmas, "encoding", .string, endpoint: e)
        snake(pragmas, "foreign_keys", .number, endpoint: e)
        snake(pragmas, "busy_timeout", .number, endpoint: e)
        let loadStats = try XCTUnwrap(db["load_stats"] as? [String: Any], "\(e): missing db.load_stats")
        assertField(loadStats, "m5", .number, endpoint: e)
        assertField(loadStats, "m15", .number, endpoint: e)
        assertField(loadStats, "h1", .number, endpoint: e)

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any], "\(e): missing 'hooks'")
        assertField(hooks, "installed", .bool, endpoint: e)
        assertField(hooks, "path", .string, endpoint: e)
        assertField(hooks, "hooks", .object, endpoint: e)

        let server = try XCTUnwrap(json["server"] as? [String: Any], "\(e): missing 'server'")
        assertField(server, "uptime", .number, endpoint: e)
        snake(server, "node_version", .string, endpoint: e)
        assertField(server, "platform", .string, endpoint: e)
        snake(server, "ws_connections", .number, endpoint: e)
        snake(server, "cpu_load", .array, endpoint: e)
        assertField(server, "arch", .string, endpoint: e)
        snake(server, "total_mem", .number, endpoint: e)
        snake(server, "free_mem", .number, endpoint: e)
        assertField(server, "cpus", .number, endpoint: e)
        // Node's process.memoryUsage() keys are camelCase literals — the
        // client destructures them verbatim (api.ts line 188).
        let memory = try XCTUnwrap(server["memory"] as? [String: Any], "\(e): missing server.memory")
        assertField(memory, "rss", .number, endpoint: e)
        camel(memory, "heapTotal", .number, endpoint: e)
        camel(memory, "heapUsed", .number, endpoint: e)
        assertField(memory, "external", .number, endpoint: e)

        // transcript_cache: snake_case container, camelCase `maxSize` inside
        // (api.ts lines 195–201 — Node's cache.stats() literal).
        let cache = try XCTUnwrap(json["transcript_cache"] as? [String: Any], "\(e): missing 'transcript_cache'")
        assertAbsent(json, "transcriptCache", endpoint: e)
        assertField(cache, "size", .number, endpoint: e)
        camel(cache, "maxSize", .number, endpoint: e)
        assertField(cache, "hits", .number, endpoint: e)
        assertField(cache, "misses", .number, endpoint: e)
        assertField(cache, "keys", .array, endpoint: e)
    }

    // MARK: - /api/workflows (camelCase exception family — types.ts WorkflowData)

    func testWorkflowsAggregateContract() async throws {
        try await bootAndSeed()
        let e = "/api/workflows"
        let json = try await getJSONObject("/api/workflows")

        let stats = try XCTUnwrap(json["stats"] as? [String: Any], "\(e): missing 'stats'")
        camel(stats, "totalSessions", .number, endpoint: e)
        camel(stats, "totalAgents", .number, endpoint: e)
        camel(stats, "totalSubagents", .number, endpoint: e)
        camel(stats, "avgSubagents", .number, endpoint: e)
        camel(stats, "successRate", .number, endpoint: e)
        camel(stats, "avgDepth", .number, endpoint: e)
        camel(stats, "avgDurationSec", .number, endpoint: e)
        camel(stats, "totalCompactions", .number, endpoint: e)
        camel(stats, "avgCompactions", .number, endpoint: e)
        assertField(stats, "topFlow", .object, .null, endpoint: e)

        let orchestration = try XCTUnwrap(json["orchestration"] as? [String: Any], "\(e): missing 'orchestration'")
        camel(orchestration, "sessionCount", .number, endpoint: e)
        camel(orchestration, "mainCount", .number, endpoint: e)
        camel(orchestration, "subagentTypes", .array, endpoint: e)
        assertField(orchestration, "edges", .array, endpoint: e)
        assertField(orchestration, "outcomes", .array, endpoint: e)
        assertField(orchestration, "compactions", .object, endpoint: e)
        if let st = (orchestration["subagentTypes"] as? [[String: Any]])?.first {
            // Inner rows stay snake_case (SQL column names pass through).
            snake(st, "subagent_type", .string, .null, endpoint: e)
            assertField(st, "count", .number, endpoint: e)
            assertField(st, "completed", .number, endpoint: e)
            assertField(st, "errors", .number, endpoint: e)
        }

        camel(json, "toolFlow", .object, endpoint: e)
        let toolFlow = try XCTUnwrap(json["toolFlow"] as? [String: Any])
        assertField(toolFlow, "transitions", .array, endpoint: e)
        camel(toolFlow, "toolCounts", .array, endpoint: e)

        assertField(json, "effectiveness", .array, endpoint: e)
        if let eff = (json["effectiveness"] as? [[String: Any]])?.first {
            snake(eff, "subagent_type", .string, .null, endpoint: e)
            assertField(eff, "total", .number, endpoint: e)
            camel(eff, "successRate", .number, endpoint: e)
            camel(eff, "avgDuration", .number, .null, endpoint: e)
            assertField(eff, "trend", .array, endpoint: e)
        }

        let patterns = try XCTUnwrap(json["patterns"] as? [String: Any], "\(e): missing 'patterns'")
        assertField(patterns, "patterns", .array, endpoint: e)
        camel(patterns, "soloSessionCount", .number, endpoint: e)
        camel(patterns, "soloPercentage", .number, endpoint: e)

        camel(json, "modelDelegation", .object, endpoint: e)
        let delegation = try XCTUnwrap(json["modelDelegation"] as? [String: Any])
        camel(delegation, "mainModels", .array, endpoint: e)
        camel(delegation, "subagentModels", .array, endpoint: e)
        camel(delegation, "tokensByModel", .array, endpoint: e)
        if let tk = (delegation["tokensByModel"] as? [[String: Any]])?.first {
            assertField(tk, "model", .string, endpoint: e)
            snake(tk, "input_tokens", .number, endpoint: e)
            snake(tk, "output_tokens", .number, endpoint: e)
        }

        camel(json, "errorPropagation", .object, endpoint: e)
        let errors = try XCTUnwrap(json["errorPropagation"] as? [String: Any])
        camel(errors, "byDepth", .array, endpoint: e)
        camel(errors, "byType", .array, endpoint: e)
        camel(errors, "eventErrors", .array, endpoint: e)
        camel(errors, "sessionsWithErrors", .number, endpoint: e)
        camel(errors, "totalSessions", .number, endpoint: e)
        camel(errors, "errorRate", .number, endpoint: e)

        let concurrency = try XCTUnwrap(json["concurrency"] as? [String: Any], "\(e): missing 'concurrency'")
        camel(concurrency, "aggregateLanes", .array, endpoint: e)

        assertField(json, "complexity", .array, endpoint: e)
        if let cx = (json["complexity"] as? [[String: Any]])?.first {
            assertField(cx, "id", .string, endpoint: e)
            assertField(cx, "duration", .number, endpoint: e)
            camel(cx, "agentCount", .number, endpoint: e)
            camel(cx, "subagentCount", .number, endpoint: e)
            camel(cx, "totalTokens", .number, endpoint: e)
        }

        let compaction = try XCTUnwrap(json["compaction"] as? [String: Any], "\(e): missing 'compaction'")
        camel(compaction, "totalCompactions", .number, endpoint: e)
        camel(compaction, "tokensRecovered", .number, endpoint: e)
        camel(compaction, "perSession", .array, endpoint: e)
        camel(compaction, "sessionsWithCompactions", .number, endpoint: e)
        camel(compaction, "totalSessions", .number, endpoint: e)

        assertField(json, "cooccurrence", .array, endpoint: e)
    }

    func testWorkflowSessionDrillInContract() async throws {
        try await bootAndSeed()
        let e = "/api/workflows/session/:id"
        let json = try await getJSONObject("/api/workflows/session/\(sessionA)")

        let session = try XCTUnwrap(json["session"] as? [String: Any], "\(e): missing 'session'")
        assertSessionShape(session, endpoint: e)

        // Top-level keys are the hand-assembled camelCase exceptions…
        camel(json, "toolTimeline", .array, endpoint: e)
        camel(json, "swimLanes", .array, endpoint: e)
        assertField(json, "tree", .array, endpoint: e)
        assertField(json, "events", .array, endpoint: e)

        // …while row fields inside stay snake_case (types.ts SessionDrillIn).
        let node = try firstObject(json, "tree", endpoint: e)
        assertField(node, "id", .string, endpoint: e)
        assertField(node, "name", .string, endpoint: e)
        assertField(node, "type", .string, endpoint: e)
        snake(node, "subagent_type", .string, .null, endpoint: e)
        assertField(node, "status", .string, endpoint: e)
        assertField(node, "task", .string, .null, endpoint: e)
        snake(node, "started_at", .string, endpoint: e)
        snake(node, "ended_at", .string, .null, endpoint: e)
        assertField(node, "children", .array, endpoint: e)

        let timelineEntry = try firstObject(json, "toolTimeline", endpoint: e)
        assertField(timelineEntry, "id", .number, endpoint: e)
        snake(timelineEntry, "tool_name", .string, .null, endpoint: e)
        snake(timelineEntry, "event_type", .string, endpoint: e)
        snake(timelineEntry, "agent_id", .string, .null, endpoint: e)
        snake(timelineEntry, "created_at", .string, endpoint: e)
        assertField(timelineEntry, "summary", .string, .null, endpoint: e)

        let lane = try firstObject(json, "swimLanes", endpoint: e)
        assertField(lane, "id", .string, endpoint: e)
        assertField(lane, "name", .string, endpoint: e)
        assertField(lane, "type", .string, endpoint: e)
        snake(lane, "subagent_type", .string, .null, endpoint: e)
        assertField(lane, "status", .string, endpoint: e)
        snake(lane, "started_at", .string, endpoint: e)
        snake(lane, "ended_at", .string, .null, endpoint: e)
        snake(lane, "parent_agent_id", .string, .null, endpoint: e)

        let event = try firstObject(json, "events", endpoint: e)
        assertEventShape(event, endpoint: e)
    }

    // MARK: - /api/run family (the deliberate camelCase "live" family + mixed history)

    private func assertRunHandleShape(_ handle: [String: Any], endpoint: String) {
        assertField(handle, "id", .string, endpoint: endpoint)
        assertField(handle, "pid", .number, .null, endpoint: endpoint)
        assertField(handle, "mode", .string, endpoint: endpoint)
        assertField(handle, "cwd", .string, endpoint: endpoint)
        assertField(handle, "model", .string, .null, endpoint: endpoint)
        camel(handle, "permissionMode", .string, endpoint: endpoint)
        assertField(handle, "effort", .string, .null, endpoint: endpoint)
        assertField(handle, "prompt", .string, endpoint: endpoint)
        assertField(handle, "argv", .array, endpoint: endpoint)
        camel(handle, "resumeSessionId", .string, .null, endpoint: endpoint)
        assertField(handle, "status", .string, endpoint: endpoint)
        camel(handle, "startedAt", .number, endpoint: endpoint)
        camel(handle, "endedAt", .number, .null, endpoint: endpoint)
        camel(handle, "exitCode", .number, .null, endpoint: endpoint)
        assertField(handle, "signal", .string, .null, endpoint: endpoint)
        assertField(handle, "error", .string, .null, endpoint: endpoint)
        camel(handle, "sessionId", .string, .null, endpoint: endpoint)
        camel(handle, "envelopeCount", .number, endpoint: endpoint)
        camel(handle, "stdoutTail", .string, endpoint: endpoint)
        camel(handle, "stderrTail", .string, endpoint: endpoint)
    }

    func testRunFamilyContract() async throws {
        try await bootServer()

        // POST /api/run — response is the initial RunHandle (api.ts RunHandle).
        let startBody = try JSONSerialization.data(withJSONObject: [
            "prompt": "contract check", "mode": "headless", "cwd": tempDir.path,
        ])
        let (createData, createResponse) = try await send("POST", "/api/run", body: startBody)
        XCTAssertEqual(
            createResponse.statusCode, 200,
            "POST /api/run — body: \(String(data: createData, encoding: .utf8) ?? "<non-utf8>")"
        )
        let handle = try XCTUnwrap(try JSONSerialization.jsonObject(with: createData) as? [String: Any])
        assertRunHandleShape(handle, endpoint: "POST /api/run")

        // GET /api/run — RunListResponse {items, maxConcurrent, activeCount}.
        let e = "/api/run"
        let list = try await getJSONObject("/api/run")
        assertField(list, "items", .array, endpoint: e)
        camel(list, "maxConcurrent", .number, endpoint: e)
        camel(list, "activeCount", .number, endpoint: e)
        let listed = try firstObject(list, "items", endpoint: e)
        assertRunHandleShape(listed, endpoint: e)

        // GET /api/run/:id?envelopes=1 — handle + envelopes array.
        let id = try XCTUnwrap(handle["id"] as? String)
        let detail = try await getJSONObject("/api/run/\(id)?envelopes=1")
        assertRunHandleShape(detail, endpoint: "/api/run/:id")
        assertField(detail, "envelopes", .array, endpoint: "/api/run/:id?envelopes=1")

        // GET /api/run/history — DashboardRunHistoryItem: DB snake_case
        // columns + the ONE hand-added camelCase flag `isLive`
        // (api.ts lines 640–655).
        let eh = "/api/run/history"
        let history = try await getJSONObject("/api/run/history?limit=50")
        let item = try firstObject(history, "items", endpoint: eh)
        assertField(item, "id", .string, endpoint: eh)
        snake(item, "session_id", .string, .null, endpoint: eh)
        assertField(item, "mode", .string, endpoint: eh)
        assertField(item, "cwd", .string, endpoint: eh)
        assertField(item, "model", .string, .null, endpoint: eh)
        snake(item, "permission_mode", .string, .null, endpoint: eh)
        assertField(item, "effort", .string, .null, endpoint: eh)
        snake(item, "resume_session_id", .string, .null, endpoint: eh)
        snake(item, "prompt_preview", .string, .null, endpoint: eh)
        assertField(item, "status", .string, endpoint: eh)
        snake(item, "exit_code", .number, .null, endpoint: eh)
        snake(item, "started_at", .string, endpoint: eh)
        snake(item, "ended_at", .string, .null, endpoint: eh)
        camel(item, "isLive", .bool, endpoint: eh)

        // GET /api/run/cwds + /api/run/binary (Run page pickers).
        let cwds = try await getJSONObject("/api/run/cwds")
        assertField(cwds, "items", .array, endpoint: "/api/run/cwds")
        if let suggestion = (cwds["items"] as? [[String: Any]])?.first {
            assertField(suggestion, "kind", .string, endpoint: "/api/run/cwds")
            assertField(suggestion, "path", .string, endpoint: "/api/run/cwds")
            assertField(suggestion, "label", .string, endpoint: "/api/run/cwds")
        }
        let binary = try await getJSONObject("/api/run/binary")
        assertField(binary, "found", .bool, endpoint: "/api/run/binary")
        assertField(binary, "path", .string, .null, endpoint: "/api/run/binary")
    }

    // MARK: - /api/push/vapid-public-key (lib/push.ts line 26: `{ publicKey }`)

    func testPushVapidPublicKeyContract() async throws {
        try await bootServer()
        let e = "/api/push/vapid-public-key"
        let json = try await getJSONObject(e)
        camel(json, "publicKey", .string, endpoint: e)
        XCTAssertFalse((json["publicKey"] as? String ?? "").isEmpty)
    }

    // MARK: - /api/import/guide (api.ts lines 267–279)

    func testImportGuideContract() async throws {
        try await bootServer()
        let e = "/api/import/guide"
        let json = try await getJSONObject(e)
        assertField(json, "platform", .string, endpoint: e)
        snake(json, "default_projects_dir", .string, endpoint: e)
        snake(json, "default_projects_dir_display", .string, endpoint: e)
        snake(json, "default_projects_dir_exists", .bool, endpoint: e)
        snake(json, "archive_command", .string, endpoint: e)
        snake(json, "supported_extensions", .array, endpoint: e)
        snake(json, "max_upload_bytes", .number, endpoint: e)
        snake(json, "max_upload_files", .number, endpoint: e)
        let dirStats = try XCTUnwrap(json["default_projects_dir_stats"] as? [String: Any], "\(e): missing 'default_projects_dir_stats'")
        assertAbsent(json, "defaultProjectsDirStats", endpoint: e)
        assertField(dirStats, "projects", .number, endpoint: e)
        snake(dirStats, "jsonl_files", .number, endpoint: e)
        let step = try firstObject(json, "steps", endpoint: e)
        assertField(step, "id", .string, endpoint: e)
        assertField(step, "title", .string, endpoint: e)
        assertField(step, "body", .string, endpoint: e)
    }

    // MARK: - /api/cc-config family (camelCase exception family — api.ts lines 366–588)

    func testCcConfigOverviewContract() async throws {
        try await bootServer()
        let e = "/api/cc-config/overview"
        let json = try await getJSONObject(e)

        let roots = try XCTUnwrap(json["roots"] as? [String: Any], "\(e): missing 'roots'")
        camel(roots, "claudeHome", .string, endpoint: e)
        camel(roots, "projectClaudeDir", .string, endpoint: e)
        camel(roots, "projectRoot", .string, endpoint: e)
        camel(roots, "claudeJson", .string, endpoint: e)

        let counts = try XCTUnwrap(json["counts"] as? [String: Any], "\(e): missing 'counts'")
        assertField(counts, "skills", .object, endpoint: e)
        assertField(counts, "agents", .object, endpoint: e)
        assertField(counts, "commands", .object, endpoint: e)
        camel(counts, "outputStyles", .object, endpoint: e)
        assertField(counts, "plugins", .number, endpoint: e)
        camel(counts, "pluginsEnabled", .number, endpoint: e)
        camel(counts, "pluginsDisabled", .number, endpoint: e)
        assertField(counts, "marketplaces", .number, endpoint: e)
        assertField(counts, "keybindings", .number, endpoint: e)
        camel(counts, "mcpServers", .object, endpoint: e)
        assertField(counts, "hooks", .object, endpoint: e)
        assertField(counts, "memory", .number, endpoint: e)
        camel(counts, "settingsFiles", .number, endpoint: e)

        let skills = try XCTUnwrap(counts["skills"] as? [String: Any])
        XCTAssertEqual(skills["user"] as? Int, 1, "\(e): fixture seeded exactly one user skill")
        let agents = try XCTUnwrap(counts["agents"] as? [String: Any])
        XCTAssertEqual(agents["user"] as? Int, 1, "\(e): fixture seeded exactly one user agent")
    }

    func testCcConfigPanelsContract() async throws {
        try await bootServer()

        // /skills — CcMdItem-like SkillItem (api.ts lines 401–411).
        let eSkills = "/api/cc-config/skills"
        let skills = try await getJSONObject("\(eSkills)?scope=user")
        let skill = try firstObject(skills, "items", endpoint: eSkills)
        assertField(skill, "scope", .string, endpoint: eSkills)
        assertField(skill, "name", .string, endpoint: eSkills)
        assertField(skill, "path", .string, endpoint: eSkills)
        assertField(skill, "file", .string, endpoint: eSkills)
        assertField(skill, "size", .number, endpoint: eSkills)
        assertField(skill, "mtime", .number, endpoint: eSkills)
        assertField(skill, "truncated", .bool, endpoint: eSkills)
        assertField(skill, "frontmatter", .object, endpoint: eSkills)
        assertField(skill, "preview", .string, endpoint: eSkills)
        XCTAssertEqual(skill["name"] as? String, "demo-skill")

        // /agents — CcMdItem.
        let eAgents = "/api/cc-config/agents"
        let agents = try await getJSONObject("\(eAgents)?scope=user")
        let agent = try firstObject(agents, "items", endpoint: eAgents)
        assertField(agent, "scope", .string, endpoint: eAgents)
        assertField(agent, "name", .string, endpoint: eAgents)
        assertField(agent, "file", .string, endpoint: eAgents)
        assertField(agent, "frontmatter", .object, endpoint: eAgents)
        assertField(agent, "preview", .string, endpoint: eAgents)
        XCTAssertEqual(agent["name"] as? String, "reviewer")
        XCTAssertEqual((agent["frontmatter"] as? [String: Any])?["description"] as? String, "Reviews code")

        // /settings — CcSettingsSource: `raw_size` is snake_case (api.ts line 497).
        let eSettings = "/api/cc-config/settings"
        let settings = try await getJSONObject(eSettings)
        let sources = try XCTUnwrap(settings["items"] as? [[String: Any]], "\(eSettings): missing 'items'")
        let userSource = try XCTUnwrap(sources.first { ($0["scope"] as? String) == "user" })
        assertField(userSource, "scope", .string, endpoint: eSettings)
        assertField(userSource, "file", .string, endpoint: eSettings)
        assertField(userSource, "exists", .bool, endpoint: eSettings)
        XCTAssertEqual(userSource["exists"] as? Bool, true, "\(eSettings): fixture settings.json exists")
        optionalSnake(userSource, "raw_size", .number, endpoint: eSettings)

        // /hooks — CcHookSource with per-event arrays of {matcher,type,command,timeout}.
        let eHooks = "/api/cc-config/hooks"
        let hooks = try await getJSONObject(eHooks)
        let hookSources = try XCTUnwrap(hooks["items"] as? [[String: Any]], "\(eHooks): missing 'items'")
        let userHooks = try XCTUnwrap(hookSources.first { ($0["scope"] as? String) == "user" })
        assertField(userHooks, "scope", .string, endpoint: eHooks)
        assertField(userHooks, "file", .string, endpoint: eHooks)
        assertField(userHooks, "exists", .bool, endpoint: eHooks)
        let hookMap = try XCTUnwrap(userHooks["hooks"] as? [String: Any], "\(eHooks): missing 'hooks' map")
        let preToolUse = try XCTUnwrap(hookMap["PreToolUse"] as? [[String: Any]], "\(eHooks): fixture PreToolUse hook missing")
        let entry = try XCTUnwrap(preToolUse.first)
        assertField(entry, "matcher", .string, endpoint: eHooks)
        assertField(entry, "type", .string, endpoint: eHooks)
        assertField(entry, "command", .string, .null, endpoint: eHooks)
        assertField(entry, "timeout", .number, .null, endpoint: eHooks)

        // /mcp — CcMcpResponse {user, projectScoped} (camelCase!).
        let eMcp = "/api/cc-config/mcp"
        let mcp = try await getJSONObject(eMcp)
        assertField(mcp, "user", .array, endpoint: eMcp)
        camel(mcp, "projectScoped", .array, endpoint: eMcp)
        let server = try firstObject(mcp, "user", endpoint: eMcp)
        assertField(server, "name", .string, endpoint: eMcp)
        assertField(server, "source", .string, endpoint: eMcp)
        assertField(server, "kind", .string, endpoint: eMcp)
        XCTAssertEqual(server["name"] as? String, "demo-mcp")
        XCTAssertEqual(server["kind"] as? String, "stdio")
    }

    // MARK: - /api/updates/status (types.ts UpdateStatusPayload — snake_case)

    func testUpdatesStatusContract() async throws {
        try await bootServer()
        let e = "/api/updates/status"
        let json = try await getJSONObject(e)
        snake(json, "git_repo", .bool, endpoint: e)
        snake(json, "update_available", .bool, endpoint: e)
        // All other fields are optional in types.ts — casing-twin check only.
        for optionalKey in ["repo_root", "remote_ref", "canonical_remote", "current_branch",
                            "tracking_upstream", "tracks_canonical", "situation_note",
                            "local_sha", "remote_sha", "commits_behind", "manual_command",
                            "fetch_error"] {
            assertAbsent(json, camelTwin(optionalKey), endpoint: e)
        }
    }

    // MARK: - /api/diagnostics (Swift-native addition — no client caller;
    // asserted against the Settings-page-facing DiagnosticsResponse wire shape)

    func testDiagnosticsContract() async throws {
        try await bootAndSeed()
        let e = "/api/diagnostics"
        let json = try await getJSONObject(e)
        let server = try XCTUnwrap(json["server"] as? [String: Any], "\(e): missing 'server'")
        snake(server, "uptime_seconds", .number, endpoint: e)
        assertField(server, "platform", .string, endpoint: e)
        snake(server, "cpu_count", .number, endpoint: e)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any], "\(e): missing 'hooks'")
        assertField(hooks, "status", .string, endpoint: e)
        snake(hooks, "last_event_at", .string, .null, endpoint: e)
        snake(hooks, "total_events_processed", .number, endpoint: e)
        snake(hooks, "total_events_failed", .number, endpoint: e)
        assertField(json, "log", .array, endpoint: e)
        XCTAssertEqual(hooks["status"] as? String, "ok", "\(e): seeding posted successful hook events")
    }

    // MARK: - /api/export/session/:id round trip (server-to-server bundle;
    // not called from api.ts — covered because it's cheap and the bundle
    // shape is a documented wire contract: export.js EXPORT_VERSION "1.0")

    func testExportSessionBundleRoundTripContract() async throws {
        try await bootAndSeed()
        let e = "/api/export/session/:id"
        let (bundleData, bundleResponse) = try await get("/api/export/session/\(sessionA)")
        XCTAssertEqual(bundleResponse.statusCode, 200)
        let bundle = try XCTUnwrap(try JSONSerialization.jsonObject(with: bundleData) as? [String: Any])
        snake(bundle, "podium_export_version", .string, endpoint: e)
        snake(bundle, "exported_at", .string, endpoint: e)
        assertField(bundle, "session", .object, endpoint: e)
        assertField(bundle, "agents", .array, endpoint: e)
        assertField(bundle, "events", .array, endpoint: e)
        snake(bundle, "token_usage", .array, endpoint: e)
        XCTAssertEqual(bundle["podium_export_version"] as? String, "1.0")
        let session = try XCTUnwrap(bundle["session"] as? [String: Any])
        assertSessionShape(session, endpoint: e)

        // Round trip: POST the bundle back (idempotent upsert-style import).
        let (importData, importResponse) = try await send("POST", "/api/export/session", body: bundleData)
        XCTAssertEqual(importResponse.statusCode, 200, "POST /api/export/session round trip")
        let importResult = try XCTUnwrap(try JSONSerialization.jsonObject(with: importData) as? [String: Any])
        snake(importResult, "session_id", .string, endpoint: "POST /api/export/session")
        XCTAssertEqual(importResult["session_id"] as? String, sessionA)
    }
}
