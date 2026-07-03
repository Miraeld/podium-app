// NativeNotifier.swift — macOS native notification surface via
// UNUserNotificationCenter. The Node app's equivalent
// (`showNativeNotificationIfElectron`) only fires inside the Electron main
// process, deliberately NOT from a plain `node server/index.js` host,
// because Web Push is unreliable in Electron (no FCM credentials) — the
// native leg exists specifically to cover that gap.
//
// The Swift architecture splits the same way: the headless `podium-server`
// CLI is not a signed app bundle, so `UNUserNotificationCenter` typically
// can't obtain authorization there (`errSecItemNotFound`/no bundle
// identifier) — this type exists to be handed to `PushService` by
// `PodiumApp` (P5.1), which *is* a proper macOS app bundle and can request
// notification permission successfully. It's still safe to use as
// `PushService`'s platform default even outside the app bundle: every
// failure mode here is caught and turned into `false`, matching
// `showNativeNotificationIfElectron`'s "fall through silently" contract.

#if os(macOS)
import Foundation
import UserNotifications

public final class NativeNotifier: NativeNotifying, @unchecked Sendable {
    public init() {}

    public func show(title: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return false }
        } catch {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
#endif
