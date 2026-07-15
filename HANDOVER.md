# HANDOVER — Podium

> Cold-start briefing for the next session. Last sealed: 2026-07-15 (Fable 5
> orchestrator, session C). Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp,
> branch `develop` @ `fc5b51f` (pushed). Remote github.com/Miraeld/podium-app.
> ROADMAP.md is the task board — its STATUS block is law; this file is the
> session-context layer on top. **Claim-before-dispatch rule applies.**

## State (verified at seal time, 2026-07-15 ~09:15 CEST)

- `develop` @ `fc5b51f`, pushed, clean tree. No agents running.
- `cd server && npm test` = **568/568 green** (run at seal, includes the
  31-test wire-contract gate).
- **CI run 29396507923 was IN PROGRESS at seal** — the first Node-era CI
  proof. The previous run (29395525806) failed on 2 known causes; fix
  pushed as `66e4dba`. **First action next session: check this run.**
  If red, suspects: (a) zero-byte externalBin placeholders not satisfying
  tauri build.rs, (b) hook build path resolution on the runner.

## Done this session (all on develop, all orchestrator-verified)

- **Hook staged in Tauri bundle** (`c3c4d9d`): prepare-sidecar.sh builds
  podium-hook as a second externalBin; packaged .dmg installs now get
  working hooks (install-hooks.js tier-3 next-to-execPath resolution,
  proven via real debug bundle + scratch-HOME boot). Hard blocker fixed:
  bun 1.3.14 Mach-O self-signing is broken (oven-sh/bun#29120) —
  `BUN_NO_CODESIGN_MACHO_BINARY=1` now on both compiles.
- **install-hooks dedup fix** (`9d370b9`): upgrade replaced only the FIRST
  legacy match per event; duplicates survived and kept throwing
  MODULE_NOT_FOUND. Now removes all extra matches + reports count. Also
  closed a coverage gap: PostToolUseFailure/SubagentStart joined HOOK_TYPES
  (hook binary already forwarded them; installer never wired them).
- **Owner's real ~/.claude/settings.json healed** (he ran install-hooks
  manually; 8 entries updated). **One rerun still owed** — see Next up.
- **ci.yml fix adopted + pushed** (`66e4dba`): builds hook binary before
  server tests; placeholder sidecars + web-dist for cargo check. Authored
  by the parallel orchestrator session which died at its usage limit
  mid-validation; session C validated (YAML + triple snippet) and landed it.

## In flight

- **CI green proof** — run 29396507923, in progress at seal. Check → if
  green, mark N6 fully proven in ROADMAP STATUS; if red, read the job logs
  and fix (suspects above), it's unclaimed.

## Next up (priority order)

1. Check the CI run (above).
2. **Ask Gaël to rerun** `node server/scripts/install-hooks.js` in a plain
   terminal (post-dedup-fix) — strips the last 6 dead entries from his
   settings.json. Permission classifier blocks Claude from doing it (own
   hook config); he must run it himself.
3. **N7 — Swift funeral** (ROADMAP has the full prompt): preconditions all
   met once CI is green. Needs Gaël present. Delete Sources/, Tests/,
   Package.swift, WebClient/; rewrite CLAUDE.md + README for Node era.
   Repo rename PodiumSwiftApp→podium-app is Gaël's manual step after.
4. **N8 — QA + 1.0.0 tag** (ROADMAP has the checklist + QA prompt).

## Gotchas (carry-forward pruned to Node-era-valid)

- **Claim-before-dispatch**: claim tasks in ROADMAP STATUS + commit BEFORE
  dispatching an agent. N4 was built twice in parallel for skipping this.
- **Frozen repo**: never git-touch /Users/gaelrobin/Desktop/Work/Claude/podium.
- **Auto-commit hook** fires on saves — ignore its commits, never
  amend/rebase. It also causes transient .git/index.lock contention when
  agents run in parallel (hit twice this session; retry, don't force —
  only remove an index.lock after `ps` proves nothing holds it).
- **Server boots auto-install hooks keyed off $HOME** — any test/scratch
  boot MUST override HOME or it rewrites the real ~/.claude/settings.json.
- **bun footguns** (all baked into prepare-sidecar.sh now, don't undo):
  `--external better-sqlite3` (stale global-cache bundling), NODE_ENV set
  at COMPILE time (env reads are inlined), BUN_NO_CODESIGN_MACHO_BINARY=1
  (broken self-sign). bun --compile bakes the build machine's __dirname
  into the binary — "no repo checkout" simulations false-pass unless you
  hide hook/dist first.
- **P8**: client builds fail without PODIUM_APP_VERSION — by design, never
  loosen. **P1**: loopback bind default is a security invariant.
- **Commit style**: plain messages, NO Co-Authored-By trailers (Gaël).
  Don't commit Package.resolved or *.bun-build artifacts.
- **Contract gate** is now `server/tests/contract/contract.test.js`
  (node:test, in `npm test`) — keep green after any server change.
- **macOS release**: ad-hoc signed, no notarization — first launch needs
  xattr dance (documented in RELEASING.md). Linux CI artifacts are x86_64.
- **NEVER touch**: ~/.claude/podium/data, Gaël's running app.

## Open decisions for Gaël (unchanged)

- "Session shows error" label debt (C4) — not a 1.0 blocker.
- Upstream EXTRAS (alerts, MCP): keep-behind-flags default; final call at N8.
