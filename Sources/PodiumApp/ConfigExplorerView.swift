#if os(macOS)
import SwiftUI

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
//
// P5.4 GAP FIX: this view used to read `~/.claude` directly via
// `FileManager` — wrong in client mode, where PodiumApp is a pure client
// connecting to a remote/Docker Podium server with no local filesystem to
// read. It now fetches everything through `PodiumAPI`'s `/api/cc-config`
// family (`Sources/PodiumServer/Routes/CcConfigRouter.swift`), matching
// `EmbeddedServer.shared.mode`-agnostic behavior — the explorer works the
// same whether this instance is hosting the server or just a client of one.

struct ConfigExplorerView: View {
    @Environment(AppState.self) var state

    @State private var selectedCategory: ConfigCategory = .settings
    @State private var isLoadingItems = false
    @State private var loadError: String?

    // Per-category item caches (typed, since the API returns different
    // shapes per surface).
    @State private var skillItems: [CcSkillItem] = []
    @State private var mdItems: [CcMdItem] = []
    @State private var mcpServers: CcMcpResponse?
    @State private var memoryItems: [CcMemoryItem] = []
    @State private var backups: [CcBackup] = []

    @State private var selectedRowId: String?

    private var projectCwd: String? { state.sessions.first?.cwd }

    var body: some View {
        HStack(spacing: 0) {
            categoryColumn
                .frame(width: 200)

            Divider().opacity(0.4)

            itemColumn
                .frame(width: 300)

            Divider().opacity(0.4)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeBackground())
        .navigationTitle("CC Config Explorer")
        .task { await reloadItems() }
        .onChange(of: selectedCategory) { _, _ in
            selectedRowId = nil
            Task { await reloadItems() }
        }
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

    @ViewBuilder
    private var itemColumn: some View {
        if isLoadingItems && currentRowCount == 0 {
            VStack {
                Spacer()
                ProgressView().tint(.cyan)
                Spacer()
            }
        } else if let loadError, currentRowCount == 0 {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't load", message: loadError)
                .padding()
        } else if currentRowCount == 0 {
            EmptyStateView(
                icon: selectedCategory.icon,
                title: "No \(selectedCategory.label) found",
                message: emptyMessage
            )
            .padding()
        } else {
            List(selection: $selectedRowId) {
                switch selectedCategory {
                case .skills:
                    ForEach(skillItems) { item in
                        ConfigItemRow(title: item.frontmatter["name"]?.nilIfEmpty ?? item.name, subtitle: item.frontmatter["description"] ?? item.scope)
                            .tag(item.id)
                    }
                case .agents:
                    ForEach(mdItems) { item in
                        ConfigItemRow(title: item.frontmatter["name"]?.nilIfEmpty ?? item.name, subtitle: item.frontmatter["description"] ?? item.scope)
                            .tag(item.id)
                    }
                case .commands:
                    ForEach(mdItems) { item in
                        ConfigItemRow(title: item.frontmatter["name"]?.nilIfEmpty ?? item.name, subtitle: item.frontmatter["description"] ?? item.scope)
                            .tag(item.id)
                    }
                case .outputStyles:
                    ForEach(mdItems) { item in
                        ConfigItemRow(title: item.frontmatter["name"]?.nilIfEmpty ?? item.name, subtitle: item.frontmatter["description"] ?? item.scope)
                            .tag(item.id)
                    }
                case .mcpServers:
                    ForEach((mcpServers?.user ?? []) + (mcpServers?.projectScoped ?? [])) { server in
                        ConfigItemRow(title: server.name, subtitle: server.command ?? server.url ?? server.kind)
                            .tag(server.id)
                    }
                case .claudeMd:
                    ForEach(memoryItems) { item in
                        ConfigItemRow(title: item.scope == "user" ? "~/.claude/CLAUDE.md" : "project/CLAUDE.md", subtitle: item.preview)
                            .tag(item.id)
                    }
                case .settings:
                    EmptyView()
                case .backups:
                    ForEach(backups) { backup in
                        ConfigItemRow(title: "\(backup.type)/\(backup.name)", subtitle: "\(backup.scope) · \(Theme.shortDate(Date(timeIntervalSince1970: backup.mtime / 1000)))")
                            .tag(backup.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var detailColumn: some View {
        Group {
            switch selectedCategory {
            case .settings:
                SettingsSurfaceView(state: state, cwd: projectCwd)
            case .skills:
                if let item = skillItems.first(where: { $0.id == selectedRowId }) {
                    SkillDetailView(item: item, state: state, cwd: projectCwd, onMutated: { await reloadItems() })
                } else {
                    ConfigEmptyDetail()
                }
            case .agents, .commands, .outputStyles:
                if let item = mdItems.first(where: { $0.id == selectedRowId }) {
                    MdDetailView(item: item, mutableType: mutableType(for: selectedCategory), state: state, cwd: projectCwd, onMutated: { await reloadItems() })
                } else {
                    ConfigEmptyDetail()
                }
            case .mcpServers:
                if let server = ((mcpServers?.user ?? []) + (mcpServers?.projectScoped ?? [])).first(where: { $0.id == selectedRowId }) {
                    McpDetailView(server: server)
                } else {
                    ConfigEmptyDetail()
                }
            case .claudeMd:
                if let item = memoryItems.first(where: { $0.id == selectedRowId }) {
                    MemoryDetailView(item: item, state: state, cwd: projectCwd, onMutated: { await reloadItems() })
                } else {
                    ConfigEmptyDetail()
                }
            case .backups:
                if let backup = backups.first(where: { $0.id == selectedRowId }) {
                    BackupDetailView(backup: backup, state: state, cwd: projectCwd)
                } else {
                    ConfigEmptyDetail()
                }
            }
        }
    }

    private func mutableType(for category: ConfigCategory) -> String {
        switch category {
        case .agents: return "agents"
        case .commands: return "commands"
        case .outputStyles: return "output-styles"
        default: return ""
        }
    }

    private var currentRowCount: Int {
        switch selectedCategory {
        case .skills: return skillItems.count
        case .agents, .commands, .outputStyles: return mdItems.count
        case .mcpServers: return (mcpServers?.user.count ?? 0) + (mcpServers?.projectScoped.count ?? 0)
        case .claudeMd: return memoryItems.count
        case .settings: return 1 // always has a detail surface
        case .backups: return backups.count
        }
    }

    private var emptyMessage: String {
        switch selectedCategory {
        case .settings:   return "No settings.json found under ~/.claude."
        case .agents:     return "No agent .md files found under ~/.claude/agents (or the project's .claude/agents)."
        case .skills:     return "No skill folders found under ~/.claude/skills."
        case .commands:   return "No command .md files found under ~/.claude/commands."
        case .outputStyles: return "No output-style .md files found."
        case .mcpServers: return "No mcpServers configured in ~/.claude.json or ~/.claude/settings.json."
        case .claudeMd:   return "No CLAUDE.md found in ~/.claude or the active project."
        case .backups:    return "No backups yet — edits and deletes to skills/agents/commands/output-styles/memory create one automatically."
        }
    }

    // MARK: Loading

    private func reloadItems() async {
        isLoadingItems = true
        loadError = nil
        defer { isLoadingItems = false }
        do {
            switch selectedCategory {
            case .settings:
                break // SettingsSurfaceView loads its own data
            case .skills:
                skillItems = try await state.ccSkills(cwd: projectCwd)
            case .agents:
                mdItems = try await state.ccAgents(cwd: projectCwd)
            case .commands:
                mdItems = try await state.ccCommands(cwd: projectCwd)
            case .outputStyles:
                mdItems = try await state.ccOutputStyles(cwd: projectCwd)
            case .mcpServers:
                mcpServers = try await state.ccMcpServers(cwd: projectCwd)
            case .claudeMd:
                memoryItems = try await state.ccMemory(cwd: projectCwd)
            case .backups:
                backups = try await state.ccBackups(cwd: projectCwd)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Category enum

enum ConfigCategory: String, CaseIterable, Hashable {
    case settings   = "settings"
    case agents     = "agents"
    case skills     = "skills"
    case commands   = "commands"
    case outputStyles = "output-styles"
    case mcpServers = "mcp"
    case claudeMd   = "claudemd"
    case backups    = "backups"

    var label: String {
        switch self {
        case .settings:   return "Settings"
        case .agents:     return "Agents"
        case .skills:     return "Skills"
        case .commands:   return "Commands"
        case .outputStyles: return "Output Styles"
        case .mcpServers: return "MCP Servers"
        case .claudeMd:   return "CLAUDE.md"
        case .backups:    return "Backups"
        }
    }

    var icon: String {
        switch self {
        case .settings:   return "gearshape"
        case .agents:     return "person.2"
        case .skills:     return "bolt"
        case .commands:   return "terminal"
        case .outputStyles: return "paintbrush"
        case .mcpServers: return "server.rack"
        case .claudeMd:   return "doc.text"
        case .backups:    return "clock.arrow.circlepath"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Item row (generic)

struct ConfigItemRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Shared header card

struct ConfigDetailHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            trailing
        }
        .padding(16)
        .glassCard()
    }
}

// MARK: - Skill detail (mutable: edit + delete)

struct SkillDetailView: View {
    let item: CcSkillItem
    let state: AppState
    let cwd: String?
    let onMutated: () async -> Void

    @State private var editedBody: String = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var statusMessage: String?
    @State private var isDirty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConfigDetailHeader(
                    title: item.frontmatter["name"]?.nilIfEmpty ?? item.name,
                    subtitle: item.path,
                    trailing: AnyView(mutationControls)
                )

                if !item.frontmatter.isEmpty {
                    FrontmatterCard(frontmatter: item.frontmatter)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "SKILL.md")
                    TextEditor(text: $editedBody)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 300)
                        .padding(12)
                        .glassCard()
                        .onChange(of: editedBody) { _, _ in isDirty = true }
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(ThemeBackground())
        .onAppear { editedBody = item.preview; isDirty = false }
        .onChange(of: item.id) { _, _ in editedBody = item.preview; isDirty = false; statusMessage = nil }
    }

    private var mutationControls: some View {
        HStack(spacing: 8) {
            if isDirty {
                Button {
                    Task { await save() }
                } label: {
                    Label(isSaving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }
            Button(role: .destructive) {
                Task { await delete() }
            } label: {
                Label(isDeleting ? "Deleting…" : "Delete", systemImage: "trash")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDeleting)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await state.ccWriteFile(scope: item.scope, type: "skills", name: item.name, content: editedBody, cwd: cwd)
            isDirty = false
            statusMessage = result.backupPath != nil ? "Saved — backup created at \(result.backupPath!)" : "Saved."
            await onMutated()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await state.ccDeleteFile(scope: item.scope, type: "skills", name: item.name, cwd: cwd)
            await onMutated()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Simple MD detail (agents / commands / output-styles — mutable)

struct MdDetailView: View {
    let item: CcMdItem
    let mutableType: String
    let state: AppState
    let cwd: String?
    let onMutated: () async -> Void

    @State private var editedBody: String = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var statusMessage: String?
    @State private var isDirty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConfigDetailHeader(
                    title: item.frontmatter["name"]?.nilIfEmpty ?? item.name,
                    subtitle: item.file,
                    trailing: AnyView(mutationControls)
                )

                if !item.frontmatter.isEmpty {
                    FrontmatterCard(frontmatter: item.frontmatter)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Content")
                    TextEditor(text: $editedBody)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 300)
                        .padding(12)
                        .glassCard()
                        .onChange(of: editedBody) { _, _ in isDirty = true }
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(ThemeBackground())
        .onAppear { editedBody = item.preview; isDirty = false }
        .onChange(of: item.id) { _, _ in editedBody = item.preview; isDirty = false; statusMessage = nil }
    }

    private var mutationControls: some View {
        HStack(spacing: 8) {
            if isDirty {
                Button {
                    Task { await save() }
                } label: {
                    Label(isSaving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }
            Button(role: .destructive) {
                Task { await delete() }
            } label: {
                Label(isDeleting ? "Deleting…" : "Delete", systemImage: "trash")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDeleting)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await state.ccWriteFile(scope: item.scope, type: mutableType, name: item.name, content: editedBody, cwd: cwd)
            isDirty = false
            statusMessage = result.backupPath != nil ? "Saved — backup created at \(result.backupPath!)" : "Saved."
            await onMutated()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await state.ccDeleteFile(scope: item.scope, type: mutableType, name: item.name, cwd: cwd)
            await onMutated()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Memory (CLAUDE.md) detail — mutable, no `name`

struct MemoryDetailView: View {
    let item: CcMemoryItem
    let state: AppState
    let cwd: String?
    let onMutated: () async -> Void

    @State private var editedBody: String = ""
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var isDirty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConfigDetailHeader(
                    title: item.scope == "user" ? "~/.claude/CLAUDE.md" : "Project CLAUDE.md",
                    subtitle: item.file,
                    trailing: AnyView(
                        Group {
                            if isDirty {
                                Button {
                                    Task { await save() }
                                } label: {
                                    Label(isSaving ? "Saving…" : "Save", systemImage: "square.and.arrow.down")
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(isSaving)
                            }
                        }
                    )
                )

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Content")
                    TextEditor(text: $editedBody)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 400)
                        .padding(12)
                        .glassCard()
                        .onChange(of: editedBody) { _, _ in isDirty = true }
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(ThemeBackground())
        .onAppear { editedBody = item.preview; isDirty = false }
        .onChange(of: item.id) { _, _ in editedBody = item.preview; isDirty = false; statusMessage = nil }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await state.ccWriteFile(scope: item.scope, type: "memory", name: nil, content: editedBody, cwd: cwd)
            isDirty = false
            statusMessage = result.backupPath != nil ? "Saved — backup created at \(result.backupPath!)" : "Saved."
            await onMutated()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCP server detail (read-only — never mutable, per CcMutate's hard constraints)

struct McpDetailView: View {
    let server: CcMcpServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConfigDetailHeader(title: server.name, subtitle: server.source)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Server Details")
                    detailRow("Kind", server.kind)
                    if let url = server.url { detailRow("URL", url) }
                    if let command = server.command {
                        detailRow("Command", ([command] + (server.args ?? [])).joined(separator: " "))
                    }
                    if let envNames = server.envNames, !envNames.isEmpty {
                        detailRow("Env vars", envNames.joined(separator: ", "))
                    }
                    if let headers = server.headers, !headers.isEmpty {
                        detailRow("Headers", headers.joined(separator: ", "))
                    }
                }
                .padding(14)
                .glassCard()

                Text("MCP servers are read-only here — they have concurrent-write races with the live Claude Code CLI, so this explorer never mutates them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(ThemeBackground())
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Settings surface (read-only aggregate: settings.json sources + overview + hooks + keybindings + statusline)

struct SettingsSurfaceView: View {
    let state: AppState
    let cwd: String?

    @State private var overview: CcOverview?
    @State private var settingsSources: [CcSettingsSource] = []
    @State private var hooks: [CcHooksSource] = []
    @State private var keybindings: CcKeybindingsResponse?
    @State private var statusline: CcStatuslineResponse?
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let overview {
                    overviewCard(overview)
                }
                ForEach(settingsSources) { source in
                    settingsSourceCard(source)
                }
                if !hooks.isEmpty {
                    hooksCard
                }
                if let keybindings, keybindings.exists {
                    keybindingsCard(keybindings)
                }
                if let statusline, statusline.config != nil || !statusline.scripts.isEmpty {
                    statuslineCard(statusline)
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(ThemeBackground())
        .task {
            guard !loaded else { return }
            loaded = true
            await load()
        }
    }

    private func load() async {
        do {
            async let ov = state.ccOverview(cwd: cwd)
            async let settings = state.ccSettings(cwd: cwd)
            async let hooksData = state.ccHooks(cwd: cwd)
            async let kb = state.ccKeybindings()
            async let sl = state.ccStatusline()
            let (o, s, h, k, l) = try await (ov, settings, hooksData, kb, sl)
            overview = o
            settingsSources = s
            hooks = h
            keybindings = k
            statusline = l
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func overviewCard(_ overview: CcOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Overview")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                overviewStat("Skills", overview.counts.skills.user + overview.counts.skills.project)
                overviewStat("Agents", overview.counts.agents.user + overview.counts.agents.project)
                overviewStat("Commands", overview.counts.commands.user + overview.counts.commands.project)
                overviewStat("Output Styles", overview.counts.outputStyles.user + overview.counts.outputStyles.project)
                overviewStat("Plugins", overview.counts.plugins)
                overviewStat("Marketplaces", overview.counts.marketplaces)
                overviewStat("MCP Servers", overview.counts.mcpServers.user + overview.counts.mcpServers.project)
                overviewStat("Keybindings", overview.counts.keybindings)
                overviewStat("Memory Files", overview.counts.memory)
            }
        }
        .padding(16)
        .glassCard()
    }

    private func overviewStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func settingsSourceCard(_ source: CcSettingsSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: source.scope)
                Spacer()
                Text(source.exists ? "\(source.rawSize ?? 0) bytes" : "missing")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(source.file)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let data = source.data {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(data.prettyText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 200)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .glassCard()
    }

    private var hooksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Hooks")
            ForEach(hooks) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(source.scope) — \(source.exists ? "\(source.hooks.count) event type(s)" : "no settings file")")
                        .font(.caption.weight(.medium))
                    ForEach(Array(source.hooks.keys.sorted()), id: \.self) { event in
                        Text(event).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if source.scope != hooks.last?.scope { Divider().opacity(0.2) }
            }
        }
        .padding(14)
        .glassCard()
    }

    private func keybindingsCard(_ kb: CcKeybindingsResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Keybindings", trailing: "\(kb.groups.reduce(0) { $0 + $1.bindings.count }) bindings")
            ForEach(kb.groups) { group in
                Text(group.context).font(.caption.weight(.medium))
            }
        }
        .padding(14)
        .glassCard()
    }

    private func statuslineCard(_ sl: CcStatuslineResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Status Line")
            if !sl.scripts.isEmpty {
                ForEach(sl.scripts) { script in
                    Text(script.file).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .glassCard()
    }
}

// MARK: - Backup detail (restore-by-copy is out of scope; this is a browser)

struct BackupDetailView: View {
    let backup: CcBackup
    let state: AppState
    let cwd: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConfigDetailHeader(
                    title: "\(backup.type)/\(backup.name)",
                    subtitle: backup.backupPath
                )
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Backup Details")
                    row("Scope", backup.scope)
                    row("Type", backup.type)
                    row("Kind", backup.isDir ? "directory" : "file")
                    if let size = backup.size {
                        row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    row("Created", Theme.shortDate(Date(timeIntervalSince1970: backup.mtime / 1000)))
                }
                .padding(14)
                .glassCard()

                Text("Backups are created automatically before every edit or delete of a mutable artifact (skills, agents, commands, output styles, memory). Restoring isn't wired up yet — copy the path above manually if you need to recover a version.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(ThemeBackground())
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

// MARK: - Frontmatter card (shared)

struct FrontmatterCard: View {
    let frontmatter: [String: String]

    var body: some View {
        let keys = frontmatter.keys.sorted()
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Frontmatter")
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 12) {
                        Text(key)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
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

#endif
