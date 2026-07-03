// ServerInfoWriter — port of dashboard/server/lib/server-info.js's
// `writeServerInfo` / `removeServerInfo`.
//
// Writes `~/.claude/.agent-dashboard.json` in the multi-server format
// `HookClient`/`HookPortDiscovery` (Sources/PodiumCore/Hooks/HookClient.swift)
// reads: `{"port","pid","startedAt","servers":[{"port","pid","startedAt"}]}`.
// The root-level `port`/`pid`/`startedAt` fields are the legacy single-record
// shape kept for backwards compatibility with hook handlers that predate the
// multi-server format (set to the most-recently-started live entry).
//
// Every operation here is best-effort and never throws — discovery must
// never block server startup or shutdown.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ServerInfoWriter {
    /// `~/.claude/.agent-dashboard.json` — same path `HookPortDiscovery.defaultInfoPath()` reads.
    public static func infoPath() -> URL {
        HookPortDiscovery.defaultInfoPath()
    }

    /// Record this process's live port, preserving other still-alive
    /// servers' entries and dropping dead ones. Best-effort: any failure
    /// (permissions, disk full, …) is silently ignored.
    public static func write(port: Int, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard port > 0 else { return }
        let path = infoPath()
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = readEntries(at: path).filter { entry in
                entry.pid != Int(pid) && isPidAlive(entry.pid)
            }
            let ours = ServerInfoRecord(
                port: port,
                pid: Int(pid),
                startedAt: PodiumDate.now()
            )
            try persist(existing + [ours], to: path)
        } catch {
            // Discovery is an optimization, not a requirement.
        }
    }

    /// Remove this process's entry (called on graceful shutdown). Safe to
    /// call when the file is absent or doesn't contain our entry.
    public static func remove(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let path = infoPath()
        let remaining = readEntries(at: path).filter { $0.pid != Int(pid) }
        try? persist(remaining, to: path)
    }

    // MARK: - Internal record + I/O

    private struct ServerInfoRecord {
        let port: Int
        let pid: Int
        let startedAt: String
    }

    private static func readEntries(at path: URL) -> [ServerInfoRecord] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let servers = obj["servers"] as? [Any] {
            return servers.compactMap { element -> ServerInfoRecord? in
                guard let dict = element as? [String: Any],
                      let port = intValue(dict["port"]) else { return nil }
                return ServerInfoRecord(
                    port: port,
                    pid: intValue(dict["pid"]) ?? 0,
                    startedAt: dict["startedAt"] as? String ?? PodiumDate.now()
                )
            }
        }
        if let port = intValue(obj["port"]) {
            return [ServerInfoRecord(
                port: port,
                pid: intValue(obj["pid"]) ?? 0,
                startedAt: obj["startedAt"] as? String ?? PodiumDate.now()
            )]
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

    /// PID liveness probe (kill(pid, 0)); EPERM counts as alive, matching
    /// hook.mjs / server-info.js semantics. A missing/zero pid is treated as
    /// alive (nothing to prune it by).
    private static func isPidAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Write `{port, pid, startedAt, servers}` via temp file + atomic rename.
    /// An empty `entries` list removes the file entirely (mirrors
    /// server-info.js's `persist([])` behavior).
    private static func persist(_ entries: [ServerInfoRecord], to path: URL) throws {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: path)
            return
        }
        let recent = entries.max { a, b in
            (PodiumDate.parse(a.startedAt) ?? .distantPast) < (PodiumDate.parse(b.startedAt) ?? .distantPast)
        } ?? entries[0]

        let payload: [String: Any] = [
            "port": recent.port,
            "pid": recent.pid,
            "startedAt": recent.startedAt,
            "servers": entries.map { entry -> [String: Any] in
                ["port": entry.port, "pid": entry.pid, "startedAt": entry.startedAt]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        let tmpPath = path.appendingPathExtension("\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: tmpPath)
        // Atomic rename: remove any existing file first (moveItem requires the
        // destination not to exist, on both Darwin and Linux Foundation).
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: tmpPath, to: path)
    }
}
