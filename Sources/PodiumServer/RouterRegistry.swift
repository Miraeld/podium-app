// RouterRegistry — the plug-in point later tasks (P2.2 read routers, P2.3
// hook ingestion, P3.x, P4.x) use to mount their `/api/...` routes without
// this file (or PodiumServerApp) needing to change.
//
// Usage from a dependent task:
//
//     public enum SessionsRouterMount: RouterMount {
//         public static func mount(on router: PodiumRouter, context: ServerContext) {
//             let group = router.group("/api/sessions")
//             group.get { req, ctx in ... }
//         }
//     }
//
// and register it in `PodiumServerApp.defaultMounts` (or pass an explicit
// `mounts:` array to `PodiumServerApp.init`).

import Hummingbird
import HummingbirdWebSocket
import PodiumCore

/// The concrete request context used throughout PodiumServer — supports both
/// plain HTTP routes and the `/ws` WebSocket upgrade.
public typealias ServerRequestContext = BasicWebSocketRequestContext

/// The concrete router type every route mount receives.
public typealias PodiumRouter = Router<ServerRequestContext>

/// Shared dependencies injected into every router mount: the data store and
/// the WebSocket broadcast hub. Later tasks add fields here (e.g. a
/// `Notifier`, `RunSpawner`) rather than threading new parameters through
/// every mount call site.
public struct ServerContext: Sendable {
    public let store: PodiumStore
    public let broadcaster: Broadcaster
    /// P4.1: supervises `claude` subprocesses spawned via `POST /api/run`.
    /// See `Sources/PodiumCore/Runs/RunSpawner.swift`.
    public let runSpawner: RunSpawner

    public init(store: PodiumStore, broadcaster: Broadcaster, runSpawner: RunSpawner) {
        self.store = store
        self.broadcaster = broadcaster
        self.runSpawner = runSpawner
    }
}

/// Conformance point for a group of related routes (one Node `routes/*.js`
/// file maps to one `RouterMount`). Kept as a protocol with a static method
/// (rather than an instance) so mounts stay stateless — all state lives in
/// `ServerContext`.
public protocol RouterMount {
    static func mount(on router: PodiumRouter, context: ServerContext)
}
