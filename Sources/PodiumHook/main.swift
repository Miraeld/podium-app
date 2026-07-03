// podium-hook — tiny native replacement for hook.mjs.
//
// Reads hook JSON on stdin, POSTs to /api/hooks/event on every live Podium
// dashboard server, with a hard 1.5s process deadline. Installed to
// ~/.claude/podium/podium-hook by HookInstaller. Foundation only — no other
// deps so it stays a fast, dependency-free binary Claude Code can shell out
// to on every tool call.
//
// All the real logic lives in PodiumCore/Hooks/HookClient.swift so it's
// unit-testable; this file is just the stdin -> exit(0) plumbing.

import Foundation
import PodiumCore

// Hard safety net: whatever happens, this process must not outlive 1.5s
// (Claude Code kills hooks that run longer than 2s).
let deadline = DispatchWorkItem { exit(0) }
DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)

let input = FileHandle.standardInput.readDataToEndOfFile()

guard
    let json = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
    let event = HookEventBuilder.build(from: json)
else {
    exit(0)
}

let ports = HookPortDiscovery.resolvePorts()
HookClient.postToAllServers(hookType: event.hookType, data: event.data, ports: ports) {
    exit(0)
}

// Keep the process alive until either postToAllServers's completion or the
// deadline above calls exit(0).
dispatchMain()
