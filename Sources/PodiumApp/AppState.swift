#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import UserNotifications
import PodiumCore

// MARK: - App State

@Observable
@MainActor
final class AppState {
    // Connection
    var host: String = UserDefaults.standard.string(forKey: "podium_host") ?? "localhost"
    var port: Int = UserDefaults.standard.integer(forKey: "podium_port") == 0
        ? 4820
        : UserDefaults.standard.integer(forKey: "podium_port")
    var isServerReachable = false
    var wsConnected = false

    // Dashboard data
    var stats: Stats?
    var sessions: [Session] = []
    var sessionTotal: Int = 0
    var analytics: Analytics?
    var totalCost: CostResult?

    // UI state
    var selectedSessionId: String?
    var navigationRequest: NavDestination? = nil
    var sessionDetailCache: [String: SessionDetailResponse] = [:]
    var sessionStatsCache: [String: SessionStats] = [:]
    var sessionCostCache: [String: CostResult] = [:]
    var gitContextCache: [String: GitInfo] = [:]
    /// True only while the very first `refresh()` is in flight. Views should
    /// gate full-screen spinners/skeletons on `isInitialLoad`, never on
    /// `isLoading` alone — that flag flips true/false on every periodic or
    /// manual (⌘R) refresh too, and blanking the UI each time is the "spinner
    /// always popping in" annoyance. Once the first load completes (success
    /// or failure), stale data stays visible and refreshes update in place.
    var isLoading = false
    var isInitialLoad = true
    /// Mirrors `isInitialLoad` for the separate `loadAnalytics()` data domain.
    var isAnalyticsInitialLoad = true
    var lastError: String?

    // Live activity feed
    var recentEvents: [DashboardEvent] = []

    /// Bumped whenever a WS `new_event` arrives for a given session id. The
    /// open Conversation/Thinking transcript tab (if any) observes its own
    /// session's counter to know when to fetch-and-append newly written
    /// transcript lines, without polling. Not cleared/removed — a growing
    /// dictionary of small Ints for the sessions seen this run is negligible.
    var transcriptEventTick: [String: Int] = [:]

    // Active agents (working or waiting)
    var activeAgents: [Agent] = []

    // MARK: Updates (TASK 2.9b)

    /// Latest known update status (from the on-launch check, a manual
    /// Settings "Check for updates", or a live `update_status` WS
    /// broadcast). `nil` until the first check completes.
    var updateStatus: UpdatesStatusResponse?
    /// True only while a check is actually in flight — gates the Settings
    /// "Check for updates" button spinner, not the proactive popup.
    var isCheckingForUpdates = false
    /// Set when the best-effort check fails (offline, GitHub unreachable,
    /// decode error). Never surfaced as an error alert — the Settings card
    /// shows it quietly; the proactive popup simply doesn't appear.
    var updateCheckFailed = false
    /// Drives the proactive "New update available" popup. Set once per
    /// launch, right after the first successful check, if the app's
    /// version hasn't already been dismissed by the user.
    var showUpdatePopup = false

    private static let dismissedUpdateVersionKey = "dismissed_update_version"
    private var hasCheckedForUpdatesThisLaunch = false

    private let ws = WebSocketClient()
    private var api: PodiumAPI = PodiumAPI()
    private let spotlight = SpotlightIndexer()

    // MARK: Init

    init() {
        ws.onStateChange = { [weak self] connected in
            Task { @MainActor in
                self?.wsConnected = connected
            }
        }
        ws.onMessage = { [weak self] type, data in
            Task { @MainActor in
                self?.handleWSMessage(type: type, data: data)
            }
        }
    }

    // MARK: Connect

    /// P5.1: resolves embedded-vs-external server mode (see
    /// `EmbeddedServer.resolveAndStart`) and points `host`/`port` at whichever
    /// mode won *before* building the API client / connecting the WebSocket,
    /// so the rest of the app (which only ever reads `host`/`port`) needs
    /// zero changes regardless of which mode is active.
    func start() async {
        let resolved = await EmbeddedServer.shared.resolveAndStart(configuredHost: host, configuredPort: port)
        switch resolved {
        case .embedded(let boundPort), .externalClient(let boundPort):
            host = "localhost"
            port = boundPort
        case .disabledByUser(let configuredPort):
            port = configuredPort
        }

        api = PodiumAPI(host: host, port: port)
        await refresh()
        await loadActiveAgents()
        let wsURL = URL(string: "ws://\(host):\(port)/ws")!
        ws.connect(url: wsURL)
        await checkForUpdatesOnLaunch()
    }

    func refresh() async {
        isLoading = true
        defer {
            isLoading = false
            isInitialLoad = false
        }
        do {
            isServerReachable = try await api.health()
            async let s = api.stats()
            async let sess = api.sessions(limit: 100)
            async let cost = api.totalCost()
            stats = try await s
            let sessResp = try await sess
            // Update in place rather than a destructive replace, so SwiftUI
            // diffs by identity and rows that haven't changed don't flicker
            // or lose transient UI state (e.g. hover, expansion).
            mergeSessions(sessResp.sessions)
            sessionTotal = sessResp.total
            totalCost = try? await cost
            lastError = nil
            // Index sessions into Spotlight (background — never blocks UI)
            let toIndex = sessions
            Task.detached(priority: .background) { await self.spotlight.index(toIndex) }
            // Update widget snapshot
            updateWidgetSnapshot()
        } catch {
            isServerReachable = false
            // Keep stale data on screen; only surface the error, don't wipe state.
            lastError = error.localizedDescription
        }
    }

    /// Reconciles the freshly-fetched session list into `sessions` without a
    /// full destructive replace: existing rows are updated in place (keeping
    /// their array position stable when the underlying id already existed),
    /// new rows are appended, and rows no longer present server-side are
    /// removed. This keeps SwiftUI's List diffing calm across refreshes.
    private func mergeSessions(_ fresh: [Session]) {
        var byId: [String: Session] = [:]
        byId.reserveCapacity(fresh.count)
        for s in fresh { byId[s.id] = s }

        var seen = Set<String>()
        for idx in sessions.indices {
            let id = sessions[idx].id
            if let updated = byId[id] {
                sessions[idx] = updated
                seen.insert(id)
            }
        }
        sessions.removeAll { !seen.contains($0.id) && byId[$0.id] == nil }

        let newOnes = fresh.filter { !seen.contains($0.id) }
        if !newOnes.isEmpty {
            sessions.insert(contentsOf: newOnes, at: 0)
        }
    }

    func loadAnalytics() async {
        defer { isAnalyticsInitialLoad = false }
        do {
            // JS `Date.prototype.getTimezoneOffset()` sign convention: positive
            // west of UTC, negative east — i.e. `-secondsFromGMT/60`. Matches
            // what `AnalyticsRouter`'s `tz_offset` expects (see PodiumAPI.analytics).
            let tzOffsetMinutes = -(TimeZone.current.secondsFromGMT() / 60)
            analytics = try await api.analytics(tzOffsetMinutes: tzOffsetMinutes)
        } catch {
            // Keep any previously-loaded analytics visible; just surface the error.
            lastError = error.localizedDescription
        }
    }

    // MARK: Session detail

    func loadSessionDetail(_ id: String) async {
        do {
            let detail = try await api.session(id)
            sessionDetailCache[id] = detail
            // Update session in list
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx] = detail.session
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadSessionStats(_ id: String) async {
        guard sessionStatsCache[id] == nil else { return }
        do {
            sessionStatsCache[id] = try await api.sessionStats(id)
        } catch {}
    }

    func loadSessionCost(_ id: String) async {
        guard sessionCostCache[id] == nil else { return }
        do {
            sessionCostCache[id] = try await api.sessionCost(id)
        } catch {}
    }

    func loadMoreSessions(offset: Int) async {
        do {
            let resp = try await api.sessions(limit: 50, offset: offset)
            let newIds = Set(sessions.map(\.id))
            sessions.append(contentsOf: resp.sessions.filter { !newIds.contains($0.id) })
            sessionTotal = resp.total
        } catch {}
    }

    func searchSessions(q: String, status: String?) async -> [Session] {
        do {
            let resp = try await api.sessions(status: status, q: q, limit: 100)
            return resp.sessions
        } catch {
            return []
        }
    }

    // MARK: WebSocket handler

    private func handleWSMessage(type: String, data: Data) {
        switch type {
        case "session_created":
            if let sess = try? JSONDecoder.podium.decode(WSSessionMsg.self, from: data).data {
                upsertSession(sess)
            }
            Task { await refreshStats() }

        case "session_updated":
            if let sess = try? JSONDecoder.podium.decode(WSSessionMsg.self, from: data).data {
                upsertSession(sess)
                if sess.status == .completed {
                    let name = sess.name ?? "Session"
                    sendLocalNotification(
                        title: "Session completed",
                        body: "\(name) finished successfully."
                    )
                } else if sess.status == .error {
                    let name = sess.name ?? "Session"
                    sendLocalNotification(
                        title: "Session failed",
                        body: "\(name) encountered an error."
                    )
                }
            }

        case "agent_created", "agent_updated":
            if let agent = try? JSONDecoder.podium.decode(WSAgentMsg.self, from: data).data {
                updateAgentInCache(agent)
                upsertActiveAgent(agent)
            }

        case "new_event":
            if let event = try? JSONDecoder.podium.decode(WSEventMsg.self, from: data).data {
                recentEvents.insert(event, at: 0)
                if recentEvents.count > 50 { recentEvents.removeLast() }
                // Invalidate stats cache for this session
                sessionStatsCache.removeValue(forKey: event.sessionId)
                transcriptEventTick[event.sessionId, default: 0] += 1
            }

        case "stats_update":
            if let s = try? JSONDecoder.podium.decode(WSStatsMsg.self, from: data).data {
                stats = s
                updateWidgetSnapshot()
            }

        case "update_status":
            // Broadcast from another client's (or this one's) manual
            // POST /api/updates/check — refreshes the Settings banner live.
            // Never triggers the proactive popup (that's launch-only).
            if let s = try? JSONDecoder.podium.decode(WSUpdateStatusMsg.self, from: data).data {
                updateStatus = s
                updateCheckFailed = false
            }

        default: break
        }
    }

    private func upsertSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0)
        }
        // Index this session into Spotlight (background)
        let s = session
        Task.detached(priority: .background) { await self.spotlight.indexOne(s) }
    }

    private func updateAgentInCache(_ agent: Agent) {
        guard var detail = sessionDetailCache[agent.sessionId] else { return }
        if let idx = detail.agents.firstIndex(where: { $0.id == agent.id }) {
            detail.agents[idx] = agent
        } else {
            detail.agents.append(agent)
        }
        sessionDetailCache[agent.sessionId] = detail
    }

    private func upsertActiveAgent(_ agent: Agent) {
        if agent.status == .working || agent.status == .waiting {
            if let idx = activeAgents.firstIndex(where: { $0.id == agent.id }) {
                activeAgents[idx] = agent
            } else {
                activeAgents.insert(agent, at: 0)
            }
        } else {
            activeAgents.removeAll { $0.id == agent.id }
        }
    }

    func loadActiveAgents() async {
        do {
            let resp = try await api.agents(status: "working,waiting")
            activeAgents = resp.agents
        } catch {}
    }

    private func refreshStats() async {
        if let s = try? await api.stats() { stats = s }
    }

    // MARK: Updates (TASK 2.9b)

    /// One auto-check per app launch — called from `start()`. Best-effort:
    /// network/decode failures degrade silently (`updateCheckFailed = true`,
    /// no alert). If an update is available for the app's own repo and its
    /// version hasn't been dismissed before, triggers the proactive popup.
    func checkForUpdatesOnLaunch() async {
        guard !hasCheckedForUpdatesThisLaunch else { return }
        hasCheckedForUpdatesThisLaunch = true
        do {
            let status = try await api.updatesStatus()
            updateStatus = status
            updateCheckFailed = false
            if status.app.updateAvailable, let latest = status.app.latestVersion,
               !isVersionDismissed(latest) {
                showUpdatePopup = true
            }
        } catch {
            updateCheckFailed = true
        }
    }

    /// Manual "Check for updates" from Settings — also broadcasts
    /// `update_status` over the WS hub server-side (other connected clients
    /// see the same result live).
    func checkForUpdatesNow() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            updateStatus = try await api.checkForUpdates()
            updateCheckFailed = false
        } catch {
            updateCheckFailed = true
        }
    }

    /// Persists the dismissal so this version never re-prompts; a newer
    /// release (different `latestVersion`) prompts again.
    func dismissUpdate(version: String) {
        UserDefaults.standard.set(version, forKey: Self.dismissedUpdateVersionKey)
        showUpdatePopup = false
    }

    private func isVersionDismissed(_ version: String) -> Bool {
        UserDefaults.standard.string(forKey: Self.dismissedUpdateVersionKey) == version
    }

    /// Opens the GitHub release page — the entire "update" flow for Stage 1
    /// (no self-update, no download-and-replace; see ROADMAP.md 2.9).
    func openReleasePage() {
        guard let urlString = updateStatus?.app.releaseUrl, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func fetchEvents(type: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> EventsResponse {
        try await api.events(sessionId: nil, type: type, limit: limit, offset: offset)
    }

    func pricingRules() async throws -> [PricingRule] {
        try await api.pricingRules()
    }

    func savePricingRules(_ rules: [PricingRule]) async throws {
        try await api.savePricingRules(rules)
    }

    func fetchTranscript(_ sessionId: String, after: Int? = nil, before: Int? = nil, limit: Int = 50) async throws -> TranscriptResponse {
        try await api.transcript(sessionId, after: after, before: before, limit: limit)
    }

    // MARK: Widget

    private func updateWidgetSnapshot() {
        let widgetSessions = sessions.prefix(5).map { s -> WidgetSnapshot.WidgetSession in
            let name: String
            if let n = s.name, !n.isEmpty {
                name = n
            } else if let cwd = s.cwd {
                name = URL(fileURLWithPath: cwd).lastPathComponent
            } else {
                name = s.id
            }
            return WidgetSnapshot.WidgetSession(id: s.id, name: name, status: s.status.rawValue)
        }
        let snapshot = WidgetSnapshot(
            activeSessions: stats?.activeSessions ?? 0,
            activeAgents: stats?.activeAgents ?? activeAgents.count,
            recentSessions: Array(widgetSessions),
            updatedAt: Date()
        )
        WidgetStore.save(snapshot)
    }

    // MARK: Notifications

    func sendLocalNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Search

    func searchGlobal(q: String) async throws -> SearchResult {
        try await api.search(q: q)
    }

    // MARK: Rename session

    func renameSession(_ id: String, name: String) async {
        do {
            try await api.patchSession(id, name: name)
            // Update in local cache immediately (optimistic)
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].name = name
            }
            if var detail = sessionDetailCache[id] {
                detail.session.name = name
                sessionDetailCache[id] = detail
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportSession(_ id: String) async throws -> Data {
        try await api.exportSession(id)
    }

    /// Load git context for a session's working directory off the main thread.
    /// No-op if the session has no cwd or context is already cached.
    func loadGitContext(for session: Session) async {
        guard let cwd = session.cwd, gitContextCache[session.id] == nil else { return }
        if let info = await GitContextReader.load(cwd: cwd) {
            gitContextCache[session.id] = info
        }
    }

    func cleanupSessions(abandonIdleHours: Int, purgeOlderDays: Int) async throws {
        try await api.cleanupSessions(abandonIdleHours: abandonIdleHours, purgeOlderDays: purgeOlderDays)
    }

    func downloadExport() async throws -> Data {
        try await api.downloadExport()
    }

    func hooksStatus() async throws -> [String: Bool] {
        try await api.hooksStatus()
    }

    func reinstallHooks() async throws {
        try await api.reinstallHooks()
    }

    // MARK: Workflow

    func loadWorkflow(_ id: String) async throws -> WorkflowSessionRaw {
        try await api.workflowSession(id)
    }

    /// Cross-session aggregate workflow intelligence — `GET /api/workflows`.
    func loadWorkflowSummary(status: String? = nil) async throws -> WorkflowSummary {
        try await api.workflowSummary(status: status)
    }

    /// Full per-session drill-in (tree, tool timeline, swimlanes, events) —
    /// `GET /api/workflows/session/:id`.
    func loadWorkflowDetail(_ id: String) async throws -> WorkflowDetail {
        try await api.workflowSessionDetail(id)
    }

    // MARK: CC Config Explorer (GET/PUT/DELETE /api/cc-config/*)
    //
    // Thin passthroughs so `ConfigExplorerView` doesn't need to construct
    // its own `PodiumAPI` instance (which is private state here) — mirrors
    // the `loadWorkflow*` passthrough pattern above. See
    // `PodiumAPI+CcConfig.swift` for the actual HTTP calls.

    func ccOverview(cwd: String?) async throws -> CcOverview { try await api.ccOverview(cwd: cwd) }
    func ccSkills(cwd: String?) async throws -> [CcSkillItem] { try await api.ccSkills(cwd: cwd) }
    func ccAgents(cwd: String?) async throws -> [CcMdItem] { try await api.ccAgents(cwd: cwd) }
    func ccCommands(cwd: String?) async throws -> [CcMdItem] { try await api.ccCommands(cwd: cwd) }
    func ccOutputStyles(cwd: String?) async throws -> [CcMdItem] { try await api.ccOutputStyles(cwd: cwd) }
    func ccMcpServers(cwd: String?) async throws -> CcMcpResponse { try await api.ccMcpServers(cwd: cwd) }
    func ccHooks(cwd: String?) async throws -> [CcHooksSource] { try await api.ccHooks(cwd: cwd) }
    func ccSettings(cwd: String?) async throws -> [CcSettingsSource] { try await api.ccSettings(cwd: cwd) }
    func ccMemory(cwd: String?) async throws -> [CcMemoryItem] { try await api.ccMemory(cwd: cwd) }
    func ccMarketplaces() async throws -> CcMarketplacesResponse { try await api.ccMarketplaces() }
    func ccKeybindings() async throws -> CcKeybindingsResponse { try await api.ccKeybindings() }
    func ccStatusline() async throws -> CcStatuslineResponse { try await api.ccStatusline() }
    func ccHookScripts() async throws -> CcHookScriptsResponse { try await api.ccHookScripts() }
    func ccBackups(cwd: String?, type: String? = nil) async throws -> [CcBackup] { try await api.ccBackups(type: type, cwd: cwd) }

    func ccWriteFile(scope: String, type: String, name: String?, content: String, cwd: String?) async throws -> CcWriteResult {
        try await api.ccWriteFile(scope: scope, type: type, name: name, content: content, cwd: cwd)
    }

    func ccDeleteFile(scope: String, type: String, name: String?, cwd: String?) async throws -> CcDeleteResult {
        try await api.ccDeleteFile(scope: scope, type: type, name: name, cwd: cwd)
    }

    // MARK: Import

    func importSession(data: Data) async throws -> String {
        let id = try await api.importSession(data: data)
        await refresh()
        return id
    }
}

// MARK: - WS message envelopes

private struct WSSessionMsg: Decodable { let data: Session? }
private struct WSAgentMsg: Decodable { let data: Agent? }
private struct WSEventMsg: Decodable { let data: DashboardEvent? }
private struct WSStatsMsg: Decodable { let data: Stats? }
private struct WSUpdateStatusMsg: Decodable { let data: UpdatesStatusResponse? }

#endif
