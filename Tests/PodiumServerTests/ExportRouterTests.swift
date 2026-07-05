import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P4.3 export/import routers (`GET
/// /api/export/session/:id`, `POST /api/export/session`, `POST
/// /api/import/session`) — port of dashboard/server/routes/export.js.
/// Follows the same boot-a-real-server pattern as `SettingsRouterTests`.
final class ExportRouterTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-export-router-tests-\(UUID().uuidString)", isDirectory: true)
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
            mounts: [ExportRouterMount.self]
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

    private func post(_ path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    /// Seeds one session with an agent, two events, and token usage — enough
    /// surface area to prove a round trip preserves every table.
    @discardableResult
    private func seedSession(id: String) throws -> Session {
        try store.insertSession(id: id, name: "Round Trip Session", status: .completed, cwd: "/tmp/proj", model: "claude-opus-4-5", metadata: nil)
        try store.insertAgent(id: "\(id)-main", sessionId: id, name: "main", type: .main, subagentType: nil, status: .completed, task: nil, parentAgentId: nil, metadata: nil)
        _ = try store.insertEvent(sessionId: id, agentId: "\(id)-main", eventType: "PreToolUse", toolName: "Bash", summary: "ran a command", data: "{\"cmd\":\"ls\"}")
        _ = try store.insertEvent(sessionId: id, agentId: "\(id)-main", eventType: "PostToolUse", toolName: "Bash", summary: "command finished", data: nil)
        try store.upsertTokenUsage(sessionId: id, model: "claude-opus-4-5", inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheWriteTokens: 5)
        return try store.getSession(id: id)!
    }

    // MARK: - GET /api/export/session/:id

    func testExportSessionReturns404ForUnknownId() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/export/session/does-not-exist")
        XCTAssertEqual(response.statusCode, 404)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "NOT_FOUND")
    }

    func testExportSessionReturnsFullBundleWithDownloadHeader() async throws {
        try seedSession(id: "sess-export-1")
        try await bootServer()

        let (data, response) = try await get("/api/export/session/sess-export-1")
        XCTAssertEqual(response.statusCode, 200)
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        XCTAssertTrue(disposition.contains("attachment"))
        XCTAssertTrue(disposition.contains("podium-session-sess-exp"))

        let bundle = try PodiumJSON.decoder.decode(SessionExportBundle.self, from: data)
        XCTAssertEqual(bundle.podiumExportVersion, SessionExportBundle.currentVersion)
        XCTAssertEqual(bundle.session.id, "sess-export-1")
        XCTAssertEqual(bundle.agents.count, 1)
        XCTAssertEqual(bundle.events.count, 2)
        XCTAssertEqual(bundle.tokenUsage.count, 1)
        // export.js orders events ASC by created_at — PreToolUse was inserted first.
        XCTAssertEqual(bundle.events.first?.eventType, "PreToolUse")
    }

    // MARK: - POST /api/export/session · POST /api/import/session — round trip

    func testExportThenImportRoundTripPreservesAllRows() async throws {
        try seedSession(id: "sess-roundtrip")
        try await bootServer()

        let (exportData, exportResponse) = try await get("/api/export/session/sess-roundtrip")
        XCTAssertEqual(exportResponse.statusCode, 200)

        // Wipe the session's rows to prove the import actually recreates them
        // (not just a no-op against still-present data).
        _ = try store.db.run("DELETE FROM events WHERE session_id = ?", [.text("sess-roundtrip")])
        _ = try store.db.run("DELETE FROM agents WHERE session_id = ?", [.text("sess-roundtrip")])
        _ = try store.db.run("DELETE FROM token_usage WHERE session_id = ?", [.text("sess-roundtrip")])
        _ = try store.db.run("DELETE FROM sessions WHERE id = ?", [.text("sess-roundtrip")])
        XCTAssertNil(try store.getSession(id: "sess-roundtrip"))

        // POST /api/import/session
        let (importData, importResponse) = try await post("/api/import/session", body: exportData)
        XCTAssertEqual(importResponse.statusCode, 200)
        let importResult = try PodiumJSON.decoder.decode(SessionImportResult.self, from: importData)
        XCTAssertTrue(importResult.ok)
        XCTAssertEqual(importResult.sessionId, "sess-roundtrip")

        let restored = try store.getSession(id: "sess-roundtrip")
        XCTAssertEqual(restored?.name, "Round Trip Session")
        XCTAssertEqual(try store.listAgentsBySession(sessionId: "sess-roundtrip").count, 1)
        XCTAssertEqual(try store.listEventsBySession(sessionId: "sess-roundtrip").count, 2)

        // Re-import (idempotency: OR IGNORE / OR REPLACE, never duplicates or throws).
        let (_, secondImportResponse) = try await post("/api/import/session", body: exportData)
        XCTAssertEqual(secondImportResponse.statusCode, 200)
        XCTAssertEqual(try store.listEventsBySession(sessionId: "sess-roundtrip").count, 2)
    }

    func testExportRouterAlsoReachableUnderApiExportSessionPath() async throws {
        // Node mounts the same export.js router at BOTH /api/import and
        // /api/export (index.js lines 79 & 83) — POST /api/export/session
        // must work exactly like POST /api/import/session.
        try seedSession(id: "sess-both-mounts")
        try await bootServer()
        let (exportData, _) = try await get("/api/export/session/sess-both-mounts")

        let (data, response) = try await post("/api/export/session", body: exportData)
        XCTAssertEqual(response.statusCode, 200)
        let result = try PodiumJSON.decoder.decode(SessionImportResult.self, from: data)
        XCTAssertEqual(result.sessionId, "sess-both-mounts")
    }

    // MARK: - Import validation

    func testImportRejectsWrongVersion() async throws {
        try await bootServer()
        let badBundle = Data("""
        {"podium_export_version":"9.9","session":{"id":"whatever","status":"active","started_at":"2024-01-01T00:00:00.000Z"}}
        """.utf8)
        let (data, response) = try await post("/api/import/session", body: badBundle)
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "UNSUPPORTED_VERSION")
    }

    func testImportRejectsMissingSession() async throws {
        try await bootServer()
        let badBundle = Data("""
        {"podium_export_version":"1.0"}
        """.utf8)
        let (data, response) = try await post("/api/import/session", body: badBundle)
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }

    func testImportRejectsNonObjectBody() async throws {
        try await bootServer()
        let (data, response) = try await post("/api/import/session", body: Data("[1,2,3]".utf8))
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }
}
