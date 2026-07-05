import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of P3.1's transcript endpoints
/// (`GET /api/sessions/:id/transcripts` and `GET /api/sessions/:id/transcript`)
/// against hand-written JSONL fixtures under a sandboxed fake `CLAUDE_HOME` —
/// a main transcript with multi-model usage + a compaction marker, plus a
/// subagent "sidechain" transcript — matched against `agents` DB rows.
/// Follows the same boot pattern as `ReadRoutersTests` (P2.2).
final class TranscriptRouterTests: XCTestCase {
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
    private var claudeHome: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!

    private let cwd = "/Users/gael/fixture-project"
    private let sessionId = "sess-transcript-fixture"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-transcript-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        claudeHome = tempDir.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": claudeHome.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDir.appendingPathComponent("data").path]
        ClaudeHome.resetOverrideCacheForTesting()

        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() async throws {
        serverTask?.cancel()
        _ = await serverTask?.result
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func bootServer() async throws {
        let candidatePort = Int.random(in: 21000..<39000)
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)

        app = PodiumServerApp(
            store: store, port: candidatePort, webDistDirectory: dist.path,
            mounts: [SessionsRouterMount.self]
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

    // MARK: - Fixture assembly

    private func writeMainTranscript(at path: URL) throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-07-03T10:00:00.000Z","message":{"content":"Fix the flaky test"}}"#,
            """
            {"type":"assistant","timestamp":"2026-07-03T10:00:05.000Z","message":{"model":"claude-sonnet-4-5","content":[{"type":"thinking","thinking":"Let me look at the test file first."},{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"/tmp/test.swift"}}],"usage":{"input_tokens":500,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """,
            #"{"type":"user","timestamp":"2026-07-03T10:00:06.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file contents here","is_error":false}]}}"#,
            // Second model mid-session (multi-model usage).
            """
            {"type":"assistant","timestamp":"2026-07-03T10:05:00.000Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Found the race condition."}],"usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}
            """,
            // Compaction marker.
            #"{"isCompactSummary":true,"uuid":"compact-uuid-1","timestamp":"2026-07-03T10:10:00.000Z"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func writeSubagentTranscript(at path: URL) throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-07-03T10:01:00.000Z","message":{"content":"Investigate flaky test root cause"}}"#,
            """
            {"type":"assistant","timestamp":"2026-07-03T10:01:10.000Z","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"It's a shared mutable timer."}],"usage":{"input_tokens":200,"output_tokens":40}}}
            """,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    /// Sets up: a session with `cwd`, a main transcript (multi-model usage +
    /// a compaction marker), one subagent "sidechain" transcript with its
    /// matching `agents` row, and the main/compaction `agents` rows.
    private func seedFixture() throws {
        try store.insertSession(id: sessionId, name: "Fixture session", status: .active, cwd: cwd, model: "claude-sonnet-4-5", metadata: nil)
        try store.insertAgent(
            id: "\(sessionId)-main", sessionId: sessionId, name: "Main", type: .main, subagentType: nil,
            status: .working, task: nil, parentAgentId: nil, metadata: nil
        )
        try store.insertAgent(
            id: "sub-1", sessionId: sessionId, name: "general-purpose", type: .subagent, subagentType: "general-purpose",
            status: .completed, task: "Investigate flaky test", parentAgentId: "\(sessionId)-main", metadata: nil
        )
        try store.insertAgent(
            id: "compact-1", sessionId: sessionId, name: "Context Compaction", type: .subagent, subagentType: "compaction",
            status: .completed, task: "Automatic conversation context compression", parentAgentId: "\(sessionId)-main", metadata: nil
        )

        let encoded = ClaudeHome.encodeCwd(cwd)
        let projectDir = claudeHome.appendingPathComponent("projects").appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try writeMainTranscript(at: projectDir.appendingPathComponent("\(sessionId).jsonl"))

        let subagentsDir = projectDir.appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try writeSubagentTranscript(at: subagentsDir.appendingPathComponent("agent-shortid1.jsonl"))
        let meta = #"{"agentType":"general-purpose","description":"Investigate flaky test"}"#
        try meta.write(to: subagentsDir.appendingPathComponent("agent-shortid1.meta.json"), atomically: true, encoding: .utf8)

        // Compaction transcript file (no meta.json — matches by "compaction" type key).
        try writeSubagentTranscript(at: subagentsDir.appendingPathComponent("agent-acompact-uuid1.jsonl"))
    }

    // MARK: - GET /:id/transcripts

    func testTranscriptsListsMainSubagentAndCompactionMatchedToDbAgents() async throws {
        try seedFixture()
        try await bootServer()

        let (data, response) = try await get("/api/sessions/\(sessionId)/transcripts")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(TranscriptListResult.self, from: data)

        XCTAssertEqual(decoded.transcripts.count, 3)
        XCTAssertEqual(decoded.transcripts.first?.id, "main")
        XCTAssertEqual(decoded.transcripts.first?.dbAgentId, "\(sessionId)-main")

        let subagentEntry = try XCTUnwrap(decoded.transcripts.first { $0.type == "subagent" })
        XCTAssertEqual(subagentEntry.id, "shortid1")
        XCTAssertEqual(subagentEntry.name, "Investigate flaky test")
        XCTAssertEqual(subagentEntry.subagentType, "general-purpose")
        XCTAssertEqual(subagentEntry.dbAgentId, "sub-1")

        let compactionEntry = try XCTUnwrap(decoded.transcripts.first { $0.type == "compaction" })
        XCTAssertEqual(compactionEntry.id, "acompact-uuid1")
        XCTAssertEqual(compactionEntry.name, "Context Compaction")
        XCTAssertEqual(compactionEntry.dbAgentId, "compact-1")
    }

    func testTranscriptsReturns404ForUnknownSession() async throws {
        try await bootServer()
        let (_, response) = try await get("/api/sessions/does-not-exist/transcripts")
        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - GET /:id/transcript

    func testTranscriptParsesMainConversationWithMultiModelUsageAndTruncatesToDisplayableBlocks() async throws {
        try seedFixture()
        try await bootServer()

        let (data, response) = try await get("/api/sessions/\(sessionId)/transcript")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(TranscriptResult.self, from: data)

        // 3 displayable messages: user prompt, assistant (thinking + tool_use),
        // user tool_result. The bare compaction-marker line has no
        // user/assistant type and is excluded entirely.
        XCTAssertEqual(decoded.messages.count, 4)
        XCTAssertEqual(decoded.total, 4)
        XCTAssertFalse(decoded.hasMore)

        let firstMessage = try XCTUnwrap(decoded.messages.first)
        XCTAssertEqual(firstMessage.type, "user")
        XCTAssertEqual(firstMessage.content.first?.text, "Fix the flaky test")

        let assistantMessage = try XCTUnwrap(decoded.messages.first { $0.type == "assistant" && $0.model == "claude-sonnet-4-5" })
        XCTAssertTrue(assistantMessage.content.contains { $0.type == "thinking" })
        XCTAssertTrue(assistantMessage.content.contains { $0.type == "tool_use" && $0.name == "Read" })
        XCTAssertEqual(assistantMessage.usage?.inputTokens, 500)

        let secondModelMessage = try XCTUnwrap(decoded.messages.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(secondModelMessage.usage?.cacheReadInputTokens, 100)
    }

    func testTranscriptWithAgentIdReadsSubagentSidechain() async throws {
        try seedFixture()
        try await bootServer()

        let (data, response) = try await get("/api/sessions/\(sessionId)/transcript?agent_id=shortid1")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(TranscriptResult.self, from: data)

        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.messages.first?.content.first?.text, "Investigate flaky test root cause")
        let assistantMessage = try XCTUnwrap(decoded.messages.first { $0.type == "assistant" })
        XCTAssertEqual(assistantMessage.model, "claude-sonnet-4-5")
    }

    func testTranscriptDefaultModeReturnsLatestNWithHasMoreWhenOlderHistoryExists() async throws {
        try seedFixture()
        try await bootServer()

        let (data, _) = try await get("/api/sessions/\(sessionId)/transcript?limit=1")
        let page = try PodiumJSON.decoder.decode(TranscriptResult.self, from: data)
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertTrue(page.hasMore)
        // The single kept message is the chronologically LATEST one (the
        // second-model assistant turn), matching the sliding-window
        // "keep the tail" semantics.
        XCTAssertEqual(page.messages.first?.model, "claude-opus-4-8")
    }

    func testTranscriptBeforeCursorReturnsOlderHistoryAheadOfTheWindow() async throws {
        try seedFixture()
        try await bootServer()

        let (firstPageData, _) = try await get("/api/sessions/\(sessionId)/transcript?limit=1")
        let firstPage = try PodiumJSON.decoder.decode(TranscriptResult.self, from: firstPageData)

        let (olderData, _) = try await get("/api/sessions/\(sessionId)/transcript?limit=50&before=\(firstPage.firstLine)")
        let older = try PodiumJSON.decoder.decode(TranscriptResult.self, from: olderData)
        XCTAssertEqual(older.messages.count, 3)
        XCTAssertFalse(older.hasMore)
        XCTAssertEqual(older.messages.first?.content.first?.text, "Fix the flaky test")
    }

    func testTranscriptAfterCursorReturnsNewerMessagesPastTheGivenLine() async throws {
        try seedFixture()
        try await bootServer()

        let (data, _) = try await get("/api/sessions/\(sessionId)/transcript?limit=50&after=1")
        let page = try PodiumJSON.decoder.decode(TranscriptResult.self, from: data)
        XCTAssertEqual(page.messages.count, 3)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.messages.last?.model, "claude-opus-4-8")
    }

    func testTranscriptReturns404ForUnknownSession() async throws {
        try await bootServer()
        let (_, response) = try await get("/api/sessions/does-not-exist/transcript")
        XCTAssertEqual(response.statusCode, 404)
    }
}
