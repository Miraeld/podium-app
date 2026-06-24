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
    var isLoading = false
    var lastError: String?

    // Live activity feed
    var recentEvents: [DashboardEvent] = []

    // Active agents (working or waiting)
    var activeAgents: [Agent] = []

    private let ws = WebSocketClient()
    private var api: PodiumAPI = PodiumAPI()

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

    func start() async {
        api = PodiumAPI(host: host, port: port)
        await refresh()
        await loadActiveAgents()
        let wsURL = URL(string: "ws://\(host):\(port)/ws")!
        ws.connect(url: wsURL)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            isServerReachable = try await api.health()
            async let s = api.stats()
            async let sess = api.sessions(limit: 100)
            async let cost = api.totalCost()
            stats = try await s
            let sessResp = try await sess
            sessions = sessResp.sessions
            sessionTotal = sessResp.total
            totalCost = try? await cost
            lastError = nil
        } catch {
            isServerReachable = false
            lastError = error.localizedDescription
        }
    }

    func loadAnalytics() async {
        do {
            analytics = try await api.analytics()
        } catch {
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
            }

        case "stats_update":
            if let s = try? JSONDecoder.podium.decode(WSStatsMsg.self, from: data).data {
                stats = s
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

    func fetchTranscript(_ sessionId: String, before: Int? = nil) async throws -> TranscriptResponse {
        try await api.transcript(sessionId, before: before)
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
}

// MARK: - WS message envelopes

private struct WSSessionMsg: Decodable { let data: Session? }
private struct WSAgentMsg: Decodable { let data: Agent? }
private struct WSEventMsg: Decodable { let data: DashboardEvent? }
private struct WSStatsMsg: Decodable { let data: Stats? }
