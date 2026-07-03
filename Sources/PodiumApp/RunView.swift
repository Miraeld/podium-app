#if os(macOS)
import SwiftUI
import AppKit

// MARK: - RunView

struct RunView: View {
    @State private var runState = RunState()
    @State private var showingNewRun = false

    var body: some View {
        HSplitView {
            // Left panel: run list
            RunListPanel(runState: runState, showingNewRun: $showingNewRun)
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)

            // Right panel: active run detail or new run form
            RunDetailPanel(runState: runState, showingNewRun: $showingNewRun)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            runState.connect()
            await runState.loadRuns()
        }
        .onDisappear {
            runState.disconnect()
        }
    }
}

// MARK: - Left: Run List Panel

private struct RunListPanel: View {
    @Bindable var runState: RunState
    @Binding var showingNewRun: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Runs")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    showingNewRun = true
                    runState.selectedRunId = nil
                } label: {
                    Label("New Run", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.cyan.opacity(0.18))
                .foregroundStyle(.cyan)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.3), lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if runState.runs.isEmpty {
                EmptyStateView(
                    icon: "terminal",
                    title: "No runs yet",
                    message: "Click \"New Run\" to spawn a Claude Code process."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(runState.runs) { run in
                            RunRowView(run: run, isSelected: runState.selectedRunId == run.id)
                                .onTapGesture {
                                    showingNewRun = false
                                    Task { await runState.select(run.id) }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Run List Row

private struct RunRowView: View {
    let run: RunHandle
    let isSelected: Bool

    private var statusColor: Color { Theme.color(for: run.status) }
    private var projectName: String { URL(fileURLWithPath: run.cwd).lastPathComponent }
    private var relativeTime: String { Theme.shortDate(run.startedDate) }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, active: run.isActive)

            VStack(alignment: .leading, spacing: 3) {
                Text(run.prompt)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                StatusBadge(label: run.status, color: statusColor)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        .glassCard()
        .contentShape(Rectangle())
    }
}

// MARK: - Right: Run Detail Panel

private struct RunDetailPanel: View {
    @Bindable var runState: RunState
    @Binding var showingNewRun: Bool

    var body: some View {
        if showingNewRun || runState.selectedRunId == nil {
            NewRunForm(runState: runState, showingNewRun: $showingNewRun)
        } else if let handle = runState.currentHandle {
            RunOutputPanel(runState: runState, handle: handle)
        } else {
            EmptyStateView(
                icon: "terminal",
                title: "Select a run",
                message: "Pick a run from the list or start a new one."
            )
        }
    }
}

// MARK: - New Run Form

private struct NewRunForm: View {
    @Bindable var runState: RunState
    @Binding var showingNewRun: Bool

    @State private var prompt: String = ""
    @State private var cwd: String = ""
    @State private var mode: String = "conversation"
    @State private var model: String = ""
    @State private var isRunning = false

    private var canRun: Bool { !cwd.isEmpty && !prompt.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Title
                Text("New Run")
                    .font(.title2.weight(.bold))

                // Working directory picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Working Directory")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(cwd.isEmpty ? "No folder selected" : cwd)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(cwd.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            pickDirectory()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .padding(12)
                    .glassCard()
                }

                // Prompt
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.callout)
                        .frame(minHeight: 120)
                        .padding(10)
                        .glassCard()
                        .scrollContentBackground(.hidden)
                }

                // Mode picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $mode) {
                        Text("Conversation").tag("conversation")
                        Text("One-shot").tag("headless")
                    }
                    .pickerStyle(.segmented)
                }

                // Model (optional)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. claude-sonnet-4-6", text: $model)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(10)
                        .glassCard()
                }

                // Error
                if let err = runState.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .glassCard()
                }

                // Run button
                HStack {
                    Spacer()
                    Button {
                        Task {
                            isRunning = true
                            let m = model.trimmingCharacters(in: .whitespaces)
                            await runState.start(
                                prompt: prompt,
                                mode: mode,
                                cwd: cwd,
                                model: m.isEmpty ? nil : m
                            )
                            isRunning = false
                            if runState.errorMessage == nil {
                                showingNewRun = false
                                prompt = ""
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView().scaleEffect(0.7).tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isRunning ? "Starting…" : "Run")
                                .font(.callout.weight(.semibold))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(canRun ? Color.cyan.opacity(0.8) : Color.secondary.opacity(0.2))
                    .foregroundStyle(canRun ? Color.white : Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(!canRun || isRunning)
                }
            }
            .padding(24)
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select working directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
        }
    }
}

// MARK: - Run Output Panel

private struct RunOutputPanel: View {
    @Bindable var runState: RunState
    let handle: RunHandle

    @State private var followupText: String = ""
    @State private var isSending = false
    @State private var scrollProxy: ScrollViewProxy?

    private var isActive: Bool { handle.isActive }
    private var duration: String {
        let start = handle.startedDate
        let end = handle.endedDate ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(handle.prompt)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(URL(fileURLWithPath: handle.cwd).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                        Text(handle.mode == "conversation" ? "Conversation" : "One-shot")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                StatusBadge(
                    label: runState.currentStatus ?? handle.status,
                    color: Theme.color(for: runState.currentStatus ?? handle.status)
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Streaming output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(runState.currentEnvelopes) { envelope in
                            ForEach(Array(envelope.segments.enumerated()), id: \.offset) { _, segment in
                                RunOutputRow(segment: segment)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: runState.currentEnvelopes.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Footer: status + duration + stop button
            HStack(spacing: 12) {
                StatusDot(
                    color: Theme.color(for: runState.currentStatus ?? handle.status),
                    active: isActive
                )
                Text(runState.currentStatus ?? handle.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                if let err = runState.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                if isActive {
                    Button {
                        Task { await runState.stop() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.18))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Follow-up field (conversation mode, terminal status)
            if handle.mode == "conversation" && !isActive {
                Divider()
                HStack(spacing: 10) {
                    TextField("Follow-up message…", text: $followupText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(10)
                        .glassCard()
                        .onSubmit {
                            sendFollowup()
                        }
                    Button {
                        sendFollowup()
                    } label: {
                        Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(followupText.isEmpty ? Color.secondary.opacity(0.15) : Color.cyan.opacity(0.8))
                    .foregroundStyle(followupText.isEmpty ? Color.secondary : Color.white)
                    .clipShape(Circle())
                    .disabled(followupText.isEmpty || isSending)
                }
                .padding(12)
            }
        }
    }

    private func sendFollowup() {
        guard !followupText.isEmpty else { return }
        let text = followupText
        followupText = ""
        isSending = true
        Task {
            await runState.sendFollowup(text: text)
            isSending = false
        }
    }
}

// MARK: - Run Output Row

struct RunOutputRow: View {
    let segment: RunSegment

    var body: some View {
        switch segment {
        case .text(let t):
            Text(t)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)

        case .toolUse(let name, let input):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                    Text(name)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.cyan)
                if !input.isEmpty {
                    Text(input)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cyan.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .toolResult(let text, let isError):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                    Text(isError ? "Tool Error" : "Tool Result")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(isError ? .red : .secondary)
                if !text.isEmpty {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? .red.opacity(0.9) : .secondary)
                        .lineLimit(6)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? Color.red.opacity(0.06) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isError ? Color.red.opacity(0.3) : Color.primary.opacity(0.1),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.leading, 16)

        case .system(let s):
            Text(s)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)

        case .result(let r):
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(.cyan)
                Text(r.isEmpty ? "Run completed" : r)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cyan.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

#endif
