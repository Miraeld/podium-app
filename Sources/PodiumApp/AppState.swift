#if os(macOS)
import Foundation
import SwiftUI
import UserNotifications

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

#endif
