import Foundation
import SwiftUI

// MARK: - RunState

@Observable
@MainActor
final class RunState {
    var runs: [RunHandle] = []
    var selectedRunId: String?
    var currentEnvelopes: [RunEnvelope] = []
    var currentStatus: String?
    var currentHandle: RunHandle?
    var isLoading = false
    var errorMessage: String?

    private let api: PodiumAPI = {
        let host = UserDefaults.standard.string(forKey: "podium_host") ?? "localhost"
        let port = UserDefaults.standard.integer(forKey: "podium_port") == 0
            ? 4820
            : UserDefaults.standard.integer(forKey: "podium_port")
        return PodiumAPI(host: host, port: port)
    }()

    private var pollTask: Task<Void, Never>?

    // MARK: Load runs (active + history merged, deduped, sorted by startedAt desc)

    func loadRuns() async {
        do {
            async let active = api.runs()
            async let history = api.runHistory()
            let (a, h) = try await (active, history)
            var seen = Set<String>()
            var merged: [RunHandle] = []
            for r in (a.items + h.items) {
                if seen.insert(r.id).inserted { merged.append(r) }
            }
            merged.sort { $0.startedAt > $1.startedAt }
            runs = merged
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Select a run

    func select(_ id: String) async {
        guard id != selectedRunId else { return }
        selectedRunId = id
        currentEnvelopes = []
        currentStatus = nil
        currentHandle = nil
        stopPolling()

        // Load once immediately, then start poll if active
        await fetchRun(id)
        if currentHandle?.isActive == true {
            startPolling(id)
        }
    }

    // MARK: Start a new run

    func start(prompt: String, mode: String, cwd: String, model: String?) async {
        errorMessage = nil
        do {
            let handle = try await api.createRun(
                prompt: prompt,
                mode: mode,
                cwd: cwd,
                model: model,
                permissionMode: "acceptEdits"
            )
            // Insert at front of list
            runs.insert(handle, at: 0)
            currentEnvelopes = []
            currentStatus = handle.status
            currentHandle = handle
            selectedRunId = handle.id
            stopPolling()
            startPolling(handle.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Send follow-up message (conversation mode)

    func sendFollowup(text: String) async {
        guard let id = selectedRunId else { return }
        errorMessage = nil
        do {
            try await api.sendRunMessage(id, text: text)
            // After sending, poll again if not already polling
            if pollTask == nil {
                startPolling(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Kill current run

    func stop() async {
        guard let id = selectedRunId else { return }
        stopPolling()
        do {
            try await api.killRun(id)
            // Refresh to get updated status
            await fetchRun(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Reload list
        await loadRuns()
    }

    // MARK: Private: fetch single run with envelopes

    private func fetchRun(_ id: String) async {
        do {
            let handle = try await api.run(id)
            currentHandle = handle
            currentStatus = handle.status
            currentEnvelopes = handle.envelopes ?? []
            // Update in list
            if let idx = runs.firstIndex(where: { $0.id == id }) {
                runs[idx] = handle
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Private: polling

    private func startPolling(_ id: String) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchRun(id)
                // Stop poll when terminal
                if let status = self.currentStatus,
                   status == "completed" || status == "error" || status == "killed" {
                    await self.loadRuns()
                    break
                }
                try? await Task.sleep(nanoseconds: 800_000_000) // 800ms
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
