#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Config Explorer View
//
// Three-pane layout: category list │ item list │ detail.
//
// NOTE (root-cause history): this view used to be a nested 3-column
// `NavigationSplitView` placed *inside* ContentView's outer split view.
// AppKit does not reliably propagate a custom-struct `List(selection:)`
// binding back up through two stacked split views, so selecting a category
// or item left the middle/detail panes blank. The selection state also got
// wiped because `loadItems()` reset it on every `.onAppear`.
//
// The fix is an explicit `HStack` of three panes driven by plain `@State`
// and wired with `.onChange`, so every selection deterministically updates
// the next pane.

struct ConfigExplorerView: View {
    @Environment(AppState.self) var state

    @State private var selectedCategory: ConfigCategory = .settings
    @State private var items: [ConfigItem] = []
    @State private var selectedItem: ConfigItem?

    private var projectCwd: String? { state.sessions.first?.cwd }

    var body: some View {
        HStack(spacing: 0) {
            categoryColumn
                .frame(width: 200)

            Divider().opacity(0.4)

            itemColumn
                .frame(width: 280)

            Divider().opacity(0.4)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeBackground())
        .navigationTitle("CC Config Explorer")
        .onAppear { reloadItems() }
        .onChange(of: selectedCategory) { _, _ in reloadItems() }
    }

    // MARK: Columns

    private var categoryColumn: some View {
        List(ConfigCategory.allCases, id: \.self, selection: $selectedCategory) { category in
            Label(category.label, systemImage: category.icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 3)
                .tag(category)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var itemColumn: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(
                    icon: selectedCategory.icon,
                    title: "No \(selectedCategory.label) found",
                    message: emptyMessage
                )
                .padding()
            } else {
                List(items, selection: $selectedItem) { item in
                    ConfigItemRow(item: item)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var detailColumn: some View {
        Group {
            if let item = selectedItem {
                ConfigDetailView(item: item)
                    .id(item.id)   // force a fresh load when the selection changes
            } else {
                ConfigEmptyDetail()
            }
        }
    }

    private var emptyMessage: String {
        switch selectedCategory {
        case .settings:   return "No settings.json found under ~/.claude."
        case .agents:     return "No agent .md files found under ~/.claude/agents (or the project's .claude/agents)."
        case .skills:     return "No skill folders found under ~/.claude/skills."
        case .commands:   return "No command .md files found under ~/.claude/commands."
        case .mcpServers: return "No mcpServers configured in ~/.claude/settings.json."
        case .claudeMd:   return "No CLAUDE.md found in ~/.claude or the active project."
        }
    }

    // MARK: Loading

    private func reloadItems() {
        let loaded = ConfigLoader.items(for: selectedCategory, projectCwd: projectCwd)
        items = loaded
        // Keep the current selection if it still exists; otherwise clear it so
        // the detail pane doesn't show a stale file from the previous category.
        if let sel = selectedItem, loaded.contains(where: { $0.id == sel.id }) {
            // keep
        } else {
            selectedItem = nil
        }
    }
}

// MARK: - Category enum

enum ConfigCategory: String, CaseIterable, Hashable {
    case settings   = "settings"
    case agents     = "agents"
    case skills     = "skills"
    case commands   = "commands"
    case mcpServers = "mcp"
    case claudeMd   = "claudemd"

    var label: String {
        switch self {
        case .settings:   return "Settings"
        case .agents:     return "Agents"
        case .skills:     return "Skills"
        case .commands:   return "Commands"
        case .mcpServers: return "MCP Servers"
        case .claudeMd:   return "CLAUDE.md"
        }
    }

    var icon: String {
        switch self {
        case .settings:   return "gearshape"
        case .agents:     return "person.2"
        case .skills:     return "bolt"
        case .commands:   return "terminal"
        case .mcpServers: return "server.rack"
        case .claudeMd:   return "doc.text"
        }
    }
}

// MARK: - Config Item model

struct ConfigItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL
    let kind: ConfigItemKind

    enum ConfigItemKind: Hashable {
        case jsonFile
        case markdownFile
        case mcpServer(command: String)
        case skillDir
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ConfigItem, rhs: ConfigItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Loader (pure, testable, no view state)

enum ConfigLoader {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var claudeDir: URL { home.appendingPathComponent(".claude") }

    static func items(for category: ConfigCategory, projectCwd: String?) -> [ConfigItem] {
        switch category {
        case .settings:
            return loadSettingsItems()
        case .agents:
            return loadMarkdownItems(dirs: agentDirs(projectCwd: projectCwd))
        case .skills:
            return loadSkillItems(projectCwd: projectCwd)
        case .commands:
            return loadMarkdownItems(dirs: commandDirs(projectCwd: projectCwd))
        case .mcpServers:
            return loadMCPItems()
        case .claudeMd:
            return loadClaudeMdItems(projectCwd: projectCwd)
        }
    }

    // MARK: Directory resolution

    private static func agentDirs(projectCwd: String?) -> [URL] {
        var dirs = [claudeDir.appendingPathComponent("agents")]
        if let cwd = projectCwd {
            dirs.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/agents"))
        }
        return dirs
    }

    private static func commandDirs(projectCwd: String?) -> [URL] {
        var dirs = [claudeDir.appendingPathComponent("commands")]
        if let cwd = projectCwd {
            dirs.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/commands"))
        }
        return dirs
    }

    private static func skillDirs(projectCwd: String?) -> [URL] {
        var dirs = [claudeDir.appendingPathComponent("skills")]
        if let cwd = projectCwd {
            dirs.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/skills"))
        }
        return dirs
    }

    // MARK: Loaders

    private static func loadSettingsItems() -> [ConfigItem] {
        let files = ["settings.json", "settings.local.json"]
        return files.compactMap { name in
            let url = claudeDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int).map { formatBytes($0) } ?? "?"
            let modified = (attrs?[.modificationDate] as? Date).map { relativeDateString($0) } ?? ""
            return ConfigItem(
                id: url.path,
                title: name,
                subtitle: "\(size) · \(modified)",
                url: url,
                kind: .jsonFile
            )
        }
    }

    private static func loadMarkdownItems(dirs: [URL]) -> [ConfigItem] {
        var result: [ConfigItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            let mdFiles = files
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for file in mdFiles {
                guard !seen.contains(file.path) else { continue }
                seen.insert(file.path)
                let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let frontmatter = parseFrontmatter(content)
                let displayName = frontmatter["name"]?.nilIfEmpty ?? file.deletingPathExtension().lastPathComponent
                let description = frontmatter["description"] ?? ""
                let attrs = try? fm.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? Int).map { formatBytes($0) } ?? "?"
                result.append(ConfigItem(
                    id: file.path,
                    title: displayName,
                    subtitle: description.isEmpty ? size : description,
                    url: file,
                    kind: .markdownFile
                ))
            }
        }
        return result
    }

    private static func loadSkillItems(projectCwd: String?) -> [ConfigItem] {
        var result: [ConfigItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in skillDirs(projectCwd: projectCwd) {
            guard let subdirs = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            let dirs = subdirs
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            for subdir in dirs {
                guard !seen.contains(subdir.path) else { continue }
                seen.insert(subdir.path)
                // SKILL.md (canonical), fall back to skill.md just in case.
                let skillMd = [subdir.appendingPathComponent("SKILL.md"),
                               subdir.appendingPathComponent("skill.md")]
                    .first { fm.fileExists(atPath: $0.path) }
                let content = skillMd.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let frontmatter = parseFrontmatter(content)
                let displayName = frontmatter["name"]?.nilIfEmpty ?? subdir.lastPathComponent
                let description = frontmatter["description"] ?? ""
                result.append(ConfigItem(
                    id: subdir.path,
                    title: displayName,
                    subtitle: description.isEmpty ? subdir.lastPathComponent : description,
                    url: skillMd ?? subdir,
                    kind: .skillDir
                ))
            }
        }
        return result
    }

    private static func loadMCPItems() -> [ConfigItem] {
        // mcpServers can live in settings.json (and/or settings.local.json).
        // Merge both, with local taking precedence.
        var merged: [String: Any] = [:]
        for name in ["settings.json", "settings.local.json"] {
            let url = claudeDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (k, v) in servers { merged[k] = v }
        }
        guard !merged.isEmpty else { return [] }

        let settingsUrl = claudeDir.appendingPathComponent("settings.json")
        return merged.keys.sorted().map { name in
            let info = merged[name] as? [String: Any]
            let command = describeMCPCommand(info)
            return ConfigItem(
                id: "mcp:\(name)",
                title: name,
                subtitle: command,
                url: settingsUrl,
                kind: .mcpServer(command: command)
            )
        }
    }

    /// Human-readable one-liner for an MCP server entry. Handles both
    /// stdio (`command` + `args`) and remote (`url`/`type`) server shapes.
    private static func describeMCPCommand(_ info: [String: Any]?) -> String {
        guard let info else { return "unknown" }
        if let cmd = info["command"] as? String {
            let args = info["args"] as? [String] ?? []
            return ([cmd] + args).joined(separator: " ")
        }
        if let url = info["url"] as? String {
            let type = info["type"] as? String
            return type.map { "\($0): \(url)" } ?? url
        }
        if let type = info["type"] as? String {
            return type
        }
        return "unknown"
    }

    private static func loadClaudeMdItems(projectCwd: String?) -> [ConfigItem] {
        var candidates: [(URL, String)] = [
            (claudeDir.appendingPathComponent("CLAUDE.md"), "~/.claude/CLAUDE.md")
        ]
        if let cwd = projectCwd {
            let proj = URL(fileURLWithPath: cwd).appendingPathComponent("CLAUDE.md")
            candidates.append((proj, "\(URL(fileURLWithPath: cwd).lastPathComponent)/CLAUDE.md"))
        }
        return candidates.compactMap { (url, label) in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int).map { formatBytes($0) } ?? "?"
            let modified = (attrs?[.modificationDate] as? Date).map { relativeDateString($0) } ?? ""
            return ConfigItem(
                id: url.path,
                title: label,
                subtitle: "\(size) · \(modified)",
                url: url,
                kind: .markdownFile
            )
        }
    }

    // MARK: Formatting helpers

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func relativeDateString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Item row

struct ConfigItemRow: View {
    let item: ConfigItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail view

struct ConfigDetailView: View {
    let item: ConfigItem

    @State private var content: String = ""
    @State private var frontmatter: [String: String] = [:]
    @State private var bodyText: String = ""
    @State private var fileSize: String = ""
    @State private var modifiedDate: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard

                switch item.kind {
                case .jsonFile:
                    jsonContentView
                case .markdownFile, .skillDir:
                    markdownContentView
                case .mcpServer(let command):
                    mcpDetailView(command: command)
                }
            }
            .padding(20)
        }
        .background(ThemeBackground())
        .onAppear { loadContent() }
        .onChange(of: item) { _, _ in loadContent() }
    }

    // MARK: Sub-views

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                    Text(displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                revealButton
            }

            if !fileSize.isEmpty || !modifiedDate.isEmpty {
                HStack(spacing: 16) {
                    if !fileSize.isEmpty {
                        Label(fileSize, systemImage: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !modifiedDate.isEmpty {
                        Label(modifiedDate, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } label: {
            Label("Reveal", systemImage: "arrow.right.circle")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Theme.accent)
    }

    private var jsonContentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Contents")
            ScrollView(.horizontal, showsIndicators: false) {
                Text(prettyJSON(content))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
            }
        }
    }

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !frontmatter.isEmpty {
                frontmatterCard
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Content")
                Text(bodyText.isEmpty ? "(empty)" : bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()
            }
        }
    }

    private var frontmatterCard: some View {
        let keys = frontmatter.keys.sorted()
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Frontmatter")
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 12) {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 100, alignment: .leading)
                        Text(frontmatter[key] ?? "")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    if key != keys.last {
                        Divider().opacity(0.3)
                    }
                }
            }
            .glassCard(radius: 10)
        }
    }

    private func mcpDetailView(command: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Server Details")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(item.title)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Divider().opacity(0.3)
                HStack(alignment: .top) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                }
                if !mcpServerJSON.isEmpty {
                    Divider().opacity(0.3)
                    HStack(alignment: .top) {
                        Text("Config")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(mcpServerJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(14)
            .glassCard()
        }
    }

    // MARK: Load

    private func loadContent() {
        content = ""
        frontmatter = [:]
        bodyText = ""
        fileSize = ""
        modifiedDate = ""

        switch item.kind {
        case .mcpServer, .jsonFile:
            content = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            loadFileMeta(item.url)

        case .markdownFile, .skillDir:
            let raw = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            let parsed = parseFrontmatterAndBody(raw)
            frontmatter = parsed.0
            bodyText = parsed.1
            loadFileMeta(item.url)
        }
    }

    private func loadFileMeta(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int {
            fileSize = ConfigLoader.formatBytes(size)
        }
        if let date = attrs?[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            modifiedDate = f.string(from: date)
        }
    }

    // MARK: Helpers

    private var displayPath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return item.url.path.replacingOccurrences(of: homePath, with: "~")
    }

    private var mcpServerJSON: String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let serverInfo = servers[item.title] else { return "" }
        let formatted = try? JSONSerialization.data(withJSONObject: serverInfo, options: [.prettyPrinted, .sortedKeys])
        return (formatted.flatMap { String(data: $0, encoding: .utf8) }) ?? ""
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw.isEmpty ? "(empty)" : raw
        }
        return str
    }
}

// MARK: - Empty detail placeholder

struct ConfigEmptyDetail: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Select a file")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Choose an item from the list to view its contents.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeBackground())
    }
}

// MARK: - Frontmatter parser

/// Parses simple YAML frontmatter delimited by `---` lines.
/// Returns (frontmatter dict, body string). No nested YAML support needed.
private func parseFrontmatter(_ text: String) -> [String: String] {
    parseFrontmatterAndBody(text).0
}

private func parseFrontmatterAndBody(_ text: String) -> ([String: String], String) {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
        return ([:], text)
    }

    var dict: [String: String] = [:]
    var i = 1
    while i < lines.count {
        let line = lines[i]
        if line.trimmingCharacters(in: .whitespaces) == "---" {
            i += 1
            break
        }
        if let colonRange = line.range(of: ":") {
            let key = String(line[line.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                dict[key] = value
            }
        }
        i += 1
    }

    let body = lines[i...].joined(separator: "\n").trimmingCharacters(in: .newlines)
    return (dict, body)
}

#endif
