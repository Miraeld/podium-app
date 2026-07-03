// Broadcaster — port of dashboard/server/websocket.js.
//
// Tracks every connected `/ws` client and fans a `{type, data, timestamp}`
// envelope out to all of them, mirroring the Node `broadcast(type, data)`
// helper. All later routers (sessions, agents, hooks, …) receive this via
// dependency injection so they can call `broadcaster.broadcast(type:data:)`
// exactly like the Node routes call `broadcast(type, data)`.
//
// Node's heartbeat (30s ping, terminate on missed pong — websocket.js lines
// 26–41) is implemented as an idle-connection reaper: connections that fail
// to send a normal WebSocket-level pong within the interval are dropped from
// the registry. hummingbird-websocket's `AutoPingSetup`/`autoPing` handles
// the protocol-level ping/pong itself; we mirror the *intent* (dead
// connections don't accumulate) by pruning failed writes eagerly.

import Foundation
import PodiumCore

/// One live `/ws` connection: an outbound writer plus an id used to remove
/// it from the registry on disconnect.
public struct BroadcastConnection: Sendable {
    public let id: UUID
    let send: @Sendable (String) async -> Bool

    public init(id: UUID = UUID(), send: @escaping @Sendable (String) async -> Bool) {
        self.id = id
        self.send = send
    }
}

/// Tracks connected WebSocket clients and broadcasts `{type, data, timestamp}`
/// envelopes to all of them — the Swift equivalent of websocket.js's module-
/// level `wss` + `broadcast()`.
public actor Broadcaster {
    private var connections: [UUID: BroadcastConnection] = [:]

    public init() {}

    /// Register a new connection. Callers should call `remove(_:)` when the
    /// connection closes.
    public func add(_ connection: BroadcastConnection) {
        connections[connection.id] = connection
    }

    /// Remove a connection from the registry (on disconnect or a failed
    /// write — mirrors ws's `readyState !== OPEN` guard).
    public func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    /// Current number of live connections (parity with
    /// `getConnectionCount()` in websocket.js).
    public var connectionCount: Int {
        connections.count
    }

    /// Encode `{type, data, timestamp}` and send it to every connected
    /// client. Connections whose send fails are pruned (equivalent to a
    /// client that closed between the readyState check and `send()` in the
    /// Node implementation).
    public func broadcast<Payload: Encodable & Sendable>(type: String, data: Payload) async {
        guard let json = Self.encodeEnvelope(type: type, data: data) else { return }
        await deliver(json)
    }

    /// Overload for callers that already have a `JSONValue` payload (e.g.
    /// re-broadcasting a loosely-typed hook-derived value).
    public func broadcast(type: String, data: JSONValue) async {
        let message = WSMessage(type: type, data: data)
        guard let json = try? PodiumJSON.encoder.encode(message),
              let text = String(data: json, encoding: .utf8) else { return }
        await deliver(text)
    }

    private func deliver(_ text: String) async {
        for (id, connection) in connections {
            let ok = await connection.send(text)
            if !ok {
                connections.removeValue(forKey: id)
            }
        }
    }

    private static func encodeEnvelope<Payload: Encodable>(type: String, data: Payload) -> String? {
        // Encode the payload first, then splice it into a JSONValue so the
        // final envelope always matches WSMessage's {type, data, timestamp}
        // shape regardless of Payload's concrete type.
        guard let payloadData = try? PodiumJSON.encoder.encode(data),
              let payloadValue = try? PodiumJSON.decoder.decode(JSONValue.self, from: payloadData) else {
            return nil
        }
        let message = WSMessage(type: type, data: payloadValue)
        guard let json = try? PodiumJSON.encoder.encode(message) else { return nil }
        return String(data: json, encoding: .utf8)
    }
}
