// APIErrorEnvelopeMiddleware — B7 (pre-1.0 audit): uniform error envelope
// for every `/api/*` failure path.
//
// Route handlers that produce *deliberate* 4xx responses already return
// `CodedErrorResponse` (`{"error": {"code", "message"}}`) directly. But
// several routers (Search, Stats, Analytics, Updates — and any handler whose
// store call throws) have no explicit failure path at all: a thrown error
// used to surface as Hummingbird's default `HTTPError` rendering —
// `{"error": {"message": ...}}` with no `code`, or an entirely empty body
// when the error carried no message — a third wire shape alongside the
// canonical one. This middleware catches anything thrown below it and
// re-encodes it as a `CodedErrorResponse`, so the documented invariant
// ("all error responses are CodedErrorResponse", CLAUDE.md) holds on every
// `/api/*` route without each router needing its own catch block.
//
// Deliberately scoped to `/api/*`: the static-file handler and SPA fallback
// (`Static/StaticFileHandler.swift`) own non-API paths and must keep serving
// HTML, not JSON envelopes.

import Foundation
import Hummingbird
import HTTPTypes

struct APIErrorEnvelopeMiddleware: RouterMiddleware {
    typealias Context = ServerRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.uri.path.hasPrefix("/api/") else {
            return try await next(request, context)
        }
        do {
            return try await next(request, context)
        } catch let error as HTTPError {
            let payload = CodedErrorResponse(
                code: Self.code(for: error.status),
                message: error.body ?? error.status.reasonPhrase
            )
            return try JSONResponse(status: error.status, payload)
                .response(from: request, context: context)
        } catch let error as DecodingError {
            // `decodeJSONBody` (Routes/RequestDecoding.swift) throws raw
            // `DecodingError` on malformed JSON bodies — that's client
            // input, not a server fault: 400, not 500.
            let payload = CodedErrorResponse(
                code: "INVALID_INPUT",
                message: "Invalid request body: \(Self.describe(error))"
            )
            return try JSONResponse(status: .badRequest, payload)
                .response(from: request, context: context)
        } catch {
            let payload = CodedErrorResponse(
                code: "INTERNAL",
                message: String(describing: error)
            )
            return try JSONResponse(status: .internalServerError, payload)
                .response(from: request, context: context)
        }
    }

    /// Stable machine-readable code per status, matching the codes the
    /// route handlers already use for the same statuses (e.g. `NOT_FOUND`,
    /// `INVALID_INPUT` — see SessionsRouter/AgentsRouter/ExportRouter).
    private static func code(for status: HTTPResponse.Status) -> String {
        switch status {
        case .badRequest: return "INVALID_INPUT"
        case .notFound: return "NOT_FOUND"
        case .contentTooLarge: return "PAYLOAD_TOO_LARGE"
        case .internalServerError: return "INTERNAL"
        default: return "HTTP_\(status.code)"
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted: return "malformed JSON"
        case .keyNotFound(let key, _): return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return ctx.debugDescription
        @unknown default: return "undecodable body"
        }
    }
}
