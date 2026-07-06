#!/bin/bash
# Builds PodiumApp and launches it wrapped in a minimal .app bundle.
# Usage: ./run.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
APP_BUNDLE="$SCRIPT_DIR/PodiumApp.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

echo "▶ Building…"
cd "$SCRIPT_DIR"
# PodiumApp embeds the server in-process (P5.1) but still shells out to the
# native podium-hook binary for Claude Code hook events (EmbeddedServer.swift
# installs it into ~/.claude/podium/), so it needs to be built and bundled too.
swift build --product PodiumApp 2>&1
swift build --product podium-hook 2>&1

echo "▶ Assembling .app bundle…"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/PodiumApp" "$MACOS_DIR/PodiumApp"
cp "$BUILD_DIR/podium-hook" "$RESOURCES_DIR/podium-hook"

# App icon: bundle AppIcon.icns from the repo root if present (same brand
# icon install.sh ships in the release build — see AppIcon.icns generated
# from dashboard/client/public/logo-mark.svg).
ICON_KEY=""
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
fi

# Bundle the vendored web client so the embedded server (EmbeddedServer.swift)
# can serve it straight from the .app bundle, same as a packaged release
# (see scripts/package-macos.sh + WebDistResolver's bundle-Resources
# fallback). Optional for dev: if WebClient/dist isn't present yet, the
# server just falls back to resolving it from the repo tree directly.
if [ -d "$SCRIPT_DIR/WebClient/dist" ]; then
  rm -rf "$RESOURCES_DIR/WebClient"
  mkdir -p "$RESOURCES_DIR/WebClient"
  cp -R "$SCRIPT_DIR/WebClient/dist" "$RESOURCES_DIR/WebClient/dist"
fi

cat > "$INFO_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>       <string>com.gaelrobin.PodiumApp</string>
  <key>CFBundleName</key>             <string>Podium</string>
  <key>CFBundleExecutable</key>       <string>PodiumApp</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.2</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
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

# Nudge LaunchServices so a refreshed icon is picked up immediately instead
# of showing a stale cached generic-executable icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_BUNDLE" 2>/dev/null || true

echo "▶ Launching…"
open "$APP_BUNDLE"
