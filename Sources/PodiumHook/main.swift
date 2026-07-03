// podium-hook — tiny native replacement for hook.mjs.
//
// Reads hook JSON on stdin, POSTs to /api/hooks/event, with a hard 1.5s
// deadline. Installed to ~/.claude/podium/. Foundation only — no other deps
// so it stays a fast, dependency-free binary Claude Code can shell out to.
//
// Real implementation lands in P2.4; this is a placeholder entry point so the
// executable target builds end-to-end today.

import Foundation

print("podium-hook: placeholder build (P2.4 will add the real stdin->POST logic)")
