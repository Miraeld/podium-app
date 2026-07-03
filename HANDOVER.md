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

- **Done (9/22):** P0.1, P1.1, P1.2, P2.1, P2.2, P2.3, P2.4, P3.4, P5.2. Phase 2
  E2E-gate passed (real binary ingested live production hook traffic).
- **In flight right now:** P3.1 (transcript engine, re-dispatched ~21:35 CEST
  2026-07-03 — fence: Transcripts/, Discovery/ClaudeHome.swift, SessionsRouter
  501 stubs, HooksRouter seam wiring, PodiumStore+Transcripts.swift) and P4.1
  (run-spawner, dispatched ~21:55 CEST — fence: Runs/, RunRouter.swift,
  PodiumStore+Runs.swift, main.swift mounts). If you're reading this cold, they
  are dead: reconcile via §0 step 2.
- **Next unblocked after those:** P3.3 (needs P3.1's ClaudeHome/ConfigFile —
  do not run concurrently with P3.1), P3.2 (needs P3.1+P2.3 — includes the
  watchdog + stuck-agent periodic loops P2.3 deferred), P4.2 (Notifier wiring
  touches HooksRouter.swift:25 — do not run concurrently with P3.1), P4.3/P4.4,
  then P5.1 → P5.3 → P5.4 → P5.5, then P6. Phase-3 hardening gate (code review
  phases 2+3 + React contract check) once P3.1/P3.2/P3.3 land.
- **Standing correction:** error responses are CodedErrorResponse
  {"error":{"code","message"}} — some §6 prompts still show the flat shape;
  the run log (P2.2 entry) is authoritative.
- **Test count at handover:** 171/171 green (`swift test`).
- **Environment quirks:** repo has an auto-commit hook (partial agent work
  lands in `Auto-commit:` commits); /Applications/Podium.app (old install) can
  shadow the dev bundle when UI-testing — check `ps` first; session-limit
  errors can kill an Agent spawn with 0 tokens used — just re-dispatch.
