# Handover prompt — paste this into a fresh Claude session to continue

> Keep this file updated: the orchestrator refreshes the "Live state" section
> after every task completion. Last update: 2026-07-04 ~00:40 CEST (Fable 5,
> session 2 resumed after the 23:10 limit reset; all 3 lanes reconciled and
> re-dispatched — see run log "🟦 reconcile #2" for what each lane resumes from).

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
- **In flight right now (3 lanes, all dispatched by session 2).** If you're
  reading this cold they died with the session — reconcile each via §0 step 2
  (partial work lands in `Auto-commit:` commits; `swift build && swift test`;
  complete → ✅, else re-dispatch §6 prompt + "audit your predecessor's partial
  work in your owned paths and continue"):
  1. **P4.2 web-push** (~01:05 CEST 2026-07-04): owns Sources/PodiumCore/Push/,
     Routes/PushRouter.swift, PodiumStore+Push.swift, HooksRouter.swift
     (Notifier seam injection), new tests. NO main.swift (reports mount line).
     Must: keep Node vapid-keys.json format working (real file exists at
     ~/.claude/podium/data/vapid-keys.json), pass RFC 8291 §5 test vectors,
     NativeNotifier (macOS #if) + LinuxDesktopNotifier (notify-send) for §6b
     Linux parity.
  2. **P3.3 pricing/settings** (~00:35 CEST, resumed): owns Sources/PodiumCore/Pricing/,
     Routes/PricingRouter.swift, Routes/SettingsRouter.swift,
     Database/PodiumStore+Pricing.swift, new tests. NO main.swift. POST
     /reimport implemented against a ReimportRunner seam (503 default) — NOT
     calling P3.2's importer directly.
  3. **P3.2 legacy import + sweeps** (~22:10 CEST): owns
     Discovery/LegacyImporter.swift (+ siblings, NOT ClaudeHome.swift),
     Routes/ImportRouter.swift, Services/ServicesRunner.swift (replace
     placeholder legacy-import + sweep services), Database/PodiumStore+Import.swift,
     Ingest/ only for the deferred watchdog/stuck-agent loops, new tests.
     NO main.swift. Must close the token-0 gap for legacy-imported sessions
     (hook-path half already closed by P3.1).
- **Wiring debt owed by the orchestrator (do this even if all three finish
  cleanly):** (a) add PricingRouter/SettingsRouter/ImportRouter mount lines to
  PodiumServerCLI/main.swift `mounts:` (P3.3/P3.2 end their reports with the
  exact lines) once P4.1 has freed the file; (b) wire P3.3's ReimportRunner
  seam to P3.2's LegacyImporter (importAllSessions with force flag) and drop
  the 503 default; (c) activate P3.2's real BackgroundServices in main.swift
  if its report says the ServicesRunner swap needs a call-site change.
- **After those + wiring: Phase-3 hardening gate** (working agreement #8):
  code review over the phases 2+3 diff (everything since 38b08ba) + contract
  sanity check against WebClient/dist's React client. THEN P4.2 (HooksRouter
  Notifier wiring — file is free now that P3.1 is done) ∥ P4.3 ∥ P4.4, then
  P5.1 → P5.3 → P5.4 → P5.5 (re-audit Sources/PodiumApp first — see §7 "Notes
  for future runs": the P5 prompts were written against a stale inventory),
  then P6.
- **Session-2 additions worth knowing:** run-log entries for P3.1/P3.4 hold
  the dependent-task notes (P5.4 response models; P5.3 drop-in endpoints;
  pattern-mining double-count quirk preserved for parity). P3.3/P3.2/P4.1
  prompts in §6 are still authoritative, but the constraint blocks above
  (fences, seams, CodedErrorResponse, JSONResponse, PodiumJSON footgun) must
  be re-attached on any re-dispatch.
- **Standing correction:** error responses are CodedErrorResponse
  {"error":{"code","message"}} — some §6 prompts still show the flat shape;
  the run log (P2.2 entry) is authoritative.
- **Test count at handover:** 171/171 green (`swift test`).
- **Environment quirks:** repo has an auto-commit hook (partial agent work
  lands in `Auto-commit:` commits); /Applications/Podium.app (old install) can
  shadow the dev bundle when UI-testing — check `ps` first; session-limit
  errors can kill an Agent spawn with 0 tokens used — just re-dispatch.
