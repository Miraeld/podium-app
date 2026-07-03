// PushNotifier.swift — the `Notifier` seam's real implementation
// (`Sources/PodiumCore/Ingest/IngestSeams.swift`), wired into
// `IngestEngine` by `HooksRouter`. Translates the four state-machine
// transitions `IngestEngine` already fires (`sessionCompleted`,
// `sessionError`, `agentStuck`, `costSpike` — see IngestEngine.swift lines
// 623–783) into a title/body pair and hands them to `PushService`.
//
// NOTE ON PARITY: dashboard/server/hooks.js does NOT call `sendPushToAll`
// from any of these transitions today — Node's `lib/push.js` is only
// reachable through the manual `POST /api/push/send` route. Auto-notifying
// on session end/error is a deliberate product enhancement (task P4.2
// brief, plan §6b №2: "notifications are a first-class product feature"),
// not a Node behavior being ported — flagged here so nobody "fixes" this
// into matching Node by deleting the auto-notify behavior.
//
// Fire-and-forget by the `Notifier` protocol's contract: never throws into
// the ingest path (every `PushService` call is wrapped in `try?`).

import Foundation

public struct PushNotifier: Notifier {
    private let service: PushService
    /// Builds the `data.url` field so a notification click-through can jump
    /// straight to the session once the web client's service worker reads
    /// it (client route is `/sessions/:id`, see App.tsx).
    private let sessionURL: (String) -> String

    public init(service: PushService, sessionURL: @escaping (String) -> String = { "/sessions/\($0)" }) {
        self.service = service
        self.sessionURL = sessionURL
    }

    public func notify(_ event: NotifierEvent) async {
        let (title, body, sessionId): (String, String, String)
        switch event {
        case .sessionCompleted(let id, let name):
            title = "Session completed"
            body = name.map { "\"\($0)\" finished." } ?? "Session \(id) finished."
            sessionId = id
        case .sessionError(let id, let name):
            title = "Session error"
            body = name.map { "\"\($0)\" ended with an error." } ?? "Session \(id) ended with an error."
            sessionId = id
        case .agentStuck(let id, let minutesStuck):
            title = "Agent stuck"
            body = "An agent has been stuck for \(minutesStuck) minute(s)."
            sessionId = id
        case .costSpike(let id, let cost):
            let formattedCost = String(format: "%.2f", cost)
            title = "Cost spike"
            body = "Session cost has reached $\(formattedCost)."
            sessionId = id
        }

        _ = try? await service.sendToAll(title: title, body: body, sessionId: sessionId, url: sessionURL(sessionId))
    }
}
