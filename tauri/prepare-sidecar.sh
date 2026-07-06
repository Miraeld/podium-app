#!/bin/bash
# Builds podium-server (release) and stages it as a Tauri externalBin
# sidecar under src-tauri/bin/, named with the current Rust target triple
# as Tauri's sidecar convention requires.
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
