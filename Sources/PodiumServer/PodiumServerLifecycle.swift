// PodiumServerLifecycle — boots a PodiumServerApp with Node-parity port
// fallback and server-info discovery-file bookkeeping (index.js lines
// 145–159, 250–298).
//
// Port selection: env DASHBOARD_PORT (default 4820); if the bind fails,
// increment and retry up to +20 (mirrors the Electron shell's fallback per
// STANDALONE_PLAN.md P2.1 spec item 2).

import Foundation
import Logging
import PodiumCore

public enum PodiumServerLifecycleError: Error, CustomStringConvertible {
    case noPortAvailable(startingAt: Int, attempts: Int)

    public var description: String {
        switch self {
        case .noPortAvailable(let start, let attempts):
            return "Could not bind any port in \(start)...\(start + attempts) — all in use."
        }
    }
}

/// Small actor tracking whether the server-info file has been written for
/// the in-flight bind attempt, so a later bind failure on a *different*
/// candidate port doesn't try to remove an entry that was never written.
private actor ListenState {
    private(set) var didWriteInfo = false

    func markWritten() {
        didWriteInfo = true
    }
}

public enum PodiumServerLifecycle {
    /// `DASHBOARD_PORT` env default, matching index.js line 251.
    public static func defaultPort(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let raw = environment["DASHBOARD_PORT"], let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return 4820
    }

    /// How many ports above the starting port to try before giving up.
    public static let maxPortAttempts = 20

    /// Build a `PodiumServerApp` bound to `port`, wiring `onListening` to
    /// write the server-info file and start background services the instant
    /// the server starts accepting connections — mirroring
    /// `startServer(...).then(startBackgroundServices)` in index.js. Exposed
    /// separately from `run(...)` so callers that want to manage their own
    /// service-lifecycle loop (e.g. the macOS app embedding the server
    /// in-process) can call `app.application.runService()` themselves.
    public static func makeApp(
        store: PodiumStore,
        port: Int,
        host: String = "0.0.0.0",
        webDistDirectory: String? = nil,
        mounts: [any RouterMount.Type] = [],
        services: [any BackgroundService]? = nil,
        logger: Logger = Logger(label: "podium-server")
    ) -> PodiumServerApp {
        let state = ListenState()
        var appBox: PodiumServerApp?
        let app = PodiumServerApp(
            store: store,
            port: port,
            host: host,
            webDistDirectory: webDistDirectory ?? WebDistResolver.resolve(
                fallback: PodiumServerApp.defaultDevDistPath()
            ),
            mounts: mounts,
            logger: logger,
            onListening: {
                ServerInfoWriter.write(port: port)
                await state.markWritten()
                if let app = appBox {
                    await app.servicesRunner.start(
                        services: services ?? ServicesRunner.defaultServices(),
                        context: app.serverContext
                    )
                }
            }
        )
        appBox = app
        return app
    }

    /// Boots the server, retrying on incrementing ports if the bind fails,
    /// writes/removes the server-info file, starts background services once
    /// listening, and runs until cancelled or a signal triggers graceful
    /// shutdown (the caller installs signal handling — see
    /// `PodiumServerCLI/main.swift`).
    ///
    /// - Returns: the port the server ended up bound to. This function only
    ///   returns once the run loop stops (cancellation/graceful shutdown);
    ///   the return value is primarily useful for logging by the caller's
    ///   `onListening`-equivalent needs, tests that want to assert the bound
    ///   port, etc. — see `Tests/PodiumServerTests` for the pattern (run in
    ///   a background `Task`, poll `/api/health`).
    @discardableResult
    public static func run(
        store: PodiumStore,
        startPort: Int,
        host: String = "0.0.0.0",
        webDistDirectory: String? = nil,
        mounts: [any RouterMount.Type] = [],
        services: [any BackgroundService]? = nil,
        logger: Logger = Logger(label: "podium-server")
    ) async throws -> Int {
        var lastError: Error?
        for attempt in 0...maxPortAttempts {
            let candidatePort = startPort + attempt
            let app = makeApp(
                store: store,
                port: candidatePort,
                host: host,
                webDistDirectory: webDistDirectory,
                mounts: mounts,
                services: services,
                logger: logger
            )

            do {
                defer {
                    Task { await app.servicesRunner.stopAll() }
                    ServerInfoWriter.remove()
                }
                try await app.application.runService()
                return candidatePort
            } catch {
                lastError = error
                logger.debug("bind failed on port \(candidatePort), trying next", metadata: ["error": "\(error)"])
                continue
            }
        }
        throw lastError ?? PodiumServerLifecycleError.noPortAvailable(startingAt: startPort, attempts: maxPortAttempts)
    }
}
