// PodiumStore+Push.swift — query methods backing P4.2 (`push_subscriptions`
// table, created in Schema.swift by P1.1; db.js has no dedicated
// `push_subscriptions` statements of its own — routes/push.js issues its
// three queries directly against `db.prepare(...)`, ported here 1:1).
//
// Kept as its own file per this task's ownership fence (P3.2/P3.3 own other
// PodiumStore+*.swift files in this same checkout).

import CSQLite
import Foundation

extension PodiumStore {
    /// `SELECT * FROM push_subscriptions` (lib/push.js `sendPushToAll`).
    public func listPushSubscriptions() throws -> [PushSubscription] {
        try db.query("SELECT * FROM push_subscriptions", []) { row in
            PushSubscription(
                endpoint: row.stringValue("endpoint"),
                p256dh: row.stringValue("p256dh"),
                auth: row.stringValue("auth"),
                createdAt: row.string("created_at")
            )
        }
    }

    /// `INSERT OR REPLACE INTO push_subscriptions (endpoint, p256dh, auth)
    /// VALUES (?, ?, ?)` (routes/push.js `POST /subscribe`) — re-subscribing
    /// the same endpoint (e.g. after the browser rotates its push keys)
    /// overwrites the stored `p256dh`/`auth` in place.
    public func upsertPushSubscription(endpoint: String, p256dh: String, auth: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO push_subscriptions (endpoint, p256dh, auth) VALUES (?, ?, ?)",
            [.text(endpoint), .text(p256dh), .text(auth)]
        )
    }

    /// `DELETE FROM push_subscriptions WHERE endpoint = ?` (routes/push.js
    /// `DELETE /subscribe`, and `PushService`'s 404/410 pruning).
    public func deletePushSubscription(endpoint: String) throws {
        try db.run("DELETE FROM push_subscriptions WHERE endpoint = ?", [.text(endpoint)])
    }
}
