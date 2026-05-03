#!/bin/bash
# Builds LiveWall.app (if needed) and packages it into a styled
# LiveWall-X.Y.dmg with a branded background, positioned icons, and a
# drag-to-install layout.
#
# Requires `create-dmg` (one-time install: `brew install create-dmg`).

set -euo pipefail

APP_NAME="LiveWall"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/$APP_NAME.app"

# Pull the version straight out of Info.plist so the DMG filename always
# matches the build (e.g. LiveWall-1.2.dmg).
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$HERE/Sources/Info.plist" 2>/dev/null || echo dev)"

DMG="$HERE/${APP_NAME}-${VERSION}.dmg"
BACKGROUND="$HERE/Resources/dmg-background.png"
STAGE="$(mktemp -d -t livewall-dmg)"
VOLNAME="$APP_NAME ${VERSION}"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "❌ create-dmg not found. Install it once:"
    echo "    brew install create-dmg"
    exit 1
fi

# 1. Build the app if it isn't there
if [ ! -d "$APP" ]; then
    echo "→ LiveWall.app not found, running build.sh first…"
    "$HERE/build.sh"
fi

if [ ! -d "$APP" ]; then
    echo "❌ Build did not produce $APP"
    exit 1
fi

# 2. Stage just the .app. create-dmg will add the Applications shortcut
#    itself via --app-drop-link.
echo "→ Staging DMG contents…"
cp -R "$APP" "$STAGE/"

# 3. Remove any existing DMG so create-dmg doesn't refuse.
rm -f "$DMG"

# 4. Create the DMG with custom background, window size, and icon
#    positions matching the arrow drawn on the background.
echo "→ Creating ${DMG}…"
create-dmg \
    --volname "$VOLNAME" \
    --background "$BACKGROUND" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 130 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 410 190 \
    --no-internet-enable \
    "$DMG" \
    "$STAGE" >/dev/null

# 5. Sanity check
SIZE_HUMAN="$(du -h "$DMG" | cut -f1)"
echo ""
echo "✅ Built $DMG ($SIZE_HUMAN)"
echo ""
echo "To install:"
echo "   open \"$DMG\""
echo "   then drag LiveWall.app onto the Applications shortcut."
echo ""
