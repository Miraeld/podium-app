#!/bin/bash
# Dev launcher for the Tauri shell: builds the podium-server sidecar and
# runs the Tauri app in dev mode against your real DB.
# Usage: ./run.sh
#
# See tauri/README.md for the full lifecycle (sidecar spawn/reuse, health
# poll, cleanup) and prerequisites (Rust toolchain + Tauri CLI v2).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR/tauri"
./prepare-sidecar.sh
cargo tauri dev
