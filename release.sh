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

echo "→ Commit 1/2: Veo 3 Fast and Generate pane reorder"
git add Sources/LeonardoService.swift Sources/Preferences.swift \
        Sources/PreferencesWindow.swift Sources/ImageUploadService.swift \
        Sources/PromptInputView.swift dev.sh release.sh
git commit -m "feat: add Veo 3 Fast and reorder Generate pane

Veo 3 Fast (1080p) added as a new model. Routed to Leonardo's v1
generations-image-to-video / generations-text-to-video endpoints since
the v2 unified endpoint rejected every Veo body shape we tried. The
v1 body uses imageId/imageType + a resolution enum instead of
guidances + width/height.

Generate pane now shows model, duration, and resolution dropdowns
above the prompt box for a clearer top to bottom flow. LTX 2.3 Pro's
4K option pulled for now since the wrapped envelope path was
inconsistent in practice; LTX is 1080p / 1440p only.

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
Veo 3 Fast joins the model lineup, plus a cleaner Generate pane layout.

## What's new

- Veo 3 Fast (1080p) added as a new model. Runs on Leonardo's v1 generation endpoints.
- Model, duration, and resolution dropdowns moved above the prompt box for a clearer top to bottom flow.

## Changed

- LTX 2.3 Pro now offers 1080p and 1440p only. The 4K option's wrapped envelope path was inconsistent in practice and has been pulled until it stabilises.

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
