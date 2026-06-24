import Foundation
import WidgetKit

// MARK: - WidgetSnapshot
//
// Shared data contract between the main app and a future WidgetKit extension.
// Cost fields are intentionally omitted (not needed by the user).

struct WidgetSnapshot: Codable {
    let activeSessions: Int
    let activeAgents: Int
    let recentSessions: [WidgetSession]
    let updatedAt: Date

    struct WidgetSession: Codable, Identifiable {
        let id: String
        let name: String
        let status: String   // raw string — no import of Session type needed by widget
    }
}

// MARK: - WidgetStore
//
// Saves/loads the snapshot via UserDefaults.
// App Groups require signing; on an unsigned SPM build the suiteName will be
// unavailable, so we degrade gracefully to UserDefaults.standard.

enum WidgetStore {
    private static let defaults: UserDefaults =
        UserDefaults(suiteName: "group.com.gaelrobin.PodiumApp") ?? .standard
    private static let key = "widgetSnapshot"

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        if #available(macOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
