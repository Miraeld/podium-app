#if os(macOS)
import SwiftUI
import PodiumCore

// MARK: - Navigation Destination

enum NavDestination: Hashable {
    case dashboard
    case sessions
    case analytics
    case activityFeed
    case search
    case kanban
    case workflows
    case importSession
    case run
    case configExplorer
    case diagnostics
}

// MARK: - Content View

struct ContentView: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: NavDestination = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = {
        UserDefaults.standard.bool(forKey: "sidebar_visible") ? .all : .detailOnly
    }()

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
                .tint(Theme.accent)
        } detail: {
            ZStack {
                ThemeBackground()
                switch selection {
                case .dashboard:    DashboardView()
                case .sessions:     SessionsView()
                case .analytics:    AnalyticsView()
                case .activityFeed: ActivityFeedView()
                case .search:       SearchView()
                case .kanban:       KanbanView()
                case .workflows:    WorkflowsView()
                case .importSession: ImportSessionView()
                case .run:          RunView()
                case .configExplorer: ConfigExplorerView()
                case .diagnostics:  DiagnosticsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            OnboardingOverlayView(anchors: anchors)
        }
        // TASK 2.9b: proactive "New update available" popup, one per launch.
        .sheet(isPresented: $state.showUpdatePopup) {
            UpdateAvailablePopup()
                .environment(state)
        }
        .onChange(of: columnVisibility) { _, v in
            UserDefaults.standard.set(v != .detailOnly, forKey: "sidebar_visible")
        }
        .onChange(of: state.navigationRequest) { _, dest in
            if let d = dest {
                selection = d
                state.navigationRequest = nil
            }
        }
        // P5.5: fires once the first real load (server up, hooks installed)
        // has settled — see AppState.isInitialLoad's own doc comment for why
        // this flips false exactly once per launch, not on every ⌘R.
        .onChange(of: state.isInitialLoad) { _, stillLoading in
            // Only present over a live server: if the first load FAILED
            // (lastError set, stats never arrived), the tour would spotlight
            // empty views and its step-0 poll would hammer a dead endpoint.
            // The tour re-arms via Help ▸ Show Tour, so skipping here is safe.
            if !stillLoading && state.lastError == nil && state.stats != nil {
                OnboardingCoordinator.shared.presentIfNeeded()
            }
        }
        .background(
            // Layer order (back → front):
            // 1. NSVisualEffectView .behindWindow — blurs the wallpaper behind the window
            // 2. Adaptive tint gradient — dark navy-purple in dark mode, soft lavender in light mode
            ZStack {
                WindowTranslucencyAccessor()
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                Group {
                    if colorScheme == .dark {
                        Theme.darkBackgroundGradient.opacity(0.38)
                    } else {
                        Theme.lightBackgroundGradient.opacity(0.18)
                    }
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 10) {
                    ConnectionBanner(isConnected: state.isServerReachable)
                    if state.wsConnected { LiveBadge() }
                    Button {
                        Task { await state.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh (⌘R)")
                }
                .padding(.trailing, 6)
            }
        }
        .background(Group {
            Button("") { selection = .dashboard }.keyboardShortcut("1", modifiers: .command)
            Button("") { selection = .sessions }.keyboardShortcut("2", modifiers: .command)
            Button("") { selection = .analytics }.keyboardShortcut("3", modifiers: .command)
            Button("") { selection = .activityFeed }.keyboardShortcut("4", modifiers: .command)
            Button("") { selection = .search }.keyboardShortcut("5", modifiers: .command)
            Button("") { selection = .kanban }.keyboardShortcut("6", modifiers: .command)
            Button("") { selection = .workflows }.keyboardShortcut("7", modifiers: .command)
            Button("") { selection = .importSession }.keyboardShortcut("8", modifiers: .command)
            Button("") { selection = .run }.keyboardShortcut("9", modifiers: .command)
            Button("") { selection = .configExplorer }.keyboardShortcut("0", modifiers: .command)
            Button("") { selection = .search }.keyboardShortcut("k", modifiers: .command)
        })
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: NavDestination
    @Environment(AppState.self) var state

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack(spacing: 10) {
                    PodiumLogo(size: 32)
                    Text("Podium")
                        .font(.title3.weight(.bold))
                    Spacer()
                }
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            }
            Section {
                SidebarRow(
                    icon: "house.fill",
                    label: "Dashboard",
                    value: .dashboard,
                    badge: state.stats.map { "\($0.activeSessions) active" }
                )
                .onboardingAnchor(.dashboard)
                SidebarRow(
                    icon: "list.bullet.rectangle.portrait.fill",
                    label: "Sessions",
                    value: .sessions,
                    badge: state.sessionTotal > 0 ? "\(state.sessionTotal)" : nil
                )
                .onboardingAnchor(.sessions)
                SidebarRow(
                    icon: "chart.bar.fill",
                    label: "Analytics",
                    value: .analytics
                )
                SidebarRow(icon: "waveform", label: "Activity", value: .activityFeed)
                    .onboardingAnchor(.activityFeed)
            } header: {
                Text("Observe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Section {
                SidebarRow(icon: "magnifyingglass", label: "Search", value: .search)
                SidebarRow(icon: "rectangle.split.3x1.fill", label: "Kanban", value: .kanban)
                SidebarRow(icon: "arrow.triangle.branch", label: "Workflows", value: .workflows)
                SidebarRow(icon: "square.and.arrow.down", label: "Import", value: .importSession)
                SidebarRow(icon: "terminal", label: "Run", value: .run)
                SidebarRow(icon: "folder.badge.gearshape", label: "CC Config", value: .configExplorer)
            } header: {
                Text("Discover")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Section {
                SidebarRow(icon: "stethoscope", label: "Diagnostics", value: .diagnostics)
            } header: {
                Text("System")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.sidebarWidth)
        .overlay(alignment: .bottom) {
            // Footer: live listener count + app version (always shown).
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption)
                    Text("\(state.stats?.wsConnections ?? 0) listener\((state.stats?.wsConnections ?? 0) == 1 ? "" : "s")")
                        .font(.caption)
                    Spacer()
                    Text("v\(UpdateCheck.currentAppVersion())")
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

struct SidebarRow: View {
    let icon: String
    let label: String
    let value: NavDestination
    var badge: String? = nil

    var body: some View {
        Label {
            HStack {
                Text(label)
                Spacer()
                if let b = badge {
                    Text(b)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(value)
    }
}


#endif
