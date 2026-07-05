import XCTest
import PodiumCore
@testable import PodiumServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Boots a real `PodiumServerApp` against a temp data dir + free port for
/// each test, and tears it down afterwards. Uses `URLSession`/
/// `URLSessionWebSocketTask` against the live loopback server rather than
/// Hummingbird's in-process test client, so the WebSocket-upgrade channel
/// builder (`.http1WebSocketUpgrade`) — which the app actually uses in
/// production — is exercised end-to-end.
final class PodiumServerAppTests: XCTestCase {
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
    private var runTask: Task<Void, Error>!
    private var port: Int!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() async throws {
        runTask?.cancel()
        _ = await runTask?.result
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Boots the app on a random high port (to avoid clashing with a real
    /// running Podium server or other parallel test runs) with an empty
    /// `WebClient/dist` fixture, and waits for `/api/health` to respond.
    @discardableResult
    private func bootServer(webDist: String? = nil) async throws -> Int {
        let candidatePort = Int.random(in: 20000..<40000)
        let dist = webDist ?? makeEmptyDistFixture()

        runTask = Task {
            try await PodiumServerLifecycle.run(
                store: store,
                startPort: candidatePort,
                webDistDirectory: dist,
                services: [] // no-op: background services are out of scope for this task's tests
            )
        }

        let resolvedPort = try await waitForHealth(startingAt: candidatePort)
        self.port = resolvedPort
        return resolvedPort
    }

    /// Polls `/api/health` on `startPort` (and a few ports above it, in case
    /// the OS happened to have that exact port busy and fallback kicked in)
    /// until it responds or a timeout elapses.
    private func waitForHealth(startingAt startPort: Int, timeout: TimeInterval = 5) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in startPort..<(startPort + 3) {
                if await isHealthy(port: candidate) {
                    return candidate
                }
            }
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

    private func makeEmptyDistFixture() -> String {
        let dist = tempDir.appendingPathComponent("empty-dist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        return dist.path
    }

    private func makeIndexedDistFixture() throws -> String {
        let dist = tempDir.appendingPathComponent("dist-\(UUID().uuidString)", isDirectory: true)
        let assetsDir = dist.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        try "<html><body>Podium</body></html>".write(
            to: dist.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        try "console.log('sw')".write(
            to: dist.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8
        )
        try "body{color:gold}".write(
            to: assetsDir.appendingPathComponent("app-abc123.css"), atomically: true, encoding: .utf8
        )
        return dist.path
    }

    // MARK: - Health

    func testHealthEndpointReturnsOk() async throws {
        let port = try await bootServer()

        let url = URL(string: "http://127.0.0.1:\(port)/api/health")!
        let (data, response) = try await session.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try PodiumJSON.decoder.decode(HealthResponse.self, from: data)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertNotNil(PodiumDate.parse(decoded.timestamp))
    }

    // MARK: - WebSocket broadcast

    /// End-to-end: connect a real `URLSessionWebSocketTask` to `/ws`, call
    /// `Broadcaster.broadcast` on the live app's own broadcaster (reached via
    /// `PodiumServerApp` directly rather than `PodiumServerLifecycle.run`,
    /// which owns the app internally), and assert the client receives the
    /// exact `{type, data, timestamp}` envelope.
    ///
    /// Skipped on Linux: swift-corelibs-foundation's
    /// `URLSessionWebSocketTask` is backed by libcurl there, which does not
    /// implement the WebSocket upgrade (`WebSockets not supported by
    /// libcurl`) — a client-library gap, not a `PodiumServer` bug. The
    /// server's WS envelope shape is still fully covered by
    /// `BroadcasterTests`, and the real upgrade handshake is exercised
    /// (and passes) on macOS.
    #if !canImport(FoundationNetworking)
    func testWebSocketReceivesBroadcastEnvelope() async throws {
        let candidatePort = Int.random(in: 20000..<40000)
        let dist = makeEmptyDistFixture()
        let app = PodiumServerApp(store: store, port: candidatePort, webDistDirectory: dist)

        let serverTask = Task { try await app.application.runService() }
        defer { serverTask.cancel() }
        let port = try await waitForHealth(startingAt: candidatePort)

        let wsURL = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: wsURL)
        task.resume()

        // Give the upgrade a moment to complete before we broadcast.
        try await Task.sleep(nanoseconds: 300_000_000)

        struct Payload: Codable, Equatable {
            let sessionId: String
            let status: String
        }
        async let received = task.receive()
        // Small delay so `receive()` above is definitely waiting before we broadcast.
        try await Task.sleep(nanoseconds: 100_000_000)
        await app.broadcaster.broadcast(type: "session_updated", data: Payload(sessionId: "sess-1", status: "active"))

        let message = try await received
        guard case .string(let text) = message else {
            return XCTFail("expected a text frame")
        }
        let data = try XCTUnwrap(text.data(using: .utf8))
        let envelope = try PodiumJSON.decoder.decode(WSMessage.self, from: data)
        XCTAssertEqual(envelope.type, "session_updated")
        XCTAssertNotNil(PodiumDate.parse(envelope.timestamp))
        guard case .object(let obj) = envelope.data else {
            return XCTFail("expected object payload")
        }
        XCTAssertEqual(obj["session_id"], .string("sess-1"))
        XCTAssertEqual(obj["status"], .string("active"))

        task.cancel(with: .goingAway, reason: nil)
    }
    #endif

    // MARK: - Static file serving

    func testStaticIndexServedWithNoCacheHeader() async throws {
        let dist = try makeIndexedDistFixture()
        let port = try await bootServer(webDist: dist)

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, response) = try await session.data(from: url)
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-cache, must-revalidate")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("Podium"))
    }

    func testStaticAssetsServedImmutable() async throws {
        let dist = try makeIndexedDistFixture()
        let port = try await bootServer(webDist: dist)

        let url = URL(string: "http://127.0.0.1:\(port)/assets/app-abc123.css")!
        let (_, response) = try await session.data(from: url)
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "public, max-age=31536000, immutable")
    }

    func testSpaFallbackServesIndexForUnknownRoute() async throws {
        let dist = try makeIndexedDistFixture()
        let port = try await bootServer(webDist: dist)

        let url = URL(string: "http://127.0.0.1:\(port)/sessions/abc-123")!
        let (data, response) = try await session.data(from: url)
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-cache, must-revalidate")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("Podium"))
    }

    func testApiRoutesAreNeverInterceptedByStaticFallback() async throws {
        let dist = try makeIndexedDistFixture()
        let port = try await bootServer(webDist: dist)

        // A non-existent /api/ route should NOT get index.html back — it
        // should 404 from the router, proving the static SPA fallback only
        // applies to non-/api/ GETs.
        let url = URL(string: "http://127.0.0.1:\(port)/api/does-not-exist")!
        let (data, response) = try await session.data(from: url)
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.statusCode, 404)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("Podium") ?? false)
    }

    // MARK: - Server-info discovery file

    func testServerInfoFileWrittenAndCleanedUpOnShutdown() async throws {
        let infoPath = ServerInfoWriter.infoPath()
        let previousContents = try? Data(contentsOf: infoPath)
        defer {
            if let previousContents {
                try? previousContents.write(to: infoPath)
            } else {
                try? FileManager.default.removeItem(at: infoPath)
            }
        }

        let port = try await bootServer()

        // Give the write a moment (onListening fires asynchronously).
        try await waitUntil(timeout: 3) {
            (try? Data(contentsOf: infoPath)) != nil
        }

        let data = try Data(contentsOf: infoPath)
        let info = try PodiumJSON.decoder.decode(ServerInfo.self, from: data)
        XCTAssertTrue(info.servers.contains { $0.port == port })
        XCTAssertEqual(info.servers.first { $0.port == port }?.pid, Int(ProcessInfo.processInfo.processIdentifier))

        runTask.cancel()
        try await Task.sleep(nanoseconds: 500_000_000)

        // After cancellation the run loop's defer should have removed our
        // entry (file may be fully gone if we were the only entry, or just
        // missing our port if other entries existed).
        try await waitUntil(timeout: 3) {
            guard let remaining = try? Data(contentsOf: infoPath),
                  let info = try? PodiumJSON.decoder.decode(ServerInfo.self, from: remaining) else {
                return true // file gone entirely — also success
            }
            return !info.servers.contains { $0.port == port }
        }
    }

    // MARK: - Port fallback

    func testPortFallbackBindsNextPortWhenFirstIsOccupied() async throws {
        // Occupy a port with a bare socket, then ask PodiumServerLifecycle to
        // start there — it should fall back to occupiedPort + 1.
        let occupiedPort = Int.random(in: 40000..<50000)
        let blocker = try Blocker(port: occupiedPort)
        defer { blocker.close() }

        let port = try await bootServerOnExactPort(occupiedPort)
        XCTAssertEqual(port, occupiedPort + 1)
    }

    @discardableResult
    private func bootServerOnExactPort(_ startPort: Int) async throws -> Int {
        let dist = makeEmptyDistFixture()
        runTask = Task {
            try await PodiumServerLifecycle.run(
                store: store,
                startPort: startPort,
                webDistDirectory: dist,
                services: []
            )
        }
        return try await waitForHealth(startingAt: startPort)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

/// Minimal POSIX TCP listener used only to occupy a port for the port-
/// fallback test — deliberately not using Hummingbird/NIO so it's a true
/// independent occupant of the port.
private final class Blocker {
    private let fd: Int32

    init(port: Int) throws {
        #if canImport(Glibc)
        // On Glibc, SOCK_STREAM is typed as __socket_type, not Int32 — cast
        // explicitly so this compiles identically on Linux and Darwin.
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Self.closeDescriptor(fd)
            throw URLError(.cannotConnectToHost)
        }
        listen(fd, 1)
    }

    func close() {
        Self.closeDescriptor(fd)
    }

    private static func closeDescriptor(_ fd: Int32) {
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }
}
