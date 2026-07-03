// LinuxDesktopNotifier.swift — Linux native notification surface via the
// freedesktop.org `notify-send` CLI (org.freedesktop.Notifications over
// D-Bus, the same mechanism GNOME/KDE/most Linux desktop notification
// daemons implement). Product requirement (plan §6b): the headless
// `podium-server` daemon IS the Linux app, so it must give the same
// "session ended / awaiting input" toasts macOS gets from `NativeNotifier`
// — Linux users shouldn't be second-class citizens for notifications.
//
// Best-effort by design: a server (no desktop session, no notification
// daemon running, `notify-send` not installed) silently no-ops rather than
// failing the push — same contract as `NativeNotifier`/
// `showNativeNotificationIfElectron`.

#if os(Linux)
import Foundation

public final class LinuxDesktopNotifier: NativeNotifying, @unchecked Sendable {
    private let binaryPath: String?

    public init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath ?? Self.locateNotifySend()
    }

    public func show(title: String, body: String) async -> Bool {
        guard let binaryPath else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["--app-name=Podium", title, body]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    /// Checks the handful of paths `notify-send` conventionally lives at
    /// across distros, then falls back to `PATH` via `which` — no bundled
    /// binary shipping is required.
    static func locateNotifySend() -> String? {
        let candidates = ["/usr/bin/notify-send", "/usr/local/bin/notify-send", "/bin/notify-send", "/snap/bin/notify-send"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "notify-send"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
#endif
