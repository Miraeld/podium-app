// WebPushTransport.swift — the HTTP boundary `PushService` sends encrypted
// push requests through. Abstracted (rather than calling `URLSession`
// directly from `PushService`) so tests can capture what would have been
// sent without making a real network call — per the P4.2 task constraint
// that tests must never send a real push notification.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One outbound Web Push HTTP request, already fully encrypted/signed.
public struct WebPushRequest: Sendable, Equatable {
    public let endpoint: URL
    public let headers: [String: String]
    public let body: Data

    public init(endpoint: URL, headers: [String: String], body: Data) {
        self.endpoint = endpoint
        self.headers = headers
        self.body = body
    }
}

/// The push service's HTTP response — only the status code matters to
/// `PushService` (2xx = delivered; 404/410 = subscription gone and should
/// be pruned; anything else = a transient failure).
public struct WebPushTransportResponse: Sendable, Equatable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

public protocol WebPushTransport: Sendable {
    func send(_ request: WebPushRequest) async throws -> WebPushTransportResponse
}

/// Production transport: a real HTTPS POST via `URLSession`.
public struct URLSessionWebPushTransport: WebPushTransport {
    public init() {}

    public func send(_ request: WebPushRequest) async throws -> WebPushTransportResponse {
        var urlRequest = URLRequest(url: request.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return WebPushTransportResponse(statusCode: statusCode)
    }
}
