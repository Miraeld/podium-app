import SwiftUI
import AppKit
import UserNotifications

// Required: SPM executables run with .prohibited activation policy by default.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Podium") {
            ContentView()
                .environment(appState)
                .task { await appState.start() }
        }
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }
}
