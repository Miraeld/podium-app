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
    private let extraHeaders: [HTTPField.Name: String]

    public init<Payload: Encodable>(
        status: HTTPResponse.Status = .ok,
        _ payload: Payload,
        extraHeaders: [HTTPField.Name: String] = [:]
    ) throws {
        self.status = status
        self.body = try PodiumJSON.encoder.encode(payload)
        self.extraHeaders = extraHeaders
    }

    /// Convenience for handlers that already have raw encoded JSON bytes
    /// (e.g. proxying an `openapi.json`-style static document).
    public init(status: HTTPResponse.Status = .ok, rawJSON: Data, extraHeaders: [HTTPField.Name: String] = [:]) {
        self.status = status
        self.body = rawJSON
        self.extraHeaders = extraHeaders
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        for (name, value) in extraHeaders {
            headers[name] = value
        }
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }
}

/// `{"error": "..."}` — flat error shape. Kept for callers that don't have a
/// structured code yet; prefer `CodedErrorResponse` for new routes since the
/// real Node routers (routes/sessions.js, agents.js, events.js, …) always
/// nest `{code, message}` and the React client reads `body.error.message`
/// (client/src/lib/api.ts lines 31–32) — a flat string would come through as
/// `undefined` there.
public struct ErrorResponse: Encodable, Sendable {
    public let error: String

    public init(_ message: String) {
        self.error = message
    }
}

/// `{"error": {"code": "...", "message": "..."}}` — the actual shape every
/// Node dashboard router uses (routes/sessions.js, agents.js, events.js,
/// pricing.js, run.js, export.js, cc-config.js all construct this literal
/// object). Use this for route error responses to stay wire-compatible with
/// the existing React client, which reads `body.error.message`.
public struct CodedErrorResponse: Encodable, Sendable {
    public struct Body: Encodable, Sendable {
        public let code: String
        public let message: String
    }
    public let error: Body

    public init(code: String, message: String) {
        self.error = Body(code: code, message: message)
    }
}
