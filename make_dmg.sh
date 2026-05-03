#!/bin/bash
# Builds LiveWall.app (if needed) and packages it into LiveWall.dmg with a
# custom installer layout: dark background, icons positioned, toolbar hidden.
#
# The background is generated from Resources/make_dmg_background.py — re-run
# that script if you want to tweak the design.

set -euo pipefail

APP_NAME="LiveWall"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/$APP_NAME.app"
DMG="$HERE/$APP_NAME.dmg"
BG_SRC="$HERE/Resources/dmg-background.png"
VOLNAME="$APP_NAME"

# Window dimensions and icon positions — keep in sync with the background PNG.
WIN_X=200
WIN_Y=200
WIN_W=600
WIN_H=420
ICON_LEFT_X=160
ICON_RIGHT_X=440
ICON_Y=200
ICON_SIZE=128

# 1. Build the app if it isn't there
if [ ! -d "$APP" ]; then
    echo "→ LiveWall.app not found, running build.sh first…"
    "$HERE/build.sh"
fi

if [ ! -d "$APP" ]; then
    echo "❌ Build did not produce $APP"
    exit 1
fi

# 2. Make sure we have the background image
if [ ! -f "$BG_SRC" ]; then
    echo "→ DMG background not found, regenerating…"
    if command -v python3 >/dev/null 2>&1; then
        python3 "$HERE/Resources/make_dmg_background.py"
    else
        echo "❌ python3 missing — install it or generate Resources/dmg-background.png by hand."
        exit 1
    fi
fi

# 3. Clean any previous output
rm -f "$DMG"
TMP_DMG="$HERE/.${APP_NAME}-tmp.dmg"
rm -f "$TMP_DMG"

# Make sure no stale mount is around from an aborted previous run
if [ -d "/Volumes/$VOLNAME" ]; then
    echo "→ Detaching stale /Volumes/$VOLNAME …"
    hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
fi

# 4. Size the writable DMG: app size + headroom for layout metadata.
APP_SIZE_MB="$(du -sm "$APP" | awk '{print $1}')"
DMG_SIZE_MB=$((APP_SIZE_MB + 25))

echo "→ Creating writable DMG (${DMG_SIZE_MB} MB)…"
# Default format for an empty DMG created from -size is already read-write
# (UDIF). Don't pass -format here — it requires -srcfolder/-srcdevice.
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$VOLNAME" \
    -ov \
    "$TMP_DMG" >/dev/null

# 5. Mount it
echo "→ Mounting…"
ATTACH_OUT="$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(echo "$ATTACH_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOLNAME"

cleanup() {
    if [ -d "$MOUNT" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_DMG"
}
trap cleanup ERR

# 6. Stage the contents
echo "→ Staging contents…"
cp -R "$APP" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications"

mkdir -p "$MOUNT/.background"
cp "$BG_SRC" "$MOUNT/.background/background.png"

# 7. Tell Finder how to lay it out
echo "→ Configuring Finder view…"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {$ICON_LEFT_X, $ICON_Y}
        set position of item "Applications" of container window to {$ICON_RIGHT_X, $ICON_Y}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# 8. Settle the filesystem so .DS_Store is fully flushed before detaching.
sync
sleep 2

# 9. Detach
echo "→ Detaching…"
hdiutil detach "$DEVICE" -quiet

# 10. Convert to compressed read-only
echo "→ Compressing…"
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG" >/dev/null

rm -f "$TMP_DMG"
trap - ERR

SIZE_HUMAN="$(du -h "$DMG" | cut -f1)"
cat <<EOF

✅ Built $DMG ($SIZE_HUMAN)

To preview the installer layout locally:
   open "$DMG"

EOF
