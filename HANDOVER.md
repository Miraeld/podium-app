# Handover prompt — paste this into a fresh Claude session to continue

> Keep this file updated: the orchestrator refreshes the "Live state" section
> after every task completion. Last update: 2026-07-04 ~01:40 CEST (Fable 5,
> session 2, second limit approaching — written for a cold session-3 pickup).

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

- **Done (12/22):** P0.1, P1.1, P1.2, P2.1, P2.2, P2.3, P2.4, P3.1, P3.3, P3.4,
  P4.1, P5.2. Phase 2 E2E-gate passed. P3.3 green at e0aa2c0 (303/303 at that
  point; suite in flux while P3.2/P4.2 work).
- **main.swift is ORCHESTRATOR-OWNED:** Pricing+Settings mounts added by the
  orchestrator (build-verify pending — P3.2's WIP broke compilation at the
  time). Remaining wiring debt: ImportRouter + PushRouter mounts, the
  ReimportRunner→LegacyImporter adapter (protocol: run() async throws ->
  ReimportResult{imported,skipped,errors}; pass adapter as
  PodiumServerApp(reimportRunner:) — currently nil → 503), and P3.2's
  ServicesRunner activation if its report asks for a call-site change.
- **In flight right now (2 lanes).** If you're reading this cold they died with
  the session — reconcile each via §0 step 2 (partial work lands in
  `Auto-commit:` commits; `swift build && swift test`; complete → ✅, else
  re-dispatch §6 prompt + "audit your predecessor's partial work in your owned
  paths and continue". Known pattern: agents finish but go idle WITHOUT
  reporting — before re-dispatching, check whether the work is actually done):
  1. **P3.2 legacy import + sweeps** (resumed ~00:35 CEST, far along):
     LegacyImporter.swift + ImportRouter.swift + ServicesRunner.swift real
     services all committed (latest e12503d), LegacyImporterTests.swift being
     written (untracked at last check). Owns those + PodiumStore+Import.swift +
     Ingest/ (watchdog loops only). NO main.swift. Outstanding scope to verify
     against its §6 prompt: multipart /upload, .legacy-import.done marker,
     sweep broadcasts, token-0 import-path fix, scanAndImportSubagents +
     watchdog/stuck-agent loops (P2.3 deferrals).
  2. **P4.2 web-push** (~01:05 CEST): owns Sources/PodiumCore/Push/,
     Routes/PushRouter.swift, PodiumStore+Push.swift, HooksRouter.swift
     (Notifier seam injection — a HooksRouter auto-commit at 778e26d suggests
     that wiring already happened), new tests. NO main.swift.
     Must: keep Node vapid-keys.json format working (real file exists at
     ~/.claude/podium/data/vapid-keys.json — never touch it in tests), pass
     RFC 8291 §5 test vectors, NativeNotifier (macOS #if) + LinuxDesktopNotifier
     (notify-send) for §6b Linux parity.
- **After P3.2 + P4.2 + wiring: Phase-3 hardening gate** (working agreement
  #8): code review over the phases 2+3 diff (everything since 38b08ba) +
  contract sanity check against WebClient/dist's React client. THEN P4.3 ∥
  P4.4 (P4.4 can build on P3.3's Diagnostics/ServerRuntimeInfo.swift), then
  P5.1 → P5.3 → P5.4 → P5.5 (re-audit Sources/PodiumApp first — see §7 "Notes
  for future runs": the P5 prompts were written against a stale inventory),
  then P6.
- **Dependent-task notes live in the run log (§7):** P5.4 response models +
  camelCase-live/snake_case-history wire split (P4.1 entry); P5.3 drop-in
  transcript endpoints (P3.1); pattern-mining double-count parity quirk (P3.4);
  Hummingbird does NOT percent-decode path params (P3.3 — check any router
  with encodable path params); §6b №2 answer-from-popup needs a stdin
  control-response framing extension in RunSpawner.sendInput (P4.1).
- **Standing corrections:** error responses are CodedErrorResponse
  {"error":{"code","message"}} — some §6 prompts still show the flat shape;
  route responses must go through JSONResponse; never mix snake_case
  CodingKeys with .convertFromSnakeCase (PodiumJSON.swift footgun). These
  constraint blocks must be re-attached verbatim on any re-dispatch.
- **Test count:** 303/303 at P3.3's close (e0aa2c0); expect ~340+ once
  P3.2/P4.2 land. Suite may transiently fail to COMPILE while agents are
  mid-edit — judge per-lane, not per-tree.
- **Environment quirks:** repo has an auto-commit hook that commits the WHOLE
  dirty tree on any agent save — commit file-lists misattribute parallel work;
  real authorship = `git show <commit> -- <file>`. Agents habitually finish
  then go idle WITHOUT sending their report — ping them via SendMessage before
  assuming death or re-dispatching. /Applications/Podium.app (old install) can
  shadow the dev bundle when UI-testing — check `ps` first. Session-limit
  errors can kill an Agent spawn with 0 tokens used — just re-dispatch. The
  user's live plugin data (Docker `podium` container, port 4820) bind-mounts
  ~/.claude/podium/data/dashboard.db + vapid-keys.json — NEVER point tests at
  it; the Swift server is schema-compatible and will take over that DB at
  switchover (planned after P5.1).
