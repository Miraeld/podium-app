import XCTest
@testable import PodiumCore

/// Regression coverage for P4 hardening-gate BLOCKER 2: `PodiumJSON.encoder`'s
/// `.convertToSnakeCase` re-transforms every resolved `CodingKey.stringValue`
/// uniformly, so several cc-config wire types that must match the Node API's
/// camelCase object literals (and, therefore, the vendored React client's
/// reads — see `dashboard/client/src/lib/api.ts` in the reference repo) were
/// coming out snake_cased. Fixed by giving each affected struct a custom
/// `encode(to:)` that writes a `[String: AnyEncodable]` (see
/// `PodiumJSON.AnyEncodable`'s doc comment for why that's the one path that
/// survives `.convertToSnakeCase`).
///
/// These assertions deliberately go through raw `Data` + `JSONSerialization`
/// (NOT `PodiumJSON.decoder` round-tripping back into the Swift struct) — a
/// round-trip through the same symmetric snake_case transform would mask the
/// exact bug this suite exists to catch.
final class CcConfigWireFormatTests: XCTestCase {
    private func encodeToJSONObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try PodiumJSON.encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Overview (roots + counts)

    func testOverviewRootsWireKeysAreCamelCase() throws {
        let roots = CcConfig.OverviewRoots(
            claudeHome: "/home/.claude",
            projectClaudeDir: "/proj/.claude",
            projectRoot: "/proj",
            claudeJson: "/home/.claude.json"
        )
        let json = try encodeToJSONObject(roots)
        XCTAssertEqual(json["claudeHome"] as? String, "/home/.claude")
        XCTAssertEqual(json["projectClaudeDir"] as? String, "/proj/.claude")
        XCTAssertEqual(json["projectRoot"] as? String, "/proj")
        XCTAssertEqual(json["claudeJson"] as? String, "/home/.claude.json")
        // None of the snake_case forms a naive .convertToSnakeCase pass
        // would have produced should be present.
        XCTAssertNil(json["claude_home"])
        XCTAssertNil(json["project_claude_dir"])
        XCTAssertNil(json["claude_json"])
    }

    func testOverviewCountsWireKeysAreCamelCase() throws {
        let counts = CcConfig.OverviewCounts(
            skills: .init(user: 1, project: 2),
            agents: .init(user: 0, project: 0),
            commands: .init(user: 0, project: 0),
            outputStyles: .init(user: 3, project: 4),
            plugins: 5,
            pluginsEnabled: 2,
            pluginsDisabled: 1,
            marketplaces: 1,
            keybindings: 0,
            mcpServers: .init(user: 6, project: 7),
            hooks: .init(user: 0, project: 0, projectLocal: 0),
            memory: 2,
            settingsFiles: 3
        )
        let json = try encodeToJSONObject(counts)
        XCTAssertNotNil(json["outputStyles"])
        XCTAssertEqual(json["pluginsEnabled"] as? Int, 2)
        XCTAssertEqual(json["pluginsDisabled"] as? Int, 1)
        XCTAssertNotNil(json["mcpServers"])
        XCTAssertEqual(json["settingsFiles"] as? Int, 3)
        XCTAssertNil(json["output_styles"])
        XCTAssertNil(json["plugins_enabled"])
        XCTAssertNil(json["plugins_disabled"])
        XCTAssertNil(json["mcp_servers"])
        XCTAssertNil(json["settings_files"])

        // mcpServers is itself nested — its own `user`/`project` fields are
        // single words, unaffected either way, but assert the container
        // survived intact.
        let mcpServers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertEqual(mcpServers["user"] as? Int, 6)
        XCTAssertEqual(mcpServers["project"] as? Int, 7)
    }

    // MARK: - MCP servers

    func testMcpServersResponseWireKeysAreCamelCase() throws {
        let response = CcConfig.McpServersResponse(
            user: [CcConfig.McpServerInfo(
                name: "user-server", source: "~/.claude/settings.json", kind: "stdio",
                url: nil, headers: nil, command: "node", args: ["server.js"], envNames: ["API_KEY"]
            )],
            projectScoped: [CcConfig.McpServerInfo(
                name: "proj-server", source: "~/.claude.json", kind: "http",
                url: "https://example.com", headers: ["X-Auth"], command: nil, args: nil, envNames: nil
            )]
        )
        let json = try encodeToJSONObject(response)
        XCTAssertNotNil(json["projectScoped"])
        XCTAssertNil(json["project_scoped"])

        let user = try XCTUnwrap(json["user"] as? [[String: Any]])
        XCTAssertEqual(user.first?["envNames"] as? [String], ["API_KEY"])
        XCTAssertNil(user.first?["env_names"])
    }

    // MARK: - Plugins

    func testPluginInfoAndContributionsWireKeysAreCamelCase() throws {
        let contributions = CcConfig.PluginContributions(
            skills: 1,
            skillItems: [.init(name: "s1", file: "/f/s1.md", description: nil, preview: "")],
            agents: 1,
            agentItems: [.init(name: "a1", file: "/f/a1.md", description: nil, preview: "")],
            commands: 1,
            commandItems: [.init(name: "c1", file: "/f/c1.md", description: nil, preview: "")],
            outputStyles: 0,
            hooks: 0,
            pluginJson: .object(["name": .string("my-plugin")])
        )
        let plugin = CcConfig.PluginInfo(
            key: "my-plugin@marketplace",
            name: "my-plugin",
            marketplace: "marketplace",
            scope: "user",
            version: "1.0.0",
            installPath: "/plugins/my-plugin",
            installedAt: "2024-01-01T00:00:00.000Z",
            lastUpdated: "2024-06-01T00:00:00.000Z",
            gitCommitSha: "abc123",
            installPathExists: true,
            enabled: true,
            contributes: contributions
        )
        let response = CcConfig.PluginsResponse(manifestPath: "/plugins/installed_plugins.json", manifestExists: true, plugins: [plugin])

        let json = try encodeToJSONObject(response)
        XCTAssertNotNil(json["manifestPath"])
        XCTAssertNotNil(json["manifestExists"])
        XCTAssertNil(json["manifest_path"])
        XCTAssertNil(json["manifest_exists"])

        let plugins = try XCTUnwrap(json["plugins"] as? [[String: Any]])
        let pluginJSON = try XCTUnwrap(plugins.first)
        XCTAssertEqual(pluginJSON["installPath"] as? String, "/plugins/my-plugin")
        XCTAssertEqual(pluginJSON["installedAt"] as? String, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(pluginJSON["lastUpdated"] as? String, "2024-06-01T00:00:00.000Z")
        XCTAssertEqual(pluginJSON["gitCommitSha"] as? String, "abc123")
        XCTAssertEqual(pluginJSON["installPathExists"] as? Bool, true)
        for badKey in ["install_path", "installed_at", "last_updated", "git_commit_sha", "install_path_exists"] {
            XCTAssertNil(pluginJSON[badKey], "unexpected snake_case key \(badKey)")
        }

        let contributesJSON = try XCTUnwrap(pluginJSON["contributes"] as? [String: Any])
        XCTAssertNotNil(contributesJSON["skillItems"])
        XCTAssertNotNil(contributesJSON["agentItems"])
        XCTAssertNotNil(contributesJSON["commandItems"])
        XCTAssertNotNil(contributesJSON["outputStyles"])
        XCTAssertNotNil(contributesJSON["pluginJson"])
        for badKey in ["skill_items", "agent_items", "command_items", "output_styles", "plugin_json"] {
            XCTAssertNil(contributesJSON[badKey], "unexpected snake_case key \(badKey)")
        }
    }

    // MARK: - Marketplaces

    func testMarketplaceWireKeysAreCamelCase() throws {
        let marketplace = CcConfig.MarketplaceInfo(
            name: "official",
            source: .object(["repo": .string("anthropics/claude-code")]),
            installLocation: "/marketplaces/official",
            lastUpdated: "2024-06-01T00:00:00.000Z",
            pluginCount: 12,
            marketplaceName: "Official Marketplace",
            marketplaceDescription: "The official one",
            marketplaceOwner: .object(["name": .string("Anthropic")])
        )
        let response = CcConfig.MarketplacesResponse(knownPath: "/plugins/known_marketplaces.json", knownExists: true, items: [marketplace])

        let json = try encodeToJSONObject(response)
        XCTAssertNotNil(json["knownPath"])
        XCTAssertNotNil(json["knownExists"])
        XCTAssertNil(json["known_path"])
        XCTAssertNil(json["known_exists"])

        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["installLocation"] as? String, "/marketplaces/official")
        XCTAssertEqual(item["lastUpdated"] as? String, "2024-06-01T00:00:00.000Z")
        XCTAssertEqual(item["pluginCount"] as? Int, 12)
        XCTAssertEqual(item["marketplaceName"] as? String, "Official Marketplace")
        XCTAssertEqual(item["marketplaceDescription"] as? String, "The official one")
        XCTAssertNotNil(item["marketplaceOwner"])
        for badKey in ["install_location", "last_updated", "plugin_count", "marketplace_name", "marketplace_description", "marketplace_owner"] {
            XCTAssertNil(item[badKey], "unexpected snake_case key \(badKey)")
        }
    }

    // MARK: - CcMutate results

    func testWriteResultAndDeleteResultBackupPathIsCamelCase() throws {
        let write = CcMutate.WriteResult(ok: true, file: "/f/hello.md", target: "/f/hello.md", backupPath: "/f/cc-config-backups/hello.md.bak", created: false)
        let writeJSON = try encodeToJSONObject(write)
        XCTAssertEqual(writeJSON["backupPath"] as? String, "/f/cc-config-backups/hello.md.bak")
        XCTAssertNil(writeJSON["backup_path"])

        let delete = CcMutate.DeleteResult(ok: true, file: "/f/hello.md", target: "/f/hello.md", backupPath: "/f/cc-config-backups/hello.md.bak")
        let deleteJSON = try encodeToJSONObject(delete)
        XCTAssertEqual(deleteJSON["backupPath"] as? String, "/f/cc-config-backups/hello.md.bak")
        XCTAssertNil(deleteJSON["backup_path"])
    }

    func testBackupEntryWireKeysAreCamelCase() throws {
        let entry = CcMutate.BackupEntry(scope: "user", type: "commands", name: "hello.md.2024.bak", backupPath: "/f/hello.md.2024.bak", isDir: false, mtime: 1_700_000_000_000, size: 42)
        let json = try encodeToJSONObject(entry)
        XCTAssertEqual(json["backupPath"] as? String, "/f/hello.md.2024.bak")
        XCTAssertEqual(json["isDir"] as? Bool, false)
        XCTAssertNil(json["backup_path"])
        XCTAssertNil(json["is_dir"])
    }

    // MARK: - Decode side stays intact (custom encode(to:) shouldn't affect synthesized init(from:))

    func testOverviewRootsStillDecodesFromItsOwnEncodedForm() throws {
        let roots = CcConfig.OverviewRoots(claudeHome: "/h", projectClaudeDir: "/p/.claude", projectRoot: "/p", claudeJson: "/h.json")
        let data = try PodiumJSON.encoder.encode(roots)
        let decoded = try PodiumJSON.decoder.decode(CcConfig.OverviewRoots.self, from: data)
        XCTAssertEqual(decoded, roots)
    }
}
