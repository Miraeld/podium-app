// CcWatcher.swift — port of dashboard/server/lib/cc-watcher.js: best-effort
// file watcher for the Claude Code config surfaces surfaced by the Config
// Explorer page. Watches ~/.claude/ (recursively where the platform
// supports it) plus ~/.claude.json and emits a debounced `cc_config_changed`
// broadcast so the UI can refetch without polling.
//
// Platform split (per the P4.3 task spec, "keep it simple, no inotify dep"):
//   - macOS: DispatchSource.makeFileSystemObjectSource per watched directory
//     (kevent-backed, no recursive-watch primitive on Darwin either — Node's
//     `fs.watch(..., { recursive: true })` uses FSEvents under the hood,
//     which isn't exposed to a plain Dispatch source; a top-level watch on
//     each RELEVANT_PREFIXES directory plus the two root files is close
//     enough for a config explorer that already has a manual refresh button
//     — deep nested changes inside e.g. skills/<name>/ still surface because
//     writes touch the SKILL.md file directly, and DispatchSource on a
//     directory fires for content changes within it via .write).
//   - Linux (and any other non-Darwin platform): 2s mtime-poll fallback —
///    no inotify dependency, matching the task's explicit "keep it simple"
//     instruction.
//
// Filtering: only paths matching real config surfaces trigger a broadcast.
// Anything else (transcripts, file history, our own backups) is ignored —
// same RELEVANT_PREFIXES / IGNORED_PREFIXES split as cc-watcher.js, applied
// here to the top-level entries scanned/watched under ClaudeHome.

import Foundation

#if canImport(Darwin)
import Darwin
import Dispatch
#endif

/// Debounce window before a broadcast fires — matches cc-watcher.js's
/// `DEBOUNCE_MS`.
let ccWatcherDebounceMs: UInt64 = 500

/// Subpaths inside `~/.claude/` that ARE config surfaces and should trigger
/// a refetch. Anything else is ignored. Match is by the first path segment
/// relative to ClaudeHome.
let ccWatcherRelevantPrefixes: Set<String> = [
    "settings.json", "settings.local.json", "keybindings.json",
    "statusline.py", "statusline-command.sh", "statusline-command.cmd", "statusline-command.bat",
    "known_marketplaces.json", "agents", "commands", "skills", "output-styles",
    "hooks", "plugins", "CLAUDE.md",
]

/// Subpaths to explicitly ignore even if they'd otherwise match — most
/// importantly our own backup dir, so writing a backup doesn't re-trigger
/// the watcher in a loop.
let ccWatcherIgnoredPrefixes: Set<String> = [
    "cc-config-backups", "projects", "file-history", "todos", "shell-snapshots", "ide", "logs", "statsig",
]

public enum CcWatcher {
    /// Port of `isRelevantUnderHome` — true if `fullPath`'s first path
    /// segment (relative to `home`) is a real config surface.
    public static func isRelevantUnderHome(_ home: String, _ fullPath: String) -> Bool {
        let homeNS = (home as NSString).standardizingPath
        let fullNS = (fullPath as NSString).standardizingPath
        guard fullNS.hasPrefix(homeNS) else { return false }
        var rel = String(fullNS.dropFirst(homeNS.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        guard !rel.isEmpty else { return false }
        let head = rel.split(separator: "/").first.map(String.init) ?? rel
        if ccWatcherIgnoredPrefixes.contains(head) { return false }
        return ccWatcherRelevantPrefixes.contains(head)
    }
}

/// Notifier seam so `CcConfigWatcherEngine` can be tested without a real
/// WebSocket hub, and so this PodiumCore type never needs to depend on
/// `PodiumServer`'s `Broadcaster` (which lives one layer up). The concrete
/// production adapter — `BroadcasterCcConfigChangeNotifier` — lives in
/// `PodiumServer/Services/CcConfigWatcherService.swift`, wrapping
/// `Broadcaster.broadcast(type:data:)`.
public protocol CcConfigChangeNotifier: Sendable {
    func notifyConfigChanged(source: String, paths: [String]) async
}

/// Background service: watches `ClaudeHome.current()` + `~/.claude.json`
/// for changes relevant to the Config Explorer and notifies (debounced)
/// through `CcConfigChangeNotifier`. `run(context:)`-style callers should
/// use `PodiumServer`'s `CcConfigWatcherBackgroundService` wrapper (kept in
/// PodiumServer since `BackgroundService`/`ServerContext` live there); this
/// type is the cross-platform engine, independent of the server layer.
public actor CcConfigWatcherEngine {
    private var pendingPaths: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private let notifier: CcConfigChangeNotifier
    private let home: String

    /// macOS-only live sources; kept referenced so they aren't deallocated.
    #if canImport(Darwin)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    #endif

    private var pollTask: Task<Void, Never>?

    public init(notifier: CcConfigChangeNotifier, home: String = ClaudeHome.current()) {
        self.notifier = notifier
        self.home = home
    }

    /// Starts watching. Safe to call once; call `stop()` before calling
    /// `start()` again. Non-fatal by design — any platform-level failure to
    /// establish a watch is swallowed (the Config Explorer still has a
    /// manual Refresh button, matching cc-watcher.js's stated philosophy).
    public func start() {
        #if canImport(Darwin)
        startDarwinWatch()
        #else
        startPollWatch()
        #endif
    }

    public func stop() {
        #if canImport(Darwin)
        for source in sources { source.cancel() }
        sources.removeAll()
        for fd in fileDescriptors where fd >= 0 { close(fd) }
        fileDescriptors.removeAll()
        #endif
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths.removeAll()
    }

    private func scheduleNotify(path: String?) {
        if let path { pendingPaths.insert(path) }
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ccWatcherDebounceMs * 1_000_000)
            guard let self else { return }
            await self.flush()
        }
    }

    private func flush() async {
        debounceTask = nil
        let paths = Array(pendingPaths)
        pendingPaths.removeAll()
        guard !paths.isEmpty else { return }
        await notifier.notifyConfigChanged(source: "fs", paths: paths)
    }

    #if canImport(Darwin)
    /// Watches the ClaudeHome top-level entries whose name matches
    /// `ccWatcherRelevantPrefixes` (creating a `DispatchSourceFileSystemObject`
    /// per matching file/dir) plus `~/.claude.json`. New entries created
    /// after start() won't be picked up until the next process restart —
    /// an accepted best-effort limitation (same as Node's non-recursive
    /// fallback would have), since the Config Explorer's manual refresh
    /// covers the gap.
    private func startDarwinWatch() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home) else { return }
        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for name in entries where ccWatcherRelevantPrefixes.contains(name) {
            let full = (home as NSString).appendingPathComponent(name)
            watchPath(full)
        }
        let claudeJson = (PodiumPaths.homeDirectory().path as NSString).appendingPathComponent(".claude.json")
        watchPath(claudeJson)
    }

    private func watchPath(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.scheduleNotify(path: path) }
        }
        source.setCancelHandler {
            close(fd)
        }
        fileDescriptors.append(fd)
        sources.append(source)
        source.resume()
    }
    #endif

    /// Non-Darwin fallback: poll top-level mtimes of the same relevant
    /// entries every 2s. Simple, dependency-free (no inotify), matching the
    /// P4.3 task's explicit instruction.
    private func startPollWatch() {
        pollTask = Task { [home] in
            var lastMtimes: [String: Date] = [:]
            while !Task.isCancelled {
                let fm = FileManager.default
                var candidates: [String] = ccWatcherRelevantPrefixes.map { (home as NSString).appendingPathComponent($0) }
                candidates.append((PodiumPaths.homeDirectory().path as NSString).appendingPathComponent(".claude.json"))
                for path in candidates {
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    if let previous = lastMtimes[path], previous != mtime {
                        await self.scheduleNotify(path: path)
                    }
                    lastMtimes[path] = mtime
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
