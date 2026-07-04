#if os(macOS)
import Foundation

// MARK: - JSON Decoder

extension JSONDecoder {
    static let podium: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(s)")
        }
        return d
    }()
}

// MARK: - API Client

actor PodiumAPI {
    var baseURL: URL
    private let session = URLSession.shared

    init(host: String = "localhost", port: Int = 4820) {
        baseURL = URL(string: "http://\(host):\(port)")!
    }

    func updateBase(host: String, port: Int) {
        baseURL = URL(string: "http://\(host):\(port)")!
    }

    // MARK: Health

    func health() async throws -> Bool {
        let url = baseURL.appending(path: "/api/health")
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Stats

    func stats() async throws -> Stats {
        try await get("/api/stats")
    }

    // MARK: Sessions

    func sessions(status: String? = nil, q: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> SessionsResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/sessions"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)")
        ]
        if let s = status { items.append(.init(name: "status", value: s)) }
        if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
        comps.queryItems = items
        return try await get(url: comps.url!)
    }

    func session(_ id: String) async throws -> SessionDetailResponse {
        try await get("/api/sessions/\(id)")
    }

    func patchSession(_ id: String, name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        var req = URLRequest(url: baseURL.appending(path: "/api/sessions/\(id)"))
        req.httpMethod = "PATCH"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func sessionStats(_ id: String) async throws -> SessionStats {
        try await get("/api/sessions/\(id)/stats")
    }

    // MARK: Agents

    func agents(sessionId: String? = nil, status: String? = nil) async throws -> AgentsResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/agents"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let s = sessionId { items.append(.init(name: "session_id", value: s)) }
        if let s = status { items.append(.init(name: "status", value: s)) }
        comps.queryItems = items.isEmpty ? nil : items
        return try await get(url: comps.url!)
    }

    // MARK: Events

    func events(sessionId: String? = nil, type: String? = nil, limit: Int = 100, offset: Int = 0) async throws -> EventsResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/events"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)")
        ]
        if let s = sessionId { items.append(.init(name: "session_id", value: s)) }
        if let t = type { items.append(.init(name: "type", value: t)) }
        comps.queryItems = items
        return try await get(url: comps.url!)
    }

    // MARK: Analytics

    /// `tz_offset` (minutes, `Date().timeZoneOffsetMinutes` on the client —
    /// i.e. `TimeZone.current.secondsFromGMT() / -60`, matching
    /// JS `Date.getTimezoneOffset()`'s sign convention) shifts the server's
    /// `daily_events`/`daily_sessions` bucketing into the caller's local
    /// timezone. See `AnalyticsRouter.swift`.
    func analytics(tzOffsetMinutes: Int? = nil) async throws -> Analytics {
        guard let tzOffsetMinutes else { return try await get("/api/analytics") }
        var comps = URLComponents(url: baseURL.appending(path: "/api/analytics"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "tz_offset", value: "\(tzOffsetMinutes)")]
        return try await get(url: comps.url!)
    }

    // MARK: Cost

    func totalCost() async throws -> CostResult {
        try await get("/api/pricing/cost")
    }

    func sessionCost(_ id: String) async throws -> CostResult {
        try await get("/api/pricing/cost/\(id)")
    }

    // MARK: Workflow

    /// `GET /api/workflows` — cross-session aggregate workflow intelligence.
    /// Optional `status` filter: active/completed/error/abandoned (omit or
    /// "all" for no filter). See `WorkflowsRouter.swift`.
    func workflowSummary(status: String? = nil) async throws -> WorkflowSummary {
        guard let status, !status.isEmpty, status != "all" else {
            return try await get("/api/workflows")
        }
        var comps = URLComponents(url: baseURL.appending(path: "/api/workflows"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "status", value: status)]
        return try await get(url: comps.url!)
    }

    /// `GET /api/workflows/session/:id` — full per-session drill-in (agent
    /// tree, tool timeline, swimlanes, first 500 events).
    func workflowSessionDetail(_ id: String) async throws -> WorkflowDetail {
        try await get("/api/workflows/session/\(id)")
    }

    func workflowSession(_ id: String) async throws -> WorkflowSessionRaw {
        try await get("/api/workflows/session/\(id)")
    }

    // MARK: Run

    func runs() async throws -> RunListResponse {
        try await get("/api/run")
    }

    func runHistory(limit: Int = 50) async throws -> RunListResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/run/history"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "limit", value: "\(limit)")]
        return try await get(url: comps.url!)
    }

    func run(_ id: String) async throws -> RunHandle {
        var comps = URLComponents(url: baseURL.appending(path: "/api/run/\(id)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "envelopes", value: "1")]
        return try await get(url: comps.url!)
    }

    func createRun(prompt: String, mode: String, cwd: String, model: String?, permissionMode: String, effort: String? = nil) async throws -> RunHandle {
        var dict: [String: String] = [
            "prompt": prompt,
            "mode": mode,
            "cwd": cwd,
            "permissionMode": permissionMode
        ]
        if let m = model { dict["model"] = m }
        if let effort, !effort.isEmpty { dict["effort"] = effort }
        let body = try JSONEncoder().encode(dict)
        return try await postDecodable("/api/run", body: body)
    }

    func sendRunMessage(_ id: String, text: String) async throws {
        let body = try JSONEncoder().encode(["text": text])
        _ = try await post("/api/run/\(id)/message", body: body)
    }

    func killRun(_ id: String) async throws {
        try await delete("/api/run/\(id)")
    }

    // MARK: Generic POST returning Decodable

    private func postDecodable<T: Decodable>(_ path: String, body: Data) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.podium.decode(T.self, from: data)
    }

    // MARK: Generic DELETE

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: Transcript

    func transcript(_ sessionId: String, after: Int? = nil, before: Int? = nil, limit: Int = 50) async throws -> TranscriptResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/sessions/\(sessionId)/transcript"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [.init(name: "limit", value: "\(limit)")]
        if let a = after { items.append(.init(name: "after", value: "\(a)")) }
        if let b = before { items.append(.init(name: "before", value: "\(b)")) }
        comps.queryItems = items
        return try await get(url: comps.url!)
    }

    // MARK: Pricing

    func pricingRules() async throws -> [PricingRule] {
        try await get("/api/settings/pricing")
    }

    @discardableResult
    func savePricingRules(_ rules: [PricingRule]) async throws -> Data {
        try await post("/api/settings/pricing", body: JSONEncoder().encode(rules))
    }

    // MARK: Generic GET

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(url: baseURL.appending(path: path))
    }

    private func get<T: Decodable>(url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.podium.decode(T.self, from: data)
    }

    @discardableResult
    private func post(_ path: String, body: Data) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

// MARK: - Workflow Session (raw)

struct WorkflowSessionRaw: Codable {
    let session: Session
    let tree: [AgentTreeNode]
}

// MARK: - Error

enum APIError: LocalizedError {
    case badStatus(Int)
    /// Like `badStatus`, but carries the server's `{"error":{"message"}}`
    /// text when available (`CodedErrorResponse` shape) — used by the
    /// cc-config endpoints so mutation failures (bad name, out-of-root,
    /// too-large, not-found, …) surface a human-readable reason instead of
    /// a bare HTTP status.
    case badStatusWithMessage(Int, String?)

    static func badStatus(_ code: Int, message: String?) -> APIError {
        .badStatusWithMessage(code, message)
    }

    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "HTTP \(c)"
        case .badStatusWithMessage(let c, let message):
            return message ?? "HTTP \(c)"
        }
    }
}

#endif
