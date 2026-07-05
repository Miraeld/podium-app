# Handover prompt — paste this into a fresh Claude session to continue

> Keep this file updated: the orchestrator refreshes the "Live state" section
> after every task completion. Last update: 2026-07-05 ~01:30 CEST (Fable 5,
> interactive session — endgame; repo now on GitHub with live CI).

## Paste-ready prompt

```
You are taking over as orchestrator of the "Podium Standalone" project in
/Users/gaelrobin/Desktop/PodiumSwiftApp (branch develop, remote
github.com/Miraeld/podium-app — public, CI live on push/PR).

Read STANDALONE_PLAN.md — start with §0 (resume protocol, binding), then §5
(task board), §7 (run log, bottom-up), §4 + §6b (working agreements + product
decisions). Then HANDOVER.md "Live state" below.

Your job: verify/close the open items below (P6.2a is the other session's
lane — coordinate via the board, don't re-dispatch it), finish P6.1's
remaining verification, then the v1 close-out list. Quality over breadth
(agreement #8). Pull before every board edit; push after every commit now
that a remote exists.
```

## Live state (refresh me on every board change)

- **2026-07-05 (late) — CI FULLY GREEN: run 28755002211, both jobs ✅.** The
  "flaky CI" was FOUR stacked real RunSpawner bugs (cooperative-pool
  deadlock from waitUntilExit in Task.detached; pipe write-ends never
  closed → EOF-less blocking drain; readabilityHandler never detached at
  EOF → GCD spin-storm until reap; the documented inFlightIO wait LOST
  from onProcessTerminated → finalize outran envelope reads) + two
  runner-env gates (Linux container networking, dead-port latency) + one
  Linux test-classifier fix (corelibs 0/1 NSNumber→Bool bridging;
  objCType=='c' is the real bool marker). Full story: §7 run log rows
  dated 2026-07-05.
- **P6.2a contract suite: 29/29 green, ours now** (@P lane dead, adopted).
  Six wire-parity bug families fixed (workflows camelCase, explicit nulls,
  settings info shape, vapid publicKey, updates git_repo, search/run
  families). ContractTests is the wire gate — keep it green.
- **P6.2b docs: DONE** (README/MIGRATION/CLAUDE.md rewritten). README's
  "Verified compatibility" holds a placeholder until the browser walk.
- **Local: 463/463.** Suite runtime dropped 18.7s→14.2s when the EOF storm
  died — regressions there are a smell.
- **NEXT WORK COMES FROM ROADMAP.md** (repo root) — the full PO plan with
  copy-paste dispatch prompts. Phase 0: 0.2 contract-check.sh, 0.3 browser
  walk, 0.4 README close-out. Phase 1: F2 bugs (likely client-mode
  degradation), QA sweep, main branch, THE SWITCHOVER (human, with Gaël).
  Phase 2 features ranked. Don't re-plan — execute.
- **CI truth policy (Gaël, binding):** local-green + runner-red ⇒
  GITHUB_ACTIONS-gated XCTSkip with the observed mechanism in a comment.
  Never delete, never gate unconditionally, never gate a local failure.
- **New global skill `/orch-fable`** (~/.claude/skills/orch-fable, model:
  opus) — run it at session start to orchestrate Fable-style after Fable
  retires. ROADMAP.md §3 has the per-repo operating rules.
- **HUMAN (Gaël) checklist:** unchanged — prod `podium` Docker container
  (UNHEALTHY since ~07-04) is his only live dashboard until the
  switchover; its DB bind-mount is the data the app takes over. Remove it
  only AS PART of the supervised switchover (ROADMAP 1.4). DMG ready at
  dist/Podium-1.0.dmg.
- **Open minor debts:** tracked in ROADMAP.md Phase 3 ledger (PushNotifier
  Sendable warning; audit LinuxDesktopNotifier/GitContext/RunBinaryLocator
  waitUntilExit call sites; cold-cache import; cc-config symlink gap;
  WorkflowSessionRaw dead code; stdin-backpressure test for 2.2a).
- **Environment quirks (still true):** auto-commit hook commits the WHOLE
  dirty tree on any agent save — authorship = `git show <sha> -- <file>`.
  Agents finish then idle without reporting — ping before assuming death.
  A USER INTERRUPT kills running background agents. /Applications/
  Podium.app (old install) can shadow the dev bundle. ClaudeHome.current()
  defaults to the REAL ~/.claude — tests need CLAUDE_HOME + PodiumPaths
  HOME overrides (ContractTests shows the pattern). /usr/bin/true, never
  /bin/true (Darwin 25 removed it). NEVER touch: ~/.claude/podium/data,
  Gaël's running PodiumApp, his prod podium container.
