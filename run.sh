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
# Only the macOS app product — the package also vends podium-server /
# podium-hook (cross-platform daemon + hook binaries), which run.sh doesn't
# need to build for the native app flow.
swift build --product PodiumApp 2>&1

echo "▶ Assembling .app bundle…"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/PodiumApp" "$MACOS_DIR/PodiumApp"

# App icon: bundle AppIcon.icns from the repo root if present (same brand
# icon install.sh ships in the release build — see AppIcon.icns generated
# from dashboard/client/public/logo-mark.svg).
ICON_KEY=""
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
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
