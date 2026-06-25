#!/bin/bash
# Build PodiumApp in release mode, bundle it as a proper macOS .app, ad-hoc
# code-sign it, and install it into /Applications.
#
# Usage:
#   ./install.sh            # SPM build + install to /Applications, then launch
#   ./install.sh --no-open  # build + install, don't launch
#   ./install.sh --update   # git pull (+ regenerate Xcode project) first, then build
#   ./install.sh --widget   # build WITH the WidgetKit widget via Xcode. Needs a
#                            #   free Personal Team — set it once in .podium-team
#                            #   or $PODIUM_TEAM_ID (the script tells you how).
#
# The DEFAULT path uses the Swift toolchain (no Xcode, no widget) and is fast.
# --widget builds through xcodebuild so the embedded widget extension is
# included + code-signed. You do NOT re-run xcodegen by hand — --update and
# --widget regenerate the project automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Podium"
INSTALL_DIR="/Applications"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
STAGE="$SCRIPT_DIR/.build/_install/$APP_NAME.app"
BIN_NAME="PodiumApp"
BUNDLE_ID="com.gaelrobin.PodiumApp"

OPEN_AFTER=1
DO_UPDATE=0
WIDGET=0
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_AFTER=0 ;;
    --update)  DO_UPDATE=1 ;;
    --widget)  WIDGET=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

cd "$SCRIPT_DIR"

if [ "$DO_UPDATE" -eq 1 ]; then
  echo "▶ Updating source (git pull)…"
  git -C "$SCRIPT_DIR" pull --ff-only
fi

# Keep the Xcode project (used by --widget) in sync automatically. Safe to run
# on every invocation: signing is passed to xcodebuild at build time, so
# regenerating from project.yml never clobbers a team set in the Xcode UI.
if command -v xcodegen >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/project.yml" ]; then
  echo "▶ Regenerating Xcode project (xcodegen)…"
  xcodegen generate >/dev/null 2>&1 || echo "  (xcodegen failed — continuing)"
fi

# ── --widget: build through Xcode so the WidgetKit extension is bundled+signed ──
if [ "$WIDGET" -eq 1 ]; then
  command -v xcodegen >/dev/null 2>&1 || { echo "✗ xcodegen not found — install with: brew install xcodegen"; exit 1; }
  [ -f "$SCRIPT_DIR/Podium.xcodeproj/project.pbxproj" ] || xcodegen generate

  # Resolve the signing team (a FREE Personal Team works for local installs).
  TEAM="${PODIUM_TEAM_ID:-}"
  [ -z "$TEAM" ] && [ -f "$SCRIPT_DIR/.podium-team" ] && TEAM="$(tr -d '[:space:]' < "$SCRIPT_DIR/.podium-team")"
  if [ -z "$TEAM" ]; then
    # Best-effort auto-detect: the Team ID is the cert's Organizational Unit
    # (NOT the parenthetical in the identity name — that's the cert ID).
    TEAM="$(security find-certificate -a -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/.*organizationalUnitName *= *//p' | head -1 | tr -d '[:space:]')"
  fi
  if [ -z "$TEAM" ]; then
    echo "✗ No signing team found. The widget needs a (free) Personal Team."
    echo "  One-time setup:"
    echo "   1. Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID (free)."
    echo "   2. Get your 10-char Team ID:  security find-identity -v -p codesigning"
    echo "      (or Xcode ▸ Podium target ▸ Signing & Capabilities)."
    echo "   3. Save it once:  echo 'XXXXXXXXXX' > \"$SCRIPT_DIR/.podium-team\""
    echo "      (or: export PODIUM_TEAM_ID=XXXXXXXXXX )"
    echo "  Then re-run: ./install.sh --widget"
    exit 1
  fi

  echo "▶ Building with widget (xcodebuild · team $TEAM)…"
  DERIVED="$SCRIPT_DIR/.build/_xcode"
  xcodebuild \
    -project "$SCRIPT_DIR/Podium.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    clean build

  BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
  [ -d "$BUILT_APP" ] || { echo "✗ Built app not found at $BUILT_APP"; exit 1; }

  echo "▶ Installing to $APP_BUNDLE…"
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  sleep 0.3
  rm -rf "$APP_BUNDLE"
  ditto "$BUILT_APP" "$APP_BUNDLE"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" 2>/dev/null || true
  echo "✓ Installed (with widget): $APP_BUNDLE"
  if [ "$OPEN_AFTER" -eq 1 ]; then
    echo "▶ Launching…"
    open "$APP_BUNDLE"
  fi
  exit 0
fi

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
