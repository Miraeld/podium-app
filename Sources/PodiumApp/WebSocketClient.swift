#if os(macOS)
import Foundation

// MARK: - WebSocket Client

@MainActor
final class WebSocketClient: NSObject, URLSessionWebSocketDelegate {
    var onMessage: ((String, Data) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var currentURL: URL?
    private var reconnectDelay: TimeInterval = 1
    private var shouldReconnect = true
    private(set) var isConnected = false

    func connect(url: URL) {
        currentURL = url
        shouldReconnect = true
        openConnection(url: url)
    }

    func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func openConnection(url: URL) {
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = urlSession?.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let text) = msg, let data = text.data(using: .utf8) {
                        if let envelope = try? JSONDecoder().decode(WSEnvelope.self, from: data) {
                            self.onMessage?(envelope.type, data)
                        }
                    }
                    self.receive()
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleDisconnect() {
        isConnected = false
        onStateChange?(false)
        guard shouldReconnect, let url = currentURL else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.openConnection(url: url)
        }
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.reconnectDelay = 1
            self.onStateChange?(true)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            self.handleDisconnect()
        }
    }
}

private struct WSEnvelope: Decodable {
    let type: String
}

#endif
