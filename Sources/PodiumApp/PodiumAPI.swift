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

    func analytics() async throws -> Analytics {
        try await get("/api/analytics")
    }

    // MARK: Cost

    func totalCost() async throws -> CostResult {
        try await get("/api/pricing/cost")
    }

    func sessionCost(_ id: String) async throws -> CostResult {
        try await get("/api/pricing/cost/\(id)")
    }

    // MARK: Workflow

    func workflowSession(_ id: String) async throws -> WorkflowSessionRaw {
        try await get("/api/workflows/session/\(id)")
    }

    // MARK: Transcript

    func transcript(_ sessionId: String, before: Int? = nil, limit: Int = 50) async throws -> TranscriptResponse {
        var comps = URLComponents(url: baseURL.appending(path: "/api/sessions/\(sessionId)/transcript"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [.init(name: "limit", value: "\(limit)")]
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
    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "HTTP \(c)"
        }
    }
}
