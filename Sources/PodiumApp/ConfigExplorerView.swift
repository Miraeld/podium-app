import SwiftUI
import AppKit

// MARK: - Config Explorer View

struct ConfigExplorerView: View {
    @Environment(AppState.self) var state

    @State private var selectedCategory: ConfigCategory? = .settings
    @State private var selectedItem: ConfigItem? = nil

    var body: some View {
        NavigationSplitView {
            categoryList
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            if let category = selectedCategory {
                ConfigItemListView(
                    category: category,
                    projectCwd: state.sessions.first?.cwd,
                    selectedItem: $selectedItem
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } else {
                Text("Select a category")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            if let item = selectedItem {
                ConfigDetailView(item: item)
            } else {
                ConfigEmptyDetail()
            }
        }
        .navigationTitle("CC Config Explorer")
        .background(ThemeBackground())
    }

    // MARK: Category sidebar

    private var categoryList: some View {
        List(ConfigCategory.allCases, id: \.self, selection: $selectedCategory) { category in
            Label(category.label, systemImage: category.icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 3)
        }
        .listStyle(.sidebar)
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

// MARK: - Item list view

struct ConfigItemListView: View {
    let category: ConfigCategory
    let projectCwd: String?
    @Binding var selectedItem: ConfigItem?

    @State private var items: [ConfigItem] = []

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var claudeDir: URL { home.appendingPathComponent(".claude") }

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(
                    icon: category.icon,
                    title: "No \(category.label) found",
                    message: "No files found under \(claudeDir.path)"
                )
            } else {
                List(items, selection: $selectedItem) { item in
                    ConfigItemRow(item: item)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle(category.label)
        .onAppear { loadItems() }
        .onChange(of: category) { _, _ in loadItems() }
    }

    private func loadItems() {
        selectedItem = nil
        items = []

        switch category {
        case .settings:
            items = loadSettingsItems()
        case .agents:
            items = loadMarkdownItems(
                dirs: agentDirs(),
                kind: .markdownFile
            )
        case .skills:
            items = loadSkillItems()
        case .commands:
            items = loadMarkdownItems(
                dirs: [claudeDir.appendingPathComponent("commands")],
                kind: .markdownFile
            )
        case .mcpServers:
            items = loadMCPItems()
        case .claudeMd:
            items = loadClaudeMdItems()
        }
    }

    // MARK: Loaders

    private func loadSettingsItems() -> [ConfigItem] {
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

    private func agentDirs() -> [URL] {
        var dirs = [claudeDir.appendingPathComponent("agents")]
        if let cwd = projectCwd {
            dirs.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/agents"))
        }
        return dirs
    }

    private func skillDirs() -> [URL] {
        var dirs = [claudeDir.appendingPathComponent("skills")]
        if let cwd = projectCwd {
            dirs.append(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/skills"))
        }
        return dirs
    }

    private func loadMarkdownItems(dirs: [URL], kind: ConfigItem.ConfigItemKind) -> [ConfigItem] {
        var result: [ConfigItem] = []
        let fm = FileManager.default
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in mdFiles {
                let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let frontmatter = parseFrontmatter(content)
                let displayName = frontmatter["name"] ?? file.deletingPathExtension().lastPathComponent
                let description = frontmatter["description"] ?? ""
                let attrs = try? fm.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? Int).map { formatBytes($0) } ?? "?"
                result.append(ConfigItem(
                    id: file.path,
                    title: displayName,
                    subtitle: description.isEmpty ? size : description,
                    url: file,
                    kind: kind
                ))
            }
        }
        return result
    }

    private func loadSkillItems() -> [ConfigItem] {
        var result: [ConfigItem] = []
        let fm = FileManager.default
        for dir in skillDirs() {
            guard let subdirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let dirs = subdirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for subdir in dirs {
                let skillMd = subdir.appendingPathComponent("SKILL.md")
                let content = (try? String(contentsOf: skillMd, encoding: .utf8)) ?? ""
                let frontmatter = parseFrontmatter(content)
                let displayName = frontmatter["name"] ?? subdir.lastPathComponent
                let description = frontmatter["description"] ?? ""
                result.append(ConfigItem(
                    id: subdir.path,
                    title: displayName,
                    subtitle: description.isEmpty ? subdir.lastPathComponent : description,
                    url: fm.fileExists(atPath: skillMd.path) ? skillMd : subdir,
                    kind: .skillDir
                ))
            }
        }
        return result
    }

    private func loadMCPItems() -> [ConfigItem] {
        let settingsUrl = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any] else { return [] }

        return mcpServers.keys.sorted().map { name in
            let serverInfo = mcpServers[name] as? [String: Any]
            let command: String
            if let cmd = serverInfo?["command"] as? String {
                let args = serverInfo?["args"] as? [String] ?? []
                command = ([cmd] + args).joined(separator: " ")
            } else {
                command = "unknown"
            }
            return ConfigItem(
                id: "mcp:\(name)",
                title: name,
                subtitle: command,
                url: settingsUrl,
                kind: .mcpServer(command: command)
            )
        }
    }

    private func loadClaudeMdItems() -> [ConfigItem] {
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

    // MARK: Helpers

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func relativeDateString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
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
    @State private var body_text: String = ""
    @State private var fileSize: String = ""
    @State private var modifiedDate: String = ""

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header card
                headerCard

                // Content area
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
                Text(body_text.isEmpty ? "(empty)" : body_text)
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Frontmatter")
            VStack(spacing: 0) {
                ForEach(frontmatter.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top, spacing: 12) {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 100, alignment: .leading)
                        Text(frontmatter[key] ?? "")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    if key != frontmatter.keys.sorted().last {
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
                if !content.isEmpty {
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
        body_text = ""
        fileSize = ""
        modifiedDate = ""

        switch item.kind {
        case .mcpServer:
            content = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            loadFileMeta(item.url)

        case .jsonFile:
            content = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            loadFileMeta(item.url)

        case .markdownFile, .skillDir:
            let raw = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
            let parsed = parseFrontmatterAndBody(raw)
            frontmatter = parsed.0
            body_text = parsed.1
            loadFileMeta(item.url)
        }
    }

    private func loadFileMeta(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int {
            fileSize = formatBytes(size)
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
            return raw
        }
        return str
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
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

