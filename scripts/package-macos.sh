#!/bin/bash
# Builds a distributable PodiumApp.app + DMG for macOS.
#
# This is the release-packaging sibling of run.sh (which does a debug build
# for local dev). It extends the same .app-assembly logic — release build,
# copy binary + podium-hook + AppIcon.icns into Resources — and adds what
# run.sh doesn't need: bundling WebClient/dist (so the embedded server has
# the dashboard even on a machine with no repo checkout), ad-hoc
# code-signing, and wrapping the result in a DMG for distribution.
#
# Usage:
#   scripts/package-macos.sh              # build + .app + DMG under dist/
#   scripts/package-macos.sh --no-dmg     # build + .app only, skip DMG
#
# Output:
#   dist/PodiumApp.app
#   dist/Podium-<version>.dmg   (unless --no-dmg)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/PodiumApp.app"
MACOS_DIR="$STAGE_DIR/Contents/MacOS"
RESOURCES_DIR="$STAGE_DIR/Contents/Resources"
INFO_PLIST="$STAGE_DIR/Contents/Info.plist"
BIN_NAME="PodiumApp"
BUNDLE_ID="com.gaelrobin.PodiumApp"
APP_DISPLAY_NAME="Podium"

MAKE_DMG=1
for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$SCRIPT_DIR"

# Version strings — mirrors install.sh's convention: short version is
# human-facing (read from run.sh's Info.plist template), build number is the
# git commit count so LaunchServices reliably notices each new install.
SHORT_VERSION="$(grep -m1 CFBundleShortVersionString "$SCRIPT_DIR/run.sh" 2>/dev/null | sed -E 's/.*<string>([^<]+)<\/string>.*/\1/' || true)"
[ -z "${SHORT_VERSION:-}" ] && SHORT_VERSION="1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ Release build (PodiumApp $SHORT_VERSION build $BUILD_NUMBER)…"
swift build -c release --product PodiumApp
swift build -c release --product podium-hook

BUILD_DIR="$SCRIPT_DIR/.build/release"
[ -x "$BUILD_DIR/$BIN_NAME" ] || { echo "✗ Release binary not found at $BUILD_DIR/$BIN_NAME"; exit 1; }
[ -x "$BUILD_DIR/podium-hook" ] || { echo "✗ podium-hook binary not found at $BUILD_DIR/podium-hook"; exit 1; }

echo "▶ Assembling .app bundle…"
rm -rf "$STAGE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$BIN_NAME" "$MACOS_DIR/$BIN_NAME"
cp "$BUILD_DIR/podium-hook" "$RESOURCES_DIR/podium-hook"

# App icon (same optional pattern as run.sh/install.sh).
ICON_KEY=""
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
fi

# Vendored web client — this is what lets EmbeddedServer.swift serve the
# dashboard on a machine with no repo checkout at all (see
# WebDistResolver.bundledResourcesDistPath in
# Sources/PodiumServer/Static/StaticFileHandler.swift). Required for a real
# distribution build, unlike run.sh's dev copy which is best-effort.
if [ ! -d "$SCRIPT_DIR/WebClient/dist" ]; then
  echo "✗ WebClient/dist not found — vendor the built web client first (see WebClient/SYNC.md)."
  exit 1
fi
mkdir -p "$RESOURCES_DIR/WebClient"
cp -R "$SCRIPT_DIR/WebClient/dist" "$RESOURCES_DIR/WebClient/dist"

cat > "$INFO_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>             <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>      <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>       <string>$BIN_NAME</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key>          <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>   <string>com.gaelrobin.PodiumApp.url</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>podium</string>
      </array>
    </dict>
  </array>
  <key>NSUserActivityTypes</key>
  <array>
    <string>com.gaelrobin.PodiumApp.viewSession</string>
  </array>
$ICON_KEY
</dict>
</plist>
PLIST

echo "▶ Ad-hoc code-signing…"
# Deep ad-hoc signature (identity "-"): no Apple Developer account needed,
# same as install.sh. Distributed users will still see a Gatekeeper
# "unidentified developer" prompt once (right-click ▸ Open) — that is a
# separate, non-blocking concern from this task (needs a paid Developer ID
# to remove entirely).
codesign --force --deep --sign - "$STAGE_DIR" 2>/dev/null \
  || echo "  (codesign unavailable — app will still run, just unsigned)"

echo "✓ .app assembled: $STAGE_DIR"

if [ "$MAKE_DMG" -eq 0 ]; then
  echo "  (--no-dmg: skipping DMG creation)"
  exit 0
fi

echo "▶ Creating DMG…"
DMG_STAGE_DIR="$DIST_DIR/.dmg-stage"
DMG_PATH="$DIST_DIR/Podium-$SHORT_VERSION.dmg"
rm -rf "$DMG_STAGE_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGE_DIR"

# Standard "drag PodiumApp.app onto Applications" layout.
ditto "$STAGE_DIR" "$DMG_STAGE_DIR/$APP_DISPLAY_NAME.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
  -volname "$APP_DISPLAY_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGE_DIR"

echo "✓ DMG created: $DMG_PATH"
