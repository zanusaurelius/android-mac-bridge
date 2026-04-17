#!/bin/bash
set -e

APP="AndroidMacBridge"
BUILD="build"

rm -rf "$BUILD"
mkdir -p "$BUILD/$APP.app/Contents/MacOS"
mkdir -p "$BUILD/$APP.app/Contents/Resources"

echo "Compiling..."

swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  -framework ImageIO \
  -framework QuickLook \
  -o "$BUILD/$APP.app/Contents/MacOS/$APP" \
  Sources/*.swift

cp Info.plist "$BUILD/$APP.app/Contents/Info.plist"

# ── Bundle adb ───────────────────────────────────────────────────────────────
echo "Looking for adb..."
ADB_PATH=""
for candidate in \
    "$(which adb 2>/dev/null || true)" \
    /opt/homebrew/bin/adb \
    /usr/local/bin/adb \
    /usr/bin/adb; do
    if [ -f "$candidate" ]; then
        ADB_PATH="$candidate"
        break
    fi
done

if [ -n "$ADB_PATH" ]; then
    cp "$ADB_PATH" "$BUILD/$APP.app/Contents/MacOS/adb"
    chmod +x "$BUILD/$APP.app/Contents/MacOS/adb"
    echo "Bundled adb from $ADB_PATH"
else
    echo ""
    echo "WARNING: adb not found. Install it first:"
    echo "    brew install android-platform-tools"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

# ── Create DMG ───────────────────────────────────────────────────────────────
echo "Creating DMG..."

STAGING="$BUILD/dmg_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -r "$BUILD/$APP.app" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$BUILD/$APP.dmg" \
    > /dev/null

rm -rf "$STAGING"

echo ""
echo "Done!"
echo ""
echo "  App: $BUILD/$APP.app"
echo "  DMG: $BUILD/$APP.dmg"
echo ""
echo "Share the DMG. Recipients:"
echo "  1. Open the DMG"
echo "  2. Drag $APP into the Applications folder"
echo "  3. Right-click the app -> Open -> Open  (first launch only, bypasses macOS warning)"
