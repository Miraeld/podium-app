#if os(macOS)
import SwiftUI
import PodiumCore

// TASK 2.9b (UI half) — the visible surface for the update system whose
// state/API layer already lives on AppState (updateStatus, checkForUpdatesNow,
// dismissUpdate, openReleasePage) and UpdateCheck. Stage 1 only: notify +
// changelog + "open the GitHub release page" — no self-download/replace
// (that's the parked 2.9c). Matches the Clawd-on-desk UX Gaël asked for:
// a popup with Dismiss / Update, where Update opens the release page.

// MARK: - Proactive popup (driven by AppState.showUpdatePopup)

/// Shown once per launch when the on-launch check finds an update for a
/// version the user hasn't already dismissed. Presented as a sheet from
/// ContentView. Both buttons call `dismissUpdate`, which persists the
/// dismissal (so this exact version never re-nags) and flips
/// `showUpdatePopup` false, closing the sheet.
struct UpdateAvailablePopup: View {
    @Environment(AppState.self) private var state

    private var app: RepoUpdateStatus? { state.updateStatus?.app }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 6) {
                Text("New update available")
                    .font(.title2.bold())
                if let latest = app?.latestVersion {
                    Text("Podium \(latest) is ready.")
                        .foregroundStyle(.secondary)
                }
                if let current = app?.currentVersion, current != "dev" {
                    Text("You're on \(current).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let notes = app?.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(changelog(notes))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(12)
                .modifier(GlassCardModifier())
            }

            HStack(spacing: 12) {
                Button("Dismiss") { dismiss(open: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { dismiss(open: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    private func dismiss(open: Bool) {
        if open { state.openReleasePage() }
        if let latest = app?.latestVersion {
            state.dismissUpdate(version: latest)
        } else {
            state.showUpdatePopup = false
        }
    }
}

// MARK: - Settings ▸ Updates tab

struct UpdatesTab: View {
    @Environment(AppState.self) private var state

    private var app: RepoUpdateStatus? { state.updateStatus?.app }

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("Current", value: UpdateCheck.currentAppVersion())
                if let latest = app?.latestVersion {
                    LabeledContent("Latest release", value: latest)
                }
                HStack {
                    Button(state.isCheckingForUpdates ? "Checking\u{2026}" : "Check for Updates") {
                        Task { await state.checkForUpdatesNow() }
                    }
                    .disabled(state.isCheckingForUpdates)
                    if state.isCheckingForUpdates { ProgressView().scaleEffect(0.7) }
                    if state.updateCheckFailed {
                        Label("Couldn't reach GitHub", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let app, app.updateAvailable {
                Section("Update available") {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                        Text(app.latestVersion.map { "Podium \($0) is available." } ?? "A new version is available.")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("View Release") { state.openReleasePage() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                    if let notes = app.releaseNotes, !notes.isEmpty {
                        ScrollView {
                            Text(changelog(notes))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                    Text("Download the DMG from the release page, then drag Podium to Applications to replace this version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if app != nil {
                Section {
                    Label("You're on the latest version.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared changelog rendering

/// Renders GitHub release-notes markdown. Falls back to the raw string if
/// markdown parsing fails (never throws away the content).
private func changelog(_ markdown: String) -> AttributedString {
    (try? AttributedString(
        markdown: markdown,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(markdown)
}

#endif
