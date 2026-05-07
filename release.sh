#!/bin/bash
# Cuts a LiveWall release end-to-end:
#   1. Stages and commits pending changes in two logical commits
#      (feature + version bump)
#   2. Builds the signed universal binary
#   3. Builds the DMG
#   4. Notarises with Apple (uses keychain profile "LiveWall-Notary")
#   5. Pushes to origin/main
#   6. Tags + creates a GitHub release with the DMG attached
#
# Run from the repo root: bash release.sh

set -euo pipefail

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Info.plist)
echo "→ Releasing LiveWall v${VERSION}"
echo ""

if [ -n "$(git status --porcelain Sources/Generated 2>/dev/null || true)" ]; then
    echo "❌ Refusing to commit Sources/Generated/ — your secrets live there."
    echo "   That folder is gitignored, but double-check before continuing."
    exit 1
fi

echo "→ Commit: Kling 4K + Veo 3.1 Fast + dock-click opens Settings"
git add Sources/LeonardoService.swift Sources/AppDelegate.swift \
        Sources/Info.plist docs/index.html release.sh
git commit -m "feat: Kling 3.0 4K + Veo 3.1 Fast + dock-click opens Settings

Kling 3.0 now offers 4K output. Adds .uhd4K to Kling's resolution
list and includes the \`mode\` parameter explicitly in the request
body so the API honors the requested resolution (without it, the
endpoint silently defaults to RESOLUTION_1080).

Veo 3.0 Fast upgraded to Veo 3.1 Fast (model id VEO3_1FAST). Still
1080p only — Veo's API explicitly rejects 4K dimensions. The v1
request body now includes width and height alongside resolution
to match the documented schema.

Clicking the dock icon now opens Settings. Previously dock clicks
did nothing because the wallpaper windows count as visible NSWindows
in AppKit's bookkeeping, so the default reopen handler thought there
was already a visible window to bring forward. Now the reopen
handler always shows the Settings window. Also calls
applyDockIconVisibility() at launch so the saved preference is
honoured across sessions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

echo ""
echo "→ Building app…"
bash build.sh

echo ""
echo "→ Building DMG…"
bash make_dmg.sh

echo ""
echo "→ Notarising (this takes a few minutes)…"
bash notarize.sh

echo ""
echo "→ Pushing to origin/main…"
git push origin main

echo ""
echo "→ Tagging v${VERSION}…"
git tag "v${VERSION}"
git push origin "v${VERSION}"

echo ""
echo "→ Creating GitHub release…"
NOTES_FILE=$(mktemp -t livewall-release-notes)
cat > "$NOTES_FILE" <<'EOF'
Model upgrades and a friendlier dock icon.

## What's new

- Kling 3.0 now offers 4K output alongside 1080p.
- Veo 3 Fast upgraded to Veo 3.1 Fast. Still 1080p (Veo's API doesn't accept 4K).

## What's fixed

- Clicking the dock icon now opens Settings, instead of doing nothing.

## Install

1. Download `LiveWall-VERSION_PLACEHOLDER.dmg` below
2. Open it
3. Drag LiveWall.app to your Applications folder
4. Open Applications then LiveWall
EOF

# Patch the version placeholder in the install instructions
sed -i.bak "s/VERSION_PLACEHOLDER/${VERSION}/g" "$NOTES_FILE" && rm "$NOTES_FILE.bak"

gh release create "v${VERSION}" "LiveWall-${VERSION}.dmg" \
    --title "LiveWall ${VERSION}" \
    --notes-file "$NOTES_FILE"

rm -f "$NOTES_FILE"

echo ""
echo "✅ Released LiveWall v${VERSION}"
echo "   https://github.com/brendanrong/livewall/releases/tag/v${VERSION}"
