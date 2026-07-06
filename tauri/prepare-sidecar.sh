#!/bin/bash
# Builds podium-server (release) and stages it as a Tauri externalBin
# sidecar under src-tauri/bin/, named with the current Rust target triple
# as Tauri's sidecar convention requires. Also stages WebClient/dist as a
# Tauri bundle resource (src-tauri/web-dist/) — podium-server's static file
# resolver (Sources/PodiumServer/Static/StaticFileHandler.swift) only knows
# how to find the web assets via $PODIUM_WEB_DIST, /usr/local/share/podium/web,
# or Bundle.main.resourceURL/WebClient/dist (the OLD SwiftUI .app layout).
# None of those exist inside a Tauri .app bundle, so main.rs passes
# `--web-dist <resources dir>/web-dist` explicitly when it spawns the
# sidecar — see the resourcePath lookup there.
#
# Usage: tauri/prepare-sidecar.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Building podium-server (release)..."
(cd "$REPO_ROOT" && swift build -c release --product podium-server)

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

cp "$REPO_ROOT/.build/release/podium-server" "$DEST"
chmod +x "$DEST"

echo "Staged sidecar: $DEST"

WEB_DIST_SRC="$REPO_ROOT/WebClient/dist"
WEB_DIST_DEST="$SCRIPT_DIR/src-tauri/web-dist"
if [ -d "$WEB_DIST_SRC" ]; then
  rm -rf "$WEB_DIST_DEST"
  mkdir -p "$WEB_DIST_DEST"
  cp -R "$WEB_DIST_SRC/." "$WEB_DIST_DEST/"
  echo "Staged web dist: $WEB_DIST_DEST"
else
  echo "WARNING: $WEB_DIST_SRC not found — the bundled app will 404 on '/'." >&2
fi
