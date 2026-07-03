# Handover prompt — paste this into a fresh Claude session to continue

> Keep this file updated: the orchestrator refreshes the "Live state" section
> after every task completion. Last update: 2026-07-03 ~21:35 CEST (Fable 5,
> session 2 — post-handover).

## Paste-ready prompt

```
You are taking over as orchestrator of the "Podium Standalone" project in
/Users/gaelrobin/Desktop/PodiumSwiftApp (branch develop).

Read STANDALONE_PLAN.md — start with §0 (resume protocol, binding), then §5
(task board), §7 (run log, bottom-up), §4 + §6b (working agreements + product
decisions). Then HANDOVER.md "Live state" for what was in flight when the
previous session ended.

Your job: reconcile any 🟦 tasks per §0 step 2 (their agents died with the old
session; partial work is auto-committed — check git log), then keep dispatching
Sonnet dev agents per §0 step 3 until the board is done, updating the board +
run log + this file as you go. Quality over breadth (agreement #8) — hardening
gate between phases.
```

## Live state (refresh me on every board change)

- **Done (8/22):** P0.1, P1.1, P1.2, P2.1, P2.2, P2.3, P2.4, P5.2. Phase 2
  E2E-gate passed (real binary ingested live production hook traffic).
- **In flight right now:** P3.1 (transcript engine) and P3.4 (workflows API) —
  RE-dispatched ~21:35 CEST 2026-07-03 by session 2 after reconciling the first
  dispatch (dead with old session; P3.4 partial work committed as c909bcb +
  stopgap fixes, P3.1 had nothing). If you're reading this cold, they are dead
  again: reconcile via §0 step 2 (fences: P3.1 owns Transcripts/, Discovery/
  ClaudeHome.swift, SessionsRouter 501 stubs, HooksRouter seam wiring,
  PodiumStore+Transcripts.swift; P3.4 owns Workflows/, PodiumStore+Workflows.swift,
  WorkflowsRouter.swift, main.swift mounts).
- **Next unblocked after those:** P3.3 (needs P3.1's ClaudeHome/ConfigFile —
  do not run concurrently with P3.1), P3.2 (needs P3.1+P2.3 — includes the
  watchdog + stuck-agent periodic loops P2.3 deferred), then P4.1/P4.2/P4.3/
  P4.4 in parallel lanes, then P5.1 → P5.3 → P5.4 → P5.5, then P6.
- **Standing correction:** error responses are CodedErrorResponse
  {"error":{"code","message"}} — some §6 prompts still show the flat shape;
  the run log (P2.2 entry) is authoritative.
- **Test count at handover:** 171/171 green (`swift test`).
- **Environment quirks:** repo has an auto-commit hook (partial agent work
  lands in `Auto-commit:` commits); /Applications/Podium.app (old install) can
  shadow the dev bundle when UI-testing — check `ps` first; session-limit
  errors can kill an Agent spawn with 0 tokens used — just re-dispatch.
