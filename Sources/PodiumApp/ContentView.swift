import SwiftUI

// MARK: - Navigation Destination

enum NavDestination: Hashable {
    case dashboard
    case sessions
    case analytics
    case activityFeed
    case search
    case kanban
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
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
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: columnVisibility) { _, v in
            UserDefaults.standard.set(v != .detailOnly, forKey: "sidebar_visible")
        }
        .onChange(of: state.navigationRequest) { _, dest in
            if let d = dest {
                selection = d
                state.navigationRequest = nil
            }
        }
        .background(
            // Layer order (back → front):
            // 1. NSVisualEffectView .behindWindow — blurs the wallpaper behind the window
            // 2. Adaptive tint gradient — dark navy-purple in dark mode, soft lavender in light mode
            ZStack {
                WindowTranslucencyAccessor()
                VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                Group {
                    if colorScheme == .dark {
                        Theme.darkBackgroundGradient.opacity(0.70)
                    } else {
                        Theme.lightBackgroundGradient.opacity(0.25)
                    }
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(Theme.accentGradient)
                    Text("Podium")
                        .font(.headline.weight(.bold))
                }
                .padding(.leading, 8)
            }
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
            }
        }
        .background(Group {
            Button("") { selection = .dashboard }.keyboardShortcut("1", modifiers: .command)
            Button("") { selection = .sessions }.keyboardShortcut("2", modifiers: .command)
            Button("") { selection = .analytics }.keyboardShortcut("3", modifiers: .command)
            Button("") { selection = .activityFeed }.keyboardShortcut("4", modifiers: .command)
            Button("") { selection = .search }.keyboardShortcut("5", modifiers: .command)
            Button("") { selection = .kanban }.keyboardShortcut("6", modifiers: .command)
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
                SidebarRow(
                    icon: "house.fill",
                    label: "Dashboard",
                    value: .dashboard,
                    badge: state.stats.map { "\($0.activeSessions) active" }
                )
                SidebarRow(
                    icon: "list.bullet.rectangle.portrait.fill",
                    label: "Sessions",
                    value: .sessions,
                    badge: state.sessionTotal > 0 ? "\(state.sessionTotal)" : nil
                )
                SidebarRow(
                    icon: "chart.bar.fill",
                    label: "Analytics",
                    value: .analytics
                )
                SidebarRow(icon: "waveform", label: "Activity", value: .activityFeed)
            } header: {
                Text("Observe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Section {
                SidebarRow(icon: "magnifyingglass", label: "Search", value: .search)
                SidebarRow(icon: "rectangle.split.3x1.fill", label: "Kanban", value: .kanban)
            } header: {
                Text("Discover")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.sidebarWidth)
        .overlay(alignment: .bottom) {
            // Footer: server info
            if let stats = state.stats {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption)
                        Text("\(stats.wsConnections) listener\(stats.wsConnections == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
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

