import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) var state

    var body: some View {
        TabView {
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
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - Connection Tab

struct ConnectionTab: View {
    @Environment(AppState.self) var state
    @AppStorage("podium_host") var host = "localhost"
    @AppStorage("podium_port") var portStr = "4820"
    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        Form {
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
        ScrollView {
            VStack(spacing: 16) {
                dbOverviewSection
                cleanupSection
                exportSection
                dangerZoneSection
            }
            .padding(16)
        }
    }

    // DB overview: sessions/agents/events counts from state.stats
    private var dbOverviewSection: some View {
        GroupBox("Database Overview") {
            if let s = state.stats {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Sessions").foregroundStyle(.secondary)
                        Text("\(s.totalSessions)").monospacedDigit()
                        Text("Agents").foregroundStyle(.secondary)
                        Text("\(s.totalAgents)").monospacedDigit()
                    }
                    GridRow {
                        Text("Events").foregroundStyle(.secondary)
                        Text(Theme.formatTokens(s.totalEvents)).monospacedDigit()
                        Text("WS Connections").foregroundStyle(.secondary)
                        Text("\(s.wsConnections)").monospacedDigit()
                    }
                }
                .font(.callout)
            } else {
                Text("Loading\u{2026}").foregroundStyle(.secondary)
            }
        }
    }

    // Cleanup: two steppers + Run button
    private var cleanupSection: some View {
        GroupBox("Session Cleanup") {
            VStack(alignment: .leading, spacing: 12) {
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
        }
    }

    // Export
    private var exportSection: some View {
        GroupBox("Export Data") {
            HStack {
                Text("Download a full JSON export of all sessions, agents, and events.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
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
            }
        }
    }

    // Danger zone
    private var dangerZoneSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Danger Zone")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("These actions are permanent and cannot be undone.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear All Data\u{2026}", role: .destructive) {
                    showDangerAlert = true
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
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.3), lineWidth: 1))
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
