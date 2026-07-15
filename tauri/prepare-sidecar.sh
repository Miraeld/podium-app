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
#
# Hook client: NOT built here. hook/ has its own bun-compile build
# (`cd hook && bun run build` -> hook/dist/podium-hook, per package.json) —
# it's a standalone artifact, not a Tauri externalBin, since hooks are
# installed by podium-server itself at runtime (server/scripts/install-hooks.js,
# invoked from server/index.js on every boot) rather than staged into the
# app bundle. The old Swift-era version of this script never built a hook
# binary either (same runtime-install design), so this preserves the
# existing convention rather than introducing a new one.
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
  NODE_ENV=production "$BUN_BIN" build --compile --external better-sqlite3 \
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

echo "Staged sidecar: $DEST ($(du -h "$DEST" | cut -f1))"

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
