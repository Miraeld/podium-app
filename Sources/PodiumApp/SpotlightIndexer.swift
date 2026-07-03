#if os(macOS)
import CoreSpotlight
import UniformTypeIdentifiers
import Foundation

// MARK: - SpotlightIndexer

actor SpotlightIndexer {
    static let domainIdentifier = "com.gaelrobin.PodiumApp.sessions"
    static let activityType     = "com.gaelrobin.PodiumApp.viewSession"

    // MARK: - Public API

    func index(_ sessions: [Session]) async {
        let items = sessions.map { makeItem(for: $0) }
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    func indexOne(_ session: Session) async {
        try? await CSSearchableIndex.default().indexSearchableItems([makeItem(for: session)])
    }

    func removeAll() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [SpotlightIndexer.domainIdentifier]
        )
    }

    func remove(sessionId: String) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [spotlightId(sessionId)]
        )
    }

    // MARK: - Private helpers

    private func makeItem(for session: Session) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .data)

        let projectName: String
        if let name = session.name, !name.isEmpty {
            projectName = name
        } else if let cwd = session.cwd {
            projectName = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            projectName = session.id
        }

        attrs.title = "Session: \(projectName)"

        // Build description WITHOUT cost — only status, path, started-relative
        var descParts: [String] = ["Status: \(session.status.rawValue)"]
        if let cwd = session.cwd { descParts.append("Path: \(cwd)") }
        descParts.append("Started: \(session.startedAt.formatted(.relative(presentation: .named)))")
        attrs.contentDescription = descParts.joined(separator: " · ")

        attrs.keywords = ([
            "podium", "claude", "session",
            session.status.rawValue,
            projectName,
            session.cwd,
            session.model
        ] as [String?]).compactMap { $0 }

        attrs.contentType = UTType.data.identifier
        attrs.relatedUniqueIdentifier = spotlightId(session.id)

        // Link an NSUserActivity so tapping the Spotlight result opens the app
        let activity = NSUserActivity(activityType: SpotlightIndexer.activityType)
        activity.title = attrs.title ?? projectName
        activity.userInfo = ["sessionId": session.id]
        activity.isEligibleForSearch = true
        activity.isEligibleForPublicIndexing = false

        let item = CSSearchableItem(
            uniqueIdentifier: spotlightId(session.id),
            domainIdentifier: SpotlightIndexer.domainIdentifier,
            attributeSet: attrs
        )
        return item
    }

    private func spotlightId(_ sessionId: String) -> String {
        "podium.session.\(sessionId)"
    }
}

#endif
