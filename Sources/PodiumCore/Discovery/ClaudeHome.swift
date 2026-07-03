// ClaudeHome.swift — port of dashboard/server/lib/claude-home.js: resolves
// the Claude Code home directory (~/.claude by default, overridable), the
// `projects/` transcript tree beneath it, and the dashboard-owned durable
// transcript snapshot directory used once Claude Code prunes originals.
//
// Node persists a `CLAUDE_HOME` override to a `.env` file next to the server
// process (repo-relative — meaningless for a standalone app). This port
// persists the override instead to a small marker file inside
// `PodiumPaths.dataDir()` (`claude-home-override`), read back on next
// process start. The env var `CLAUDE_HOME` still wins parity-checks in tests
// but is second priority behind an explicit `setClaudeHome` override, exactly
// as Node's `process.env.CLAUDE_HOME = resolved` makes the override win for
// the remainder of that process's lifetime.

import Foundation

public enum ClaudeHomeError: Error, CustomStringConvertible, Equatable {
    case notAbsolute
    case doesNotExist(String)
    case notADirectory(String)

    public var description: String {
        switch self {
        case .notAbsolute:
            return "CLAUDE_HOME must be an absolute path"
        case .doesNotExist(let path):
            return "Directory does not exist: \(path)"
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        }
    }
}

public enum ClaudeHome {
    /// Environment lookup indirection so tests can inject a fake environment
    /// without mutating the real process environment (mirrors
    /// `PodiumPaths.environment`).
    public static var environment: [String: String] = ProcessInfo.processInfo.environment

    /// In-memory cache of the persisted override, loaded lazily. `nil` means
    /// "not loaded yet"; `.some(nil)` means "loaded, no override present".
    private static var overrideCache: String??

    private static var overrideFilePath: URL {
        PodiumPaths.dataDir().appendingPathComponent("claude-home-override", isDirectory: false)
    }

    /// Test-only: drop the in-memory override cache so a freshly-written
    /// override file (or a swapped `PodiumPaths.environment`/data dir) takes
    /// effect on the next `current()` call.
    public static func resetOverrideCacheForTesting() {
        overrideCache = nil
    }

    private static func loadOverride() -> String? {
        if case .some(let cached) = overrideCache { return cached }
        let value = try? String(contentsOf: overrideFilePath, encoding: .utf8)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty == false) ? trimmed : nil
        overrideCache = .some(resolved)
        return resolved
    }

    /// `getClaudeHome()` — resolution order: persisted override >
    /// `CLAUDE_HOME` env > `~/.claude`.
    public static func current() -> String {
        if let override = loadOverride() { return override }
        if let env = environment["CLAUDE_HOME"], !env.isEmpty { return env }
        return PodiumPaths.homeDirectory().appendingPathComponent(".claude", isDirectory: true).path
    }

    /// `getProjectsDir()`.
    public static func projectsDir() -> String {
        (current() as NSString).appendingPathComponent("projects")
    }

    /// `getTranscriptSnapshotDir()` — lives under this app's data dir rather
    /// than a repo-relative `../../data`, since a standalone app has no repo.
    public static func transcriptSnapshotDir() -> String {
        PodiumPaths.dataDir().appendingPathComponent("transcripts", isDirectory: true).path
    }

    /// `getSettingsPath()`.
    public static func settingsPath() -> String {
        (current() as NSString).appendingPathComponent("settings.json")
    }

    /// Claude Code path encoding: replace all non-alphanumeric characters
    /// with "-". Example: "/Users/txj/.codefuse" → "-Users-txj--codefuse".
    public static func encodeCwd(_ cwd: String) -> String {
        String(cwd.map { char -> Character in
            let isAlnum = char.isASCII && (char.isLetter || char.isNumber)
            return isAlnum ? char : "-"
        })
    }

    /// `getTranscriptPath(sessionId, cwd)`.
    public static func transcriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let encoded = encodeCwd(cwd)
        let candidate = (((projectsDir() as NSString).appendingPathComponent(encoded)) as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
        return findTranscriptPath(sessionId: sessionId)
    }

    /// `getSubagentTranscriptPath(sessionId, cwd, agentId)`.
    public static func subagentTranscriptPath(sessionId: String, cwd: String?, agentId: String) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let encoded = encodeCwd(cwd)
        let sessionDir = ((projectsDir() as NSString).appendingPathComponent(encoded) as NSString)
            .appendingPathComponent(sessionId)
        let subagentsDir = (sessionDir as NSString).appendingPathComponent("subagents")
        let candidate = (subagentsDir as NSString).appendingPathComponent("agent-\(agentId).jsonl")
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
        return findSubagentTranscriptPath(sessionId: sessionId, agentId: agentId)
    }

    /// `findTranscriptPath(sessionId)` — scan `projects/*/​<sessionId>.jsonl`
    /// when the cwd-derived direct path doesn't exist.
    public static func findTranscriptPath(sessionId: String) -> String? {
        let dir = projectsDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries.sorted() {
            let entryPath = (dir as NSString).appendingPathComponent(entry)
            guard isDirectory(entryPath) else { continue }
            let candidate = (entryPath as NSString).appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `findSubagentTranscriptPath(sessionId, agentId)` — exact match, plus
    /// prefix-fuzzy match for compaction agent ids (`acompact-*`).
    public static func findSubagentTranscriptPath(sessionId: String, agentId: String) -> String? {
        let dir = projectsDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries.sorted() {
            let entryPath = (dir as NSString).appendingPathComponent(entry)
            guard isDirectory(entryPath) else { continue }
            let subagentsDir = ((entryPath as NSString).appendingPathComponent(sessionId) as NSString)
                .appendingPathComponent("subagents")
            guard isDirectory(subagentsDir) else { continue }

            let exact = (subagentsDir as NSString).appendingPathComponent("agent-\(agentId).jsonl")
            if FileManager.default.fileExists(atPath: exact) { return exact }

            if agentId.hasPrefix("acompact-") {
                if let files = try? FileManager.default.contentsOfDirectory(atPath: subagentsDir),
                   let match = files.sorted().first(where: { $0.hasPrefix("agent-acompact-") && $0.hasSuffix(".jsonl") }) {
                    return (subagentsDir as NSString).appendingPathComponent(match)
                }
            }
        }
        return nil
    }

    /// `getSnapshotTranscriptPath(sessionId)`.
    public static func snapshotTranscriptPath(sessionId: String) -> String? {
        let candidate = (transcriptSnapshotDir() as NSString).appendingPathComponent("\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// `getSnapshotSubagentTranscriptPath(sessionId, agentId)`.
    public static func snapshotSubagentTranscriptPath(sessionId: String, agentId: String) -> String? {
        let subDir = ((transcriptSnapshotDir() as NSString).appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("subagents")
        guard isDirectory(subDir) else { return nil }
        let exact = (subDir as NSString).appendingPathComponent("agent-\(agentId).jsonl")
        if FileManager.default.fileExists(atPath: exact) { return exact }
        if agentId.hasPrefix("acompact-") {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: subDir),
               let match = files.sorted().first(where: { $0.hasPrefix("agent-acompact-") && $0.hasSuffix(".jsonl") }) {
                return (subDir as NSString).appendingPathComponent(match)
            }
        }
        return nil
    }

    /// `setClaudeHome(newPath)` — validates, persists, and applies the
    /// override immediately (mirrors Node setting `process.env.CLAUDE_HOME`
    /// synchronously before returning). Throws `ClaudeHomeError` for
    /// relative paths, missing directories, or non-directories.
    @discardableResult
    public static func setClaudeHome(_ newPath: String) throws -> String {
        var resolved = newPath
        if resolved == "~" {
            resolved = PodiumPaths.homeDirectory().path
        } else if resolved.hasPrefix("~/") {
            resolved = PodiumPaths.homeDirectory().path + resolved.dropFirst(1)
        }
        guard resolved.hasPrefix("/") else {
            throw ClaudeHomeError.notAbsolute
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ClaudeHomeError.doesNotExist(resolved)
        }
        guard isDirectory(resolved) else {
            throw ClaudeHomeError.notADirectory(resolved)
        }
        try resolved.write(to: overrideFilePath, atomically: true, encoding: .utf8)
        overrideCache = .some(resolved)
        return resolved
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &flag) else { return false }
        return flag.boolValue
    }
}
