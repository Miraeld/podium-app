import SwiftUI
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
            SystemInfoTab()
                .environment(state)
                .tabItem { Label("System", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
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

// MARK: - System Info Tab

struct SystemInfoTab: View {
    @Environment(AppState.self) var state
    @State private var showPurgeAlert = false

    var body: some View {
        Form {
            Section("Server Status") {
                if let s = state.stats {
                    LabeledContent("Total Sessions", value: "\(s.totalSessions)")
                    LabeledContent("Active Sessions", value: "\(s.activeSessions)")
                    LabeledContent("Total Agents", value: "\(s.totalAgents)")
                    LabeledContent("Total Events", value: Theme.formatTokens(s.totalEvents))
                    LabeledContent("WS Connections", value: "\(s.wsConnections)")
                } else {
                    Text("Loading\u{2026}").foregroundStyle(.secondary)
                }
            }
            Section("Maintenance") {
                Button("Purge Sessions Older than 30 Days", role: .destructive) {
                    showPurgeAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .alert("Purge Old Sessions?", isPresented: $showPurgeAlert) {
            Button("Purge", role: .destructive) { }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete sessions older than 30 days. This action cannot be undone.")
        }
    }
}
