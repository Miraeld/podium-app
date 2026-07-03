// HookClient — port of podium/hook.mjs.
//
// Reads a Claude Code hook payload (already parsed JSON), discovers the live
// Podium dashboard server port(s), and POSTs `{hook_type, data}` to
// `/api/hooks/event` on each one. Lives in PodiumCore so it's unit-testable;
// Sources/PodiumHook/main.swift is a thin stdin -> HookClient shim.
//
// Behavioral parity notes (see hook.mjs lines 20–90):
//   - CLAUDE_DASHBOARD_PORT env var wins outright when it's a positive integer.
//   - Otherwise read ~/.claude/.agent-dashboard.json:
//       * multi-server format: {"servers": [{"port": N, "pid": N}, ...]}
//       * legacy single format: {"port": N, "pid": N}
//     Filter to "live" entries: no pid (or pid <= 0) => assume alive; else
//     probe via kill(pid, 0) — success or EPERM => alive, ESRCH (etc) => dead.
//   - If nothing live (or file missing/unreadable), fall back to [4820].
//   - POST to every live port; each request gets its own 1s timeout; the
//     caller (main.swift) enforces a hard 1.5s process deadline on top.
//   - Never throws for malformed input — the hook must never crash or block
//     Claude Code.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One dashboard server entry as read from `.agent-dashboard.json`.
public struct DashboardServerEntry: Equatable {
    public let port: Int
    public let pid: Int?

    public init(port: Int, pid: Int?) {
        self.port = port
        self.pid = pid
    }
}

public enum HookPortDiscovery {
    /// Default fallback when no live server can be discovered.
    public static let fallbackPorts = [4820]

    /// Resolve the home directory in a way that works on macOS and Linux,
    /// without depending on AppKit/SwiftUI.
    public static func homeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Default path to `~/.claude/.agent-dashboard.json`.
    public static func defaultInfoPath() -> URL {
        homeDirectory()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".agent-dashboard.json", isDirectory: false)
    }

    /// True if the process with the given pid is alive (or we can't tell
    /// because we lack permission to signal it — EPERM counts as alive, same
    /// as hook.mjs's `e.code === 'EPERM'` check). A pid <= 0 has no meaning
    /// here and callers should treat "no pid" as alive before calling this.
    public static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Parse the raw JSON bytes of `.agent-dashboard.json` into a list of
    /// server entries, supporting both the multi-server and legacy single
    /// formats. Returns an empty array if the JSON is malformed or has
    /// neither shape.
    public static func parseServerEntries(from data: Data) -> [DashboardServerEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let servers = obj["servers"] as? [Any] {
            return servers.compactMap { element -> DashboardServerEntry? in
                guard let dict = element as? [String: Any],
                      let port = intValue(dict["port"]) else { return nil }
                return DashboardServerEntry(port: port, pid: intValue(dict["pid"]))
            }
        }

        if let port = intValue(obj["port"]) {
            return [DashboardServerEntry(port: port, pid: intValue(obj["pid"]))]
        }

        return []
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double where d.truncatingRemainder(dividingBy: 1) == 0: return Int(d)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    /// Filter server entries down to the "live" ones per hook.mjs semantics.
    public static func liveEntries(_ entries: [DashboardServerEntry]) -> [DashboardServerEntry] {
        entries.filter { entry in
            guard let pid = entry.pid, pid > 0 else { return true }
            return isProcessAlive(pid: pid)
        }
    }

    /// Full port discovery: env override, then info file (multi or legacy
    /// format) filtered to live entries, then the conventional fallback.
    /// De-duplicates ports while preserving order, mirroring
    /// `[...new Set(...)]` in hook.mjs.
    public static func resolvePorts(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoPath: URL? = nil
    ) -> [Int] {
        if let envPortString = environment["CLAUDE_DASHBOARD_PORT"],
           let envPort = Int(envPortString.trimmingCharacters(in: .whitespaces)),
           envPort > 0 {
            return [envPort]
        }

        let path = infoPath ?? defaultInfoPath()
        guard let data = try? Data(contentsOf: path) else {
            return fallbackPorts
        }

        let entries = parseServerEntries(from: data)
        let live = liveEntries(entries)
        if live.isEmpty {
            return fallbackPorts
        }

        var seen = Set<Int>()
        var ordered: [Int] = []
        for entry in live where !seen.contains(entry.port) {
            seen.insert(entry.port)
            ordered.append(entry.port)
        }
        return ordered
    }
}

/// Builds and sends the `{hook_type, data}` payload to every live dashboard
/// server, per hook.mjs's `postToDashboard`.
public enum HookClient {
    /// Per-request timeout (hook.mjs: `req.setTimeout(1000, ...)`).
    public static let requestTimeout: TimeInterval = 1.0

    /// Build the JSON payload posted to `/api/hooks/event`. Returns nil if it
    /// can't be encoded (mirrors hook.mjs's try/catch around JSON.stringify).
    public static func buildPayload(hookType: String, data: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(data) else {
            // Still attempt — data may contain NSNull etc. valid for JSONSerialization
            // but let's just try encoding via wrapper below.
            return encodeEnvelope(hookType: hookType, data: data)
        }
        return encodeEnvelope(hookType: hookType, data: data)
    }

    private static func encodeEnvelope(hookType: String, data: [String: Any]) -> Data? {
        let envelope: [String: Any] = ["hook_type": hookType, "data": data]
        return try? JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    /// POST the payload to every live port. Calls `completion` once all
    /// requests have settled (success, error, or per-request timeout).
    /// Never throws; if there are no ports, completion fires immediately.
    public static func postToAllServers(
        hookType: String,
        data: [String: Any],
        ports: [Int],
        session: URLSession = HookClient.makeSession(),
        completion: @escaping () -> Void
    ) {
        guard let payload = buildPayload(hookType: hookType, data: data) else {
            completion()
            return
        }

        if ports.isEmpty {
            completion()
            return
        }

        let group = DispatchGroup()
        for port in ports {
            group.enter()
            send(payload: payload, port: port, session: session) {
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            completion()
        }
    }

    private static func send(payload: Data, port: Int, session: URLSession, done: @escaping () -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/hooks/event") else {
            done()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(payload.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = payload
        request.timeoutInterval = requestTimeout

        var finished = false
        let lock = NSLock()
        func finishOnce() {
            lock.lock()
            let alreadyDone = finished
            finished = true
            lock.unlock()
            if !alreadyDone { done() }
        }

        let task = session.dataTask(with: request) { _, _, _ in
            finishOnce()
        }
        task.resume()
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: config)
    }
}

/// Port of hook.mjs's `run()` — turns a raw parsed hook payload into the
/// `{hookType, data}` tuple to POST, or nil if there's nothing to send.
public enum HookEventBuilder {
    /// The 8 hook events Podium registers for for (kept in sync with
    /// HookInstaller.hookEvents).
    public static let handledEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    /// Returns (hookType, data) to POST, or nil if the payload is invalid or
    /// the event type is unhandled. `data` is always the raw parsed payload —
    /// hook.mjs posts `p` verbatim as `data`, it only builds `event` to decide
    /// *whether* to post, not what to send.
    public static func build(from payload: [String: Any]) -> (hookType: String, data: [String: Any])? {
        guard let hookEventName = payload["hook_event_name"] as? String, !hookEventName.isEmpty else {
            return nil
        }
        guard let sessionId = payload["session_id"], !isNullOrEmpty(sessionId) else {
            return nil
        }
        guard handledEvents.contains(hookEventName) else {
            return nil
        }
        return (hookEventName, payload)
    }

    private static func isNullOrEmpty(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let s = value as? String { return s.isEmpty }
        return false
    }
}
