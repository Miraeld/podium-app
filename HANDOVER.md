# HANDOVER — Podium

> Cold-start briefing for the next session. Last sealed: 2026-07-07 (Opus 4.8,
> interactive). Repo: /Users/gaelrobin/Desktop/PodiumSwiftApp, branch
> `develop` @ `3aa1751` (pushed). Remote github.com/Miraeld/podium-app
> (public, CI live). **Gaël is token-constrained — be economical.**

## Paste-ready cold-start prompt

```
You're taking over Podium (/Users/gaelrobin/Desktop/PodiumSwiftApp, branch
develop). Read HANDOVER.md then ROADMAP.md. The Tauri consolidation is
DONE and shipping: Podium is now ONE native app (macOS .dmg + Linux
.AppImage/.deb) that bundles the Swift podium-server as a sidecar and shows
the web dashboard. SwiftUI app is deleted. The release pipeline works (v0.5.3
draft release has all 3 installers). What's left before tagging 1.0.0 is
mostly LINUX GUI QA on a real Linux box. Don't re-do "Done" items; verify
build/tests before continuing. Same rules (global + project CLAUDE.md, ROADMAP
§7 fence block).
```

## State (verify before trusting)

- **`develop` @ `3aa1751`, pushed.** `swift build` clean, `swift test` = 465/465,
  ContractTests 29/29 (SwiftUI target removed — see below).
- **Release pipeline WORKS.** Tag `v*` → `.github/workflows/release.yml` builds
  the Tauri app on macOS + Linux and publishes a **draft** GitHub release with
  `.dmg` + `.AppImage` + `.deb`. Validated on **v0.5.3** (draft release live,
  all 3 assets attached: aarch64 .dmg 11MB, amd64 .AppImage 123MB, amd64 .deb
  24MB). First run caught+fixed a real bug (nested-artifact glob).
- **Single worktree, clean tree.** No agents running.

## What Podium IS now (internalize)

Native Tauri app on mac+linux wrapping the React web dashboard, with
`podium-server` bundled as a sidecar. **Closing the window keeps the server
running in the tray** (it must keep observing) — quit only from the tray/⌘Q.
The Swift server + web client are unchanged and authoritative.

## Done this session (all merged on develop)

- **T1.1–T1.4**: Tauri sidecar shell, macOS `.dmg` + vibrancy, Linux
  `.AppImage`/`.deb` (Docker), tray + notifications.
- **Close-to-tray** (`b658dd6`): the fix for "my live session shows as
  error/abandoned" — root cause was the sidecar dying on window close so hooks
  hit no server. NOT a hook conflict (ruled out). See [[ingestion-architecture]].
- **T2.1** update popup + Settings Updates panel (browser-verified).
- **T2.2** onboarding tour (driver.js, re-runnable from Settings). Fixed a real
  launch bug (onDestroyed marked "seen" on teardown → tour never showed).
- **Branding**: sidebar subtitle → "Gael R", version → real app version
  (0.5.x via `PODIUM_APP_VERSION` build stamp, was stale plugin 1.4.0),
  wp-media.me link hidden (`SHOW_WEBSITE_LINK=false`).
- **T3.1** release pipeline (Tauri installers on tag). **T3.2** SwiftUI
  `PodiumApp` target + `Sources/PodiumApp/` DELETED (run.sh → Tauri dev,
  package-macos.sh gutted). **T3.3** README/MIGRATION/CLAUDE.md rewritten for
  Tauri. **T3.4 macOS QA GREEN** (launch→live data→render→all 9 pages, zero
  console errors→close-to-tray→clean quit).

## Next up — the road to 1.0.0

1. **LINUX GUI QA (THE gate).** Can't be done on the Mac. Download the v0.5.3
   `.AppImage` (or `.deb`) from the draft release onto a real Linux desktop/VM:
   `chmod +x` + run → confirm the window opens, dashboard loads, a notification
   fires, and no orphaned `podium-server` after quit. This is the last thing
   between us and tagging.
2. **Tag v1.0.0** once Linux QA is green: bump `tauri/src-tauri/tauri.conf.json`
   version to `1.0.0`; ideally rebuild the vendored dist with
   `PODIUM_APP_VERSION=1.0.0` so the sidebar shows it (two-repo flow, see
   Gotchas); commit; `git tag -a v1.0.0`; push tag → draft release → **publish
   the draft** on GitHub. That's the finish line.
3. **T2.3 (Tauri built-in auto-updater) = POST-1.0 (1.0.1).** Gaël confirmed not
   mandatory for 1.0. T2.1's notify+open-release-page is a sufficient v1 update
   story. Pipeline already has `TODO(T2.3)` slots for the EdDSA signing key +
   `latest.json` manifest.

## Open decisions for Gaël (don't act without his call)

- **The "session shows error" label**: a transient APIError flips a session to
  `error` status (by design, ported from Node hooks.js, 3 tests lock it in;
  recovers on next live PreToolUse). Close-to-tray fixed the "not tracked"
  part, but a long/overloaded session still *reads* "error". Leave as debt, or
  change the classification (diverges from tested parity + needs 3 test
  updates)? He's deciding separately; not a 1.0 blocker.
- **De-vendor / repo-split**: Gaël wants (post-1.0) to split server and
  front-end into separate repos so the front-end can be reused by the Claude
  plugin. Related near-term choice: de-vendor the React source INTO this repo
  vs keep the two-repo `cp -R` flow. Spec it when prioritized; the
  ContractTests + types.ts↔PodiumJSON wire format is the natural contract seam.

## Gotchas (carry forward)

- **Two-repo web workflow**: the React source is NOT here — it's at
  `/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client` (separate git
  repo). Edit source there → `PODIUM_APP_VERSION=<v> npm run build` → re-vendor
  `WebClient/dist` per `WebClient/SYNC.md`. **That repo currently has
  UNCOMMITTED source changes** (T2.1 popup + branding + T2.2 tour + the tour
  fix) — Gaël wants to review before committing; **DO NOT commit/stash/reset
  there.** The next dist rebuild will include them (fine).
- **Verifying web UI**: the `Claude_Preview` MCP works from the main repo
  (used it to browser-verify popup/tour/branding). It resolves
  `.claude/launch.json` from the main repo root, so worktree agents can't use
  it — verify UI yourself from the main checkout. Chrome MCP was unreachable
  all session.
- **Worktree agents branch from a STALE base** (`df96ea3`, pre-most-of-this-
  work). Their re-vendored dist / deletions are still correct — but MERGE their
  output surgically (copy the dist / apply the specific file changes), don't do
  a full `git merge` from the stale base. Verify build+tests after.
- **Auto-commit hook** commits the dirty tree on any save (often splits your
  work into an extra "Auto-commit:" commit) — ignore it, never
  amend/rebase around it; real authorship via `git show <sha> -- <file>`.
- **Release**: `permissions: contents: write` is set; publish job uses `find`
  to collect nested artifacts; macOS is ad-hoc signed (no notarization — first
  launch needs `xattr -dr com.apple.quarantine` / right-click-Open). Linux CI
  artifacts are **x86_64** (runners), vs the aarch64 local Docker build.
- **ContractTests** is the wire gate — keep green after any server change
  (`swift test --filter ContractTests`). snake_case via PodiumJSON; camelCase
  exceptions via the AnyEncodable dict pattern; errors are CodedErrorResponse;
  never mix snake_case CodingKeys with .convertFromSnakeCase. `/usr/bin/true`
  not `/bin/true`.
- **NEVER touch**: `~/.claude/podium/data` (old Docker DB backup), Gaël's
  running app, `WebClient/dist` except via the reference-repo rebuild.
