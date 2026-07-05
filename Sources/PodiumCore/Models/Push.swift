import Foundation

/// A `push_subscriptions` row (db.js lines 112–117) — a Web Push
/// subscription (RFC 8291 keys). Note the wire/DB key names `p256dh` and
/// `auth` are NOT snake_case-transformed further (they're already the exact
/// lowercase tokens the Push API spec and the Node server use) — no
/// underscore boundaries, so `.convertToSnakeCase`/`.convertFromSnakeCase`
/// pass them through unchanged and no explicit `CodingKeys` are needed for
/// those two.
///
/// IMPORTANT: `PodiumJSON.decoder`/`.encoder` apply
/// `.convertFromSnakeCase`/`.convertToSnakeCase` globally, which convert the
/// wire key to/from camelCase *before* matching against `CodingKeys` raw
/// values. An explicit `CodingKeys` entry using the original snake_case
/// wire string (e.g. `case createdAt = "created_at"`) would silently fail
/// to match against the already-converted `"createdAt"` key — decoding
/// `created_at` to `nil` instead of throwing, since the property is
/// Optional. So `createdAt` here relies on the implicit default
/// (`createdAt` Swift name ⇄ `created_at` wire name via the strategy) and
/// carries NO explicit `CodingKeys` case.
public struct PushSubscription: Codable, Equatable, Sendable {
    public var endpoint: String
    public var p256dh: String
    public var auth: String
    public var createdAt: String?

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

    // `publicKey` is a camelCase literal in Node's response and the client
    // reads it verbatim (lib/push.ts line 26: `{ publicKey }`) — see
    // `AnyEncodable`'s doc comment.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(["publicKey": AnyEncodable(publicKey)])
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
