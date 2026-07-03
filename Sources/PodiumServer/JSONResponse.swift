// JSONResponse — encodes PodiumCore models to HTTP responses using
// `PodiumJSON.encoder` (snake_case, matching the Node API exactly) instead
// of Hummingbird's default `JSONEncoder` (which would emit camelCase and
// break wire-format parity with the React client).
//
// Route handlers should return `JSONResponse(status:body:)` rather than a
// bare `Encodable` value, since `RequestContext`'s default `Encoder`
// associated type has no way to know about PodiumJSON's snake_case /
// millisecond-ISO8601 conventions.

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import PodiumCore

/// A `ResponseGenerator` that encodes its payload with `PodiumJSON.encoder`.
public struct JSONResponse: ResponseGenerator {
    public let status: HTTPResponse.Status
    private let body: Data

    public init<Payload: Encodable>(status: HTTPResponse.Status = .ok, _ payload: Payload) throws {
        self.status = status
        self.body = try PodiumJSON.encoder.encode(payload)
    }

    /// Convenience for handlers that already have raw encoded JSON bytes
    /// (e.g. proxying an `openapi.json`-style static document).
    public init(status: HTTPResponse.Status = .ok, rawJSON: Data) {
        self.status = status
        self.body = rawJSON
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }
}

/// `{"error": "..."}` — the Node routers' standard error body shape (plan §4.3).
public struct ErrorResponse: Encodable, Sendable {
    public let error: String

    public init(_ message: String) {
        self.error = message
    }
}
