#!/bin/bash
# Builds podium-server + podium-hook for Linux and packages them into a
# tarball with the vendored web client + scripts/install-linux.sh.
#
# Portability note: this repo pins `swift-tools-version: 5.10` in
# Package.swift, but CI (.github/workflows/ci.yml) builds/tests the Linux
# products inside a `swift:6.1` container, and that is the combination
# verified working during P0.1 — the plan's older "swift:6.0" suggestion
# does NOT work (P0.1 run-log note). Use swift:6.1 for a reproducible build
# regardless of the host machine's own Swift toolchain.
#
# Usage:
#   scripts/build-linux.sh            # build inside docker (swift:6.1) if
#                                      # docker is available, else build with
#                                      # the host's own `swift` (must be Linux)
#   scripts/build-linux.sh --docker   # force the docker path
#   scripts/build-linux.sh --host     # force building with the host toolchain
#                                      # (fails fast if not running on Linux)
#
# Output:
#   dist-linux/podium-linux-<version>-<arch>.tar.gz
#     bin/podium-server
#     bin/podium-hook
#     share/podium/web/            (WebClient/dist)
#     install-linux.sh
#     podium-server.service        (systemd user unit, for reference/lint)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist-linux"
DOCKER_IMAGE="swift:6.1"

MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --docker) MODE="docker" ;;
    --host)   MODE="host" ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$MODE" = "auto" ]; then
  if command -v docker >/dev/null 2>&1; then
    MODE="docker"
  else
    MODE="host"
  fi
fi

cd "$SCRIPT_DIR"

# VERSION can be stamped from outside (release.yml passes the git tag, e.g.
# "1.2.3" derived from "v1.2.3") — falls back to the short commit SHA for
# local/dev runs, preserving the previous default behavior exactly.
VERSION="${VERSION:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"

if [ "$MODE" = "docker" ]; then
  command -v docker >/dev/null 2>&1 || { echo "✗ docker not found (use --host to build with the local toolchain instead)"; exit 1; }
  echo "▶ Building inside docker ($DOCKER_IMAGE)…"
  docker run --rm \
    -v "$SCRIPT_DIR:/src" \
    -w /src \
    "$DOCKER_IMAGE" \
    bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift build -c release --product podium-server && swift build -c release --product podium-hook"
    # NOTE: one `swift build` per product — passing --product twice silently
    # honors only the last flag and builds a single product.
else
  echo "▶ Building with the host Swift toolchain…"
  if [ "$(uname -s)" != "Linux" ]; then
    echo "✗ --host build must run on Linux (this machine is $(uname -s)). Use --docker (default when docker is available) instead."
    exit 1
  fi
  command -v swift >/dev/null 2>&1 || { echo "✗ swift not found on PATH"; exit 1; }
  swift build -c release --product podium-server
  swift build -c release --product podium-hook
fi

BUILD_DIR="$SCRIPT_DIR/.build/release"
[ -f "$BUILD_DIR/podium-server" ] || { echo "✗ podium-server binary not found at $BUILD_DIR/podium-server"; exit 1; }
[ -f "$BUILD_DIR/podium-hook" ] || { echo "✗ podium-hook binary not found at $BUILD_DIR/podium-hook"; exit 1; }

if [ ! -d "$SCRIPT_DIR/WebClient/dist" ]; then
  echo "✗ WebClient/dist not found — vendor the built web client first (see WebClient/SYNC.md)."
  exit 1
fi

echo "▶ Assembling tarball…"
ARCH="$(uname -m)"
PKG_NAME="podium-linux-$VERSION-$ARCH"
PKG_DIR="$DIST_DIR/$PKG_NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/share/podium"

cp "$BUILD_DIR/podium-server" "$PKG_DIR/bin/podium-server"
cp "$BUILD_DIR/podium-hook" "$PKG_DIR/bin/podium-hook"
chmod +x "$PKG_DIR/bin/podium-server" "$PKG_DIR/bin/podium-hook"
cp -R "$SCRIPT_DIR/WebClient/dist" "$PKG_DIR/share/podium/web"
cp "$SCRIPT_DIR/scripts/install-linux.sh" "$PKG_DIR/install-linux.sh"
chmod +x "$PKG_DIR/install-linux.sh"
cp "$SCRIPT_DIR/scripts/podium-server.service" "$PKG_DIR/podium-server.service"

TARBALL="$DIST_DIR/$PKG_NAME.tar.gz"
tar -C "$DIST_DIR" -czf "$TARBALL" "$PKG_NAME"
rm -rf "$PKG_DIR"

echo "✓ Tarball created: $TARBALL"
echo "  Install on the target machine with:"
echo "    tar xzf $(basename "$TARBALL") && cd $PKG_NAME && ./install-linux.sh"
