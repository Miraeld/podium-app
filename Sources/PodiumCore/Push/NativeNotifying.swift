// NativeNotifying.swift — cross-platform seam for "show a native OS
// notification right now" (as opposed to Web Push, which goes through a
// browser's push service). Mirrors lib/push.js's
// `showNativeNotificationIfElectron`: a same-process, no-network way to
// alert the user, tried unconditionally alongside the Web Push leg so
// whichever surface the user is on receives the alert (see `PushService`).
//
// Concrete implementations:
//   - `NativeNotifier` (macOS, UNUserNotificationCenter) — NativeNotifier.swift
//   - `LinuxDesktopNotifier` (notify-send) — LinuxDesktopNotifier.swift
//   - `PlatformNotifier.default()` picks the right one per-platform.

/// Returns `true` when a notification was actually shown — a silent
/// no-op (no notification permission, no `notify-send` binary, …) must
/// never look like success to the caller.
public protocol NativeNotifying: Sendable {
    func show(title: String, body: String) async -> Bool
}

/// Always-false stand-in for platforms/hosts with no native notification
/// surface at all — never the production default, but useful for tests
/// that want to assert the push leg's behavior in isolation.
public struct NoOpNativeNotifier: NativeNotifying {
    public init() {}
    public func show(title: String, body: String) async -> Bool { false }
}

public enum PlatformNotifier {
    /// The default native notifier for the current platform — used by
    /// `PushService` unless a caller (e.g. the macOS app wiring a
    /// permission-aware notifier in P5.1) injects a different one.
    public static func makeDefault() -> NativeNotifying {
        #if os(macOS)
        return NativeNotifier()
        #else
        return LinuxDesktopNotifier()
        #endif
    }
}
