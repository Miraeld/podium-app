// Broadcast.swift — the value IngestEngine.process(...) returns instead of
// calling `broadcast(type, data)` directly (Node's hooks.js does the latter,
// inline, mid-transaction). Collecting broadcasts and returning them lets
// callers (HooksRouter, tests) decide when/how to fan them out — HooksRouter
// sends them over the real WS hub after the DB transaction commits; tests
// assert on the exact ordered list, which is the whole point of "broadcasts
// emitted in the same order Node emits them."

import Foundation

/// One `{type, data}` broadcast the engine wants sent to every `/ws` client.
/// `data` is `JSONValue` rather than `any Encodable` — the payload shapes
/// here are exactly what hooks.js broadcasts (raw `session`/`agent` rows or
/// small ad-hoc objects like `{session_id, cost}`), and `JSONValue` lets
/// `IngestEngineTests` pattern-match on them without needing concrete
/// Decodable types for every ad-hoc shape.
public struct Broadcast: Equatable, Sendable {
    public let type: String
    public let data: JSONValue

    public init(type: String, data: JSONValue) {
        self.type = type
        self.data = data
    }

    public init(type: String, session: Session) {
        self.type = type
        self.data = Broadcast.encode(session) ?? .null
    }

    public init(type: String, agent: Agent) {
        self.type = type
        self.data = Broadcast.encode(agent) ?? .null
    }

    private static func encode<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? PodiumJSON.encoder.encode(value) else { return nil }
        return try? PodiumJSON.decoder.decode(JSONValue.self, from: data)
    }
}
