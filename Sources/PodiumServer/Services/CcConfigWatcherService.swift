// CcConfigWatcherService.swift — the `BackgroundService` wiring for
// PodiumCore's `CcConfigWatcherEngine` (P4.3, replacing
// `PlaceholderServices.ccWatcher`'s `NoOpService`).
//
// `CcConfigWatcherEngine` lives in PodiumCore and knows nothing about
// `Broadcaster`/`ServerContext` (those are PodiumServer-layer types); this
// file supplies the one adapter (`BroadcasterCcConfigChangeNotifier`) and
// the `BackgroundService` conformance that runs the engine for the
// lifetime of the process, exactly like every other P2.3/P3.2 service in
// `ServicesRunner.swift`.

import Foundation
import PodiumCore

/// Production notifier: broadcasts `cc_config_changed` over the real `/ws`
/// hub — the PodiumServer-side half of the `CcConfigChangeNotifier` seam
/// declared in `PodiumCore/Discovery/CcWatcher.swift`.
public struct BroadcasterCcConfigChangeNotifier: CcConfigChangeNotifier {
    let broadcaster: Broadcaster

    public init(broadcaster: Broadcaster) {
        self.broadcaster = broadcaster
    }

    public func notifyConfigChanged(source: String, paths: [String]) async {
        let payload = JSONValue.object([
            "source": .string(source),
            "paths": .array(paths.map(JSONValue.string)),
        ])
        await broadcaster.broadcast(type: "cc_config_changed", data: payload)
    }
}

/// `~/.claude` config filesystem watcher → `cc_config_changed` broadcast.
/// Replaces `PlaceholderServices.ccWatcher`'s `NoOpService(name: "ccWatcher")`
/// — see `ServicesRunner.swift`'s `PlaceholderServices.ccWatcher` doc
/// comment, which this task's report tells the orchestrator to swap.
public struct CcConfigWatcherService: BackgroundService {
    public let name = "ccWatcher"

    public init() {}

    public func run(context: ServerContext) async throws {
        let notifier = BroadcasterCcConfigChangeNotifier(broadcaster: context.broadcaster)
        let engine = CcConfigWatcherEngine(notifier: notifier)
        await engine.start()
        defer { Task { await engine.stop() } }

        // Keep this service's Task alive for the lifetime of the process —
        // the engine itself does the real watching/polling on its own
        // Task(s); this loop just waits for cancellation (server shutdown)
        // so `defer`'s `engine.stop()` fires at the right time.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
