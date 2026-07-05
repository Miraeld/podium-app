import XCTest
import Crypto
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-level coverage of the P4.2 push router (`GET /vapid-public-key` ·
/// `POST/DELETE /subscribe` · `POST /send`). Uses a `StubWebPushTransport`
/// so no real network call ever happens and a `NoOpNativeNotifier` so no
/// real OS notification is shown — every `PushService` in this file also
/// points `keysPath` at a throwaway temp file, NEVER the user's real
/// `~/.claude/podium/data/vapid-keys.json` (STANDALONE_PLAN.md §7 quirk).
final class PushRouterTests: XCTestCase {
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
    private var transport: StubWebPushTransport!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-push-router-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
        transport = StubWebPushTransport()
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

        let pushService = PushService(
            store: store,
            keysPath: tempDir.appendingPathComponent("vapid-keys.json"),
            subject: "mailto:test@example.com",
            transport: transport,
            nativeNotifier: NoOpNativeNotifier()
        )

        app = PodiumServerApp(
            store: store,
            port: candidatePort,
            webDistDirectory: dist.path,
            mounts: [PushRouterMount.self],
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

    private func send(_ method: String, _ path: String, body: Data = Data()) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    /// Valid RFC 8291-shaped p256dh/auth values so `WebPushEncryptor` doesn't
    /// reject them before the stub transport is even reached.
    private func validSubscriptionBody(endpoint: String) -> Data {
        let receiverKey = P256KeyPairFixture.generate()
        let payload: [String: Any] = [
            "endpoint": endpoint,
            "keys": ["p256dh": receiverKey.publicKeyBase64URL, "auth": receiverKey.authBase64URL],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - GET /vapid-public-key

    func testVapidPublicKeyReturnsBase64URLEncodedP256Point() async throws {
        try await bootServer()
        let (data, response) = try await get("/api/push/vapid-public-key")
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(VapidPublicKeyResponse.self, from: data)
        XCTAssertFalse(body.publicKey.isEmpty)
        XCTAssertEqual(Base64URL.decode(body.publicKey)?.count, 65)
    }

    // MARK: - POST /subscribe

    func testSubscribeUpsertsSubscription() async throws {
        try await bootServer()
        let endpoint = "https://push.example.net/push/abc123"
        let (data, response) = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: endpoint))
        XCTAssertEqual(response.statusCode, 200)
        let body = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(body["ok"], true)

        let stored = try store.listPushSubscriptions()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.endpoint, endpoint)
    }

    func testSubscribeRejectsMissingFields() async throws {
        try await bootServer()
        let payload = Data("""
        {"endpoint":"https://push.example.net/push/abc123"}
        """.utf8)
        let (data, response) = try await send("POST", "/api/push/subscribe", body: payload)
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }

    func testResubscribingSameEndpointReplacesKeys() async throws {
        try await bootServer()
        let endpoint = "https://push.example.net/push/abc123"
        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: endpoint))
        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: endpoint))

        let stored = try store.listPushSubscriptions()
        XCTAssertEqual(stored.count, 1, "re-subscribing the same endpoint must upsert, not duplicate")
    }

    // MARK: - DELETE /subscribe

    func testUnsubscribeRemovesSubscription() async throws {
        try await bootServer()
        let endpoint = "https://push.example.net/push/abc123"
        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: endpoint))
        XCTAssertEqual(try store.listPushSubscriptions().count, 1)

        let unsubBody = Data("{\"endpoint\":\"\(endpoint)\"}".utf8)
        let (data, response) = try await send("DELETE", "/api/push/subscribe", body: unsubBody)
        XCTAssertEqual(response.statusCode, 200)
        let body = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(body["ok"], true)
        XCTAssertEqual(try store.listPushSubscriptions().count, 0)
    }

    func testUnsubscribeRejectsMissingEndpoint() async throws {
        try await bootServer()
        let (data, response) = try await send("DELETE", "/api/push/subscribe", body: Data("{}".utf8))
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }

    // MARK: - POST /send

    func testSendRejectsMissingTitleOrBody() async throws {
        try await bootServer()
        let (data, response) = try await send("POST", "/api/push/send", body: Data("{\"title\":\"only title\"}".utf8))
        XCTAssertEqual(response.statusCode, 400)
        let body = try JSONDecoder().decode([String: [String: String]].self, from: data)
        XCTAssertEqual(body["error"]?["code"], "INVALID_INPUT")
    }

    func testSendWithNoSubscriptionsReturnsZeroPushedAndFailed() async throws {
        try await bootServer()
        let payload = Data("""
        {"title":"Hello","body":"World"}
        """.utf8)
        let (data, response) = try await send("POST", "/api/push/send", body: payload)
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(PushSendResult.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.pushed, 0)
        XCTAssertEqual(body.failed, 0)
    }

    func testSendDeliversToEverySubscriptionViaStubTransport() async throws {
        try await bootServer()
        await transport.setResponseStatusCode(201)

        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: "https://push.example.net/push/one"))
        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: "https://push.example.net/push/two"))

        let payload = Data("""
        {"title":"Session completed","body":"\\"my-session\\" finished."}
        """.utf8)
        let (data, response) = try await send("POST", "/api/push/send", body: payload)
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(PushSendResult.self, from: data)
        XCTAssertTrue(body.ok)
        XCTAssertEqual(body.pushed, 2)
        XCTAssertEqual(body.failed, 0)

        let sentRequests = await transport.sentRequests
        XCTAssertEqual(sentRequests.count, 2)
        for request in sentRequests {
            XCTAssertEqual(request.headers["Content-Encoding"], "aes128gcm")
            XCTAssertEqual(request.headers["Content-Type"], "application/octet-stream")
            XCTAssertTrue(request.headers["Authorization"]?.hasPrefix("vapid t=") ?? false)
        }
        // Every subscription must still be present — no pruning on success.
        XCTAssertEqual(try store.listPushSubscriptions().count, 2)
    }

    func test404FromTransportPrunesSubscription() async throws {
        try await bootServer()
        await transport.setResponseStatusCode(404)

        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: "https://push.example.net/push/gone"))
        XCTAssertEqual(try store.listPushSubscriptions().count, 1)

        let payload = Data("""
        {"title":"Hi","body":"there"}
        """.utf8)
        let (data, response) = try await send("POST", "/api/push/send", body: payload)
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(PushSendResult.self, from: data)
        XCTAssertEqual(body.pushed, 0)
        XCTAssertEqual(body.failed, 1)

        XCTAssertEqual(try store.listPushSubscriptions().count, 0, "a 404 response must prune the dead subscription")
    }

    func test410FromTransportPrunesSubscription() async throws {
        try await bootServer()
        await transport.setResponseStatusCode(410)

        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: "https://push.example.net/push/expired"))
        XCTAssertEqual(try store.listPushSubscriptions().count, 1)

        let payload = Data("""
        {"title":"Hi","body":"there"}
        """.utf8)
        _ = try await send("POST", "/api/push/send", body: payload)

        XCTAssertEqual(try store.listPushSubscriptions().count, 0, "a 410 response must prune the gone subscription")
    }

    func testNonPruningFailureStatusKeepsSubscription() async throws {
        try await bootServer()
        await transport.setResponseStatusCode(500)

        _ = try await send("POST", "/api/push/subscribe", body: validSubscriptionBody(endpoint: "https://push.example.net/push/temp-failure"))

        let payload = Data("""
        {"title":"Hi","body":"there"}
        """.utf8)
        let (data, response) = try await send("POST", "/api/push/send", body: payload)
        XCTAssertEqual(response.statusCode, 200)
        let body = try PodiumJSON.decoder.decode(PushSendResult.self, from: data)
        XCTAssertEqual(body.failed, 1)

        XCTAssertEqual(try store.listPushSubscriptions().count, 1, "a transient 5xx must NOT prune the subscription")
    }
}

// MARK: - Test doubles

/// Captures every outgoing `WebPushRequest` and returns a configurable
/// status code, instead of making a real HTTPS call — the P4.2 acceptance
/// bar requires push tests never hit the network for real.
actor StubWebPushTransport: WebPushTransport {
    private var responseStatusCode = 201
    private(set) var sentRequests: [WebPushRequest] = []

    func setResponseStatusCode(_ code: Int) {
        responseStatusCode = code
    }

    func send(_ request: WebPushRequest) async throws -> WebPushTransportResponse {
        sentRequests.append(request)
        return WebPushTransportResponse(statusCode: responseStatusCode)
    }
}

/// Generates a fresh P-256 key pair + random auth secret in the exact
/// base64url shape a browser's `PushSubscription.toJSON()` would send —
/// used so `/subscribe` request bodies pass `WebPushEncryptor`'s validation
/// (a real 65-byte uncompressed point + >=16-byte auth secret).
enum P256KeyPairFixture {
    struct Fixture {
        let publicKeyBase64URL: String
        let authBase64URL: String
    }

    static func generate() -> Fixture {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let auth = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return Fixture(
            publicKeyBase64URL: Base64URL.encode(privateKey.publicKey.x963Representation),
            authBase64URL: Base64URL.encode(auth)
        )
    }
}
