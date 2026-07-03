import XCTest
import PodiumCore
@testable import PodiumServer

/// Unit tests for `Broadcaster`'s envelope shape and connection bookkeeping
/// — the WS `/ws` route in `PodiumServerApp` is a thin adapter over this
/// actor, so exercising it directly here is more precise than round-
/// tripping through a live socket (that's covered end-to-end in
/// `PodiumServerAppTests.testWebSocketReceivesBroadcastEnvelope`).
final class BroadcasterTests: XCTestCase {
    func testBroadcastDeliversEnvelopeToAllConnections() async throws {
        let broadcaster = Broadcaster()

        actor Sink {
            var received: [String] = []
            func record(_ text: String) { received.append(text) }
        }
        let sinkA = Sink()
        let sinkB = Sink()

        await broadcaster.add(BroadcastConnection { text in
            await sinkA.record(text)
            return true
        })
        await broadcaster.add(BroadcastConnection { text in
            await sinkB.record(text)
            return true
        })

        struct Payload: Codable, Equatable {
            let sessionId: String
            let status: String
        }
        await broadcaster.broadcast(type: "session_updated", data: Payload(sessionId: "abc-123", status: "active"))

        let textA = await sinkA.received.first
        let textB = await sinkB.received.first
        XCTAssertNotNil(textA)
        XCTAssertNotNil(textB)
        XCTAssertEqual(textA, textB)

        let data = try XCTUnwrap(textA?.data(using: .utf8))
        let message = try PodiumJSON.decoder.decode(WSMessage.self, from: data)
        XCTAssertEqual(message.type, "session_updated")
        XCTAssertNotNil(PodiumDate.parse(message.timestamp))

        guard case .object(let obj) = message.data else {
            return XCTFail("expected object payload")
        }
        XCTAssertEqual(obj["session_id"], .string("abc-123"))
        XCTAssertEqual(obj["status"], .string("active"))
    }

    func testFailedSendPrunesConnection() async {
        let broadcaster = Broadcaster()
        var count = await broadcaster.connectionCount
        XCTAssertEqual(count, 0)

        await broadcaster.add(BroadcastConnection { _ in false }) // always fails
        count = await broadcaster.connectionCount
        XCTAssertEqual(count, 1)

        struct Empty: Codable {}
        await broadcaster.broadcast(type: "ping", data: Empty())

        count = await broadcaster.connectionCount
        XCTAssertEqual(count, 0, "a connection whose send() returns false should be pruned")
    }

    func testRemoveDropsConnection() async {
        let broadcaster = Broadcaster()
        let id = UUID()
        await broadcaster.add(BroadcastConnection(id: id) { _ in true })
        var count = await broadcaster.connectionCount
        XCTAssertEqual(count, 1)

        await broadcaster.remove(id)
        count = await broadcaster.connectionCount
        XCTAssertEqual(count, 0)
    }
}
