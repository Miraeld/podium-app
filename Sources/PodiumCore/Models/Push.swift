import Foundation

/// A `push_subscriptions` row (db.js lines 112–117) — a Web Push
/// subscription (RFC 8291 keys). Note the wire/DB key names `p256dh` and
/// `auth` are NOT snake_case-transformed further (they're already the exact
/// lowercase tokens the Push API spec and the Node server use) — explicit
/// `CodingKeys` pin them so `.convertToSnakeCase`/`.convertFromSnakeCase`
/// can't mangle `p256dh` (no underscore boundaries to convert, so it's safe
/// either way, but keys are pinned defensively since this is exactly the
/// kind of field the task warned must round-trip exactly).
public struct PushSubscription: Codable, Equatable, Sendable {
    public var endpoint: String
    public var p256dh: String
    public var auth: String
    public var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case p256dh
        case auth
        case createdAt = "created_at"
    }

    public init(endpoint: String, p256dh: String, auth: String, createdAt: String? = nil) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.createdAt = createdAt
    }

    public var createdAtDate: Date? { createdAt.flatMap(PodiumDate.parse) }
}

/// `POST /api/push/subscribe` request body (routes/push.js) — the shape a
/// browser's `PushSubscription.toJSON()` produces: `{ endpoint, keys: {
/// p256dh, auth } }`.
public struct PushSubscribeRequest: Codable, Equatable, Sendable {
    public var endpoint: String
    public var keys: Keys

    public init(endpoint: String, keys: Keys) {
        self.endpoint = endpoint
        self.keys = keys
    }

    public struct Keys: Codable, Equatable, Sendable {
        public var p256dh: String
        public var auth: String

        enum CodingKeys: String, CodingKey {
            case p256dh
            case auth
        }

        public init(p256dh: String, auth: String) {
            self.p256dh = p256dh
            self.auth = auth
        }
    }
}

/// `DELETE /api/push/subscribe` request body (routes/push.js).
public struct PushUnsubscribeRequest: Codable, Equatable, Sendable {
    public var endpoint: String

    public init(endpoint: String) {
        self.endpoint = endpoint
    }
}

/// `GET /api/push/vapid-public-key` response (routes/push.js).
public struct VapidPublicKeyResponse: Codable, Equatable, Sendable {
    public var publicKey: String

    public init(publicKey: String) {
        self.publicKey = publicKey
    }
}

/// `POST /api/push/send` request body (routes/push.js).
public struct PushSendRequest: Codable, Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// `POST /api/push/send` response — `{ ok: true, ...result }` where result
/// is `{ native, pushed, failed }` from `sendPushToAll` (lib/push.js).
public struct PushSendResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var native: Bool
    public var pushed: Int
    public var failed: Int

    public init(ok: Bool, native: Bool, pushed: Int, failed: Int) {
        self.ok = ok
        self.native = native
        self.pushed = pushed
        self.failed = failed
    }
}
