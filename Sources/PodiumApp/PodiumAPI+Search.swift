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
}
