#if os(macOS)
import Foundation

// MARK: - CC Config Explorer API (GET/PUT/DELETE /api/cc-config/*)
//
// Mirrors `Sources/PodiumServer/Routes/CcConfigRouter.swift`. Read-only
// discovery (`GET`) surfaces are literal camelCase-safe under
// `JSONDecoder.podium`'s `.convertFromSnakeCase` (no underscores to rewrite
// in fields like `installPath`/`envNames`/`backupPath`) — see
// `Models+CcConfig.swift`'s header comment. Mutation (`PUT`/`DELETE`) is
// the low-risk text-artifact surface only (skills/agents/commands/
// output-styles/memory) — plugins, MCP servers, and settings.json are
// intentionally NOT mutable here, matching `CcMutate.swift`'s hard
// constraints.
//
// NOTE: PodiumAPI.get(url:)/post(_:body:) are private, so — like
// PodiumAPI+Search.swift — this extension implements HTTP directly rather
// than reaching into the actor's private interface.

extension PodiumAPI {

    // MARK: Query helpers

    private func ccURL(_ path: String, scope: String? = nil, cwd: String? = nil, extra: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "/api/cc-config\(path)"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let scope { items.append(.init(name: "scope", value: scope)) }
        if let cwd, !cwd.isEmpty { items.append(.init(name: "cwd", value: cwd)) }
        items.append(contentsOf: extra)
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url!
    }

    private func ccGet<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(CcErrorBody.self, from: data))?.error
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0, message: body?.message)
        }
        return try JSONDecoder.podium.decode(T.self, from: data)
    }

    // MARK: Overview + list surfaces

    func ccOverview(cwd: String? = nil) async throws -> CcOverview {
        try await ccGet(ccURL("/overview", cwd: cwd))
    }

    func ccSkills(scope: String = "all", cwd: String? = nil) async throws -> [CcSkillItem] {
        let envelope: CcItemsEnvelope<CcSkillItem> = try await ccGet(ccURL("/skills", scope: scope, cwd: cwd))
        return envelope.items
    }

    func ccAgents(scope: String = "all", cwd: String? = nil) async throws -> [CcMdItem] {
        let envelope: CcItemsEnvelope<CcMdItem> = try await ccGet(ccURL("/agents", scope: scope, cwd: cwd))
        return envelope.items
    }

    func ccCommands(scope: String = "all", cwd: String? = nil) async throws -> [CcMdItem] {
        let envelope: CcItemsEnvelope<CcMdItem> = try await ccGet(ccURL("/commands", scope: scope, cwd: cwd))
        return envelope.items
    }

    func ccOutputStyles(scope: String = "all", cwd: String? = nil) async throws -> [CcMdItem] {
        let envelope: CcItemsEnvelope<CcMdItem> = try await ccGet(ccURL("/output-styles", scope: scope, cwd: cwd))
        return envelope.items
    }

    func ccPlugins() async throws -> CcPluginsResponse {
        try await ccGet(ccURL("/plugins"))
    }

    func ccMcpServers(cwd: String? = nil) async throws -> CcMcpResponse {
        try await ccGet(ccURL("/mcp", cwd: cwd))
    }

    func ccHooks(cwd: String? = nil) async throws -> [CcHooksSource] {
        let envelope: CcItemsEnvelope<CcHooksSource> = try await ccGet(ccURL("/hooks", cwd: cwd))
        return envelope.items
    }

    func ccSettings(cwd: String? = nil) async throws -> [CcSettingsSource] {
        let envelope: CcItemsEnvelope<CcSettingsSource> = try await ccGet(ccURL("/settings", cwd: cwd))
        return envelope.items
    }

    func ccMemory(cwd: String? = nil) async throws -> [CcMemoryItem] {
        let envelope: CcItemsEnvelope<CcMemoryItem> = try await ccGet(ccURL("/memory", cwd: cwd))
        return envelope.items
    }

    func ccMarketplaces() async throws -> CcMarketplacesResponse {
        try await ccGet(ccURL("/marketplaces"))
    }

    func ccKeybindings() async throws -> CcKeybindingsResponse {
        try await ccGet(ccURL("/keybindings"))
    }

    func ccStatusline() async throws -> CcStatuslineResponse {
        try await ccGet(ccURL("/statusline"))
    }

    func ccHookScripts() async throws -> CcHookScriptsResponse {
        try await ccGet(ccURL("/hook-scripts"))
    }

    /// `type` filters to a single mutable artifact kind (skills/agents/
    /// commands/output-styles/memory); omit for all types. `scope` filters
    /// to user/project; omit for both.
    func ccBackups(scope: String? = nil, type: String? = nil, cwd: String? = nil) async throws -> [CcBackup] {
        var extra: [URLQueryItem] = []
        if let type { extra.append(.init(name: "type", value: type)) }
        let envelope: CcItemsEnvelope<CcBackup> = try await ccGet(ccURL("/backups", scope: scope, cwd: cwd, extra: extra))
        return envelope.items
    }

    // MARK: Single file body (GET /api/cc-config/file)

    func ccReadFile(path: String, cwd: String? = nil) async throws -> CcFileReadResult {
        try await ccGet(ccURL("/file", cwd: cwd, extra: [.init(name: "path", value: path)]))
    }

    // MARK: Mutation (PUT / DELETE /api/cc-config/file)

    /// Create or overwrite a mutable text artifact. `type` is one of
    /// skills/agents/commands/output-styles/memory; `name` is required for
    /// everything except memory (CLAUDE.md has no name). Always backs up
    /// the previous version first (`CcMutate.writeArtifact`).
    func ccWriteFile(scope: String, type: String, name: String?, content: String, cwd: String? = nil) async throws -> CcWriteResult {
        var dict: [String: String] = ["scope": scope, "type": type, "content": content]
        if let name { dict["name"] = name }
        let body = try JSONEncoder().encode(dict)
        var req = URLRequest(url: ccURL("/file", cwd: cwd))
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(CcErrorBody.self, from: data))?.error
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0, message: body?.message)
        }
        return try JSONDecoder.podium.decode(CcWriteResult.self, from: data)
    }

    /// Delete a mutable text artifact. Always backs up first
    /// (`CcMutate.deleteArtifact`) — the backup is recoverable via
    /// `ccBackups`.
    func ccDeleteFile(scope: String, type: String, name: String?, cwd: String? = nil) async throws -> CcDeleteResult {
        var dict: [String: String] = ["scope": scope, "type": type]
        if let name { dict["name"] = name }
        let body = try JSONEncoder().encode(dict)
        var req = URLRequest(url: ccURL("/file", cwd: cwd))
        req.httpMethod = "DELETE"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(CcErrorBody.self, from: data))?.error
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0, message: body?.message)
        }
        return try JSONDecoder.podium.decode(CcDeleteResult.self, from: data)
    }
}

/// `{"error": {"code", "message"}}` — matches `CodedErrorResponse` on the
/// server (cc-config.js's `ERR_TO_STATUS` table via `CcConfigRouter`).
private struct CcErrorBody: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

#endif
