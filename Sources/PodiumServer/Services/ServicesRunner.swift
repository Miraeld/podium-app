// ServicesRunner — scaffold for the background services index.js starts
// after the HTTP server begins listening (index.js lines 211–398):
// one-time legacy import, the periodic stale-session/compaction sweep, the
// cc-config filesystem watcher, and the update scheduler.
//
// This task (P2.1) only wires the scaffold with no-op placeholders so
// dependent tasks (P2.3 hook ingestion touches the sweep's compaction scan;
// P3.2 fills in legacy import + the sweep; P4.3 fills in the cc-watcher and
// update scheduler) have a home to plug into without touching
// PodiumServerApp or PodiumServerCLI.

import Foundation
import PodiumCore

/// One pluggable background service. Conforming types should be cheap to
/// construct and do their real work inside `run()`, which is expected to
/// run for the lifetime of the process (a long-lived loop) or return quickly
/// after doing one-shot work (e.g. the legacy import).
public protocol BackgroundService: Sendable {
    /// Short identifier used in log lines (`"[services] <name> failed: ..."`).
    var name: String { get }

    /// Perform the service's work. For one-shot services this should return
    /// once done; for recurring services it should run until `Task` cancellation
    /// (checked via `Task.isCancelled` / `Task.checkCancellation()`) and return
    /// then. Throwing is treated as non-fatal — `ServicesRunner` logs and moves on.
    func run(context: ServerContext) async throws
}

/// No-op placeholder used for the four services this task scaffolds but does
/// not implement: legacyImport, periodicSweep, ccWatcher, updateScheduler.
/// Dependent tasks replace the placeholder with a real `BackgroundService`
/// conformance and swap it into `ServicesRunner.defaultServices`.
public struct NoOpService: BackgroundService {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public func run(context: ServerContext) async throws {
        // Intentionally empty — see the four `PodiumServer.Services.*` cases
        // below and the task references in STANDALONE_PLAN.md §5 (P2.3/P3.2/P4.3).
    }
}

/// Named placeholders for the four services index.js starts post-listen.
/// Kept as static factories (rather than bare `NoOpService(name:)` calls at
/// every call site) so a dependent task can `grep` for exactly one spot to
/// replace per service.
public enum PlaceholderServices {
    /// One-time legacy import from `~/.claude/projects/**` — P3.2.
    public static var legacyImport: any BackgroundService { NoOpService(name: "legacyImport") }

    /// Periodic stale-session sweep + compaction scan — P3.2 (coordinates
    /// with P2.3's IngestEngine for the compaction-token seam).
    public static var periodicSweep: any BackgroundService { NoOpService(name: "periodicSweep") }

    /// `~/.claude` config filesystem watcher -> `cc_config_changed` broadcast — P4.3.
    public static var ccWatcher: any BackgroundService { NoOpService(name: "ccWatcher") }

    /// Upstream version-check scheduler -> `update_status` broadcast — P4.3.
    public static var updateScheduler: any BackgroundService { NoOpService(name: "updateScheduler") }
}

/// Starts and supervises a fixed set of `BackgroundService`s as independent
/// tasks once the HTTP server is listening. Mirrors `startBackgroundServices()`
/// in index.js: fire-and-forget, a failure in one service is logged and never
/// brings down the server or the other services.
public actor ServicesRunner {
    public static func defaultServices() -> [any BackgroundService] {
        [
            PlaceholderServices.legacyImport,
            PlaceholderServices.periodicSweep,
            PlaceholderServices.ccWatcher,
            PlaceholderServices.updateScheduler,
        ]
    }

    private var tasks: [Task<Void, Never>] = []

    public init() {}

    /// Start every service as its own detached-from-caller `Task`. Safe to
    /// call once; call `stopAll()` before calling `start` again.
    public func start(services: [any BackgroundService] = ServicesRunner.defaultServices(), context: ServerContext) {
        for service in services {
            let task = Task {
                do {
                    try await service.run(context: context)
                } catch {
                    FileHandle.standardError.write(
                        Data("[services] \(service.name) failed: \(error)\n".utf8)
                    )
                }
            }
            tasks.append(task)
        }
    }

    /// Cancel every running service task (called on graceful shutdown).
    public func stopAll() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }
}
