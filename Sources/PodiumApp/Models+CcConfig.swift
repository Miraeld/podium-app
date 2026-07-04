#if os(macOS)
import Foundation

// MARK: - CC Config Explorer models (GET /api/cc-config/*)
//
// Client-side mirrors of `PodiumCore/Discovery/CcConfig.swift` and
// `CcMutate.swift`. Field names here match the server's Swift property
// names 1:1 (which is also the literal wire JSON key for AnyEncodable-
// backed types, and happens to already be camelCase-safe for the plain
// Codable types too — `.convertFromSnakeCase` only rewrites keys that
// contain underscores, so it leaves fields like `installPath`, `envNames`,
// `backupPath` untouched). No custom `CodingKeys` needed anywhere in this
// file — see the Phase-4 gate note in STANDALONE_PLAN.md §7 for the
// AnyEncodable fix that made this safe to build against.

// MARK: - Skills / Agents / Commands / Output Styles (list items)

struct CcSkillItem: Codable, Identifiable, Hashable {
    var scope: String
    var name: String
    var path: String
    var file: String
    var size: Int
    var mtime: Double
    var truncated: Bool
    var frontmatter: [String: String]
    var preview: String

    var id: String { file }
}

struct CcMdItem: Codable, Identifiable, Hashable {
    var scope: String
    var name: String
    var file: String
    var size: Int
    var mtime: Double
    var truncated: Bool
    var frontmatter: [String: String]
    var preview: String

    var id: String { file }
}

/// `{"items": [...]}` envelope every cc-config list endpoint wraps its
/// payload in (`CcConfigRouter`'s private `ItemsEnvelope`).
struct CcItemsEnvelope<Item: Codable & Hashable>: Codable {
    let items: [Item]
}

// MARK: - Plugins

struct CcPluginMdItem: Codable, Identifiable, Hashable {
    var name: String
    var file: String
    var description: String?
    var preview: String

    var id: String { file }
}

struct CcPluginContributions: Codable, Hashable {
    var skills: Int
    var skillItems: [CcPluginMdItem]
    var agents: Int
    var agentItems: [CcPluginMdItem]
    var commands: Int
    var commandItems: [CcPluginMdItem]
    var outputStyles: Int
    var hooks: Int
    var pluginJson: CcJSONValue?
}

struct CcPlugin: Codable, Identifiable, Hashable {
    var key: String
    var name: String
    var marketplace: String?
    var scope: String
    var version: String?
    var installPath: String?
    var installedAt: String?
    var lastUpdated: String?
    var gitCommitSha: String?
    var installPathExists: Bool
    var enabled: Bool?
    var contributes: CcPluginContributions?

    var id: String { key }
}

struct CcPluginsResponse: Codable {
    var manifestPath: String
    var manifestExists: Bool
    var plugins: [CcPlugin]
}

// MARK: - MCP servers

struct CcMcpServer: Codable, Identifiable, Hashable {
    var name: String
    var source: String
    var kind: String
    var url: String?
    var headers: [String]?
    var command: String?
    var args: [String]?
    var envNames: [String]?

    var id: String { "\(source)/\(name)" }
}

struct CcMcpResponse: Codable {
    var user: [CcMcpServer]
    var projectScoped: [CcMcpServer]
}

// MARK: - Hooks

struct CcHookEntry: Codable, Hashable {
    var matcher: String
    var type: String
    var command: String?
    var timeout: Double?
}

struct CcHooksSource: Codable, Identifiable, Hashable {
    var scope: String
    var file: String
    var exists: Bool
    /// Keyed by event name; each value is either a flattened `[CcHookEntry]`
    /// (known event types) or a raw JSON array (unknown event types). Kept
    /// as `CcJSONValue` so both shapes decode without loss.
    var hooks: [String: CcJSONValue]

    var id: String { file }
}

// MARK: - Settings

struct CcSettingsSource: Codable, Identifiable, Hashable {
    var scope: String
    var file: String
    var exists: Bool
    var data: CcJSONValue?
    var rawSize: Int?

    var id: String { file }
}

// MARK: - Marketplaces

struct CcMarketplace: Codable, Identifiable, Hashable {
    var name: String
    var source: CcJSONValue?
    var installLocation: String?
    var lastUpdated: String?
    var pluginCount: Int?
    var marketplaceName: String?
    var marketplaceDescription: String?
    var marketplaceOwner: CcJSONValue?

    var id: String { name }
}

struct CcMarketplacesResponse: Codable {
    var knownPath: String
    var knownExists: Bool
    var items: [CcMarketplace]
}

// MARK: - Keybindings

struct CcKeybindingEntry: Codable, Identifiable, Hashable {
    var key: String
    var action: String
    var id: String { key }
}

struct CcKeybindingGroup: Codable, Identifiable, Hashable {
    var context: String
    var bindings: [CcKeybindingEntry]
    var id: String { context }
}

struct CcKeybindingsResponse: Codable {
    var file: String
    var exists: Bool
    var schema: String?
    var docs: String?
    var groups: [CcKeybindingGroup]
}

// MARK: - Statusline

struct CcStatuslineScript: Codable, Identifiable, Hashable {
    var file: String
    var size: Int
    var mtime: Double
    var truncated: Bool
    var preview: String
    var id: String { file }
}

struct CcStatuslineResponse: Codable {
    var config: CcJSONValue?
    var scripts: [CcStatuslineScript]
}

// MARK: - Hook scripts

struct CcHookScriptItem: Codable, Identifiable, Hashable {
    var name: String
    var file: String
    var size: Int
    var mtime: Double
    var id: String { file }
}

struct CcHookScriptsResponse: Codable {
    var dir: String
    var items: [CcHookScriptItem]
}

// MARK: - Memory (CLAUDE.md)

struct CcMemoryItem: Codable, Identifiable, Hashable {
    var scope: String
    var file: String
    var size: Int
    var mtime: Double
    var truncated: Bool
    var preview: String
    var id: String { file }
}

// MARK: - Single-file body read (GET /api/cc-config/file)

struct CcFileReadResult: Codable {
    var ok: Bool
    var file: String?
    var truncated: Bool?
    var size: Int?
    var mtime: Double?
    var text: String?
    var error: String?
}

// MARK: - Overview

struct CcScopeCounts: Codable, Hashable {
    var user: Int
    var project: Int
}

struct CcMcpCounts: Codable, Hashable {
    var user: Int
    var project: Int
}

struct CcHookCounts: Codable, Hashable {
    var user: Int
    var project: Int
    var projectLocal: Int

    enum CodingKeys: String, CodingKey {
        case user, project
        case projectLocal = "project-local"
    }
}

struct CcOverviewCounts: Codable, Hashable {
    var skills: CcScopeCounts
    var agents: CcScopeCounts
    var commands: CcScopeCounts
    var outputStyles: CcScopeCounts
    var plugins: Int
    var pluginsEnabled: Int
    var pluginsDisabled: Int
    var marketplaces: Int
    var keybindings: Int
    var mcpServers: CcMcpCounts
    var hooks: CcHookCounts
    var memory: Int
    var settingsFiles: Int
}

struct CcOverviewRoots: Codable, Hashable {
    var claudeHome: String
    var projectClaudeDir: String
    var projectRoot: String
    var claudeJson: String
}

struct CcOverview: Codable {
    var roots: CcOverviewRoots
    var counts: CcOverviewCounts
}

// MARK: - Mutation (PUT/DELETE /api/cc-config/file)

struct CcWriteResult: Codable {
    var ok: Bool
    var file: String
    var target: String
    var backupPath: String?
    var created: Bool
}

struct CcDeleteResult: Codable {
    var ok: Bool
    var file: String
    var target: String
    var backupPath: String?
}

struct CcBackup: Codable, Identifiable, Hashable {
    var scope: String
    var type: String
    var name: String
    var backupPath: String
    var isDir: Bool
    var mtime: Double
    var size: Int?

    var id: String { backupPath }
}

// MARK: - Generic JSON value (settings/plugin.json/marketplace.json blobs)

enum CcJSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([CcJSONValue])
    case object([String: CcJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([CcJSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: CcJSONValue].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Pretty-printed JSON text, for display in a detail pane.
    var prettyText: String {
        guard let data = try? JSONEncoder.ccPretty.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }
}

private extension JSONEncoder {
    static let ccPretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

#endif
