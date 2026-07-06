// PodiumServerApp — Hummingbird 2 application assembly.
//
// Port of dashboard/server/index.js lines 58–159 (app assembly + static
// cache policy) and 250–298 (boot, server-info, graceful shutdown). See
// StaticFileHandler.swift for the exact cache-policy port and
// WebSocket/Broadcaster.swift for the `/ws` hub.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import PodiumCore

/// Everything needed to boot one Podium server instance: the store,
/// broadcaster, and the resolved static-assets directory. Produced by
/// `PodiumServerApp.build` and handed to `PodiumServerCLI`/the macOS app
/// so both can drive the same lifecycle (listen, run background services,
/// shut down).
public struct PodiumServerApp: Sendable {
    public let store: PodiumStore
    public let broadcaster: Broadcaster
    public let webDistDirectory: String
    public let application: Application<RouterResponder<ServerRequestContext>>
    public let servicesRunner: ServicesRunner
    public let serverContext: ServerContext
    public let runSpawner: RunSpawner

    /// Default `/api/health` route + whatever mounts are registered.
    /// `mounts` defaults to empty — dependent tasks (P2.2, P2.3, …) pass
    /// their `RouterMount` types once they exist; PodiumServerCLI is the
    /// single place that lists every mount for the production binary.
    ///
    /// - Parameter runSpawner: Injectable (P4.1) so tests can point
    ///   `RunRouter` at a fixture "claude" binary instead of spawning the
    ///   real CLI. `nil` (the default) builds a production
    ///   `RunSpawner(store:broadcaster:)` that resolves `claude` off `PATH`.
    /// - Parameter reimportRunner: Injectable (P3.3) — backs `POST
    ///   /api/settings/reimport`. `nil` (the default) makes that endpoint
    ///   respond `503 NOT_IMPLEMENTED` until the orchestrator wires a
    ///   concrete adapter over P3.2's `LegacyImporter`. See
    ///   `Routes/ReimportRunner.swift`.
    /// - Parameter pushService: Injectable (P4.2) — backs `PushRouter` and
    ///   the `IngestEngine` `Notifier` seam (`HooksRouterMount` wraps it in
    ///   a `PushNotifier`). `nil` (the default) builds a production
    ///   `PushService(store:)`, which defers all VAPID-key disk I/O and
    ///   native-notifier dispatch to first actual use — constructing it
    ///   here has no side effects. Tests that exercise push endpoints
    ///   should pass one pointed at a temp `keysPath` and a fake
    ///   `WebPushTransport` (see `PushRouterTests`).
    public init(
        store: PodiumStore,
        port: Int,
        host: String = "0.0.0.0",
        webDistDirectory: String = WebDistResolver.resolve(
            fallback: PodiumServerApp.defaultDevDistPath()
        ),
        mounts: [any RouterMount.Type] = [],
        runSpawner: RunSpawner? = nil,
        reimportRunner: ReimportRunner? = nil,
        pushService: PushService? = nil,
        logger: Logger = Logger(label: "podium-server"),
        onListening: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.broadcaster = Broadcaster()
        self.webDistDirectory = webDistDirectory
        self.servicesRunner = ServicesRunner()
        let resolvedRunSpawner = runSpawner ?? RunSpawner(store: store, broadcaster: broadcaster)
        self.runSpawner = resolvedRunSpawner
        let resolvedPushService = pushService ?? PushService(store: store)
        let context = ServerContext(
            store: store,
            broadcaster: broadcaster,
            runSpawner: resolvedRunSpawner,
            reimportRunner: reimportRunner,
            pushService: resolvedPushService
        )
        self.serverContext = context

        let router = Router(context: ServerRequestContext.self)

        // CORS — allow all, parity with Node's bare `cors()`.
        router.middlewares.add(CORSMiddleware(
            allowOrigin: .all,
            allowHeaders: [.accept, .authorization, .contentType, .origin],
            allowMethods: [.get, .post, .put, .patch, .delete, .head, .options]
        ))

        // Health check (index.js line 96).
        router.get("/api/health") { _, _ -> JSONResponse in
            try JSONResponse(HealthResponse(status: "ok", timestamp: PodiumDate.now()))
        }

        // WebSocket hub at /ws.
        router.ws("/ws") { inbound, outbound, wsContext in
            let connectionId = UUID()
            let connection = BroadcastConnection(id: connectionId) { text in
                do {
                    try await outbound.write(.text(text))
                    return true
                } catch {
                    return false
                }
            }
            await context.broadcaster.add(connection)
            defer {
                Task { await context.broadcaster.remove(connectionId) }
            }
            // Drain inbound frames until the client disconnects. Podium's
            // clients don't send anything meaningful (server pushes only —
            // plan §2.3), so we just wait for close.
            for try await _ in inbound {}
        }

        // Plug-in point for later tasks' /api/... routers.
        for mount in mounts {
            mount.mount(on: router, context: context)
        }

        // Static file serving + SPA fallback (must be added after the API
        // routes above so /api/* always wins the match).
        router.middlewares.add(StaticFileHandler(distDirectory: webDistDirectory))

        let wsRouter = router
        let app = Application(
            router: router,
            // autoPing DISABLED: hummingbird-websocket's auto-ping loop
            // (`WebSocketHandler.runAutoPingLoop`, swift-websocket) crashes in
            // `swift_task_dealloc` when a connection closes with a `Task.sleep`
            // pending — a task-allocator corruption that aborted the whole app
            // both mid-use (any tab disconnect) and on quit. Disabling it
            // deletes the crashing code path entirely. Liveness is unaffected:
            // the web/native clients own their own reconnect, and half-open
            // connections are a minor resource concern vs a hard crash.
            server: .http1WebSocketUpgrade(
                webSocketRouter: wsRouter,
                configuration: .init(ws: .init(autoPing: .disabled))
            ),
            configuration: .init(address: .hostname(host, port: port)),
            onServerRunning: { @Sendable _ in await onListening() },
            logger: logger
        )
        self.application = app
    }

    /// Dev-time fallback: `<repo>/WebClient/dist`, resolved relative to the
    /// running executable's directory by walking up until `WebClient/dist`
    /// is found, so it works whether the binary runs from `.build/debug` or
    /// a packaged bundle during development. Falls back to a relative path
    /// if nothing is found (caller/tests can always override via
    /// `PODIUM_WEB_DIST` or the `webDistDirectory` init parameter).
    public static func defaultDevDistPath() -> String {
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".", isDirectory: false)
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("WebClient/dist", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return "WebClient/dist"
    }
}
