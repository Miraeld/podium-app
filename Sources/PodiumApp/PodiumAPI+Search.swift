import Foundation

// MARK: - Search & Patch Extension
// NOTE: PodiumAPI.get(url:) is private, so we implement HTTP directly here.

extension PodiumAPI {

    func search(q: String, limit: Int = 20) async throws -> SearchResult {
        var comps = URLComponents(url: baseURL.appending(path: "/api/search"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "q", value: q),
            .init(name: "limit", value: "\(limit)")
        ]
        return try await searchGet(url: comps.url!)
    }

    func exportSession(_ id: String) async throws -> Data {
        let url = baseURL.appending(path: "/api/export/session/\(id)")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    // Private helper — mirrors the private get(url:) but defined here so this
    // extension compiles without touching the actor's private interface.
    private func searchGet<T: Decodable>(url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.podium.decode(T.self, from: data)
    }

    func cleanupSessions(abandonIdleHours: Int, purgeOlderDays: Int) async throws {
        let body = try JSONEncoder().encode([
            "abandon_idle_hours": abandonIdleHours,
            "purge_older_days": purgeOlderDays
        ])
        var req = URLRequest(url: baseURL.appending(path: "/api/settings/cleanup"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func downloadExport() async throws -> Data {
        let url = baseURL.appending(path: "/api/settings/export")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    func hooksStatus() async throws -> [String: Bool] {
        let url = baseURL.appending(path: "/api/settings/hooks")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    func reinstallHooks() async throws {
        var req = URLRequest(url: baseURL.appending(path: "/api/settings/hooks/reinstall"))
        req.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func importSession(data: Data) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "/api/import/session"))
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if let json = try? JSONDecoder().decode([String: String].self, from: respData),
           let id = json["session_id"] ?? json["id"] {
            return id
        }
        return ""
    }
}
