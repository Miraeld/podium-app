#!/bin/bash
# Build PodiumApp in release mode, bundle it as a proper macOS .app, ad-hoc
# code-sign it, and install it into /Applications.
#
# Usage:
#   ./install.sh            # build + install to /Applications, then launch
#   ./install.sh --no-open  # build + install, don't launch
#   ./install.sh --update   # git pull first, then build + install
#
# You do NOT need Xcode — this uses the Swift toolchain on the command line.
# Re-run this any time you want to ship your latest changes to the installed app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Podium"
INSTALL_DIR="/Applications"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
STAGE="$SCRIPT_DIR/.build/_install/$APP_NAME.app"
BIN_NAME="PodiumApp"
BUNDLE_ID="com.gaelrobin.PodiumApp"

OPEN_AFTER=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_AFTER=0 ;;
    --update)
      echo "▶ Updating source (git pull)…"
      git -C "$SCRIPT_DIR" pull --ff-only
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# Version strings — short version is human-facing; build number is the git
# commit count so LaunchServices reliably notices each new install.
SHORT_VERSION="$(grep -m1 CFBundleShortVersionString "$SCRIPT_DIR/run.sh" 2>/dev/null | sed -E 's/.*<string>([^<]+)<\/string>.*/\1/' || true)"
[ -z "${SHORT_VERSION:-}" ] && SHORT_VERSION="1.0"
BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ Building release ($APP_NAME $SHORT_VERSION build $BUILD_NUMBER)…"
cd "$SCRIPT_DIR"
swift build -c release

REL_BIN="$SCRIPT_DIR/.build/release/$BIN_NAME"
[ -x "$REL_BIN" ] || { echo "✗ Release binary not found at $REL_BIN"; exit 1; }

echo "▶ Assembling .app bundle…"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$REL_BIN" "$STAGE/Contents/MacOS/$BIN_NAME"

# Optional app icon: drop an AppIcon.icns at the repo root to have it bundled.
ICON_KEY=""
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
  ICON_KEY='  <key>CFBundleIconFile</key>        <string>AppIcon</string>'
fi

cat > "$STAGE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>             <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>      <string>$APP_NAME</string>
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
      <key>CFBundleURLName</key>    <string>com.gaelrobin.PodiumApp.url</string>
      <key>CFBundleURLSchemes</key> <array><string>podium</string></array>
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
# Deep ad-hoc signature (identity "-"): no Apple Developer account required.
codesign --force --deep --sign - "$STAGE" 2>/dev/null \
  || echo "  (codesign unavailable — app will still run, just unsigned)"

echo "▶ Installing to $APP_BUNDLE…"
# Quit a running copy so we can replace it cleanly.
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 0.3
rm -rf "$APP_BUNDLE"
ditto "$STAGE" "$APP_BUNDLE"
# Nudge LaunchServices so the new version/icon are picked up immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_BUNDLE" 2>/dev/null || true

echo "✓ Installed: $APP_BUNDLE  ($APP_NAME $SHORT_VERSION, build $BUILD_NUMBER)"
if [ "$OPEN_AFTER" -eq 1 ]; then
  echo "▶ Launching…"
  open "$APP_BUNDLE"
fi
