#!/bin/bash
# Builds podium-server (bun-compiled single-file binary, ROADMAP N5 TASK A)
# and stages it as a Tauri externalBin sidecar under src-tauri/bin/, named
# with the current Rust target triple as Tauri's sidecar convention requires
# (same naming convention the old Swift-built sidecar used — only the build
# tool changed). Also stages client/dist as a Tauri bundle resource
# (src-tauri/web-dist/) — server/index.js's static-file handler serves
# whatever DASHBOARD_WEB_DIST (--web-dist) points it at in production, and a
# Tauri .app bundle has no other way to locate the client build relative to
# the sidecar binary — see main.rs's resourcePath lookup.
#
# Node-era notes (see server/UPSTREAM.md "SQLite backend decision" +
# "CLI flags for the Tauri sidecar" for the full rationale):
#   - bun 1.3.x has NO node:sqlite, and better-sqlite3 has no working
#     prebuilt/native build on this toolchain, so bun:sqlite
#     (server/compat-bunsqlite.js) is the sqlite backend the compiled binary
#     actually uses at runtime.
#   - `--external better-sqlite3` is REQUIRED on `bun build --compile`: bun's
#     bundler resolves optionalDependencies against ITS OWN global module
#     cache (~/.bun/install/cache), independent of whether the package is
#     present in server/node_modules. If any previous `bun install`
#     anywhere on the machine ever cached better-sqlite3, `--compile` will
#     silently bundle its native-binding loader, which then crashes at
#     runtime inside the single-file binary (`Could not find module root...`
#     from the `bindings` package) because there's no real native .node file
#     to load. Marking it external makes require("better-sqlite3") a genuine
#     runtime MODULE_NOT_FOUND every time, so db.js's fallback chain
#     (better-sqlite3 -> bun:sqlite -> node:sqlite) engages as designed.
#   - `NODE_ENV=production` MUST be set in the environment bun runs in for
#     THIS build step, not just at runtime: bun's bundler statically inlines
#     `process.env.NODE_ENV` reads using the build-machine's env at bundle
#     time. Building with it unset bakes in `isProduction = false` forever
#     (the compiled binary then 404s on `/` — the API still works, but the
#     dashboard UI never loads), regardless of what's passed at run time.
#   - `BUN_NO_CODESIGN_MACHO_BINARY=1` is REQUIRED on every `bun build
#     --compile` here (HOOK-BUNDLE STAGING finding): bun 1.3.x's own Mach-O
#     ad-hoc self-signing step is buggy on some compiles (oven-sh/bun#29120,
#     truncated code signature) and produces a binary that
#     `codesign --force` (what Tauri's bundler runs on every externalBin at
#     package time, even with signingIdentity "-") rejects outright with
#     "main executable failed strict validation" — reproduced consistently
#     for hook/'s compile on this toolchain, entitlements make no
#     difference. This flag makes bun skip its own broken self-signing so
#     Tauri's codesign pass is the only one that ever touches the binary,
#     which then succeeds normally.
#
# Hook client: now built + staged here too (HOOK-BUNDLE STAGING). hook/ has
# its own bun-compile build (`cd hook && bun run build` -> hook/dist/
# podium-hook, per hook/package.json) — this script drives that build
# directly and stages the result as a SECOND Tauri externalBin, using the
# exact same target-triple naming convention as podium-server
# (podium-hook-<rust-triple>). Tauri strips the triple suffix when it copies
# externalBin entries into the bundle, so both binaries end up side by side
# in the final app (Contents/MacOS/ on macOS) as `podium-server` and
# `podium-hook`. That is exactly the layout server/scripts/install-hooks.js's
# third resolution tier expects: a `podium-hook` binary sitting next to
# `process.execPath` (the running podium-server sidecar) — see that file's
# `resolveHookBinary()` for the full PODIUM_HOOK_BIN env > repo hook/dist/
# podium-hook > next-to-execPath resolution order. In a packaged install
# (.dmg/.AppImage, no repo checkout alongside it) the first two tiers miss
# and this third tier is what makes hook installation succeed instead of
# skipping with a warning.
#
# Usage: tauri/prepare-sidecar.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUN_BIN="${BUN_BIN:-bun}"
if ! command -v "$BUN_BIN" >/dev/null 2>&1; then
  echo "bun not found on PATH (expected e.g. /opt/homebrew/bin/bun). Install it: https://bun.sh" >&2
  exit 1
fi

echo "Installing server/ dependencies..."
(cd "$REPO_ROOT/server" && "$BUN_BIN" install --production)

echo "Compiling podium-server (bun build --compile)..."
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

(
  cd "$REPO_ROOT/server"
  # PODIUM_APP_VERSION=... (T2.3 sidecar version-string fix): bun's bundler
  # inlines `process.env.PODIUM_APP_VERSION` reads at compile time, exactly
  # like NODE_ENV above — server/lib/update-check.js reads
  # `process.env.PODIUM_APP_VERSION || "dev"`, so whatever value is present
  # in THIS build step's environment gets baked into the compiled binary
  # forever, regardless of what's set at run time. Passing the (possibly
  # empty) shell var through explicitly means a real release build (which
  # exports PODIUM_APP_VERSION before calling this script) bakes in the real
  # version, while local/dev builds where it's unset still fall back to
  # "dev" as before.
  NODE_ENV=production BUN_NO_CODESIGN_MACHO_BINARY=1 PODIUM_APP_VERSION="${PODIUM_APP_VERSION:-}" "$BUN_BIN" build --compile --external better-sqlite3 \
    index.js --outfile "$BUILD_TMP/podium-server"
)

# rustc lives in ~/.cargo/bin, which may not be on PATH in non-login shells.
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

TRIPLE="$(rustc -vV | awk '/^host:/ { print $2 }')"
if [ -z "$TRIPLE" ]; then
  echo "Could not determine Rust host triple (is rustc on PATH?)" >&2
  exit 1
fi

DEST_DIR="$SCRIPT_DIR/src-tauri/bin"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/podium-server-$TRIPLE"

cp "$BUILD_TMP/podium-server" "$DEST"
chmod +x "$DEST"

# Ad-hoc sign the staged server sidecar (mirrors the hook signing below).
# Without this, macOS arm64 SIGKILLs the sidecar the instant Tauri spawns it
# (exit 137) because BUN_NO_CODESIGN_MACHO_BINARY=1 above left it with NO
# valid Mach-O code signature, and Tauri's own bundle-time codesign pass does
# NOT reliably re-sign nested externalBin sidecars — it's a signature-VALIDITY
# kill, not a quarantine issue, so removing quarantine does not help. The
# Tauri shell then hangs on its synchronous sidecar health-poll and the app
# bounces in the Dock forever. Signing the exact staged binary here fixes it.
if [ "$(uname)" = "Darwin" ]; then
  codesign -s - --force "$DEST"
fi

echo "Staged sidecar: $DEST ($(du -h "$DEST" | cut -f1))"

echo "Installing hook/ dependencies..."
(cd "$REPO_ROOT/hook" && "$BUN_BIN" install)

echo "Compiling podium-hook (bun run build)..."
(cd "$REPO_ROOT/hook" && BUN_NO_CODESIGN_MACHO_BINARY=1 "$BUN_BIN" run build)

# hook/dist/podium-hook is used DIRECTLY by install-hooks.js's second
# resolution tier (repo checkout → ~/.claude/settings.json points straight at
# it). Tauri's codesign pass only ever signs the staged sidecar copy below, so
# without an ad-hoc signature here the repo copy — unsigned because of
# BUN_NO_CODESIGN_MACHO_BINARY above — is SIGKILLed by macOS on every hook
# event (arm64 refuses unsigned/invalid Mach-O executables).
if [ "$(uname)" = "Darwin" ]; then
  codesign -s - --force "$REPO_ROOT/hook/dist/podium-hook"
fi

HOOK_DEST="$DEST_DIR/podium-hook-$TRIPLE"
cp "$REPO_ROOT/hook/dist/podium-hook" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

echo "Staged hook: $HOOK_DEST ($(du -h "$HOOK_DEST" | cut -f1))"

WEB_DIST_SRC="$REPO_ROOT/client/dist"
WEB_DIST_DEST="$SCRIPT_DIR/src-tauri/web-dist"
if [ -d "$WEB_DIST_SRC" ]; then
  rm -rf "$WEB_DIST_DEST"
  mkdir -p "$WEB_DIST_DEST"
  cp -R "$WEB_DIST_SRC/." "$WEB_DIST_DEST/"
  echo "Staged web dist: $WEB_DIST_DEST"
else
  echo "WARNING: $WEB_DIST_SRC not found — build it first:" >&2
  echo "  cd client && PODIUM_APP_VERSION=0.0.0-dev npm run build" >&2
  echo "The bundled app will 404 on '/' until then." >&2
fi
