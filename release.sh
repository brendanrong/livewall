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

echo "→ Commit 1/2: image to video, LTX 2.3 Pro, live cost estimate"
git add Sources/LeonardoService.swift Sources/Preferences.swift \
        Sources/PreferencesWindow.swift Sources/ImageUploadService.swift \
        Sources/PromptInputView.swift dev.sh release.sh
git commit -m "feat: image to video with start and end frames

Drag an image into the prompt box (or click the photo icon) to use it
as the starting frame for generation. A second image becomes the
ending frame and the model interpolates between them. Adds LTX 2.3 Pro
as a new model with native 4K support via the wrapped envelope path.
A live cost estimate sits next to the Generate button and updates as
you change model, duration, and resolution. Rebuilt prompt input view
from scratch so text input, attachment chips, photo-icon picker, and
whole-box drop zone are all rock-solid.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

echo ""
echo "→ Commit 2/2: bump to v${VERSION} and update landing page"
git add Sources/Info.plist docs/index.html
git commit -m "chore: bump to v${VERSION} and update landing page

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
Image to video lands in LiveWall. Drag a frame in, generate a wallpaper around it.

## What's new

- Image to video: drag an image into the prompt box (or click the photo icon) to use it as the starting frame for your generation
- Add a second image as the ending frame and let the model interpolate between them
- LTX 2.3 Pro added as a new model, with native 4K support
- Live cost estimate next to the Generate button updates as you change model, duration, and resolution
- Rebuilt prompt box that's faster to use and accepts drops anywhere on the box

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
