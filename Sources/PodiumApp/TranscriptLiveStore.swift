#if os(macOS)
import Foundation

/// Owns transcript pagination + live-append state for one session's
/// Conversation or Thinking tab. Pulled out of the view body (per the
/// project's `@Observable`-owns-logic convention — see `RunState`) so the
/// cursor/dedupe/debounce behavior is a plain, DI-friendly unit rather than
/// `@State` scattered across a SwiftUI view.
///
/// Builds its own `PodiumAPI` from `UserDefaults` host/port rather than
/// taking `AppState` via `@Environment` — the same independence `RunState`
/// uses, and it sidesteps `@Environment` not being populated yet at `@State`
/// default-value construction time. A `fetch` override can be injected for
/// tests (no `PodiumApp` XCTest target exists in this repo yet to exercise
/// that — see SessionDetailView.swift's live-append section for the gap this
/// was built to close).
@Observable
@MainActor
final class TranscriptLiveStore {
    typealias Fetch = (_ after: Int?, _ before: Int?, _ limit: Int) async throws -> TranscriptResponse

    let sessionId: String
    var messages: [TranscriptMessage] = []
    var isLoading = false
    var hasLoadedOnce = false
    var hasMore = false
    var firstLine: Int? = nil
    var lastLine: Int? = nil

    /// Whether the view believes the user is following along at the bottom
    /// of the transcript (vs. scrolled up reading history). Set by the view
    /// from its own scroll-position tracking; read here to decide whether a
    /// live append should surface a "N new messages" pill instead of
    /// silently growing the list off-screen.
    var isNearBottom = true
    var pendingNewCount = 0

    private var isAppendingLive = false
    private var appendDebounce: Task<Void, Never>? = nil
    private let fetch: Fetch

    init(sessionId: String, fetch: Fetch? = nil) {
        self.sessionId = sessionId
        if let fetch {
            self.fetch = fetch
        } else {
            let host = UserDefaults.standard.string(forKey: "podium_host") ?? "localhost"
            let rawPort = UserDefaults.standard.integer(forKey: "podium_port")
            let api = PodiumAPI(host: host, port: rawPort == 0 ? 4820 : rawPort)
            self.fetch = { after, before, limit in
                try await api.transcript(sessionId, after: after, before: before, limit: limit)
            }
        }
    }

    // Deliberately no `deinit` cancellation: `deinit` runs nonisolated even on
    // a `@MainActor` class, so it can't touch `appendDebounce` directly. The
    // view calls `cancelPendingAppend()` from `.onDisappear` instead, and an
    // orphaned debounce Task is harmless — it fires once, finds nothing to
    // append against a deallocated fetch closure's captured state, and ends.

    // MARK: Initial load / backward pagination

    func loadInitial() async {
        guard !hasLoadedOnce else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await fetch(nil, nil, 50)
            messages = resp.messages
            hasMore = resp.hasMore
            firstLine = resp.firstLine
            lastLine = resp.lastLine
            hasLoadedOnce = true
        } catch {}
    }

    func loadMore() async {
        guard let before = firstLine else { return }
        do {
            let resp = try await fetch(nil, before, 50)
            messages = resp.messages + messages
            hasMore = resp.hasMore
            firstLine = resp.firstLine
        } catch {}
    }

    // MARK: Scroll-position bookkeeping (driven by the view)

    func setNearBottom(_ value: Bool) {
        guard value != isNearBottom else { return }
        isNearBottom = value
        if value { pendingNewCount = 0 }
    }

    func acknowledgeJumpToLatest() {
        pendingNewCount = 0
    }

    // MARK: Live append

    /// Debounces bursts of WS `new_event` ticks (hook events can arrive in
    /// quick succession — several PostToolUse events per turn) into a single
    /// fetch rather than one per event.
    func scheduleLiveAppend(debounce: Duration = .milliseconds(600)) {
        guard hasLoadedOnce else { return }
        appendDebounce?.cancel()
        appendDebounce = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.appendLiveMessages()
        }
    }

    func cancelPendingAppend() {
        appendDebounce?.cancel()
    }

    /// Fetches everything newly written since `lastLine` and appends it.
    /// Guarded by `isAppendingLive` so overlapping calls (e.g. a debounced
    /// call landing while a previous one is still in flight) can't double
    /// append the same lines. Drains up to 5 pages per call so a burst of
    /// >200 new lines doesn't stall indefinitely — any remainder is picked
    /// up by the next scheduled append.
    @discardableResult
    func appendLiveMessages(pageLimit: Int = 200, maxPages: Int = 5) async -> Int {
        guard var cursor = lastLine, !isAppendingLive else { return 0 }
        isAppendingLive = true
        defer { isAppendingLive = false }
        var appended = 0
        for _ in 0..<maxPages {
            guard let resp = try? await fetch(cursor, nil, pageLimit), !resp.messages.isEmpty else { break }
            messages.append(contentsOf: resp.messages)
            appended += resp.messages.count
            cursor = resp.lastLine ?? cursor
            lastLine = cursor
            if !isNearBottom { pendingNewCount += resp.messages.count }
            guard resp.hasMore else { break }
        }
        return appended
    }
}
#endif
