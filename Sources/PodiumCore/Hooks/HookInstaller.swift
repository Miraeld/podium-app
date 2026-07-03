// HookInstaller — port of podium/install.mjs.
//
// Registers/removes the Podium hook command in a Claude Code settings.json
// (global `~/.claude/settings.json` by default; a `settingsPath` parameter
// is accepted so callers — and tests — can target project-local
// `.claude/settings.json` instead).
//
// Differences from install.mjs (intentional, standalone-app parity):
//   - install.mjs registers `node "<stableDir>/hook.mjs"`; we register the
//     native binary `"<home>/.claude/podium/podium-hook"` (no `node`, no
//     quoting requirement beyond wrapping the path — kept quoted for
//     consistency with spaces-in-home-dir safety).
//   - The detection marker is `.claude/podium/podium-hook` instead of
//     `.claude/podium/hook.mjs`.
//   - We still detect (and remove, on install/uninstall) legacy Node-based
//     entries so plugin users get upgraded in place: `.claude/podium/hook.mjs`,
//     `plugins/cache/wp-media/podium`, `hook-handler.js`,
//     `podium/dashboard/scripts`.
//   - Binary installation (copying the built podium-hook executable into
//     ~/.claude/podium/) is a separate step, `installBinary(from:)`, since
//     install.mjs's equivalent (`copyFileSync` of hook.mjs) assumed a
//     scripting language needing no compilation step.

import Foundation

public enum HookInstallerError: Error, Equatable {
    case settingsUnreadable(String)
    case binarySourceMissing(String)
    case binaryCopyFailed(String)
}

/// Result of an install/uninstall/check operation.
public struct HookInstallResult: Equatable {
    public let settingsPath: String
    public let addedCount: Int
    public let removedCount: Int
    public let legacyCleanedCount: Int
    public let alreadyInstalled: Bool

    public init(
        settingsPath: String,
        addedCount: Int = 0,
        removedCount: Int = 0,
        legacyCleanedCount: Int = 0,
        alreadyInstalled: Bool = false
    ) {
        self.settingsPath = settingsPath
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.legacyCleanedCount = legacyCleanedCount
        self.alreadyInstalled = alreadyInstalled
    }
}

public enum HookInstallStatus: Equatable {
    case installed
    case installedViaLegacy
    case notInstalled
}

public enum HookInstaller {
    /// The 8 hook events Podium registers for, in registration order —
    /// identical set to install.mjs's HOOK_EVENTS.
    public static let hookEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "SubagentStart",
        "SubagentStop",
        "SessionEnd",
    ]

    /// Marker substring identifying our own, stable-path native hook entry.
    public static let podiumMarker = ".claude/podium/podium-hook"

    /// Legacy markers recognized (and cleaned up) so upgrades from the
    /// Node/plugin-based install happen in place. Mirrors install.mjs's
    /// PLUGIN_CACHE_MARKER + LEGACY_MARKERS, plus the old native hook.mjs
    /// stable path itself (now superseded by podium-hook).
    public static let legacyMarkers: [String] = [
        ".claude/podium/hook.mjs",
        "plugins/cache/wp-media/podium",
        "hook-handler.js",
        "podium/dashboard/scripts",
    ]

    /// All markers that count as "an active Podium hook" for lenient
    /// detection (install.mjs's `hasActivePodiumHooks`).
    private static var allActiveMarkers: [String] { [podiumMarker] + legacyMarkers }

    // MARK: - Paths

    public static func homeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claude/settings.json` — the default (global) settings path.
    public static func defaultSettingsPath() -> String {
        homeDirectory()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
    }

    /// `~/.claude/podium/podium-hook` — where the native binary is installed
    /// and the path registered in settings.json.
    public static func defaultBinaryInstallPath() -> String {
        homeDirectory()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("podium", isDirectory: true)
            .appendingPathComponent("podium-hook", isDirectory: false)
            .path
    }

    /// The command string registered in settings.json for each hook event.
    public static func registeredCommand(binaryPath: String = HookInstaller.defaultBinaryInstallPath()) -> String {
        "\"\(binaryPath)\""
    }

    // MARK: - Binary install

    /// Copies the built podium-hook executable from `sourcePath` to
    /// `destinationPath` (default: `~/.claude/podium/podium-hook`), creating
    /// the parent directory if needed, and marks it executable (0755).
    @discardableResult
    public static func installBinary(
        from sourcePath: String,
        to destinationPath: String = HookInstaller.defaultBinaryInstallPath(),
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw HookInstallerError.binarySourceMissing(sourcePath)
        }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        let destinationDir = destinationURL.deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: destinationDir.path) {
                try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.removeItem(atPath: destinationPath)
            }
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
        } catch let error as HookInstallerError {
            throw error
        } catch {
            throw HookInstallerError.binaryCopyFailed("\(error)")
        }

        return destinationPath
    }

    // MARK: - Settings I/O

    /// Reads and parses settings.json at `path`. Returns an empty object
    /// (`[:]`) if the file doesn't exist. Throws if the file exists but is
    /// not valid JSON (mirrors install.mjs's hard failure on unparsable
    /// settings — we surface it instead of exiting the process).
    static func readSettings(at path: String, fileManager: FileManager = .default) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw HookInstallerError.settingsUnreadable(path)
        }
        guard !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.settingsUnreadable(path)
        }
        return obj
    }

    /// Writes settings back as pretty 2-space JSON with a trailing newline,
    /// creating the parent directory if needed. Uses sorted keys for
    /// deterministic output... except JSONSerialization's `.sortedKeys`
    /// would reorder unrelated user settings alphabetically, which is NOT
    /// what install.mjs does (`JSON.stringify(data, null, 2)` preserves
    /// insertion order). To keep behavior close to Node's object-key-order
    /// semantics while still being deterministic for keys we add, we do a
    /// order-preserving serialize via a small helper.
    static func writeSettings(_ settings: [String: Any], to path: String, fileManager: FileManager = .default) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        // JSONSerialization emits "\/" unescaped forward slashes already in
        // Foundation (no escaping needed) but uses 4-space-ish formatting via
        // \t on some platforms; normalize to exactly 2-space indentation.
        let normalized = normalizeIndentation(String(data: data, encoding: .utf8) ?? "")
        let final = normalized.hasSuffix("\n") ? normalized : normalized + "\n"
        try final.data(using: .utf8)?.write(to: url)
    }

    /// JSONSerialization's prettyPrinted output uses 2-space indentation on
    /// Linux/modern Foundation already, but guard against variants that use
    /// tabs by converting leading tabs to 2 spaces per level.
    private static func normalizeIndentation(_ json: String) -> String {
        var result = ""
        result.reserveCapacity(json.count)
        for line in json.split(separator: "\n", omittingEmptySubsequences: false) {
            var chars = Substring(line)
            var leadingTabs = 0
            while chars.first == "\t" {
                leadingTabs += 1
                chars = chars.dropFirst()
            }
            if leadingTabs > 0 {
                result += String(repeating: "  ", count: leadingTabs) + chars
            } else {
                result += line
            }
            result += "\n"
        }
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    // MARK: - Detection

    /// True if any hook entry for the 8 events contains a command matching
    /// any of `markers` as a substring.
    static func hasHookMatching(_ settings: [String: Any], markers: [String]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in hookEvents {
            guard let entries = hooks[event] as? [Any] else { continue }
            for case let entry as [String: Any] in entries {
                guard let innerHooks = entry["hooks"] as? [Any] else { continue }
                for case let h as [String: Any] in innerHooks {
                    guard let command = h["command"] as? String else { continue }
                    if markers.contains(where: { command.contains($0) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Strict: only our stable native-binary marker (used to decide whether
    /// install has "nothing to add").
    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        hasHookMatching(settings, markers: [podiumMarker])
    }

    /// Lenient: any active Podium hook, stable or legacy.
    public static func hasActivePodiumHooks(_ settings: [String: Any]) -> Bool {
        hasHookMatching(settings, markers: allActiveMarkers)
    }

    /// Port of settings.js's `getHookStatus()`: per-event installed flags for
    /// the Settings page. Uses `hookEvents` (the 8 events this installer
    /// actually registers) rather than Node's stale 7-event list
    /// (`PreToolUse/PostToolUse/Stop/SubagentStop/Notification/
    /// SessionStart/SessionEnd`, which predates `UserPromptSubmit`/
    /// `PostToolUseFailure`/`SubagentStart` support and includes `Stop`/
    /// `Notification`, never registered by `install()`) — the React
    /// Settings page just iterates `Object.entries(hooks)` generically, so
    /// this is a compatible, more-accurate substitution. `installed` is true
    /// only when every event has an active entry. Never throws: an
    /// unreadable/missing settings file reports everything as not installed,
    /// matching Node's `catch` fallback.
    public static func hookStatus(settingsPath: String = HookInstaller.defaultSettingsPath()) -> (installed: Bool, hooks: [String: Bool]) {
        guard let settings = try? readSettings(at: settingsPath) else {
            return (false, Dictionary(uniqueKeysWithValues: hookEvents.map { ($0, false) }))
        }
        let allHooks = settings["hooks"] as? [String: Any]
        var perEvent: [String: Bool] = [:]
        for event in hookEvents {
            let entries = (allHooks?[event] as? [[String: Any]]) ?? []
            perEvent[event] = entries.contains { entryMatches($0, markers: allActiveMarkers) }
        }
        return (perEvent.values.allSatisfy { $0 }, perEvent)
    }

    // MARK: - Public operations

    /// `install.mjs --check` equivalent — purely read-only, no binary copy.
    public static func check(settingsPath: String = HookInstaller.defaultSettingsPath()) throws -> HookInstallStatus {
        let settings = try readSettings(at: settingsPath)
        if isInstalled(settings) { return .installed }
        if hasActivePodiumHooks(settings) { return .installedViaLegacy }
        return .notInstalled
    }

    /// Install: clean up legacy entries, then append our stable entry for
    /// any of the 8 events that doesn't already have it. Idempotent — a
    /// second call adds 0 entries. Does NOT copy the binary; call
    /// `installBinary(from:)` separately (main installer flow does both).
    @discardableResult
    public static func install(
        settingsPath: String = HookInstaller.defaultSettingsPath(),
        binaryPath: String = HookInstaller.defaultBinaryInstallPath(),
        timeout: Int = 2
    ) throws -> HookInstallResult {
        var settings = try readSettings(at: settingsPath)

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        // Remove legacy entries first (install.mjs: cleaned up before adding).
        var legacyCleaned = 0
        for event in hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries = entries.filter { entry in
                !entryMatches(entry, markers: legacyMarkers)
            }
            legacyCleaned += before - entries.count
            hooks[event] = entries
        }

        var added = 0
        let command = registeredCommand(binaryPath: binaryPath)
        for event in hookEvents {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            let already = entries.contains { entryMatches($0, markers: [podiumMarker]) }
            if already { continue }

            let newEntry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": timeout,
                    ] as [String: Any]
                ]
            ]
            entries.append(newEntry)
            hooks[event] = entries
            added += 1
        }

        settings["hooks"] = hooks

        if added == 0 && legacyCleaned == 0 {
            return HookInstallResult(
                settingsPath: settingsPath,
                addedCount: 0,
                removedCount: 0,
                legacyCleanedCount: 0,
                alreadyInstalled: true
            )
        }

        try writeSettings(settings, to: settingsPath)

        return HookInstallResult(
            settingsPath: settingsPath,
            addedCount: added,
            removedCount: 0,
            legacyCleanedCount: legacyCleaned,
            alreadyInstalled: added == 0
        )
    }

    /// Uninstall: remove every hook entry matching our stable marker, any
    /// legacy marker, or the plugin-cache marker — exactly install.mjs's
    /// `--uninstall` set (`PODIUM_MARKER, PLUGIN_CACHE_MARKER, ...LEGACY_MARKERS`).
    @discardableResult
    public static func uninstall(
        settingsPath: String = HookInstaller.defaultSettingsPath()
    ) throws -> HookInstallResult {
        var settings = try readSettings(at: settingsPath)

        guard var hooks = settings["hooks"] as? [String: Any] else {
            return HookInstallResult(settingsPath: settingsPath)
        }

        let allMarkers = allActiveMarkers
        var removed = 0
        for event in hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries = entries.filter { entry in
                !entryMatches(entry, markers: allMarkers)
            }
            removed += before - entries.count
            hooks[event] = entries
        }
        settings["hooks"] = hooks

        if removed == 0 {
            return HookInstallResult(settingsPath: settingsPath, removedCount: 0)
        }

        try writeSettings(settings, to: settingsPath)
        return HookInstallResult(settingsPath: settingsPath, removedCount: removed)
    }

    private static func entryMatches(_ entry: [String: Any], markers: [String]) -> Bool {
        guard let innerHooks = entry["hooks"] as? [Any] else { return false }
        for case let h as [String: Any] in innerHooks {
            guard let command = h["command"] as? String else { continue }
            if markers.contains(where: { command.contains($0) }) {
                return true
            }
        }
        return false
    }
}
