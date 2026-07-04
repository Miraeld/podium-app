import XCTest
import Crypto
@testable import PodiumCore

/// Coverage of `PushNotifier` — the `IngestEngine` `Notifier` seam's real
/// implementation (P4.2 acceptance bar: "fires on sessionCompleted/
/// sessionError through the seam; payload shape matches the web client").
///
/// Every `PushService` here points `keysPath` at a throwaway temp file and
/// uses a capturing stub transport — never the user's real
/// `~/.claude/podium/data/vapid-keys.json`, never a real network call.
final class PushNotifierTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!
    private var transport: CapturingWebPushTransport!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-push-notifier-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
        transport = CapturingWebPushTransport()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService() -> PushService {
        PushService(
            store: store,
            keysPath: tempDir.appendingPathComponent("vapid-keys.json"),
            subject: "mailto:test@example.com",
            transport: transport,
            nativeNotifier: NoOpNativeNotifier()
        )
    }

    /// Seeds one subscription and wires `transport` to be able to decrypt
    /// whatever gets sent to it (real p256dh/auth keys, private half kept
    /// only in this test process).
    private func seedSubscription() async throws {
        let receiverKey = P256.KeyAgreement.PrivateKey()
        let auth = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        try store.upsertPushSubscription(
            endpoint: "https://push.example.net/push/notify-test",
            p256dh: Base64URL.encode(receiverKey.publicKey.x963Representation),
            auth: Base64URL.encode(auth)
        )
        await transport.configure(receiverPrivateKey: receiverKey, authSecret: auth)
    }

    // MARK: - Fires through the Notifier seam

    func testSessionCompletedFiresPushWithSessionTitle() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.sessionCompleted(sessionId: "sess-1", sessionName: "My Session"))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["title"] as? String, "Session completed")
        XCTAssertEqual(payload["body"] as? String, "\"My Session\" finished.")
    }

    func testSessionCompletedFallsBackToSessionIdWhenNameMissing() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.sessionCompleted(sessionId: "sess-1", sessionName: nil))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["body"] as? String, "Session sess-1 finished.")
    }

    func testSessionErrorFiresPushWithErrorTitle() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.sessionError(sessionId: "sess-2", sessionName: "Broken Session"))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["title"] as? String, "Session error")
        XCTAssertEqual(payload["body"] as? String, "\"Broken Session\" ended with an error.")
    }

    func testAgentStuckFiresPushWithMinutesStuck() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.agentStuck(sessionId: "sess-3", minutesStuck: 7))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["title"] as? String, "Agent stuck")
        XCTAssertEqual(payload["body"] as? String, "An agent has been stuck for 7 minute(s).")
    }

    func testCostSpikeFiresPushWithFormattedCost() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.costSpike(sessionId: "sess-4", cost: 12.5))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["title"] as? String, "Cost spike")
        XCTAssertEqual(payload["body"] as? String, "Session cost has reached $12.50.")
    }

    // MARK: - Payload shape matches the web client (push.ts / sw.js)

    /// `sw.js`'s `push` event handler does
    /// `const { title, ...options } = event.data.json()` then
    /// `showNotification(title, { silent: false, ...options })` — so every
    /// key besides `title` must be a valid `NotificationOptions` field (or
    /// at minimum, harmless to spread). This locks the exact key set/types
    /// `PushService.encodePayload` produces.
    func testPayloadShapeMatchesWebClientNotificationOptionsContract() async throws {
        try await seedSubscription()
        let notifier = PushNotifier(service: makeService())

        await notifier.notify(.sessionCompleted(sessionId: "sess-5", sessionName: "Shape Check"))

        let payload = try await transport.decodedPayload()
        XCTAssertEqual(payload["title"] as? String, "Session completed")
        XCTAssertNotNil(payload["body"] as? String)
        XCTAssertNotNil(payload["icon"] as? String)
        XCTAssertNotNil(payload["badge"] as? String)
        XCTAssertEqual(payload["silent"] as? Bool, false)
        XCTAssertEqual(payload["sound"] as? String, "default")

        // Additive `data.session_id`/`data.url` for click-through — sw.js
        // spreads unknown fields harmlessly, so this is safe to add.
        // `PushService.encodePayload` goes through `PodiumJSON.encoder`
        // (`.convertToSnakeCase`), so the wire key is `session_id`, not
        // `sessionId`.
        let data = payload["data"] as? [String: Any]
        XCTAssertEqual(data?["session_id"] as? String, "sess-5")
        XCTAssertEqual(data?["url"] as? String, "/sessions/sess-5")
    }

    // MARK: - Fire-and-forget contract

    func testNotifyNeverThrowsWhenNoSubscriptionsExist() async throws {
        // No seedSubscription() call — store has zero push_subscriptions.
        let notifier = PushNotifier(service: makeService())
        // Must not throw / must not crash; Notifier.notify has no throwing
        // signature, so this just asserts it completes.
        await notifier.notify(.sessionCompleted(sessionId: "sess-6", sessionName: nil))
    }
}

// MARK: - Test doubles

/// Captures the single most recent outbound `WebPushRequest` and always
/// reports success — used to inspect the plaintext-before-encryption
/// payload indirectly isn't possible (it's encrypted on the wire), so
/// instead these tests decrypt it back using the subscription's own keys
/// (registered via `configure`, called from `seedSubscription`).
actor CapturingWebPushTransport: WebPushTransport {
    private var lastRequest: WebPushRequest?
    private var receiverPrivateKey: P256.KeyAgreement.PrivateKey?
    private var authSecret: Data?

    func send(_ request: WebPushRequest) async throws -> WebPushTransportResponse {
        lastRequest = request
        return WebPushTransportResponse(statusCode: 201)
    }

    func configure(receiverPrivateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) {
        self.receiverPrivateKey = receiverPrivateKey
        self.authSecret = authSecret
    }

    /// Decrypts the most recently captured request's body using the
    /// subscription keys registered via `configure`, returning the
    /// notification payload as a `[String: Any]` JSON object.
    func decodedPayload() throws -> [String: Any] {
        guard let request = lastRequest else {
            throw TestError.noRequestCaptured
        }
        guard let receiverPrivateKey, let authSecret else {
            throw TestError.transportNotConfigured
        }
        let plaintext = try WebPushNotifierTestDecryption.decrypt(
            ciphertext: request.body,
            receiverPrivateKey: receiverPrivateKey,
            authSecret: authSecret
        )
        guard let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw TestError.payloadNotJSONObject
        }
        return json
    }

    enum TestError: Error {
        case noRequestCaptured
        case transportNotConfigured
        case payloadNotJSONObject
    }
}

/// Minimal receiver-side aes128gcm decoder — the mirror image of
/// `WebPushEncryptorTests`'s decrypt helper, duplicated here (rather than
/// shared) since `PushNotifierTests` lives in a different test target-file
/// and this is test-only code with no product-code caller.
enum WebPushNotifierTestDecryption {
    static func decrypt(ciphertext: Data, receiverPrivateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let salt = ciphertext.subdata(in: ciphertext.startIndex..<(ciphertext.startIndex + 16))
        let idLen = Int(ciphertext[ciphertext.startIndex + 20])
        let keyIdStart = ciphertext.startIndex + 21
        let senderPublicRaw = ciphertext.subdata(in: keyIdStart..<(keyIdStart + idLen))
        let bodyStart = keyIdStart + idLen

        let senderPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicRaw)
        let sharedSecret = try receiverPrivateKey.sharedSecretFromKeyAgreement(with: senderPublicKey)

        var context = Data("WebPush: info\0".utf8)
        context.append(receiverPrivateKey.publicKey.x963Representation)
        context.append(senderPublicRaw)

        let ikm = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: authSecret, sharedInfo: context, outputByteCount: 32)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonceBase = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let nonceBaseBytes = nonceBase.withUnsafeBytes { Data($0) }

        let sealedBody = ciphertext.subdata(in: bodyStart..<ciphertext.endIndex)
        let tagSize = 16
        let ciphertextPart = sealedBody.subdata(in: sealedBody.startIndex..<(sealedBody.endIndex - tagSize))
        let tag = sealedBody.subdata(in: (sealedBody.endIndex - tagSize)..<sealedBody.endIndex)

        let nonce = try AES.GCM.Nonce(data: nonceBaseBytes) // counter 0 -> unchanged
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextPart, tag: tag)
        var opened = try AES.GCM.open(sealedBox, using: cek)
        opened.removeLast() // strip the padding delimiter byte
        return opened
    }
}
