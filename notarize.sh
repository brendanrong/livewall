#!/bin/bash
# Builds, signs, packages, notarises, and staples LiveWall.dmg for distribution.
#
# Prerequisites (do these once):
#   1. Developer ID Application certificate installed in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID
#      Application).
#   2. App-specific password generated at appleid.apple.com → Sign-In and
#      Security → App-Specific Passwords.
#   3. notarytool credentials stored under profile "LiveWall-Notary":
#        xcrun notarytool store-credentials "LiveWall-Notary" \
#            --apple-id "brendanrong22@gmail.com" \
#            --team-id "VTMKE23N5G" \
#            --password "<app-specific-password>"
#
# After all that, just run: ./notarize.sh

set -euo pipefail

APP_NAME="LiveWall"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/$APP_NAME.app"
DMG="$HERE/$APP_NAME.dmg"

SIGN_IDENTITY="Developer ID Application: Brendan Rong (VTMKE23N5G)"
NOTARY_PROFILE="LiveWall-Notary"

# 1. Build a fresh, Developer ID-signed .app
echo "→ Step 1/5: Building LiveWall.app …"
"$HERE/build.sh"

# 2. Package into a DMG (calls make_dmg.sh which packages the already-signed .app)
echo "→ Step 2/5: Building LiveWall.dmg …"
"$HERE/make_dmg.sh"

# 3. Sign the DMG itself. Notarisation requires the DMG to be signed too.
echo "→ Step 3/5: Signing the DMG …"
codesign --force --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$DMG"

# 4. Submit to Apple's notary service. This usually takes 1-5 minutes.
echo "→ Step 4/5: Submitting to Apple notarisation (1-5 min) …"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# 5. Staple the notarisation ticket onto the DMG so Gatekeeper can verify
#    offline (without re-contacting Apple every time someone opens it).
echo "→ Step 5/5: Stapling ticket onto DMG …"
xcrun stapler staple "$DMG"

# Final verification
echo "→ Verifying …"
xcrun stapler validate "$DMG"

cat <<EOF

✅ Notarised and stapled: $DMG

You can host this DMG anywhere — GitHub Releases, your own site, whatever.
When users download it, double-click the DMG, and drag LiveWall.app to
Applications, macOS will verify the Apple-issued ticket and let it open
without the "cannot verify developer" warning.

EOF
