import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P3.3 settings router (`GET /info`,
/// `POST /clear-data`, `POST /reimport`, `POST /reinstall-hooks`,
/// `POST /reset-pricing`, `GET /export`, `GET/PUT /claude-home`,
/// `POST /cleanup`). Follows the same boot-a-real-server pattern as
/// `ReadRoutersTests`/`WorkflowsRouterTests`.
final class SettingsRouterTests: XCTestCase {
    private var tempDir: URL!
    private var tempHome: URL!
    private var tempDataDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-settings-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)

        // Isolate ClaudeHome/HookInstaller from the real ~/.claude and the
        // shared PodiumPaths data dir — same pattern as ClaudeHomeTests —
        // so GET /info's hook-status probe and PUT /claude-home's override
        // persistence never touch real machine state.
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-settings-router-claude-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        tempDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-settings-router-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": tempHome.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDataDir.path]
        ClaudeHome.resetOverrideCacheForTesting()
    }

    override func tearDown() async throws {
        serverTask?.cancel()
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: tempHome)
        try? FileManager.default.removeItem(at: tempDataDir)
    }

    private func bootServer() async throws {
        let candidatePort = Int.random(in: 21000..<39000)
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)

        app = PodiumServerApp(
            store: store,
            port: candidatePort,
            webDistDirectory: dist.path,
            mounts: [SettingsRouterMount.self]
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

    private func send(_ method: String, _ path: String, body: Data = Data()) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - GET /info

    func testInfoReportsDbCountsPragmasAndHookStatus() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "tool_use", toolName: nil, summary: nil, data: nil)

        try await bootServer()
        let (data, response) = try await get("/api/settings/info")
        XCTAssertEqual(response.statusCode, 200)

        let info = try PodiumJSON.decoder.decode(SettingsInfoResponse.self, from: data)
        XCTAssertEqual(info.db.counts["sessions"], 1)
        XCTAssertEqual(info.db.counts["events"], 1)
        XCTAssertEqual(info.db.counts["model_pricing"], Schema.defaultPricing.count)
        XCTAssertEqual(info.db.pragmas.foreignKeys, 1)
        XCTAssertGreaterThan(info.db.size, 0)
        XCTAssertEqual(info.db.loadStats.m5, 1)
        // No hooks installed in a fresh test HOME — every hook type false.
        XCTAssertFalse(info.hooks.installed)
        XCTAssertEqual(info.hooks.hooks.count, HookInstaller.hookEvents.count)
        XCTAssertGreaterThan(info.server.cpus, 0)
        XCTAssertGreaterThan(info.server.totalMem, 0)
    }

    // MARK: - POST /clear-data

    func testClearDataWipesSessionsButKeepsPricing() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)

        try await bootServer()
        let (data, response) = try await send("POST", "/api/settings/clear-data")
        XCTAssertEqual(response.statusCode, 200)

        let body = try PodiumJSON.decoder.decode(ClearDataResponse.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.cleared["sessions"], 1)
        XCTAssertEqual(try store.listSessions(limit: 10, offset: 0).count, 0)
        XCTAssertEqual(try store.listPricing().count, Schema.defaultPricing.count)
    }

    // MARK: - POST /reimport (unconfigured seam)

    func testReimportWithoutConfiguredRunnerReturns503NotImplemented() async throws {
        try await bootServer()
        let (data, response) = try await send("POST", "/api/settings/reimport")
        XCTAssertEqual(response.statusCode, 503)

        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "NOT_IMPLEMENTED")
    }

    // MARK: - POST /reset-pricing

    func testResetPricingRestoresDefaultsAfterUserEdit() async throws {
        try store.upsertPricing(PricingPutRequest(modelPattern: "claude-opus-4-5%", displayName: "Edited", inputPerMtok: 999, outputPerMtok: 999, cacheReadPerMtok: 999, cacheWritePerMtok: 999))

        try await bootServer()
        let (data, response) = try await send("POST", "/api/settings/reset-pricing")
        XCTAssertEqual(response.statusCode, 200)

        let body = try PodiumJSON.decoder.decode(ResetPricingResponse.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.pricing.count, Schema.defaultPricing.count)
        XCTAssertEqual(body.pricing.first { $0.modelPattern == "claude-opus-4-5%" }?.displayName, "Claude Opus 4.5")
    }

    // MARK: - GET /export

    func testExportReturnsAllTablesWithDownloadHeader() async throws {
        try store.insertSession(id: "s1", name: "My Session", status: .active, cwd: nil, model: nil, metadata: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5", inputTokens: 10, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)

        try await bootServer()
        let (data, response) = try await get("/api/settings/export")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue((response.value(forHTTPHeaderField: "Content-Disposition") ?? "").contains("attachment"))
        XCTAssertTrue((response.value(forHTTPHeaderField: "Content-Disposition") ?? "").contains(".json"))

        let body = try PodiumJSON.decoder.decode(ExportResponse.self, from: data)
        XCTAssertEqual(body.sessions.count, 1)
        XCTAssertEqual(body.tokenUsage.count, 1)
        XCTAssertEqual(body.modelPricing.count, Schema.defaultPricing.count)
    }

    // MARK: - GET/PUT /claude-home

    func testGetClaudeHomeReturnsCurrentPath() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/settings/claude-home")
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(ClaudeHomeResponse.self, from: data)
        XCTAssertFalse(body.claudeHome.isEmpty)
    }

    func testPutClaudeHomeRejectsMissingPath() async throws {
        try await bootServer()
        let (data, response) = try await send("PUT", "/api/settings/claude-home", body: Data("{}".utf8))
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_PATH")
    }

    func testPutClaudeHomeUpdatesToValidDirectory() async throws {
        let newHome = tempDir.appendingPathComponent("alt-claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)

        try await bootServer()
        let payload = try PodiumJSON.encoder.encode(ClaudeHomePutRequest(path: newHome.path))
        let (data, response) = try await send("PUT", "/api/settings/claude-home", body: payload)
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(ClaudeHomePutResponse.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.claudeHome, newHome.path)
        XCTAssertEqual(ClaudeHome.current(), newHome.path)
    }

    // MARK: - POST /cleanup

    func testCleanupAbandonsStaleSessionsOverHttp() async throws {
        try store.insertSession(id: "stale", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.db.run("UPDATE sessions SET started_at = ? WHERE id = ?", [.text("2020-01-01T00:00:00.000Z"), .text("stale")])

        try await bootServer()
        let payload = try PodiumJSON.encoder.encode(CleanupRequest(abandonHours: 1, purgeDays: nil))
        let (data, response) = try await send("POST", "/api/settings/cleanup", body: payload)
        XCTAssertEqual(response.statusCode, 200)

        let body = try PodiumJSON.decoder.decode(CleanupResponse.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.abandoned, 1)
        XCTAssertEqual(try store.getSession(id: "stale")?.status.knownValue, .abandoned)
    }
}
