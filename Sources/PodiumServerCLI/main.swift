// podium-server — headless daemon CLI.
//
// On Linux this IS the app: it serves the glassmorphism web dashboard over
// HTTP for browser use. Port of dashboard/server/index.js's
// `require.main === module` block (lines 250–403): boots the HTTP+WS
// server, auto-installs Claude Code hooks, starts background services, and
// shuts down gracefully on SIGINT/SIGTERM (handled by Hummingbird's
// ServiceGroup — see PodiumServerLifecycle.run).

import ArgumentParser
import Foundation
import Logging
import PodiumCore
import PodiumServer

@main
struct PodiumServerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "podium-server",
        abstract: "Podium standalone server — serves the REST + WebSocket API and the web dashboard."
    )

    @Option(name: .long, help: "Port to listen on (default: $DASHBOARD_PORT or 4820).")
    var port: Int?

    @Option(name: .long, help: "Data directory for dashboard.db and other writable state.")
    var dataDir: String?

    @Flag(name: .long, help: "Skip auto-installing Claude Code hooks on startup.")
    var noHooks: Bool = false

    @Option(name: .long, help: "Path to the built web client (WebClient/dist). Overrides $PODIUM_WEB_DIST.")
    var webDist: String?

    func run() async throws {
        // --data-dir wins over DASHBOARD_DATA_DIR/DASHBOARD_DB_PATH env for
        // this process only — set the env var so every PodiumPaths call
        // (including PodiumStore's default path resolution) picks it up.
        if let dataDir {
            PodiumPaths.environment["DASHBOARD_DATA_DIR"] = dataDir
        }
        if let webDist {
            setenv("PODIUM_WEB_DIST", webDist, 1)
        }

        var logger = Logger(label: "podium-server")
        logger.logLevel = .info

        let store: PodiumStore
        do {
            store = try PodiumStore(path: PodiumPaths.databasePath())
        } catch {
            FileHandle.standardError.write(Data("podium-server: failed to open database: \(error)\n".utf8))
            throw ExitCode.failure
        }

        if !noHooks {
            installHooksNonFatal(logger: logger)
        }

        let startPort = port ?? PodiumServerLifecycle.defaultPort()

        logger.info("Podium server starting", metadata: ["dataDir": "\(PodiumPaths.dataDir().path)"])

        do {
            let boundPort = try await PodiumServerLifecycle.run(
                store: store,
                startPort: startPort,
                mounts: [
                    SessionsRouterMount.self,
                    AgentsRouterMount.self,
                    EventsRouterMount.self,
                    StatsRouterMount.self,
                    AnalyticsRouterMount.self,
                    SearchRouterMount.self,
                    HooksRouterMount.self,
                ],
                logger: logger
            )
            print("Podium server running on http://localhost:\(boundPort) (production)")
        } catch {
            FileHandle.standardError.write(Data("podium-server: failed to start: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }

    /// Port of index.js's auto-install-hooks block (lines 289–298): copy the
    /// sibling `podium-hook` binary into `~/.claude/podium/` and register it
    /// in `~/.claude/settings.json`. Any failure is logged as a warning —
    /// never fatal, matching the Node behavior ("user can run
    /// npm run install-hooks manually").
    private func installHooksNonFatal(logger: Logger) {
        do {
            let hookBinaryPath = try HookInstaller.installBinary(from: siblingExecutablePath("podium-hook"))
            let result = try HookInstaller.install(binaryPath: hookBinaryPath)
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
            logger.warning("hook auto-install failed (non-fatal): \(error)")
        }
    }

    /// Resolves a binary that should live next to this executable (e.g.
    /// `podium-hook` built into the same `.build/<config>` or app-bundle
    /// directory as `podium-server`).
    private func siblingExecutablePath(_ name: String) -> String {
        let selfPath = CommandLine.arguments[0]
        let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
        return dir.appendingPathComponent(name).path
    }
}
