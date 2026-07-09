#!/bin/bash
# Runs INSIDE the podium-tauri-linux-build image (see ./Dockerfile) with the
# repo root bind-mounted at /src. Produces the Linux .AppImage + .deb for the
# Podium Tauri shell, bundling a freshly-built Linux podium-server sidecar.
#
# Do not run this directly on the host — it assumes the container's toolchain
# (Swift 6.1, Rust, webkitgtk, tauri-cli). See tauri/linux-build/README.md
# (or the block comment atop ./Dockerfile) for the docker invocation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Dedicated scratch dir, NOT the host's own .build/. The host bind-mounts the
# repo root read-write, so if this build shared .build/ with a concurrent
# host-side `swift build`/`swift test`, the two toolchain runs interleave
# writes to the same SQLite-backed build database and can trip SQLite
# assertion crashes (B8). Keep the container's build products fully
# separate — see .gitignore for `.build-linux-tauri/`.
SCRATCH_DIR="$REPO_ROOT/.build-linux-tauri"

echo "▶ [1/4] Building podium-server (release) for Linux..."
swift build -c release --product podium-server --scratch-path "$SCRATCH_DIR"

BUILD_DIR="$SCRATCH_DIR/release"
[ -f "$BUILD_DIR/podium-server" ] || { echo "✗ podium-server binary not found at $BUILD_DIR/podium-server"; exit 1; }

echo "▶ [2/4] Staging sidecar under the Rust target-triple naming Tauri expects..."
TRIPLE="$(rustc -vV | awk '/^host:/ { print $2 }')"
[ -n "$TRIPLE" ] || { echo "✗ could not determine rustc host triple"; exit 1; }

DEST_DIR="$REPO_ROOT/tauri/src-tauri/bin"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/podium-server-$TRIPLE"
cp "$BUILD_DIR/podium-server" "$DEST"
chmod +x "$DEST"
echo "  Staged: $DEST ($TRIPLE)"

echo "▶ [3/4] Ensuring an icon set exists (cargo tauri build needs one)..."
cd "$REPO_ROOT/tauri"
if [ ! -f "src-tauri/icons/icon.png" ]; then
  if [ -f "src-tauri/icon-source.png" ]; then
    cargo tauri icon src-tauri/icon-source.png
  else
    echo "  ⚠ no icon-source.png and no existing icons/ — using whatever is bind-mounted from the host (macOS icons/ is checked out but git-ignored; if this is a clean checkout, generate icons first)."
  fi
fi

echo "▶ [4/4] Building the Tauri Linux bundle (.AppImage + .deb)..."
cargo tauri build --bundles appimage,deb

echo
echo "✓ Done. Artifacts:"
find "$REPO_ROOT/tauri/src-tauri/target/release/bundle" \( -name '*.AppImage' -o -name '*.deb' \) -exec ls -lh {} \;
