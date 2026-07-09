# Pre-1.0.0 Audit — 2026-07-08

> Four-agent audit (dead code, API surface, robustness/security, product/UX),
> findings verified where marked ✓. Owner decisions marked 🟡.
> Work items ordered: A (must fix before tag) → B (should) → C (decide/skip).

## A — Fix before 1.0.0

- **A1 ✅ DONE (`e8b57f4`) SECURITY: server bound 0.0.0.0, no auth.** Was verified
  live. Now: default `127.0.0.1`; `--host` flag > `PODIUM_HOST` env > default,
  stderr warning on non-loopback; `podium-server.service` opts into 0.0.0.0
  explicitly (headless LAN use). 471/471 tests.
- **A2 ✅ DONE (client `0f2a507`, tauri `1b97246`): sidebar GitHub link.** Now
  points at the public `github.com/Miraeld/podium-app` (verified live origin).
  Tauri half: window creation moved to Rust (`create_main_window()`), external
  http(s) links open in the system browser via `tauri-plugin-opener`.
- **A3 ✅ DONE (client `0f2a507`): import guide vs upload mismatch.** Client-side
  fix: guide copy now says upload `.jsonl`/`.meta.json` directly (no tar step);
  archive extensions removed from accept list + file filter. en/vi/zh mirrored.
- **A4 ✅ DONE (`1322f7a`): dead SwiftUI scaffolding removed** (`project.yml`,
  `install.sh`, `Podium-Info.plist`, entitlements, `PodiumWidget/`, root icons).
  References grepped first — all self-referential.
- **A5 ✅ DONE (`32750a2`): `.gitignore`** now covers `.build-linux-tauri/`,
  `tauri/src-tauri/target*/`, `.DS_Store` (none were tracked).
- **A6 ✅ DONE (`32750a2`): `RELEASING.md`** now describes the real CI artifacts
  (`.dmg` + `.AppImage`/`.deb` via Tauri); tarball documented as the manual
  headless-server path.
- **A7 ✅ DONE (`1322f7a` + tests in `ee00f03`): HookInstaller** writes
  `settings.json` via temp-file + atomic replace, with a `settings.json.bak`
  of the previous content. Covered by `HookInstallerTests`.
- **A8 ✅ DONE (client `0f2a507`): first-run guidance.** Dashboard/Sessions
  zero-data states now show "install the Claude Code hooks" CTA linking to
  `/settings#hooks` (anchor added). Tour untouched (in-flight WIP file).

## B — Should fix (small, worth it before tag)

- **B1 ✅ DONE (`1b97246`): Tauri port-fallback.** Shell discovers the actual
  port from the server-info file (pid-matched), falls back to a health-poll
  sweep of +1…+20; unresolvable → inline error page instead of blank window.
- **B2 ✅ DONE (`1b97246`): health-check trust.** Reuse requires the exact
  podium-server health shape, not any 200. Post-1.0 hardening idea: add an
  `"app":"podium"` marker field to `/api/health` for a real fingerprint.
- **B3 ✅ DONE (in `1322f7a`, tests `ee00f03`): VAPID key** created 0600;
  looser pre-existing files tightened on load.
- **B4 ✅ DONE (client `0f2a507`): import progress copy** trimmed to the real
  server phases (`complete`/`error` only) + honest "can take a few minutes"
  message. Real per-phase progress remains post-1.0 (roadmap).
- **B5 ✅ DONE (client `0f2a507`): Workflows** zero-data now renders one
  `EmptyState` (with hooks CTA) instead of empty chart husks.
- **B6 ✅ DONE (routers `2913673`…`23a757b`, tests `ee00f03`): API trim.**
  Removed: `GET /agents/:id`, `POST /agents`, `GET /events/:id/full`,
  `GET /diagnostics` (zero usage, verified in client src + shipped bundle).
  KEPT (audit flags were stale): `GET /export/session/:id` — live caller in
  `SessionDetail.tsx:313`; `POST /settings/reimport` — api.ts wrapper still
  references it (dead wrapper cleanup = client follow-up). `POST /push/send`
  untouched — live callers (web client ×2 + internal PushNotifier).
- **B7 ✅ DONE (`1ebad1a` + `ee00f03`): error envelope.** New
  `APIErrorEnvelopeMiddleware` renders every `/api/*` error as
  `CodedErrorResponse`; HooksRouter converted (wire-identical; podium-hook is
  fire-and-forget). Note: `DiagnosticsRouterTests.swift` (CI-gated set in
  CLAUDE.md) deleted because its endpoint was removed — not a CI dodge.
- **B8 ✅ DONE (`32750a2`): `build-in-container.sh`** uses
  `--scratch-path .build-linux-tauri` — no more shared host `.build/`.

> Post-A/B state: `swift test` 462/462 green, `contract-check.sh` 30/30,
> `cargo check`/`clippy` clean, client `npm run build` clean, dist synced.

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
