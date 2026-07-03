#if os(macOS)
import Foundation

// MARK: - IntentAPIClient
//
// Lightweight API client for use from App Intents (which run out-of-process
// and cannot access the main app's AppState actor). Reads host/port from
// UserDefaults.standard, falling back to localhost:4820.

struct IntentAPIClient {

    // MARK: - Base URL

    private static var baseURL: URL {
        let host = UserDefaults.standard.string(forKey: "podium_host") ?? "localhost"
        let rawPort = UserDefaults.standard.integer(forKey: "podium_port")
        let port = rawPort == 0 ? 4820 : rawPort
        // Guard against a malformed URL — fall back to localhost
        guard let url = URL(string: "http://\(host):\(port)") else {
            return URL(string: "http://localhost:4820")!
        }
        return url
    }

    // MARK: - Stats

    static func stats() async throws -> Stats {
        let url = baseURL.appending(path: "/api/stats")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder.podium.decode(Stats.self, from: data)
    }

    // MARK: - Sessions

    static func sessions(limit: Int = 5) async throws -> [Session] {
        guard var comps = URLComponents(
            url: baseURL.appending(path: "/api/sessions"),
            resolvingAgainstBaseURL: false
        ) else {
            return []
        }
        comps.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder.podium.decode(SessionsResponse.self, from: data).sessions
    }
}

#endif
