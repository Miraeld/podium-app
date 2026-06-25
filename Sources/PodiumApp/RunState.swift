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

    private let ws = WebSocketClient()

    // MARK: Connect WebSocket (called from RunView .task)

    func connect() {
        let host = UserDefaults.standard.string(forKey: "podium_host") ?? "localhost"
        let rawPort = UserDefaults.standard.integer(forKey: "podium_port")
        let port = rawPort == 0 ? 4820 : rawPort
        guard let url = URL(string: "ws://\(host):\(port)/ws") else { return }

        ws.onMessage = { [weak self] type, data in
            Task { @MainActor [weak self] in
                self?.handleWSMessage(type: type, data: data)
            }
        }

        ws.onStateChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self, connected else { return }
                // Re-fetch on reconnect to close any gap while disconnected
                if let id = self.selectedRunId,
                   self.currentHandle?.isActive == true {
                    await self.fetchRun(id)
                }
            }
        }

        ws.connect(url: url)
    }

    func disconnect() {
        ws.disconnect()
    }

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

        // Catch-up: load authoritative envelope log once, then WS streams the rest
        await fetchRun(id)
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
            // Catch-up fetch (may be empty now, WS will stream live output)
            await fetchRun(handle.id)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Kill current run

    func stop() async {
        guard let id = selectedRunId else { return }
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

    // MARK: Private: fetch single run with envelopes (catch-up)

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

    // MARK: Private: WebSocket message handler

    private func handleWSMessage(type: String, data: Data) {
        switch type {
        case "run_stream":
            guard let msg = try? JSONDecoder.podium.decode(RunStreamMessage.self, from: data) else { return }
            let payload = msg.data
            guard payload.id == selectedRunId else { return }
            currentEnvelopes.append(payload.envelope)

        case "run_status":
            guard let msg = try? JSONDecoder.podium.decode(RunStatusMessage.self, from: data) else { return }
            let payload = msg.data
            // Update current run status if selected
            if payload.id == selectedRunId {
                currentStatus = payload.status
            }
            // Update in the runs list regardless
            if let idx = runs.firstIndex(where: { $0.id == payload.id }) {
                // Rebuild the handle with the updated status via a local copy trick;
                // since RunHandle is a struct with a let status, we re-fetch lazily
                // only when selected. For the list badge we update the status display
                // by triggering a lightweight reload at terminal state.
                let wasActive = runs[idx].isActive
                if wasActive && (payload.status == "completed" || payload.status == "error" || payload.status == "killed") {
                    Task { await self.loadRuns() }
                }
            }

        default:
            break
        }
    }
}
