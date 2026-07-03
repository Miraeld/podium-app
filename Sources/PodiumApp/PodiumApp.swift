#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications
import CoreSpotlight

// Required: SPM executables run with .prohibited activation policy by default.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // UNUserNotificationCenter requires a bundle identifier — skip when running
        // as a raw Xcode DerivedData executable (bundleIdentifier is nil there).
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        // Defer until SwiftUI has finished building the window hierarchy.
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PodiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()
    @AppStorage("appearance_mode") private var appearanceMode = AppearanceMode.system.rawValue

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private var preferredColorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("Podium") {
            ContentView()
                .environment(appState)
                .preferredColorScheme(preferredColorScheme)
                .task { await appState.start() }
                .task { PodiumShortcuts.updateAppShortcutParameters() }
                .onOpenURL { url in
                    guard url.scheme == "podium" else { return }
                    // Bring the existing window forward instead of spawning a new one.
                    NSApp.activate(ignoringOtherApps: true)
                    if url.host == "session" {
                        if let id = url.pathComponents.last, !id.isEmpty, id != "/" {
                            appState.selectedSessionId = id
                            appState.navigationRequest = .sessions
                        }
                    } else if url.host == "dashboard" {
                        appState.navigationRequest = .dashboard
                    }
                }
                .onContinueUserActivity(SpotlightIndexer.activityType) { activity in
                    NSApp.activate(ignoringOtherApps: true)
                    if let sessionId = activity.userInfo?["sessionId"] as? String {
                        appState.selectedSessionId = sessionId
                        appState.navigationRequest = .sessions
                    }
                }
        }
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(preferredColorScheme)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Appearance mode

/// Persisted appearance override (system/dark/light). `nil` colorScheme means
/// "follow the system appearance" — SwiftUI's default behavior.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

#endif
