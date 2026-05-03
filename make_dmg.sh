#!/bin/bash
# Builds LiveWall.app (if needed) and packages it into LiveWall.dmg.
# The DMG includes a drag-to-install layout: LiveWall.app + a shortcut to /Applications.

set -euo pipefail

APP_NAME="LiveWall"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/$APP_NAME.app"
DMG="$HERE/$APP_NAME.dmg"
STAGE="$(mktemp -d -t livewall-dmg)"
VOLNAME="$APP_NAME"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# 1. Build the app if it isn't there
if [ ! -d "$APP" ]; then
    echo "→ LiveWall.app not found, running build.sh first…"
    "$HERE/build.sh"
fi

if [ ! -d "$APP" ]; then
    echo "❌ Build did not produce $APP"
    exit 1
fi

# 2. Stage the contents
echo "→ Staging DMG contents…"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Remove any existing DMG
rm -f "$DMG"

# 4. Create the DMG (compressed, read-only)
echo "→ Creating ${DMG}…"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

# 5. Sanity check
SIZE_HUMAN="$(du -h "$DMG" | cut -f1)"
echo ""
echo "✅ Built $DMG ($SIZE_HUMAN)"
echo ""
echo "To install:"
echo "   open \"$DMG\""
echo "   then drag LiveWall.app onto the Applications shortcut."
echo ""
