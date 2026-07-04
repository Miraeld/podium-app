// UpdateSchedulerService.swift — periodic version-check scheduler, backing
// `PlaceholderServices.updateScheduler` (P4.3). Port of index.js's
// update-check interval (the Node original schedules a periodic call to
// `getUpdatesStatus()` + broadcast, same shape `POST /api/updates/check`
// exposes on demand — see `Routes/UpdatesRouter.swift`).
//
// Runs once at startup, then every 6 hours (GitHub Releases don't change
// often enough to warrant tighter polling, and the anonymous GitHub API
// rate limit is 60 req/hour per IP — two repos every 6h stays well under
// that even across restarts).

import Foundation
import PodiumCore

public struct UpdateSchedulerService: BackgroundService {
    public let name = "updateScheduler"

    static let intervalNanoseconds: UInt64 = 6 * 60 * 60 * 1_000_000_000

    public init() {}

    public func run(context: ServerContext) async throws {
        while !Task.isCancelled {
            let result = await UpdateCheck.status()
            await context.broadcaster.broadcast(type: "update_status", data: result)
            try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
        }
    }
}
