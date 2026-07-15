#!/bin/bash
# Builds a headless podium-server for Linux and packages it into a tarball
# with the vendored web client + scripts/install-linux.sh.
#
# Node-era approach (N6): the headless Linux path uses the SAME bun-compiled
# single-file binary as the Tauri sidecar (tauri/prepare-sidecar.sh), not
# `node` + `npm ci` on the target host. Rationale: the bun-compiled binary
# needs no Node/npm/node_modules on the target machine at all (just glibc),
# matches the sidecar build path exactly (one build recipe, not two), and
# sidesteps the native-module footguns documented in
# tauri/prepare-sidecar.sh's header (bun's bundler resolving
# optionalDependencies from ITS OWN global cache, NODE_ENV=production having
# to be set at BUILD time). See tauri/prepare-sidecar.sh and
# server/UPSTREAM.md "SQLite backend decision" for the full rationale — the
# runtime sqlite backend is bun:sqlite (server/compat-bunsqlite.js), not
# better-sqlite3 or node:sqlite.
#
# Portability note: this repo's docker path builds inside `oven/bun:1` so the
# compiled binary's glibc/libc baseline matches a container, not whatever
# glibc happens to be on the dev machine — the same "build inside a
# container for a reproducible target" rationale the old Swift-era
# `swift:6.1` container path used.
#
# Usage:
#   scripts/build-linux.sh            # build inside docker (oven/bun:1) if
#                                      # docker is available, else build with
#                                      # the host's own `bun` (must be Linux)
#   scripts/build-linux.sh --docker   # force the docker path
#   scripts/build-linux.sh --host     # force building with the host toolchain
#                                      # (fails fast if not running on Linux)
#
# Also bun-compiles hook/ (a standalone artifact, per hook/package.json's own
# `build` script — NOT staged by tauri/prepare-sidecar.sh, since Tauri-shell
# installs are handled by the server calling install-hooks.js at runtime; a
# headless install has no app bundle to ship it alongside, so this script
# stages it into the tarball instead, matching the old Swift-era tarball's
# `bin/podium-hook` layout).
#
# Output:
#   dist-linux/podium-linux-<version>-<arch>.tar.gz
#     bin/podium-server            (bun-compiled single-file binary)
#     bin/podium-hook              (bun-compiled single-file binary)
#     share/podium/web/            (client/dist)
#     install-linux.sh
#     podium-server.service        (systemd user unit, for reference/lint)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist-linux"
DOCKER_IMAGE="oven/bun:1"

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

BUILD_CMD='
set -euo pipefail
cd /src/server && bun install --production && NODE_ENV=production bun build --compile --external better-sqlite3 index.js --outfile /src/.build-linux-out/podium-server
cd /src/hook && bun install --production && bun build --compile --outfile /src/.build-linux-out/podium-hook src/index.ts
'

if [ "$MODE" = "docker" ]; then
  command -v docker >/dev/null 2>&1 || { echo "✗ docker not found (use --host to build with the local toolchain instead)"; exit 1; }
  echo "▶ Building inside docker ($DOCKER_IMAGE)…"
  rm -rf "$SCRIPT_DIR/.build-linux-out"
  mkdir -p "$SCRIPT_DIR/.build-linux-out"
  docker run --rm \
    -v "$SCRIPT_DIR:/src" \
    -w /src \
    "$DOCKER_IMAGE" \
    bash -c "$BUILD_CMD"
else
  echo "▶ Building with the host bun toolchain…"
  if [ "$(uname -s)" != "Linux" ]; then
    echo "✗ --host build must run on Linux (this machine is $(uname -s)). Use --docker (default when docker is available) instead."
    exit 1
  fi
  command -v bun >/dev/null 2>&1 || { echo "✗ bun not found on PATH — install it: https://bun.sh"; exit 1; }
  rm -rf "$SCRIPT_DIR/.build-linux-out"
  mkdir -p "$SCRIPT_DIR/.build-linux-out"
  (cd server && bun install --production)
  (cd server && NODE_ENV=production bun build --compile --external better-sqlite3 index.js --outfile "$SCRIPT_DIR/.build-linux-out/podium-server")
  (cd hook && bun install --production)
  (cd hook && bun build --compile --outfile "$SCRIPT_DIR/.build-linux-out/podium-hook" src/index.ts)
fi

BUILD_OUT="$SCRIPT_DIR/.build-linux-out"
[ -f "$BUILD_OUT/podium-server" ] || { echo "✗ podium-server binary not found at $BUILD_OUT/podium-server"; exit 1; }
[ -f "$BUILD_OUT/podium-hook" ] || { echo "✗ podium-hook binary not found at $BUILD_OUT/podium-hook"; exit 1; }

if [ ! -d "$SCRIPT_DIR/client/dist" ]; then
  echo "✗ client/dist not found — build the web client first:"
  echo "  cd client && PODIUM_APP_VERSION=$VERSION npm run build"
  exit 1
fi

echo "▶ Assembling tarball…"
ARCH="$(uname -m)"
PKG_NAME="podium-linux-$VERSION-$ARCH"
PKG_DIR="$DIST_DIR/$PKG_NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/share/podium"

cp "$BUILD_OUT/podium-server" "$PKG_DIR/bin/podium-server"
cp "$BUILD_OUT/podium-hook" "$PKG_DIR/bin/podium-hook"
chmod +x "$PKG_DIR/bin/podium-server" "$PKG_DIR/bin/podium-hook"
rm -rf "$BUILD_OUT"
cp -R "$SCRIPT_DIR/client/dist" "$PKG_DIR/share/podium/web"
cp "$SCRIPT_DIR/scripts/install-linux.sh" "$PKG_DIR/install-linux.sh"
chmod +x "$PKG_DIR/install-linux.sh"
cp "$SCRIPT_DIR/scripts/podium-server.service" "$PKG_DIR/podium-server.service"

TARBALL="$DIST_DIR/$PKG_NAME.tar.gz"
tar -C "$DIST_DIR" -czf "$TARBALL" "$PKG_NAME"
rm -rf "$PKG_DIR"

echo "✓ Tarball created: $TARBALL"
echo "  Install on the target machine with:"
echo "    tar xzf $(basename "$TARBALL") && cd $PKG_NAME && ./install-linux.sh"
