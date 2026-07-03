import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P3.3 pricing router (`GET /` · `PUT /` ·
/// `DELETE /:pattern` · `GET /cost` · `GET /cost/:sessionId`). Cost math
/// itself (pattern precedence, cache-rate handling, rounding) is covered at
/// the unit level in `CostCalculatorTests`; this file exercises HTTP status
/// codes, validation, and wiring into `PodiumStore`.
final class PricingRouterTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var app: PodiumServerApp!
    private var serverTask: Task<Void, Error>!
    private var port: Int!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-pricing-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() async throws {
        serverTask?.cancel()
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
            mounts: [PricingRouterMount.self]
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

    // MARK: - GET /

    func testListReturnsSeededDefaultPricing() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/pricing")
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(PricingListResponseFixture.self, from: data)
        XCTAssertEqual(body.pricing.count, Schema.defaultPricing.count)
    }

    // MARK: - PUT /

    func testPutUpsertsNewRuleAndDefaultsMissingRatesToZero() async throws {
        try await bootServer()
        let payload = Data("""
        {"model_pattern":"my-custom-model%","display_name":"My Custom Model"}
        """.utf8)
        let (data, response) = try await send("PUT", "/api/pricing", body: payload)
        XCTAssertEqual(response.statusCode, 200)

        let body = try PodiumJSON.decoder.decode(PricingPutResponseFixture.self, from: data)
        XCTAssertEqual(body.pricing.modelPattern, "my-custom-model%")
        XCTAssertEqual(body.pricing.inputPerMtok, 0)
        XCTAssertEqual(body.pricing.outputPerMtok, 0)

        let persisted = try store.getPricing(pattern: "my-custom-model%")
        XCTAssertNotNil(persisted)
    }

    func testPutRejectsMissingRequiredFields() async throws {
        try await bootServer()
        let payload = Data("""
        {"display_name":"Missing pattern"}
        """.utf8)
        let (data, response) = try await send("PUT", "/api/pricing", body: payload)
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }

    // MARK: - DELETE /:pattern

    func testDeleteRemovesExistingRule() async throws {
        try await bootServer()
        let (_, deleteResponse) = try await send("DELETE", "/api/pricing/claude-opus-4-5%25")
        XCTAssertEqual(deleteResponse.statusCode, 200)
        XCTAssertNil(try store.getPricing(pattern: "claude-opus-4-5%"))
    }

    func testDeleteUnknownPatternReturns404() async throws {
        try await bootServer()
        let (data, response) = try await send("DELETE", "/api/pricing/does-not-exist%25")
        XCTAssertEqual(response.statusCode, 404)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "NOT_FOUND")
    }

    // MARK: - GET /cost

    func testGlobalCostAggregatesAcrossSessions() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s2", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5-20250101", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        try store.upsertTokenUsage(sessionId: "s2", model: "claude-opus-4-5-20250101", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        try await bootServer()
        let (data, response) = try await get("/api/pricing/cost")
        XCTAssertEqual(response.statusCode, 200)

        let result = try PodiumJSON.decoder.decode(CostResult.self, from: data)
        // Default seed: claude-opus-4-5% = $5/Mtok input. 2M input tokens total = $10.
        XCTAssertEqual(result.totalCost, 10.0, accuracy: 1e-9)
    }

    // MARK: - GET /cost/:sessionId

    func testSessionCostNeverReturns404ForMissingSession() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/pricing/cost/does-not-exist")
        XCTAssertEqual(response.statusCode, 200)
        let result = try PodiumJSON.decoder.decode(CostResult.self, from: data)
        XCTAssertEqual(result.totalCost, 0)
        XCTAssertEqual(result.dailyCosts, [])
    }

    func testSessionCostReturnsSingleDayEntry() async throws {
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.upsertTokenUsage(sessionId: "s1", model: "claude-opus-4-5-20250101", inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

        try await bootServer()
        let (data, response) = try await get("/api/pricing/cost/s1")
        XCTAssertEqual(response.statusCode, 200)
        let result = try PodiumJSON.decoder.decode(CostResult.self, from: data)
        XCTAssertEqual(result.totalCost, 5.0, accuracy: 1e-9)
        XCTAssertEqual(result.dailyCosts.count, 1)
    }
}

private struct PricingListResponseFixture: Decodable {
    let pricing: [ModelPricing]
}

private struct PricingPutResponseFixture: Decodable {
    let pricing: ModelPricing
}
