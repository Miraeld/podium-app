// EmbeddedServer.swift — P5.1: embeds PodiumServer in-process so the macOS
// app is the zero-setup demo: download -> open -> your agents appear live,
// no separate daemon, no Node, no plugin.
//
// Single-instance semantics (task 2): before hosting, we ask
// HookPortDiscovery (Sources/PodiumCore/Hooks/HookClient.swift) whether a
// live Podium server already owns a port via ~/.claude/.agent-dashboard.json
// (PID-liveness checked there already) and, belt-and-suspenders, do a quick
// GET /api/health against the discovered port(s). If one answers, we do NOT
// host — AppState just points at that port and behaves exactly like today's
// pure-client mode. If none answers, we host via `PodiumServerLifecycle.run`
// (not `.makeApp` + manual `runService()` — `.run` already gives us the
// port-fallback loop, server-info write/remove, and background-services
// bookkeeping the CLI relies on, so re-deriving that here would just be a
// worse copy of code that already exists and is tested).
//
// The embedded PushService is constructed with a real `NativeNotifier()`
// (task 4) — `PodiumServerApp`'s own default (`PlatformNotifier.makeDefault()`
// via `PushService.init`'s default argument) already resolves to
// `NativeNotifier()` on macOS, but we pass it explicitly here so this stays
// correct even if that default ever changes, and so it's obvious at the call
// site that native notifications are intentionally wired end-to-end.

#if os(macOS)
import Foundation
import Logging
import PodiumCore
import PodiumServer

/// Where this launch of the app ended up getting its data from: hosting the
/// server itself, or riding on an already-live external instance (another
/// app launch, the CLI daemon, or Gaël's production Docker container).
enum EmbeddedServerMode: Equatable {
    case embedded(port: Int)
    case externalClient(port: Int)
    /// User disabled embedding in Settings; we didn't even attempt a
    /// liveness probe before falling back to pure-client.
    case disabledByUser(port: Int)
}

/// Owns the lifecycle of the in-process server (when we're the one hosting).
/// One instance lives for the app's lifetime, created before `AppState.start()`
/// is called so `AppState.host`/`.port` can be pointed at the right place.
@MainActor
final class EmbeddedServer {
    static let shared = EmbeddedServer()

    private(set) var mode: EmbeddedServerMode?
    private var runTask: Task<Void, Never>?
    private let logger: Logger = {
        var l = Logger(label: "com.gaelrobin.PodiumApp.embedded-server")
        l.logLevel = .info
        return l
    }()

    /// `@AppStorage`-backed default (see SettingsView's "Embedded server"
    /// toggle) — read once at launch, same key so the toggle and this stay
    /// in sync. Default ON per task 3.
    static let embeddedServerEnabledKey = "podium_embedded_server_enabled"

    private init() {}

    /// Resolves which mode to run in and, if we're hosting, starts the
    /// server in a background Task. Must be awaited before `AppState.start()`
    /// reads `host`/`port` so the client points at the winning mode.
    ///
    /// - Returns: the resolved mode (also stored in `self.mode`).
    @discardableResult
    func resolveAndStart(configuredHost: String, configuredPort: Int) async -> EmbeddedServerMode {
        let embeddingEnabled = UserDefaults.standard.object(forKey: Self.embeddedServerEnabledKey) == nil
            ? true // default ON
            : UserDefaults.standard.bool(forKey: Self.embeddedServerEnabledKey)

        guard embeddingEnabled else {
            logger.info("Embedded server disabled by user setting — pure client mode.")
            let resolved = EmbeddedServerMode.disabledByUser(port: configuredPort)
            mode = resolved
            return resolved
        }

        let startPort = configuredPort > 0 ? configuredPort : PodiumServerLifecycle.defaultPort()

        if let livePort = await Self.discoverLiveExternalServer(preferredPort: startPort) {
            logger.info("Live Podium server already running — connecting as a client.", metadata: ["port": "\(livePort)"])
            let resolved = EmbeddedServerMode.externalClient(port: livePort)
            mode = resolved
            return resolved
        }

        let boundPort = await start(startPort: startPort)
        let resolved = EmbeddedServerMode.embedded(port: boundPort)
        mode = resolved
        return resolved
    }

    /// Task 2: reuse `HookPortDiscovery`'s multi-server-file + PID-liveness
    /// logic (the exact thing `podium-hook` uses to find where to POST) to
    /// enumerate candidate ports, then confirm with a real health GET so a
    /// stale/half-dead entry that happens to pass the PID check doesn't fool
    /// us into skipping hosting.
    ///
    /// Deliberately does NOT require `.agent-dashboard.json` to exist before
    /// checking: that file records servers *this machine's own* podium
    /// processes wrote, so a containerized/external instance (e.g. Gaël's
    /// production Docker container bind-mounting a different `~/.claude`
    /// inside the container) will never appear in it, yet is exactly the
    /// kind of already-live server task 2 says must win over hosting. A real
    /// TCP health check against `preferredPort` (our own configured/default
    /// port) is the ground truth; the info file's PID-checked entries are
    /// just additional candidates in case the live server ended up on a
    /// fallback port a previous launch chose.
    private static func discoverLiveExternalServer(preferredPort: Int) async -> Int? {
        var candidatePorts = [preferredPort]
        for port in HookPortDiscovery.resolvePorts() where !candidatePorts.contains(port) {
            candidatePorts.append(port)
        }
        for port in candidatePorts {
            if await healthCheck(port: port) {
                return port
            }
        }
        return nil
    }

    private static func healthCheck(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    /// Boots the embedded server via `PodiumServerLifecycle.run` in a
    /// detached background Task (it only returns once the server stops), and
    /// waits for the first successful health check on the *candidate* port
    /// (or its `+20` fallbacks) so callers get back a real bound port before
    /// `AppState.start()` fires.
    private func start(startPort: Int) async -> Int {
        let dataDir = PodiumPaths.dataDir()
        logger.info("Starting embedded Podium server.", metadata: ["dataDir": "\(dataDir.path)"])

        let store: PodiumStore
        do {
            store = try PodiumStore(path: PodiumPaths.databasePath())
        } catch {
            logger.error("Failed to open PodiumStore — falling back to unhosted client mode.", metadata: ["error": "\(error)"])
            // Nothing to host; return the originally configured port so the
            // client at least attempts a connection (may just fail cleanly,
            // same as today's behavior when no server is reachable).
            return startPort
        }

        // Orphaned dashboard_runs from a previous launch of this same app
        // (crash, force-quit) — same reconciliation podium-server's CLI does
        // on boot.
        if let reconciled = try? store.reconcileOrphanRuns(), reconciled > 0 {
            logger.info("Reconciled orphaned runs from a previous instance.", metadata: ["count": "\(reconciled)"])
        }

        installHooksNonFatal()

        let pushService = PushService(store: store, nativeNotifier: NativeNotifier())

        let logger = self.logger
        runTask = Task.detached(priority: .utility) {
            do {
                _ = try await PodiumServerLifecycle.run(
                    store: store,
                    startPort: startPort,
                    mounts: EmbeddedServer.makeServerMounts(),
                    reimportRunner: LegacyImporterReimportRunner(store: store),
                    pushService: pushService,
                    logger: logger
                )
            } catch {
                logger.error("Embedded server stopped with error.", metadata: ["error": "\(error)"])
            }
        }

        // `.run` writes the server-info file (and thus makes /api/health
        // answer) only once Hummingbird's `onListening` fires, which happens
        // strictly after `runService()` starts accepting connections. Poll
        // the candidate port range briefly rather than guessing a fixed
        // delay — the port-fallback loop means we don't know in advance
        // which of [startPort ... startPort+20] we'll land on.
        return await waitForBoundPort(startingAt: startPort)
    }

    private func waitForBoundPort(startingAt startPort: Int) async -> Int {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for candidate in startPort...(startPort + PodiumServerLifecycle.maxPortAttempts) {
                if await Self.healthCheck(port: candidate) {
                    return candidate
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        logger.warning("Timed out waiting for embedded server to come up; defaulting to the starting port.")
        return startPort
    }

    /// Exact same mounts list as `PodiumServerCLI/main.swift` — every REST
    /// router the standalone server exposes. Kept in sync manually; if a
    /// future router lands there, add it here too. A plain function (not a
    /// stored property) so it can be called from the `Task.detached` closure
    /// below without capturing a `MainActor`-isolated static across an
    /// isolation boundary (router mount types are non-`Sendable` metatypes).
    nonisolated static func makeServerMounts() -> [any RouterMount.Type] {
        [
            SessionsRouterMount.self,
            AgentsRouterMount.self,
            EventsRouterMount.self,
            StatsRouterMount.self,
            AnalyticsRouterMount.self,
            SearchRouterMount.self,
            HooksRouterMount.self,
            WorkflowsRouterMount.self,
            RunRouterMount.self,
            PricingRouterMount.self,
            SettingsRouterMount.self,
            ImportRouterMount.self,
            PushRouterMount.self,
        ]
    }

    /// Same non-fatal pattern as `PodiumServerCLI.installHooksNonFatal`:
    /// copy `podium-hook` next to the app's own executable (bundled into
    /// `PodiumApp.app/Contents/Resources` by run.sh / the packaging script)
    /// into `~/.claude/podium/`, then register it in `~/.claude/settings.json`.
    /// Any failure is logged and swallowed — never blocks app launch.
    private func installHooksNonFatal() {
        do {
            let hookSourcePath = Self.bundledHookBinaryPath()
            let installedPath = try HookInstaller.installBinary(from: hookSourcePath)
            let result = try HookInstaller.install(binaryPath: installedPath)
            if result.alreadyInstalled {
                logger.info("Podium hooks already configured.")
            } else {
                logger.info(
                    "Podium hooks auto-configured.",
                    metadata: [
                        "added": "\(result.addedCount)",
                        "legacyCleaned": "\(result.legacyCleanedCount)",
                    ]
                )
            }
        } catch {
            logger.warning("Hook auto-install failed (non-fatal): \(error)")
        }
    }

    /// Resolves the `podium-hook` binary bundled alongside this app.
    /// Checked in order: `Contents/Resources/podium-hook` (release .app
    /// bundle layout — see run.sh), then a sibling of the running executable
    /// (dev `.build/debug` layout, mirroring
    /// `PodiumServerCLI.siblingExecutablePath`).
    private static func bundledHookBinaryPath() -> String {
        if let resourcePath = Bundle.main.path(forResource: "podium-hook", ofType: nil) {
            return resourcePath
        }
        let selfPath = CommandLine.arguments[0]
        let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
        return dir.appendingPathComponent("podium-hook").path
    }

    /// Task 5: graceful shutdown. Cancels the background run Task (which
    /// cancels Hummingbird's `ServiceGroup`, triggering `.run`'s own `defer`
    /// block to call `servicesRunner.stopAll()` and `ServerInfoWriter.remove()`
    /// — see PodiumServerLifecycle.swift) and, belt-and-suspenders, calls
    /// `ServerInfoWriter.remove()` again directly since `Task.cancel()` only
    /// *requests* cooperative cancellation and Hummingbird's shutdown is
    /// async — we don't want to block app termination waiting for it.
    func shutdown() {
        guard case .embedded = mode else { return }
        logger.info("Shutting down embedded server.")
        runTask?.cancel()
        ServerInfoWriter.remove()
    }
}

/// Wires `POST /api/settings/reimport` to `LegacyImporter`, identical to
/// `PodiumServerCLI/main.swift`'s adapter of the same name — duplicated
/// here (rather than imported) because it's `internal` to the CLI target;
/// keep both in sync if the `ReimportResult` shape ever changes.
struct LegacyImporterReimportRunner: ReimportRunner {
    let store: PodiumStore

    func run() async throws -> ReimportResult {
        let counters = try LegacyImporter.importAllSessions(store: store)
        _ = try LegacyImporter.backfillCompactions(store: store)
        return ReimportResult(
            imported: counters.imported,
            skipped: counters.skipped,
            errors: counters.errors
        )
    }
}
#endif
