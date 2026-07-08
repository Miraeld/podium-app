# Pre-1.0.0 Audit — 2026-07-08

> Four-agent audit (dead code, API surface, robustness/security, product/UX),
> findings verified where marked ✓. Owner decisions marked 🟡.
> Work items ordered: A (must fix before tag) → B (should) → C (decide/skip).

## A — Fix before 1.0.0

- **A1 ✓ SECURITY: server binds 0.0.0.0, no auth.** Verified live (`lsof`: `*:4820`).
  Any LAN peer can read all session data AND `POST /api/run` (defaults
  `acceptEdits`) → RCE. Fix in flight: default `127.0.0.1`, `--host`/`PODIUM_HOST`
  opt-in with warning. (`PodiumServerApp.swift:55`, `PodiumServerLifecycle.swift:72,123`)
- **A2: sidebar GitHub link → `github.com/wp-media/maestro`** (internal codename
  repo) on every page (`Sidebar.tsx:452,482`). Every 1.0 user who clicks gets a
  404/private wall. Point at the public Podium repo or hide.
- **A3: Import-upload rejects the archives its own guide tells users to make.**
  Guide says `tar -czf claude-history.tar.gz …`; upload endpoint only accepts
  raw `.jsonl`/`.meta.json` → `NO_JSONL` error (`ImportRouter.swift:12-19,157-164`,
  `ImportHistory.tsx` ~155). Fix: server-side archive extraction OR remove
  archive extensions + fix guide copy. (Client-side fix is the cheap 1.0 answer.)
- **A4: remove dead SwiftUI scaffolding**: `project.yml`, `install.sh`,
  `Podium-Info.plist`, `PodiumApp.entitlements`, `PodiumWidget/` (3 files),
  root `AppIcon.icns` + `Assets.xcassets/`. All reference the deleted app;
  `install.sh` actively fails. Tauri has its own icon pipeline.
- **A5: `.gitignore` gaps**: add `.build-linux-tauri/`, `tauri/src-tauri/target*/`,
  `.DS_Store`. (One `git add -A` away from vendoring gigabytes.)
- **A6: `RELEASING.md` describes the wrong Linux artifact** (tarball vs the
  actual `.AppImage`/`.deb` CI ships). Also clarify `scripts/build-linux.sh`
  tarball = manual headless path, not the release.
- **A7: HookInstaller writes `~/.claude/settings.json` non-atomically, no backup**
  (`HookInstaller.swift:190-206`). Crash mid-write corrupts the user's GLOBAL
  Claude settings. Fix: atomic write + `.bak`. Small, high blast-radius.
- **A8: first-run guidance gap.** Fresh install (no DB, hooks not installed):
  empty states render but nothing says "install hooks to see data" — the only
  path is a buried Settings button. Minimum 1.0 fix: empty-state CTA on
  Dashboard/Sessions linking to hook install; tour should mention it.

## B — Should fix (small, worth it before tag)

- **B1: Tauri ignores the server's port-fallback** (+1…+20 on conflict) → if
  4820 is taken, shell polls a dead port, user sees a blank window with no
  message. Fix: read the actual port from the server-info file, or at least
  show an error page. (`main.rs` vs `PodiumServerLifecycle.swift:60`)
- **B2: Tauri trusts any 200 on `/api/health`** when "reusing" a server —
  verify a Podium marker (version field) before navigating.
- **B3: VAPID private key written without 0600 perms** (`VAPIDKeys.swift:80-87`).
  One-line fix.
- **B4: import progress theater**: client handles scan/extract/parse phases the
  server never sends — big rescan = spinner with zero feedback. 1.0-cheap fix:
  trim client copy to reality; real per-phase progress = post-1.0 (roadmap item).
- **B5: Workflows page has no top-level empty state** — zero-data renders 10
  stacked empty chart husks. One `EmptyState` guard.
- **B6: API surface trim before it becomes a compatibility promise.** Unused:
  `GET /agents/:id`, `POST /agents`, `GET /events/:id/full`, `GET /diagnostics`,
  `POST /settings/reimport` (dead api.ts wrapper too), `GET /export/session/:id`.
  Remove or add explicit keep-comments; adjust ContractTests accordingly.
  (Verify `POST /push/send` has a server-internal caller before touching.)
- **B7: HooksRouter error shape** is a third bespoke shape; Diagnostics/Search/
  Stats/Analytics/Updates routers don't use `CodedErrorResponse` on failure
  paths. Standardize or document the hooks deviation.
- **B8: `build-in-container.sh` shares the host `.build/`** → SQLite assertion
  crash (hit during the arm64 build). Add `--scratch-path`.

## C — Owner decisions 🟡 / deliberately post-1.0

- **C1 🟡 macOS notarization** ($99/yr Apple Developer ID) vs the xattr dance.
  Biggest install-time trust signal; Gaël's call.
- **C2 🟡 Drop the `wp-media/podium` half of the update check?** Standalone app
  releases from its own repo; the reference-repo check is plugin-era intent.
- **C3 🟡 Nav clutter**: Dashboard / Sessions / Activity / Search overlap for a
  new user. Product judgment, not a bug.
- **C4 🟡 "session shows error" label** (transient APIError → `error` status) —
  known, tested-parity debt, decided separately.
- **C5 post-1.0**: async reimport with real progress, T2.3 auto-updater,
  repo split / de-vendor, Windows, HookInstaller legacy-marker retirement.
- **C6: `Package.resolved` local diff** — verify intentional before tag.

## Needs the live browser pass (P6.2a, before tag)

Fresh-install walk (what does a no-data, no-hooks user actually see);
archive-upload repro (A3); long-rescan spinner timing (B4); Workflows page
with zero sessions (B5); both themes screenshot pass.
