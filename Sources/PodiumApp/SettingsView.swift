#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import PodiumCore

struct SettingsView: View {
    @Environment(AppState.self) var state

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConnectionTab()
                .environment(state)
                .tabItem { Label("Connection", systemImage: "wifi") }
            PricingTab()
                .environment(state)
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            DataManagementTab()
                .environment(state)
                .tabItem { Label("Data", systemImage: "internaldrive") }
            HooksTab()
                .environment(state)
                .tabItem { Label("Hooks", systemImage: "bolt.fill") }
            UpdatesTab()
                .environment(state)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("appearance_mode") private var appearanceMode = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Podium's glassmorphism design adapts to both light and dark appearances. \u{201c}System\u{201d} follows your macOS setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connection Tab

struct ConnectionTab: View {
    @Environment(AppState.self) var state
    @AppStorage("podium_host") var host = "localhost"
    @AppStorage("podium_port") var portStr = "4820"
    @AppStorage(EmbeddedServer.embeddedServerEnabledKey) var embeddedServerEnabled = true
    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        Form {
            Section("Embedded Server") {
                Toggle("Host Podium automatically on launch", isOn: $embeddedServerEnabled)
                Text("When on (default), Podium starts its own server in the background the moment the app opens — nothing else to install or run. When off, the app only connects to whatever server is already running at the host/port below (restart to apply).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                embeddedStatusRow
            }
            Section("Server") {
                TextField("Host", text: $host)
                TextField("Port", text: $portStr)
                HStack {
                    Button("Test Connection") {
                        testing = true
                        Task {
                            await state.start()
                            testing = false
                            testResult = state.isServerReachable ? "Connected \u{2713}" : "Unreachable \u{2717}"
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().scaleEffect(0.7) }
                    if let r = testResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.contains("\u{2713}") ? Color.green : Color.red)
                    }
                }
            }
            Section {
                HStack {
                    Circle()
                        .fill(state.isServerReachable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(state.isServerReachable ? "Connected to Podium" : "Not connected")
                        .font(.callout)
                    Spacer()
                    if state.wsConnected {
                        Text("WebSocket live").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var embeddedStatusRow: some View {
        switch EmbeddedServer.shared.mode {
        case .embedded(let port):
            LabeledContent("Mode") {
                Label("Embedded \u{00b7} port \(port)", systemImage: "bolt.fill")
                    .foregroundStyle(.green)
            }
            LabeledContent("Database", value: PodiumPaths.databasePath())
                .font(.caption)
                .foregroundStyle(.secondary)
        case .externalClient(let port):
            LabeledContent("Mode") {
                Label("Connected to external server \u{00b7} port \(port)", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.cyan)
            }
        case .disabledByUser(let port):
            LabeledContent("Mode") {
                Label("Client only (embedding disabled) \u{00b7} port \(port)", systemImage: "network")
                    .foregroundStyle(.secondary)
            }
        case nil:
            LabeledContent("Mode", value: "Resolving\u{2026}")
        }
    }
}

// MARK: - Pricing Tab

struct PricingTab: View {
    @Environment(AppState.self) var state
    @State private var rules: [PricingRule] = PricingTab.defaultRules
    @State private var editingId: String? = nil
    @State private var isSaving = false
    @State private var saveResult: String? = nil

    static let defaultRules: [PricingRule] = [
        PricingRule(id: "claude-opus-4-8", model: "claude-opus-4-8", inputPer1M: 15.0, outputPer1M: 75.0),
        PricingRule(id: "claude-sonnet-4-6", model: "claude-sonnet-4-6", inputPer1M: 3.0, outputPer1M: 15.0),
        PricingRule(id: "claude-haiku-4-5", model: "claude-haiku-4-5", inputPer1M: 0.25, outputPer1M: 1.25),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading).font(.caption.weight(.semibold))
                Text("Input $/1M").frame(width: 100, alignment: .trailing).font(.caption.weight(.semibold))
                Text("Output $/1M").frame(width: 100, alignment: .trailing).font(.caption.weight(.semibold))
                Spacer().frame(width: 50)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach($rules) { $rule in
                    HStack {
                        if editingId == rule.id {
                            TextField("Model", text: $rule.model).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                            TextField("Input", value: $rule.inputPer1M, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                            TextField("Output", value: $rule.outputPer1M, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                            Button("Done") { editingId = nil }.buttonStyle(.bordered)
                        } else {
                            Text(rule.model).frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "$%.2f", rule.inputPer1M)).frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                            Text(String(format: "$%.2f", rule.outputPer1M)).frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                            Button("Edit") { editingId = rule.id }.frame(width: 40)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Reset to Defaults") { rules = PricingTab.defaultRules }
                Spacer()
                if let r = saveResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                Button(isSaving ? "Saving\u{2026}" : "Save Rules") {
                    isSaving = true
                    Task {
                        do {
                            try await state.savePricingRules(rules)
                            saveResult = "Saved \u{2713}"
                        } catch {
                            saveResult = "Error saving"
                        }
                        isSaving = false
                    }
                }
                .disabled(isSaving)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .task {
            if let loaded = try? await state.pricingRules(), !loaded.isEmpty {
                rules = loaded
            }
        }
    }
}

// MARK: - Notifications Tab

struct NotificationsTab: View {
    @AppStorage("notifs_enabled") var enabled = false
    @AppStorage("notif_session_start") var sessionStart = true
    @AppStorage("notif_session_complete") var sessionComplete = true
    @AppStorage("notif_agent_error") var agentError = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable macOS Notifications", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        if newValue {
                            Task {
                                let center = UNUserNotificationCenter.current()
                                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                            }
                        }
                    }
            }
            if enabled {
                Section("Notify me when") {
                    Toggle("Session starts", isOn: $sessionStart)
                    Toggle("Session completes", isOn: $sessionComplete)
                    Toggle("Agent encounters an error", isOn: $agentError)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data Management Tab

struct DataManagementTab: View {
    @Environment(AppState.self) var state
    @State private var abandonHours = 24
    @State private var purgedays = 30
    @State private var isRunningCleanup = false
    @State private var cleanupResult: String? = nil
    @State private var showDangerAlert = false
    @State private var isExporting = false

    var body: some View {
        Form {
            Section("Database") {
                if let s = state.stats {
                    LabeledContent("Sessions") { Text("\(s.totalSessions)").monospacedDigit() }
                    LabeledContent("Agents") { Text("\(s.totalAgents)").monospacedDigit() }
                    LabeledContent("Events") { Text(Theme.formatTokens(s.totalEvents)).monospacedDigit() }
                    LabeledContent("WS Connections") { Text("\(s.wsConnections)").monospacedDigit() }
                } else {
                    Text("Loading\u{2026}").foregroundStyle(.secondary)
                }
            }

            Section("Session Cleanup") {
                Stepper("Abandon sessions idle for \(abandonHours)h", value: $abandonHours, in: 1...168)
                Stepper("Purge sessions older than \(purgedays) days", value: $purgedays, in: 1...365)
                HStack {
                    Button(isRunningCleanup ? "Running\u{2026}" : "Run Cleanup") {
                        isRunningCleanup = true
                        Task {
                            do {
                                try await state.cleanupSessions(abandonIdleHours: abandonHours, purgeOlderDays: purgedays)
                                cleanupResult = "\u{2713} Cleanup complete"
                            } catch {
                                cleanupResult = "Error: \(error.localizedDescription)"
                            }
                            isRunningCleanup = false
                        }
                    }
                    .disabled(isRunningCleanup)
                    if let r = cleanupResult {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Export") {
                LabeledContent {
                    Button(isExporting ? "Exporting\u{2026}" : "Export JSON") {
                        isExporting = true
                        Task {
                            do {
                                let data = try await state.downloadExport()
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = "podium-export-\(Date().formatted(.iso8601.year().month().day())).json"
                                panel.allowedContentTypes = [.json]
                                if panel.runModal() == .OK, let url = panel.url {
                                    try data.write(to: url)
                                }
                            } catch {}
                            isExporting = false
                        }
                    }
                    .disabled(isExporting)
                } label: {
                    Text("Full JSON export")
                    Text("All sessions, agents, and events.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Danger Zone") {
                LabeledContent {
                    Button("Clear All Data\u{2026}", role: .destructive) {
                        showDangerAlert = true
                    }
                } label: {
                    Text("Wipe the database").foregroundStyle(.red)
                    Text("Permanent — cannot be undone.").font(.caption).foregroundStyle(.secondary)
                }
                .alert("Clear All Data?", isPresented: $showDangerAlert) {
                    Button("Clear Everything", role: .destructive) {
                        Task {
                            let url = URL(string: "http://\(state.host):\(state.port)/api/settings/clear")!
                            var req = URLRequest(url: url)
                            req.httpMethod = "POST"
                            _ = try? await URLSession.shared.data(for: req)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will delete ALL sessions, agents, events, and pricing rules. The Podium server database will be wiped.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hooks Tab

struct HooksTab: View {
    @Environment(AppState.self) var state
    @State private var hooks: [String: Bool] = [:]
    @State private var isLoading = false
    @State private var isReinstalling = false
    @State private var reinstallResult: String? = nil
    @State private var loadError: String? = nil

    var body: some View {
        Form {
            Section("Hook Status") {
                if isLoading {
                    ProgressView("Checking hooks\u{2026}")
                } else if hooks.isEmpty && loadError != nil {
                    Label(loadError ?? "Failed to load", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if hooks.isEmpty {
                    Text("No hooks configured").foregroundStyle(.secondary)
                } else {
                    ForEach(hooks.keys.sorted(), id: \.self) { hookName in
                        let installed = hooks[hookName] ?? false
                        LabeledContent(hookName) {
                            HStack(spacing: 6) {
                                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(installed ? .green : .red)
                                Text(installed ? "Installed" : "Missing")
                                    .font(.caption)
                                    .foregroundStyle(installed ? .green : .red)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Button(isReinstalling ? "Reinstalling\u{2026}" : "Reinstall Hooks") {
                        isReinstalling = true
                        Task {
                            do {
                                try await state.reinstallHooks()
                                reinstallResult = "\u{2713} Hooks reinstalled"
                                hooks = (try? await state.hooksStatus()) ?? [:]
                            } catch {
                                reinstallResult = "Error reinstalling"
                            }
                            isReinstalling = false
                        }
                    }
                    .disabled(isReinstalling)
                    if let r = reinstallResult {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Refresh Status") {
                    Task { await loadHooks() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadHooks() }
    }

    private func loadHooks() async {
        isLoading = true
        do {
            hooks = try await state.hooksStatus()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#endif
