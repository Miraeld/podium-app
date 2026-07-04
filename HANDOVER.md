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

- **Board: 21 ✅ + P6.1 ⚠️→closing + P6.2a 🟦@P.** All of phases 0–5 and F1
  done. Tests: 433/433 in our scope (the 83 failures visible in a full run
  are ALL in the @P session's untracked WIP Tests/PodiumServerTests/
  ContractTests.swift — do not "fix" them, that lane is theirs).
- **NEW: GitHub remote + CI.** `github.com/Miraeld/podium-app` (public),
  created by Gaël 2026-07-05 ~01:20 CEST, develop pushed. CI (.github/
  workflows/ci.yml: macOS + Linux swift:6.1 container) triggered on the
  push — first-ever CI run; check `gh run list` for the verdict. From now
  on: push after committing; watch CI. Suggested once the board is done:
  create `main` from develop and make it the GitHub default (plan convention
  expects PRs → main).
- **P6.1 status:** macOS fully verified earlier (dist/Podium-1.0.dmg built,
  ad-hoc signed, sandbox-launched clean). Linux: after 4 rounds of real
  verification the tarball now BUILDS — dist-linux/podium-linux-ba5d107.tar.gz
  (25MB, aarch64). Four real bugs found+fixed on the way (run log has
  details): missing Crypto dep on PodiumCore, Glibc getloadavg signature,
  CFGetTypeID absent on corelibs-foundation, and `swift build --product A
  --product B` silently building only the last product (script + §6 prompt
  both had this wrong). REMAINING to close ⚠️→✅: ONLY a first green Linux CI run (runs 28722982661 +
  28723047443 were in_progress at handover — check `gh run list`). The
  in-container smoke already proved the Linux binary boots + listens
  ("Server started and listening on 0.0.0.0:48111"); the HTTP probe step
  failed on a shell quirk, not the server — CI's Linux test job covers the
  rest. If CI is red instead: fix forward, the log will say exactly what. NOTE: the Linux docker build re-points
  the shared .build/release symlink to the Linux triple — package-macos.sh
  re-runs swift build itself so it self-heals, but don't be surprised by it.
- **P6.2a (contract E2E) — the @P session's lane (scheduled-pickup session,
  tag @P on the board).** Its WIP ContractTests.swift is untracked in the
  tree with 83 failing asserts (in-progress, expected). Coordinate via the
  board; don't dispatch P6.2 work yourself unless @P's lane is confirmed
  dead AND its board entry is reconciled per §0 step 2.
- **v1 close-out list (after P6.2a lands):** (1) final v1 QA sweep — empty/
  error states, light/dark pass on new views (tour, diagnostics, config
  editor); (2) README/MIGRATION docs (part of P6.2 scope); (3) create main
  branch + set default; (4) HUMAN items below.
- **HUMAN (Gaël) checklist — pending his eyes:**
  - Visual pass: onboarding tour light+dark (P5.5 couldn't launch — his app
    was running); live-transcript append click-through (P5.3).
  - `docker rm -f wizardly_golick` — stalled swift:6.1 build container from
    P6.1's first attempt (orchestrator not permitted to remove it).
  - His prod `podium` container reports UNHEALTHY since ~2026-07-04 (was
    healthy before; nobody here touched it — read-only observations only).
  - The supervised switchover: stop Docker → app hosts against a COPY of
    ~/.claude/podium/data/dashboard.db first → verify → real thing. DMG is
    ready at dist/Podium-1.0.dmg.
- **Open minor debts (documented, non-blocking):** PushNotifier Sendable
  closure warning (Swift-6 mode); cold-cache first import still CPU-bound
  seconds-per-hundred-files (async reimport endpoint = Routes change,
  revisit if real-corpus UX warrants); symlink-following gap in cc-config
  file API (EXACT Node parity — joint ticket both codebases); web push
  click-through fields are snake_case on the wire while future client JS
  may expect camelCase (no consumer yet).
- **Dependent-task notes live in the run log (§7):** camelCase run
  live-handle wire family vs snake_case history (P4.1); Hummingbird does NOT
  percent-decode path params (P3.3); JSONResponse(fields:) for intentionally
  camelCase top-level keys; PodiumJSON CodingKeys footgun; PodiumJSON.
  AnyEncodable dictionary-encode pattern for camelCase field names (gate
  fix); §6b №2 answer-from-popup needs a stdin control-response framing
  extension in RunSpawner.sendInput.
- **Standing corrections:** error responses are CodedErrorResponse
  {"error":{"code","message"}}; route responses must go through
  JSONResponse; never mix snake_case CodingKeys with .convertFromSnakeCase.
  Re-attach the fence/constraint blocks verbatim on any re-dispatch.
- **Environment quirks:** auto-commit hook commits the WHOLE dirty tree on
  any agent save — commit file-lists misattribute parallel work; real
  authorship = `git show <commit> -- <file>`. Agents habitually finish then
  go idle WITHOUT reporting — ping via SendMessage before assuming death.
  A USER INTERRUPT of the main conversation kills running background agents.
  /Applications/Podium.app (old install) can shadow the dev bundle.
  Session-limit errors can kill an Agent spawn with 0 tokens — re-dispatch.
  `ClaudeHome.current()` defaults to the REAL ~/.claude regardless of
  --data-dir — smoke tests need CLAUDE_HOME pointed at a fixture.
  NEVER touch: Gaël's ~/.claude/podium/data (live Docker bind-mount), his
  running PodiumApp process, his prod `podium` container.
