// CcConfig.swift — port of dashboard/server/lib/cc-discovery.js: read-only
// discovery of Claude Code configuration surfaces (skills, subagents, slash
// commands, output styles, plugins, marketplaces, MCP servers, hooks,
// settings, memory, keybindings, statusline, hook scripts). Powers the
// Claude Config Explorer dashboard page.
//
// Path containment: every read resolves under `ClaudeHome.current()`,
// `projectClaudeDir(cwd:)`, or `projectRoot(cwd:)` (for CLAUDE.md only).
// Reads outside those roots return nil/an error. Settings are redacted of
// secret-like keys before returning (`CcConfig.redactSettings`).
//
// All types here are `Codable` + snake_case-friendly (encoded via
// `PodiumJSON.encoder`, same as every other PodiumCore model) so
// `CcConfigRouter` can hand these straight to `JSONResponse`.

import Foundation

public enum CcConfig {
    /// `MAX_FILE_BYTES` — skip reads above this; truncate body in details.
    public static let maxFileBytes = 256 * 1024

    /// `REDACT_KEY_RE` — case-insensitive match on secret-shaped key names.
    private static let redactKeyPattern = try! NSRegularExpression(
        pattern: "token|secret|password|api[_-]?key|auth",
        options: [.caseInsensitive]
    )

    /// `HOOK_EVENT_TYPES` — known hook event names surfaced explicitly by
    /// `readHooks`; anything else found in a settings file's `hooks` object
    /// is still surfaced, just under its own literal key.
    public static let hookEventTypes = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Stop", "SubagentStop", "Notification", "PreCompact",
    ]

    // MARK: - Path helpers

    public static func projectRoot(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else {
            return FileManager.default.currentDirectoryPath
        }
        return (cwd as NSString).standardizingPath.hasPrefix("/") ? (cwd as NSString).standardizingPath : URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    public static func projectClaudeDir(cwd: String?) -> String {
        (projectRoot(cwd: cwd) as NSString).appendingPathComponent(".claude")
    }

    /// `~/.claude.json` sits beside `~/.claude/`, NOT inside it. Resolved
    /// from `$HOME` so a CLAUDE_HOME override doesn't relocate it.
    public static func claudeJsonPath() -> String {
        (PodiumPaths.homeDirectory().path as NSString).appendingPathComponent(".claude.json")
    }

    /// True if `target` is contained within `root` (after resolving `.`/
    /// `..` segments) — defends `readFileSafe` against traversal / absolute-
    /// path tricks. Mirrors cc-discovery.js's `isUnder`.
    public static func isUnder(_ root: String, _ target: String) -> Bool {
        let r = (root as NSString).standardizingPath
        let t = (target as NSString).standardizingPath
        if t == r { return true }
        return t.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: - Low-level FS helpers

    struct JSONReadResult {
        let ok: Bool
        let data: JSONValue?
        let raw: String?
        let missing: Bool

        static func success(data: JSONValue, raw: String) -> JSONReadResult { JSONReadResult(ok: true, data: data, raw: raw, missing: false) }
        static func missingFile() -> JSONReadResult { JSONReadResult(ok: false, data: nil, raw: nil, missing: true) }
        static func failure() -> JSONReadResult { JSONReadResult(ok: false, data: nil, raw: nil, missing: false) }
    }

    static func readJSON(_ path: String) -> JSONReadResult {
        guard FileManager.default.fileExists(atPath: path) else { return .missingFile() }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return .failure() }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .failure() }
        return .success(data: value, raw: raw)
    }

    /// Recursively redacts values under secret-shaped keys — port of
    /// cc-discovery.js's `redactSettings`.
    public static func redactSettings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map(redactSettings))
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (key, v) in dict {
                if case .string = v, matchesRedactKey(key) {
                    out[key] = .string("<redacted>")
                } else {
                    out[key] = redactSettings(v)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    private static func matchesRedactKey(_ key: String) -> Bool {
        let range = NSRange(key.startIndex..., in: key)
        return redactKeyPattern.firstMatch(in: key, options: [], range: range) != nil
    }

    /// Minimal YAML-frontmatter parser: handles `---\n<key>: <value>\n---\n<body>`.
    /// Quoted strings (single + double) are stripped; multi-line continuation
    /// values (indented lines following a key) are appended with `\n`.
    /// Port of cc-discovery.js's `parseFrontmatter`.
    public static func parseFrontmatter(_ text: String) -> (frontmatter: [String: String]?, body: String) {
        guard text.hasPrefix("---") else { return (nil, text) }
        // Find "\n---" starting the search from index 3.
        let startIndex = text.index(text.startIndex, offsetBy: 3)
        guard let endRange = text.range(of: "\n---", range: startIndex..<text.endIndex) else {
            return (nil, text)
        }
        var head = String(text[startIndex..<endRange.lowerBound])
        head = stripLeadingBlankLine(head)
        let afterMarker = text.index(endRange.lowerBound, offsetBy: 4)
        var body = afterMarker < text.endIndex ? String(text[afterMarker...]) : ""
        body = stripLeadingBlankLine(body)

        var fm: [String: String] = [:]
        var currentKey: String?
        let lines = head.components(separatedBy: "\n")
        for rawLine in lines {
            let line = trimTrailingWhitespace(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let key = currentKey, rawLine.first.map({ $0 == " " || $0 == "\t" }) == true {
                fm[key, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let match = matchKeyValue(line) else {
                currentKey = nil
                continue
            }
            currentKey = match.key
            var v = match.value
            if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
                v = String(v.dropFirst().dropLast())
            }
            fm[match.key] = v
        }
        return (fm, body)
    }

    private static func stripLeadingBlankLine(_ text: String) -> String {
        guard let range = text.range(of: "^\\s*\\n", options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" || last == "\r" {
            s.removeLast()
        }
        return String(s)
    }

    private static func matchKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let range = line.range(of: "^([A-Za-z0-9_-]+):\\s*(.*)$", options: .regularExpression) else { return nil }
        let matched = String(line[range])
        guard let colonIndex = matched.firstIndex(of: ":") else { return nil }
        let key = String(matched[matched.startIndex..<colonIndex])
        var value = String(matched[matched.index(after: colonIndex)...])
        value = value.trimmingCharacters(in: .init(charactersIn: " ")).trimmingCharacters(in: CharacterSet(charactersIn: " \t")).trimmingLeadingWhitespace()
        return (key, value)
    }

    struct SafeTextRead {
        let truncated: Bool
        let size: Int
        let text: String
        let mtime: Double
    }

    static func safeReadText(_ path: String) -> SafeTextRead? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = ((attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
        guard let data = fm.contents(atPath: path) else { return nil }
        if size > maxFileBytes {
            let truncatedData = data.prefix(maxFileBytes)
            let text = String(data: truncatedData, encoding: .utf8) ?? ""
            return SafeTextRead(truncated: true, size: size, text: text, mtime: mtime)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return SafeTextRead(truncated: false, size: size, text: text, mtime: mtime)
    }

    static func listDir(_ path: String) -> [(name: String, isDirectory: Bool)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return entries.compactMap { name in
            var isDir: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
            return (name, isDir.boolValue)
        }
    }

    // MARK: - Skills

    public struct SkillItem: Codable, Equatable, Sendable {
        public var scope: String
        public var name: String
        public var path: String
        public var file: String
        public var size: Int
        public var mtime: Double
        public var truncated: Bool
        public var frontmatter: [String: String]
        public var preview: String
    }

    static func readSkillsAt(scope: String, claudeDir: String) -> [SkillItem] {
        let dir = (claudeDir as NSString).appendingPathComponent("skills")
        var out: [SkillItem] = []
        for entry in listDir(dir) where entry.isDirectory {
            let skillDir = (dir as NSString).appendingPathComponent(entry.name)
            let skillFile = (skillDir as NSString).appendingPathComponent("SKILL.md")
            guard let read = safeReadText(skillFile) else { continue }
            let (frontmatter, body) = parseFrontmatter(read.text)
            out.append(SkillItem(
                scope: scope, name: entry.name, path: skillDir, file: skillFile,
                size: read.size, mtime: read.mtime, truncated: read.truncated,
                frontmatter: frontmatter ?? [:], preview: String(body.prefix(320))
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    public static func readSkills(scope: String, cwd: String?) -> [SkillItem] {
        var out: [SkillItem] = []
        if scope != "project" { out.append(contentsOf: readSkillsAt(scope: "user", claudeDir: ClaudeHome.current())) }
        if scope != "user" { out.append(contentsOf: readSkillsAt(scope: "project", claudeDir: projectClaudeDir(cwd: cwd))) }
        return out
    }

    // MARK: - Single-file MD surfaces (agents, commands, output styles)

    public struct MdItem: Codable, Equatable, Sendable {
        public var scope: String
        public var name: String
        public var file: String
        public var size: Int
        public var mtime: Double
        public var truncated: Bool
        public var frontmatter: [String: String]
        public var preview: String
    }

    static func readMdFilesAt(scope: String, claudeDir: String, subdir: String) -> [MdItem] {
        let dir = (claudeDir as NSString).appendingPathComponent(subdir)
        var out: [MdItem] = []
        for entry in listDir(dir) where !entry.isDirectory && entry.name.hasSuffix(".md") {
            let file = (dir as NSString).appendingPathComponent(entry.name)
            guard let read = safeReadText(file) else { continue }
            let (frontmatter, body) = parseFrontmatter(read.text)
            let name = String(entry.name.dropLast(3))
            out.append(MdItem(
                scope: scope, name: name, file: file, size: read.size, mtime: read.mtime,
                truncated: read.truncated, frontmatter: frontmatter ?? [:], preview: String(body.prefix(320))
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func readSimpleMdSurface(subdir: String, scope: String, cwd: String?) -> [MdItem] {
        var out: [MdItem] = []
        if scope != "project" { out.append(contentsOf: readMdFilesAt(scope: "user", claudeDir: ClaudeHome.current(), subdir: subdir)) }
        if scope != "user" { out.append(contentsOf: readMdFilesAt(scope: "project", claudeDir: projectClaudeDir(cwd: cwd), subdir: subdir)) }
        return out
    }

    public static func readAgents(scope: String, cwd: String?) -> [MdItem] { readSimpleMdSurface(subdir: "agents", scope: scope, cwd: cwd) }
    public static func readCommands(scope: String, cwd: String?) -> [MdItem] { readSimpleMdSurface(subdir: "commands", scope: scope, cwd: cwd) }
    public static func readOutputStyles(scope: String, cwd: String?) -> [MdItem] { readSimpleMdSurface(subdir: "output-styles", scope: scope, cwd: cwd) }

    // MARK: - Plugins

    public struct PluginMdItem: Codable, Equatable, Sendable {
        public var name: String
        public var file: String
        public var description: String?
        public var preview: String
    }

    static func countMdIn(_ dir: String) -> Int {
        listDir(dir).filter { !$0.isDirectory && $0.name.hasSuffix(".md") }.count
    }

    static func listMdItemsIn(_ dir: String) -> [PluginMdItem] {
        listDir(dir).filter { !$0.isDirectory && $0.name.hasSuffix(".md") }.map { entry in
            let file = (dir as NSString).appendingPathComponent(entry.name)
            let read = safeReadText(file)
            let (frontmatter, body) = read.map { parseFrontmatter($0.text) } ?? (nil, "")
            return PluginMdItem(name: String(entry.name.dropLast(3)), file: file, description: frontmatter?["description"], preview: String(body.prefix(320)))
        }.sorted { $0.name < $1.name }
    }

    static func listSkillItemsIn(_ dir: String) -> [PluginMdItem] {
        listDir(dir).filter { entry in
            guard entry.isDirectory else { return false }
            let skillMd = (dir as NSString).appendingPathComponent(entry.name) as NSString
            return FileManager.default.fileExists(atPath: skillMd.appendingPathComponent("SKILL.md"))
        }.map { entry in
            let file = ((dir as NSString).appendingPathComponent(entry.name) as NSString).appendingPathComponent("SKILL.md")
            let read = safeReadText(file)
            let (frontmatter, body) = read.map { parseFrontmatter($0.text) } ?? (nil, "")
            return PluginMdItem(name: entry.name, file: file, description: frontmatter?["description"], preview: String(body.prefix(320)))
        }.sorted { $0.name < $1.name }
    }

    public struct PluginContributions: Codable, Equatable, Sendable {
        public var skills: Int
        public var skillItems: [PluginMdItem]
        public var agents: Int
        public var agentItems: [PluginMdItem]
        public var commands: Int
        public var commandItems: [PluginMdItem]
        public var outputStyles: Int
        public var hooks: Int
        public var pluginJson: JSONValue?

        // skillItems/agentItems/commandItems/outputStyles/pluginJson must
        // stay literal camelCase (client's `CcPluginContributions`) — see
        // `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "skills": AnyEncodable(skills),
                "skillItems": AnyEncodable(skillItems),
                "agents": AnyEncodable(agents),
                "agentItems": AnyEncodable(agentItems),
                "commands": AnyEncodable(commands),
                "commandItems": AnyEncodable(commandItems),
                "outputStyles": AnyEncodable(outputStyles),
                "hooks": AnyEncodable(hooks),
                "pluginJson": AnyEncodable(pluginJson),
            ])
        }
    }

    static func readPluginContributions(installPath: String?) -> PluginContributions? {
        guard let installPath, !installPath.isEmpty else { return nil }
        let pluginJsonPath = ((installPath as NSString).appendingPathComponent(".claude-plugin") as NSString).appendingPathComponent("plugin.json")
        let pluginJson = readJSON(pluginJsonPath).data

        let commandItems = listMdItemsIn((installPath as NSString).appendingPathComponent("commands"))
        let agentItems = listMdItemsIn((installPath as NSString).appendingPathComponent("agents"))
        let skillItems = listSkillItemsIn((installPath as NSString).appendingPathComponent("skills"))
        let hooksDir = (installPath as NSString).appendingPathComponent("hooks")
        let hookCount = listDir(hooksDir).filter { !$0.isDirectory }.count

        return PluginContributions(
            skills: skillItems.count, skillItems: skillItems,
            agents: agentItems.count, agentItems: agentItems,
            commands: commandItems.count, commandItems: commandItems,
            outputStyles: countMdIn((installPath as NSString).appendingPathComponent("output-styles")),
            hooks: hookCount, pluginJson: pluginJson
        )
    }

    static func readEnabledPluginsMap() -> [String: Bool] {
        let settingsPath = (ClaudeHome.current() as NSString).appendingPathComponent("settings.json")
        let result = readJSON(settingsPath)
        guard result.ok, let data = result.data, case .object(let root) = data,
              case .object(let enabledPlugins)? = root["enabledPlugins"] else { return [:] }
        var out: [String: Bool] = [:]
        for (key, value) in enabledPlugins {
            if case .bool(let b) = value { out[key] = b }
        }
        return out
    }

    public struct PluginInfo: Codable, Equatable, Sendable {
        public var key: String
        public var name: String
        public var marketplace: String?
        public var scope: String
        public var version: String?
        public var installPath: String?
        public var installedAt: String?
        public var lastUpdated: String?
        public var gitCommitSha: String?
        public var installPathExists: Bool
        public var enabled: Bool?
        public var contributes: PluginContributions?

        // installPath/installedAt/lastUpdated/gitCommitSha/installPathExists
        // must stay literal camelCase (client's `CcPlugin`) — see
        // `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "key": AnyEncodable(key),
                "name": AnyEncodable(name),
                "marketplace": AnyEncodable(marketplace),
                "scope": AnyEncodable(scope),
                "version": AnyEncodable(version),
                "installPath": AnyEncodable(installPath),
                "installedAt": AnyEncodable(installedAt),
                "lastUpdated": AnyEncodable(lastUpdated),
                "gitCommitSha": AnyEncodable(gitCommitSha),
                "installPathExists": AnyEncodable(installPathExists),
                "enabled": AnyEncodable(enabled),
                "contributes": AnyEncodable(contributes),
            ])
        }
    }

    public struct PluginsResponse: Codable, Equatable, Sendable {
        public var manifestPath: String
        public var manifestExists: Bool
        public var plugins: [PluginInfo]

        // manifestPath/manifestExists must stay literal camelCase (client's
        // `CcPluginsResponse`) — see `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "manifestPath": AnyEncodable(manifestPath),
                "manifestExists": AnyEncodable(manifestExists),
                "plugins": AnyEncodable(plugins),
            ])
        }
    }

    public static func readPlugins() -> PluginsResponse {
        let home = ClaudeHome.current()
        let manifestPath = ((home as NSString).appendingPathComponent("plugins") as NSString).appendingPathComponent("installed_plugins.json")
        let manifest = readJSON(manifestPath)
        let enabledMap = readEnabledPluginsMap()
        var plugins: [PluginInfo] = []

        if manifest.ok, let data = manifest.data, case .object(let root) = data,
           case .object(let pluginsMap)? = root["plugins"] {
            for (pluginKey, instancesValue) in pluginsMap {
                let instances: [JSONValue]
                if case .array(let arr) = instancesValue { instances = arr } else { instances = [instancesValue] }
                for instJSON in instances {
                    guard case .object(let inst) = instJSON else { continue }
                    let installPath = inst["installPath"]?.stringValue
                    var exists = false
                    if let installPath {
                        var isDir: ObjCBool = false
                        exists = FileManager.default.fileExists(atPath: installPath, isDirectory: &isDir) && isDir.boolValue
                    }
                    let contributes = exists ? readPluginContributions(installPath: installPath) : nil
                    let baseName = pluginKey.split(separator: "@", maxSplits: 1).first.map(String.init) ?? pluginKey
                    let enabledByKey = enabledMap[pluginKey]
                    let enabledByName = enabledMap[baseName]
                    let enabled: Bool? = {
                        if enabledByKey == true || enabledByName == true { return true }
                        if enabledByKey == false || enabledByName == false { return false }
                        return nil
                    }()
                    plugins.append(PluginInfo(
                        key: pluginKey,
                        name: baseName,
                        marketplace: pluginKey.contains("@") ? String(pluginKey.split(separator: "@", maxSplits: 1)[1]) : nil,
                        scope: inst["scope"]?.stringValue ?? "user",
                        version: inst["version"]?.stringValue,
                        installPath: installPath,
                        installedAt: inst["installedAt"]?.stringValue,
                        lastUpdated: inst["lastUpdated"]?.stringValue,
                        gitCommitSha: inst["gitCommitSha"]?.stringValue,
                        installPathExists: exists,
                        enabled: enabled,
                        contributes: contributes
                    ))
                }
            }
        }
        return PluginsResponse(manifestPath: manifestPath, manifestExists: manifest.ok, plugins: plugins.sorted { $0.key < $1.key })
    }

    // MARK: - MCP servers

    public struct McpServerInfo: Codable, Equatable, Sendable {
        public var name: String
        public var source: String
        public var kind: String
        public var url: String?
        public var headers: [String]?
        public var command: String?
        public var args: [String]?
        public var envNames: [String]?

        // `envNames` must stay literal camelCase on the wire (client reads
        // `server.envNames`) — see `AnyEncodable`'s doc comment for why a
        // `CodingKeys` raw value alone can't survive `PodiumJSON.encoder`'s
        // `.convertToSnakeCase`. Encoded literally throughout for consistency.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "name": AnyEncodable(name),
                "source": AnyEncodable(source),
                "kind": AnyEncodable(kind),
                "url": AnyEncodable(url),
                "headers": AnyEncodable(headers),
                "command": AnyEncodable(command),
                "args": AnyEncodable(args),
                "envNames": AnyEncodable(envNames),
            ])
        }
    }

    public struct McpServersResponse: Codable, Equatable, Sendable {
        public var user: [McpServerInfo]
        public var projectScoped: [McpServerInfo]

        // `projectScoped` must stay literal camelCase (client reads
        // `CcMcpResponse.projectScoped`) — see `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "user": AnyEncodable(user),
                "projectScoped": AnyEncodable(projectScoped),
            ])
        }
    }

    static func summarizeMcpDef(_ def: JSONValue, name: String, source: String) -> McpServerInfo {
        guard case .object(let obj) = def else {
            return McpServerInfo(name: name, source: source, kind: "unknown", url: nil, headers: nil, command: nil, args: nil, envNames: nil)
        }
        if let url = obj["url"]?.stringValue {
            let headerKeys: [String]?
            if case .object(let headers)? = obj["headers"] { headerKeys = Array(headers.keys) } else { headerKeys = [] }
            return McpServerInfo(name: name, source: source, kind: "http", url: url, headers: headerKeys, command: nil, args: nil, envNames: nil)
        }
        if let command = obj["command"]?.stringValue {
            var args: [String] = []
            if case .array(let arr)? = obj["args"] { args = arr.compactMap(\.stringValue) }
            var envNames: [String] = []
            if case .object(let env)? = obj["env"] { envNames = Array(env.keys) }
            return McpServerInfo(name: name, source: source, kind: "stdio", url: nil, headers: nil, command: command, args: args, envNames: envNames)
        }
        return McpServerInfo(name: name, source: source, kind: "unknown", url: nil, headers: nil, command: nil, args: nil, envNames: nil)
    }

    public static func readMcpServers(cwd: String?) -> McpServersResponse {
        var user: [McpServerInfo] = []
        var projectScoped: [McpServerInfo] = []

        let claudeJson = readJSON(claudeJsonPath())
        if claudeJson.ok, let data = claudeJson.data, case .object(let root) = data {
            if case .object(let top)? = root["mcpServers"] {
                for (name, def) in top {
                    user.append(summarizeMcpDef(def, name: name, source: "~/.claude.json (top-level)"))
                }
            }
            if case .object(let projects)? = root["projects"] {
                let projectRootPath = projectRoot(cwd: cwd)
                if case .object(let projectEntry)? = projects[projectRootPath],
                   case .object(let mcpServers)? = projectEntry["mcpServers"] {
                    for (name, def) in mcpServers {
                        projectScoped.append(summarizeMcpDef(def, name: name, source: "~/.claude.json (projects[\(projectRootPath)])"))
                    }
                }
            }
        }

        let settingsPath = (ClaudeHome.current() as NSString).appendingPathComponent("settings.json")
        let userSettings = readJSON(settingsPath)
        if userSettings.ok, let data = userSettings.data, case .object(let root) = data,
           case .object(let mcpServers)? = root["mcpServers"] {
            for (name, def) in mcpServers {
                user.append(summarizeMcpDef(def, name: name, source: "~/.claude/settings.json"))
            }
        }

        return McpServersResponse(user: user, projectScoped: projectScoped)
    }

    // MARK: - Hooks

    public struct HookEntry: Codable, Equatable, Sendable {
        public var matcher: String
        public var type: String
        public var command: String?
        public var timeout: Double?
    }

    public struct HooksSource: Codable, Equatable, Sendable {
        public var scope: String
        public var file: String
        public var exists: Bool
        /// Keyed by event name; each entry is either the flattened
        /// `[HookEntry]` (known event types) or the raw JSON matchers array
        /// (unknown event types, surfaced verbatim). Represented as
        /// `JSONValue` so both shapes encode identically to Node's output.
        public var hooks: [String: JSONValue]
    }

    static func hooksSources(cwd: String?) -> [(scope: String, file: String)] {
        [
            ("user", (ClaudeHome.current() as NSString).appendingPathComponent("settings.json")),
            ("project", (projectClaudeDir(cwd: cwd) as NSString).appendingPathComponent("settings.json")),
            ("project-local", (projectClaudeDir(cwd: cwd) as NSString).appendingPathComponent("settings.local.json")),
        ]
    }

    public static func readHooks(cwd: String?) -> [HooksSource] {
        var result: [HooksSource] = []
        for (scope, file) in hooksSources(cwd: cwd) {
            let j = readJSON(file)
            var hooksOut: [String: JSONValue] = [:]
            if j.ok, let data = j.data, case .object(let root) = data, case .object(let hooksObj)? = root["hooks"] {
                for event in hookEventTypes {
                    guard case .array(let matchers)? = hooksObj[event] else { continue }
                    var flat: [JSONValue] = []
                    for matcherValue in matchers {
                        guard case .object(let matcherObj) = matcherValue else { continue }
                        let matcher = matcherObj["matcher"]?.stringValue ?? "*"
                        guard case .array(let hookList)? = matcherObj["hooks"] else { continue }
                        for hookValue in hookList {
                            guard case .object(let hookObj) = hookValue else { continue }
                            let type = hookObj["type"]?.stringValue ?? "command"
                            let command = hookObj["command"]?.stringValue
                            var timeout: JSONValue = .null
                            if case .number(let n)? = hookObj["timeout"] { timeout = .number(n) }
                            flat.append(.object([
                                "matcher": .string(matcher), "type": .string(type),
                                "command": command.map(JSONValue.string) ?? .null, "timeout": timeout,
                            ]))
                        }
                    }
                    if !flat.isEmpty { hooksOut[event] = .array(flat) }
                }
                // Surface unknown events verbatim.
                for (event, matchers) in hooksObj {
                    guard !hookEventTypes.contains(event) else { continue }
                    guard case .array = matchers else { continue }
                    hooksOut[event] = matchers
                }
            }
            result.append(HooksSource(scope: scope, file: file, exists: j.ok, hooks: hooksOut))
        }
        return result
    }

    // MARK: - Settings

    public struct SettingsSource: Codable, Equatable, Sendable {
        public var scope: String
        public var file: String
        public var exists: Bool
        public var data: JSONValue?
        public var rawSize: Int?
    }

    public static func readSettings(cwd: String?) -> [SettingsSource] {
        hooksSources(cwd: cwd).map { scope, file in
            let j = readJSON(file)
            guard j.ok, let data = j.data else { return SettingsSource(scope: scope, file: file, exists: false, data: nil, rawSize: nil) }
            return SettingsSource(scope: scope, file: file, exists: true, data: redactSettings(data), rawSize: j.raw?.utf8.count)
        }
    }

    // MARK: - Marketplaces

    public struct MarketplaceInfo: Codable, Equatable, Sendable {
        public var name: String
        public var source: JSONValue?
        public var installLocation: String?
        public var lastUpdated: String?
        public var pluginCount: Int?
        public var marketplaceName: String?
        public var marketplaceDescription: String?
        public var marketplaceOwner: JSONValue?

        // installLocation/lastUpdated/pluginCount/marketplaceName/
        // marketplaceDescription/marketplaceOwner must stay literal
        // camelCase (client's `CcMarketplace`) — see `AnyEncodable`'s doc
        // comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "name": AnyEncodable(name),
                "source": AnyEncodable(source),
                "installLocation": AnyEncodable(installLocation),
                "lastUpdated": AnyEncodable(lastUpdated),
                "pluginCount": AnyEncodable(pluginCount),
                "marketplaceName": AnyEncodable(marketplaceName),
                "marketplaceDescription": AnyEncodable(marketplaceDescription),
                "marketplaceOwner": AnyEncodable(marketplaceOwner),
            ])
        }
    }

    public struct MarketplacesResponse: Codable, Equatable, Sendable {
        public var knownPath: String
        public var knownExists: Bool
        public var items: [MarketplaceInfo]

        // knownPath/knownExists must stay literal camelCase (client's
        // `CcMarketplacesResponse`) — see `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "knownPath": AnyEncodable(knownPath),
                "knownExists": AnyEncodable(knownExists),
                "items": AnyEncodable(items),
            ])
        }
    }

    public static func readMarketplaces() -> MarketplacesResponse {
        let home = ClaudeHome.current()
        let knownPath = ((home as NSString).appendingPathComponent("plugins") as NSString).appendingPathComponent("known_marketplaces.json")
        let known = readJSON(knownPath)
        var out: [MarketplaceInfo] = []
        if known.ok, let data = known.data, case .object(let root) = data {
            for (name, defValue) in root {
                guard case .object(let def) = defValue else { continue }
                let installLocation = def["installLocation"]?.stringValue
                let sourceDef = def["source"]
                var pluginCount: Int?
                var marketplaceJson: JSONValue?
                if let installLocation {
                    let mfPath = ((installLocation as NSString).appendingPathComponent(".claude-plugin") as NSString).appendingPathComponent("marketplace.json")
                    let r = readJSON(mfPath)
                    if r.ok, let data = r.data {
                        marketplaceJson = data
                        if case .object(let mfObj) = data, case .array(let plugins)? = mfObj["plugins"] {
                            pluginCount = plugins.count
                        }
                    }
                }
                var marketplaceName: String?
                var marketplaceDescription: String?
                var marketplaceOwner: JSONValue?
                if case .object(let mfObj)? = marketplaceJson {
                    marketplaceName = mfObj["name"]?.stringValue
                    marketplaceDescription = mfObj["description"]?.stringValue
                    marketplaceOwner = mfObj["owner"]
                }
                out.append(MarketplaceInfo(
                    name: name,
                    source: (sourceDef.map { if case .object = $0 { return $0 } else { return nil } }) ?? nil,
                    installLocation: installLocation,
                    lastUpdated: def["lastUpdated"]?.stringValue,
                    pluginCount: pluginCount,
                    marketplaceName: marketplaceName,
                    marketplaceDescription: marketplaceDescription,
                    marketplaceOwner: marketplaceOwner
                ))
            }
        }
        return MarketplacesResponse(knownPath: knownPath, knownExists: known.ok, items: out.sorted { $0.name < $1.name })
    }

    // MARK: - Keybindings

    public struct KeybindingEntry: Codable, Equatable, Sendable {
        public var key: String
        public var action: String
    }

    public struct KeybindingGroup: Codable, Equatable, Sendable {
        public var context: String
        public var bindings: [KeybindingEntry]
    }

    public struct KeybindingsResponse: Codable, Equatable, Sendable {
        public var file: String
        public var exists: Bool
        public var schema: String?
        public var docs: String?
        public var groups: [KeybindingGroup]

        public init(file: String, exists: Bool, schema: String? = nil, docs: String? = nil, groups: [KeybindingGroup] = []) {
            self.file = file
            self.exists = exists
            self.schema = schema
            self.docs = docs
            self.groups = groups
        }
    }

    public static func readKeybindings() -> KeybindingsResponse {
        let file = (ClaudeHome.current() as NSString).appendingPathComponent("keybindings.json")
        let j = readJSON(file)
        guard j.ok, let data = j.data, case .object(let root) = data else {
            return KeybindingsResponse(file: file, exists: j.ok)
        }
        let schema = root["$schema"]?.stringValue
        let docs = root["$docs"]?.stringValue
        var groups: [KeybindingGroup] = []
        if case .array(let arr)? = root["bindings"] {
            for groupValue in arr {
                guard case .object(let g) = groupValue else { continue }
                let context = g["context"]?.stringValue ?? ""
                var bindings: [KeybindingEntry] = []
                if case .object(let bindingsObj)? = g["bindings"] {
                    for (key, action) in bindingsObj {
                        bindings.append(KeybindingEntry(key: key, action: stringify(action)))
                    }
                }
                groups.append(KeybindingGroup(context: context, bindings: bindings))
            }
        }
        return KeybindingsResponse(file: file, exists: true, schema: schema, docs: docs, groups: groups)
    }

    private static func stringify(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        default: return (try? String(data: PodiumJSON.encoder.encode(value), encoding: .utf8) ?? "") ?? ""
        }
    }

    // MARK: - Statusline

    public struct StatuslineScript: Codable, Equatable, Sendable {
        public var file: String
        public var size: Int
        public var mtime: Double
        public var truncated: Bool
        public var preview: String
    }

    public struct StatuslineResponse: Codable, Equatable, Sendable {
        public var config: JSONValue?
        public var scripts: [StatuslineScript]
    }

    public static func readStatusline() -> StatuslineResponse {
        let userSettingsPath = (ClaudeHome.current() as NSString).appendingPathComponent("settings.json")
        let j = readJSON(userSettingsPath)
        var config: JSONValue?
        if j.ok, let data = j.data, case .object(let root) = data, let statusLine = root["statusLine"] {
            config = statusLine
        }
        let candidates = [
            (ClaudeHome.current() as NSString).appendingPathComponent("statusline.py"),
            (ClaudeHome.current() as NSString).appendingPathComponent("statusline-command.sh"),
            (ClaudeHome.current() as NSString).appendingPathComponent("statusline-command.cmd"),
            (ClaudeHome.current() as NSString).appendingPathComponent("statusline-command.bat"),
        ]
        var scripts: [StatuslineScript] = []
        for file in candidates {
            guard let r = safeReadText(file) else { continue }
            scripts.append(StatuslineScript(file: file, size: r.size, mtime: r.mtime, truncated: r.truncated, preview: String(r.text.prefix(4000))))
        }
        return StatuslineResponse(config: config, scripts: scripts)
    }

    // MARK: - Hook handler scripts (~/.claude/hooks/)

    public struct HookScriptItem: Codable, Equatable, Sendable {
        public var name: String
        public var file: String
        public var size: Int
        public var mtime: Double
    }

    public struct HookScriptsResponse: Codable, Equatable, Sendable {
        public var dir: String
        public var items: [HookScriptItem]
    }

    public static func readHookScripts() -> HookScriptsResponse {
        let dir = (ClaudeHome.current() as NSString).appendingPathComponent("hooks")
        var items: [HookScriptItem] = []
        for entry in listDir(dir) where !entry.isDirectory {
            let file = (dir as NSString).appendingPathComponent(entry.name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file) else { continue }
            let size = (attrs[.size] as? Int) ?? 0
            let mtime = ((attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
            items.append(HookScriptItem(name: entry.name, file: file, size: size, mtime: mtime))
        }
        return HookScriptsResponse(dir: dir, items: items.sorted { $0.name < $1.name })
    }

    // MARK: - Memory (CLAUDE.md)

    public struct MemoryItem: Codable, Equatable, Sendable {
        public var scope: String
        public var file: String
        public var size: Int
        public var mtime: Double
        public var truncated: Bool
        public var preview: String
    }

    public static func readMemory(cwd: String?) -> [MemoryItem] {
        let sources = [
            ("user", (ClaudeHome.current() as NSString).appendingPathComponent("CLAUDE.md")),
            ("project", (projectRoot(cwd: cwd) as NSString).appendingPathComponent("CLAUDE.md")),
        ]
        var result: [MemoryItem] = []
        for (scope, file) in sources {
            guard let r = safeReadText(file) else { continue }
            result.append(MemoryItem(scope: scope, file: file, size: r.size, mtime: r.mtime, truncated: r.truncated, preview: String(r.text.prefix(480))))
        }
        return result
    }

    // MARK: - Single-file body endpoint (with strict path containment)

    public struct FileReadResult: Codable, Equatable, Sendable {
        public var ok: Bool
        public var file: String?
        public var truncated: Bool?
        public var size: Int?
        public var mtime: Double?
        public var text: String?
        public var error: String?

        static func failure(_ message: String) -> FileReadResult {
            FileReadResult(ok: false, file: nil, truncated: nil, size: nil, mtime: nil, text: nil, error: message)
        }
    }

    /// Port of `readFileSafe(absPath, opts)` — every candidate path must
    /// resolve inside `ClaudeHome.current()`, `projectClaudeDir(cwd:)`, or
    /// (for `CLAUDE.md` only) `projectRoot(cwd:)`.
    public static func readFileSafe(_ path: String, cwd: String?) -> FileReadResult {
        let allowedRoots = [ClaudeHome.current(), projectClaudeDir(cwd: cwd), projectRoot(cwd: cwd)]
        let resolved = (path as NSString).standardizingPath
        let inside = allowedRoots.contains { isUnder($0, resolved) }
        guard inside else { return .failure("path is outside allowed roots") }

        if isUnder(projectRoot(cwd: cwd), resolved),
           !isUnder(projectClaudeDir(cwd: cwd), resolved),
           (resolved as NSString).lastPathComponent != "CLAUDE.md" {
            return .failure("only CLAUDE.md is readable from project root")
        }

        guard let r = safeReadText(resolved) else { return .failure("file not readable") }
        return FileReadResult(ok: true, file: resolved, truncated: r.truncated, size: r.size, mtime: r.mtime, text: r.text, error: nil)
    }

    // MARK: - Overview (counts + roots)

    public struct ScopeCounts: Codable, Equatable, Sendable {
        public var user: Int
        public var project: Int
    }

    public struct McpCounts: Codable, Equatable, Sendable {
        public var user: Int
        public var project: Int
    }

    public struct HookCounts: Codable, Equatable, Sendable {
        public var user: Int
        public var project: Int
        public var projectLocal: Int

        enum CodingKeys: String, CodingKey {
            case user, project
            case projectLocal = "project-local"
        }
    }

    public struct OverviewCounts: Codable, Equatable, Sendable {
        public var skills: ScopeCounts
        public var agents: ScopeCounts
        public var commands: ScopeCounts
        public var outputStyles: ScopeCounts
        public var plugins: Int
        public var pluginsEnabled: Int
        public var pluginsDisabled: Int
        public var marketplaces: Int
        public var keybindings: Int
        public var mcpServers: McpCounts
        public var hooks: HookCounts
        public var memory: Int
        public var settingsFiles: Int

        // outputStyles/pluginsEnabled/pluginsDisabled/mcpServers/
        // settingsFiles must stay literal camelCase (client's
        // `CcOverview.counts`) — see `AnyEncodable`'s doc comment. All keys
        // encoded literally here for consistency, even the single-word ones
        // `.convertToSnakeCase` would leave alone anyway.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "skills": AnyEncodable(skills),
                "agents": AnyEncodable(agents),
                "commands": AnyEncodable(commands),
                "outputStyles": AnyEncodable(outputStyles),
                "plugins": AnyEncodable(plugins),
                "pluginsEnabled": AnyEncodable(pluginsEnabled),
                "pluginsDisabled": AnyEncodable(pluginsDisabled),
                "marketplaces": AnyEncodable(marketplaces),
                "keybindings": AnyEncodable(keybindings),
                "mcpServers": AnyEncodable(mcpServers),
                "hooks": AnyEncodable(hooks),
                "memory": AnyEncodable(memory),
                "settingsFiles": AnyEncodable(settingsFiles),
            ])
        }
    }

    public struct OverviewRoots: Codable, Equatable, Sendable {
        public var claudeHome: String
        public var projectClaudeDir: String
        public var projectRoot: String
        public var claudeJson: String

        // Every field here must stay literal camelCase (client's
        // `CcOverview.roots`) — see `AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "claudeHome": AnyEncodable(claudeHome),
                "projectClaudeDir": AnyEncodable(projectClaudeDir),
                "projectRoot": AnyEncodable(projectRoot),
                "claudeJson": AnyEncodable(claudeJson),
            ])
        }
    }

    public struct OverviewResponse: Codable, Equatable, Sendable {
        public var roots: OverviewRoots
        public var counts: OverviewCounts
    }

    public static func readOverview(cwd: String?) -> OverviewResponse {
        let skills = readSkills(scope: "all", cwd: cwd)
        let agents = readAgents(scope: "all", cwd: cwd)
        let commands = readCommands(scope: "all", cwd: cwd)
        let outputStyles = readOutputStyles(scope: "all", cwd: cwd)
        let plugins = readPlugins()
        let mcp = readMcpServers(cwd: cwd)
        let hooks = readHooks(cwd: cwd)
        let settings = readSettings(cwd: cwd)
        let memory = readMemory(cwd: cwd)
        let marketplaces = readMarketplaces()
        let keybindings = readKeybindings()

        func countByScope(_ items: [(scope: String, isUser: Bool)]) -> ScopeCounts {
            ScopeCounts(user: items.filter { $0.scope == "user" }.count, project: items.filter { $0.scope == "project" }.count)
        }

        let enabledPlugins = plugins.plugins.filter { $0.enabled == true }.count
        let disabledPlugins = plugins.plugins.filter { $0.enabled == false }.count
        let keybindingTotal = keybindings.exists ? keybindings.groups.reduce(0) { $0 + $1.bindings.count } : 0

        var hookCounts = HookCounts(user: 0, project: 0, projectLocal: 0)
        for source in hooks {
            let count = source.hooks.values.reduce(0) { sum, value in
                if case .array(let arr) = value { return sum + arr.count }
                return sum
            }
            switch source.scope {
            case "user": hookCounts.user = count
            case "project": hookCounts.project = count
            case "project-local": hookCounts.projectLocal = count
            default: break
            }
        }

        return OverviewResponse(
            roots: OverviewRoots(
                claudeHome: ClaudeHome.current(),
                projectClaudeDir: projectClaudeDir(cwd: cwd),
                projectRoot: projectRoot(cwd: cwd),
                claudeJson: claudeJsonPath()
            ),
            counts: OverviewCounts(
                skills: ScopeCounts(user: skills.filter { $0.scope == "user" }.count, project: skills.filter { $0.scope == "project" }.count),
                agents: ScopeCounts(user: agents.filter { $0.scope == "user" }.count, project: agents.filter { $0.scope == "project" }.count),
                commands: ScopeCounts(user: commands.filter { $0.scope == "user" }.count, project: commands.filter { $0.scope == "project" }.count),
                outputStyles: ScopeCounts(user: outputStyles.filter { $0.scope == "user" }.count, project: outputStyles.filter { $0.scope == "project" }.count),
                plugins: plugins.plugins.count,
                pluginsEnabled: enabledPlugins,
                pluginsDisabled: disabledPlugins,
                marketplaces: marketplaces.items.count,
                keybindings: keybindingTotal,
                mcpServers: McpCounts(user: mcp.user.count, project: mcp.projectScoped.count),
                hooks: hookCounts,
                memory: memory.count,
                settingsFiles: settings.filter(\.exists).count
            )
        )
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        var s = Substring(self)
        while let first = s.first, first == " " || first == "\t" {
            s.removeFirst()
        }
        return String(s)
    }
}
