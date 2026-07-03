// PushService.swift — port of lib/push.js: VAPID public key exposure,
// `sendPushToAll` (native notification + Web Push fan-out with 404/410
// pruning). This is the seam `PushRouter` (HTTP) and `PushNotifier` (the
// `IngestEngine` `Notifier` seam) both sit on top of.
//
// All disk I/O (loading/creating `vapid-keys.json`) and native-notifier
// dispatch is deferred to first actual use (`publicKey()`/`sendToAll(...)`)
// rather than done eagerly in `init` — so constructing a `PushService` (as
// `PodiumServerApp` does by default for every server instance) never
// touches the filesystem or the notification center unless a push endpoint
// is actually hit. This matters for tests: booting a server for, say,
// `PricingRouterTests` must never read/write the user's real
// `~/Library/Application Support/Podium/vapid-keys.json`.

import Foundation

public actor PushService {
    private let store: PodiumStore
    private let explicitKeysPath: URL?
    private let subject: String
    private let transport: WebPushTransport
    private let nativeNotifier: NativeNotifying?
    private var cachedKeys: VAPIDKeyPair?

    /// web-push's `DEFAULT_TTL` (4 weeks) — how long a push service should
    /// hold an undelivered notification before giving up.
    private static let defaultTTLSeconds = 2_419_200

    /// The VAPID subject (RFC 8292 `sub` claim) lib/push.js hard-codes.
    /// Overridable via `PODIUM_VAPID_SUBJECT` for deployments that want
    /// their own contact URI; kept as the same default for parity with the
    /// existing Node server (and any push services that have already seen
    /// this VAPID key pair's JWTs).
    public static func defaultSubject() -> String {
        PodiumPaths.environment["PODIUM_VAPID_SUBJECT"] ?? "https://github.com/hoangsonww/Claude-Code-Agent-Monitor"
    }

    public init(
        store: PodiumStore,
        keysPath: URL? = nil,
        subject: String = PushService.defaultSubject(),
        transport: WebPushTransport = URLSessionWebPushTransport(),
        nativeNotifier: NativeNotifying? = PlatformNotifier.makeDefault()
    ) {
        self.store = store
        self.explicitKeysPath = keysPath
        self.subject = subject
        self.transport = transport
        self.nativeNotifier = nativeNotifier
    }

    /// `{ native, pushed, failed }` — mirrors `sendPushToAll`'s return
    /// shape exactly (`PushSendResult` adds the wrapping `ok: true`).
    public struct SendResult: Sendable, Equatable {
        public let native: Bool
        public let pushed: Int
        public let failed: Int
    }

    /// `getPublicKey()` — the VAPID public key for client-side
    /// `pushManager.subscribe({ applicationServerKey: ... })`. Loads (or
    /// generates) the key pair on first call.
    public func publicKey() throws -> String {
        try loadedKeys().publicKey
    }

    /// `sendPushToAll(db, title, body)`. `sessionId`/`url` are additive
    /// (not present in the Node payload) — carried in the payload's `data`
    /// field so a click-through can jump straight to the right session
    /// once the web client's service worker reads it (product context
    /// §6b №2; `sw.js`'s current `push` handler already spreads unknown
    /// fields into `showNotification` harmlessly, so this is forward
    /// compatible without touching the vendored client).
    public func sendToAll(title: String, body: String, sessionId: String? = nil, url: String? = nil) async throws -> SendResult {
        let native = await nativeNotifier?.show(title: title, body: body) ?? false

        let subscriptions = try store.listPushSubscriptions()
        guard !subscriptions.isEmpty else {
            return SendResult(native: native, pushed: 0, failed: 0)
        }

        let keys = try loadedKeys()
        let payload = try Self.encodePayload(title: title, body: body, sessionId: sessionId, url: url)
        // Read once here (synchronously, still on the actor's executor) so
        // the child tasks below capture plain local values instead of
        // `self` — keeps delivery entirely off the actor's executor after
        // this point.
        let subject = self.subject
        let transport = self.transport

        var pushed = 0
        var failed = 0
        await withTaskGroup(of: (String, Bool, Bool).self) { group in
            for subscription in subscriptions {
                group.addTask {
                    await Self.deliver(
                        subscription: subscription,
                        payload: payload,
                        keys: keys,
                        subject: subject,
                        transport: transport,
                        ttlSeconds: Self.defaultTTLSeconds
                    )
                }
            }
            for await (endpoint, delivered, shouldPrune) in group {
                if delivered {
                    pushed += 1
                } else {
                    failed += 1
                    if shouldPrune {
                        try? store.deletePushSubscription(endpoint: endpoint)
                    }
                }
            }
        }

        return SendResult(native: native, pushed: pushed, failed: failed)
    }

    // MARK: - Key loading

    private func loadedKeys() throws -> VAPIDKeyPair {
        if let cachedKeys { return cachedKeys }
        let keys = try VAPIDKeyStore.loadOrCreate(path: resolvedKeysPath())
        cachedKeys = keys
        return keys
    }

    private func resolvedKeysPath() -> URL {
        explicitKeysPath ?? PodiumPaths.dataDir().appendingPathComponent("vapid-keys.json")
    }

    // MARK: - Per-subscription delivery

    /// Encrypts and sends `payload` to one subscription. Returns
    /// `(endpoint, delivered, shouldPruneOn404Or410)` so the caller can
    /// tally results and prune dead subscriptions without touching the
    /// store from inside a `TaskGroup` child task (actor isolation keeps
    /// all store writes back on `PushService`'s executor via `try?
    /// store.deletePushSubscription` in the `for await` loop above).
    private static func deliver(
        subscription: PushSubscription,
        payload: Data,
        keys: VAPIDKeyPair,
        subject: String,
        transport: WebPushTransport,
        ttlSeconds: Int
    ) async -> (String, Bool, Bool) {
        guard let endpointURL = URL(string: subscription.endpoint) else {
            return (subscription.endpoint, false, false)
        }
        do {
            let encrypted = try WebPushEncryptor.encrypt(
                payload: payload,
                userPublicKeyBase64URL: subscription.p256dh,
                userAuthBase64URL: subscription.auth
            )
            let authorization = try VAPID.authorizationHeader(
                endpoint: subscription.endpoint,
                subject: subject,
                keys: keys
            )
            let request = WebPushRequest(
                endpoint: endpointURL,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Encoding": "aes128gcm",
                    "TTL": "\(ttlSeconds)",
                    "Urgency": "normal",
                    "Authorization": authorization,
                ],
                body: encrypted
            )
            let response = try await transport.send(request)
            if (200...299).contains(response.statusCode) {
                return (subscription.endpoint, true, false)
            }
            let shouldPrune = response.statusCode == 404 || response.statusCode == 410
            return (subscription.endpoint, false, shouldPrune)
        } catch {
            return (subscription.endpoint, false, false)
        }
    }

    // MARK: - Payload shape

    private struct Payload: Encodable {
        struct SessionRef: Encodable {
            let sessionId: String?
            let url: String?
        }
        let title: String
        let body: String
        let icon: String
        let badge: String
        let silent: Bool
        let sound: String
        let data: SessionRef?
    }

    /// lib/push.js's payload shape (`title, body, icon, badge, silent,
    /// sound`) plus an additive `data: { sessionId, url }` when provided.
    static func encodePayload(title: String, body: String, sessionId: String?, url: String?) throws -> Data {
        let iconURL = "https://raw.githubusercontent.com/hoangsonww/Claude-Code-Agent-Monitor/main/client/public/favicon.ico"
        let hasData = sessionId != nil || url != nil
        let payload = Payload(
            title: title,
            body: body,
            icon: iconURL,
            badge: iconURL,
            silent: false,
            sound: "default",
            data: hasData ? Payload.SessionRef(sessionId: sessionId, url: url) : nil
        )
        return try PodiumJSON.encoder.encode(payload)
    }
}
