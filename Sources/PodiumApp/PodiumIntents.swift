import AppIntents
import AppKit
import Foundation

// MARK: - Intent 1: Get Active Sessions

struct GetActiveSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Active Claude Sessions"
    static var description = IntentDescription(
        "Returns the number of currently active Claude Code sessions."
    )

    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let stats = try await IntentAPIClient.stats()
        let n = stats.activeSessions
        let word = n == 1 ? "session" : "sessions"
        return .result(
            value: n,
            dialog: "\(n) active Claude Code \(word) right now."
        )
    }
}

// MARK: - Intent 2: List Recent Sessions

struct ListRecentSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Recent Claude Sessions"
    static var description = IntentDescription(
        "Lists your most recent Claude Code sessions."
    )

    @Parameter(title: "Limit", default: 5, inclusiveRange: (1, 10))
    var limit: Int

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let sessions = try await IntentAPIClient.sessions(limit: limit)
        let lines = sessions.map { s -> String in
            let name: String
            if let n = s.name, !n.isEmpty {
                name = n
            } else if let cwd = s.cwd {
                name = URL(fileURLWithPath: cwd).lastPathComponent
            } else {
                name = s.id
            }
            return "\(name) — \(s.status.rawValue)"
        }
        let result = lines.joined(separator: "\n")
        return .result(
            value: result,
            dialog: "Here are your last \(sessions.count) Claude Code sessions."
        )
    }
}

// MARK: - Intent 3: Open Session in Podium

struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Session in Podium"
    static var description = IntentDescription(
        "Opens Podium and navigates to the specified session."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session ID")
    var sessionId: String

    func perform() async throws -> some IntentResult {
        guard let url = URL(string: "podium://session/\(sessionId)") else {
            return .result()
        }
        await NSWorkspace.shared.open(url)
        return .result()
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct PodiumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetActiveSessionsIntent(),
            phrases: [
                "How many active sessions in \(.applicationName)",
                "Show \(.applicationName) sessions",
                "Are any \(.applicationName) sessions running"
            ],
            shortTitle: "Active Sessions",
            systemImageName: "person.fill.badge.clock"
        )
        AppShortcut(
            intent: ListRecentSessionsIntent(),
            phrases: [
                "List my recent \(.applicationName) sessions",
                "Show recent \(.applicationName) sessions",
                "What sessions ran in \(.applicationName)"
            ],
            shortTitle: "Recent Sessions",
            systemImageName: "list.bullet.clipboard"
        )
    }
}
