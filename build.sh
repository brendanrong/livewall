#!/bin/bash
# Builds LiveWall.app from the Sources/ directory.
# Requires Xcode Command Line Tools (run `xcode-select --install` once if needed).

set -euo pipefail

APP_NAME="LiveWall"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Sources"
APP="$HERE/$APP_NAME.app"

# Developer ID Application cert in the login keychain. If this string is
# missing or wrong, codesign falls back to ad-hoc signing (so the build
# still works for local testing, but Gatekeeper warns and the result is
# NOT notarisable).
SIGN_IDENTITY="Developer ID Application: Brendan Rong (VTMKE23N5G)"

# Minimum macOS version this binary will run on. Without an explicit -target
# flag, swiftc embeds the compiler's host SDK as the minimum (e.g. macOS 26
# if you're building on macOS 26), which locks out everyone on older systems
# even though Info.plist claims wider compatibility.
DEPLOYMENT_TARGET="13.0"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "❌ swiftc not found. Install Xcode Command Line Tools first:"
    echo "    xcode-select --install"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "❌ Sources directory not found at $SRC"
    exit 1
fi

echo "→ Cleaning previous build…"
rm -rf "$APP"

echo "→ Creating bundle structure…"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "→ Copying Info.plist…"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$HERE/Resources/AppIcon.iconset"
if [ -d "$ICONSET" ]; then
    echo "→ Building AppIcon.icns…"
    if command -v iconutil >/dev/null 2>&1; then
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    else
        echo "  (iconutil not found — skipping icon)"
    fi
fi

echo "→ Copying menu bar icons…"
for f in "MenuBarIcon.png" "MenuBarIcon@2x.png" "MenuBarIcon@3x.png"; do
    if [ -f "$HERE/Resources/$f" ]; then
        cp "$HERE/Resources/$f" "$APP/Contents/Resources/$f"
    fi
done

echo "→ Compiling Swift sources…"
# Collect Swift sources safely (handles spaces in paths)
SWIFT_FILES=()
while IFS= read -r -d '' f; do
    SWIFT_FILES+=("$f")
done < <(find "$SRC" -name "*.swift" -type f -print0)

if [ ${#SWIFT_FILES[@]} -eq 0 ]; then
    echo "❌ No .swift files found in $SRC"
    exit 1
fi

# Build separate per-architecture binaries targeting the minimum macOS
# version, then merge them into one universal binary so the app runs on
# both Apple Silicon and Intel Macs from macOS $DEPLOYMENT_TARGET upward.
ARM_BIN="$APP/Contents/MacOS/${APP_NAME}_arm64"
X86_BIN="$APP/Contents/MacOS/${APP_NAME}_x86_64"
FINAL_BIN="$APP/Contents/MacOS/$APP_NAME"

compile_for_arch() {
    local target="$1"
    local out="$2"
    echo "  → $target"
    swiftc \
        -O \
        -target "$target" \
        -framework Cocoa \
        -framework AVFoundation \
        -framework AVKit \
        -framework WebKit \
        -framework UniformTypeIdentifiers \
        -framework ServiceManagement \
        -framework Carbon \
        -o "$out" \
        "${SWIFT_FILES[@]}"
}

compile_for_arch "arm64-apple-macos${DEPLOYMENT_TARGET}"  "$ARM_BIN"
compile_for_arch "x86_64-apple-macos${DEPLOYMENT_TARGET}" "$X86_BIN"

echo "→ Merging into universal binary…"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$FINAL_BIN"
rm -f "$ARM_BIN" "$X86_BIN"

echo "→ Marking executable…"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "→ Codesigning…"
# Try signing with the Developer ID cert + hardened runtime (required for
# notarisation). If the cert isn't installed (e.g. someone else cloning the
# repo), fall back to ad-hoc so the build still produces a runnable app.
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "  Using $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP"
    SIGNED_WITH="Developer ID"
else
    echo "  ⚠️  Developer ID cert not found, falling back to ad-hoc."
    echo "     The app will run locally but cannot be notarised."
    codesign --force --sign - "$APP"
    SIGNED_WITH="ad-hoc"
fi

cat <<EOF

✅ Built: $APP  (signed: $SIGNED_WITH)

To launch:
   open "$APP"

The app runs in the menu bar (look for the picture icon in the top-right).

EOF
