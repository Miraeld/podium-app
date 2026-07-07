#!/bin/bash
# The SwiftUI PodiumApp has been retired (T3.2) — macOS packaging now goes
# through the Tauri shell instead. See tauri/README.md for prerequisites,
# then build the installer with:
#
#   tauri/prepare-sidecar.sh   # build + stage the podium-server sidecar
#   cd tauri && cargo tauri build
#
# This produces Podium.app + a .dmg under
# tauri/src-tauri/target/release/bundle/ (see tauri.conf.json for exact
# targets/paths).

set -euo pipefail

echo "scripts/package-macos.sh is retired — the SwiftUI PodiumApp it packaged is gone (T3.2)."
echo "Build the macOS installer via the Tauri shell instead:"
echo
echo "  tauri/prepare-sidecar.sh && (cd tauri && cargo tauri build)"
echo
echo "See tauri/README.md for details."
exit 1
