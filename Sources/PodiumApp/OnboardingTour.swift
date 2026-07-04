// OnboardingTour.swift — P5.5: first-run onboarding, in-app.
//
// Product frame (STANDALONE_PLAN.md §6b): the objection to kill is "too
// complicated" — this tour is the moment that either proves Podium is simple
// or destroys that impression. So: 5 steps max, one sentence each, every
// step skippable, spotlight-highlights real UI (sidebar rows via anchor
// preferences) instead of screenshots, and it must be re-runnable from
// Help → Show Tour without re-triggering the first-run-only import copy.
//
// Wiring (kept to the fenced files):
//   - PodiumApp.swift: `@State private var onboarding = OnboardingCoordinator.shared`
//     forces the coordinator (and its legacy-import-marker baseline capture)
//     to exist *before* `appState.start()` fires — see `isImportingHistoryThisLaunch`
//     below for why that ordering matters. Also adds the Help-menu command.
//   - ContentView.swift: three `.onboardingAnchor(_:)` tags on the Dashboard/
//     Sessions/Activity sidebar rows, one `.overlayPreferenceValue` to collect
//     them, and one `.onChange(of: state.isInitialLoad)` to trigger the tour
//     once the first real data load (and therefore hook install + embedded
//     server boot) has completed.

#if os(macOS)
import SwiftUI
import PodiumCore

// MARK: - Anchor plumbing (spotlight targets)

/// Collects the on-screen rect of any view tagged `.onboardingAnchor(_:)`,
/// keyed by the sidebar destination it represents. Read back at the
/// NavigationSplitView level via `.overlayPreferenceValue` so the tour
/// overlay can draw a spotlight cutout around the real UI element.
struct OnboardingAnchorKey: PreferenceKey {
    static var defaultValue: [NavDestination: Anchor<CGRect>] = [:]
    static func reduce(value: inout [NavDestination: Anchor<CGRect>], nextValue: () -> [NavDestination: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func onboardingAnchor(_ id: NavDestination) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Steps

struct OnboardingStep: Identifiable {
    let id: Int
    let title: String
    let message: String
    /// Sidebar destination to spotlight, or `nil` for a centered card (used
    /// for the intro and the Settings step — Settings lives in a separate
    /// SwiftUI `Scene`, outside this window, so there's nothing in-window to
    /// spotlight for it).
    let anchor: NavDestination?

    static let steps: [OnboardingStep] = [
        OnboardingStep(
            id: 0,
            title: "Welcome to Podium",
            message: "Podium watches your Claude Code agents live — every session, subagent, and tool call, in one place.",
            anchor: nil
        ),
        OnboardingStep(
            id: 1,
            title: "Live Dashboard",
            message: "This is home base. Active sessions and agents update the moment Claude does something — no refresh needed.",
            anchor: .dashboard
        ),
        OnboardingStep(
            id: 2,
            title: "Sessions & Detail",
            message: "Open any session for its full story: the subagent tree, every tool call, and the raw conversation transcript.",
            anchor: .sessions
        ),
        OnboardingStep(
            id: 3,
            title: "When an Agent Needs You",
            message: "If an agent is waiting on a permission or a question, Podium flags it here and sends a macOS notification.",
            anchor: .activityFeed
        ),
        OnboardingStep(
            id: 4,
            title: "Settings, Whenever",
            message: "Connection, notifications, pricing, and hooks all live in the Podium menu → Settings (⌘,). Re-run this tour anytime from Help → Show Tour.",
            anchor: nil
        ),
    ]
}

// MARK: - Coordinator

@Observable
@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()

    static let completedKey = "podium_onboarding_completed"

    var isPresenting = false
    var stepIndex = 0
    /// Polled live during the intro step while a legacy import is in
    /// flight — see `OnboardingOverlayView.pollLegacyImportIfNeeded()`.
    var legacyImportSessionCount: Int? = nil

    /// Whether `~/Library/Application Support/Podium/.legacy-import.done`
    /// already existed the instant this process launched — captured in
    /// `init()`, which must run before `EmbeddedServer` gets a chance to
    /// create that marker (see PodiumApp.swift's `@State` ordering note).
    private let legacyImportMarkerExistedBeforeLaunch: Bool

    private init() {
        let markerURL = PodiumPaths.dataDir().appendingPathComponent(".legacy-import.done", isDirectory: false)
        legacyImportMarkerExistedBeforeLaunch = FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// True only when THIS launch is the one that ran the one-time legacy
    /// import: we're hosting the embedded server (a pure client didn't run
    /// any import locally) and the marker didn't already exist when we
    /// checked at process start. Drives the dynamic intro-step copy from
    /// STANDALONE_PLAN.md P5.5 task 2.
    var isImportingHistoryThisLaunch: Bool {
        guard case .embedded = EmbeddedServer.shared.mode else { return false }
        return !legacyImportMarkerExistedBeforeLaunch
    }

    /// Called once, after the first real data load completes. No-ops on
    /// every launch after the first (see `completedKey`).
    func presentIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        stepIndex = 0
        legacyImportSessionCount = nil
        isPresenting = true
    }

    /// Help menu → "Show Tour" — always re-runnable, doesn't touch the
    /// completed flag (it's already set by the time a user could reach this).
    func showTour() {
        stepIndex = 0
        legacyImportSessionCount = nil
        isPresenting = true
    }

    func advance() {
        if stepIndex + 1 < OnboardingStep.steps.count {
            stepIndex += 1
        } else {
            finish()
        }
    }

    func back() {
        if stepIndex > 0 { stepIndex -= 1 }
    }

    func skip() { finish() }

    private func finish() {
        isPresenting = false
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}

// MARK: - Overlay

struct OnboardingOverlayView: View {
    @Environment(AppState.self) private var state
    let anchors: [NavDestination: Anchor<CGRect>]

    private let coordinator = OnboardingCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            if coordinator.isPresenting, let step = currentStep {
                ZStack {
                    SpotlightMask(rect: step.anchor.flatMap { anchors[$0] }.map { proxy[$0] })
                        .allowsHitTesting(false)
                    cardView(for: step, in: proxy)
                }
                .task(id: coordinator.stepIndex) {
                    await pollLegacyImportIfNeeded()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: coordinator.stepIndex)
        .animation(.easeInOut(duration: 0.22), value: coordinator.isPresenting)
        .ignoresSafeArea()
    }

    private var currentStep: OnboardingStep? {
        let steps = OnboardingStep.steps
        guard coordinator.stepIndex >= 0, coordinator.stepIndex < steps.count else { return nil }
        return steps[coordinator.stepIndex]
    }

    @ViewBuilder
    private func cardView(for step: OnboardingStep, in proxy: GeometryProxy) -> some View {
        let steps = OnboardingStep.steps
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(step.title)
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(coordinator.stepIndex + 1)/\(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message(for: step))
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip tour") { coordinator.skip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.stepIndex > 0 {
                    Button("Back") { coordinator.back() }
                }
                Button(coordinator.stepIndex == steps.count - 1 ? "Done" : "Next") {
                    coordinator.advance()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .glassCard()
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
        .position(cardPosition(for: step, in: proxy))
    }

    private func message(for step: OnboardingStep) -> String {
        guard step.id == 0, coordinator.isImportingHistoryThisLaunch else { return step.message }
        let countText: String
        if let count = coordinator.legacyImportSessionCount {
            countText = "\(count) session\(count == 1 ? "" : "s") found so far"
        } else {
            countText = "starting now"
        }
        return "\(step.message)\n\nImporting your history — \(countText)."
    }

    private func cardPosition(for step: OnboardingStep, in proxy: GeometryProxy) -> CGPoint {
        let cardHalfWidth: CGFloat = 190
        if let anchorId = step.anchor, let anchor = anchors[anchorId] {
            let rect = proxy[anchor]
            let x = min(rect.maxX + cardHalfWidth + 20, proxy.size.width - cardHalfWidth - 12)
            let y = min(max(rect.midY, 140), proxy.size.height - 140)
            return CGPoint(x: x, y: y)
        }
        return CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }

    /// Only relevant for the intro step on a launch that's actually running
    /// the one-time legacy import — polls `AppState.refresh()` (the existing
    /// public entry point; no need to add a new one) every 1.5s so the
    /// "N sessions found so far" copy is live, not a one-shot snapshot.
    private func pollLegacyImportIfNeeded() async {
        guard coordinator.stepIndex == 0, coordinator.isImportingHistoryThisLaunch else { return }
        while !Task.isCancelled && coordinator.isPresenting && coordinator.stepIndex == 0 {
            coordinator.legacyImportSessionCount = state.stats?.totalSessions
            await state.refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}

/// Full-window dim with a rounded-rect cutout around the spotlighted anchor
/// (even-odd fill rule punches the hole), plus a thin gold ring tracing it.
/// `rect == nil` just dims the whole window uniformly (intro/Settings steps).
private struct SpotlightMask: View {
    var rect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                if let rect {
                    path.addRoundedRect(
                        in: rect.insetBy(dx: -10, dy: -8),
                        cornerSize: CGSize(width: 12, height: 12)
                    )
                }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            if let rect {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .frame(width: rect.width + 20, height: rect.height + 16)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

#endif
