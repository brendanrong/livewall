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

echo "→ Commit 1/2: growable prompt, surface failure reasons, drop LTX 4K"
git add Sources/LeonardoService.swift Sources/Preferences.swift \
        Sources/PreferencesWindow.swift Sources/ImageUploadService.swift \
        Sources/PromptInputView.swift dev.sh release.sh
git commit -m "fix: growable prompt, surface failure reasons, drop LTX 4K

Prompt box swapped to NSTextView in NSScrollView so it grows as you
type, capped at five lines then scrolls past that. Stock config —
no acceptableDragTypes, acceptsFirstResponder, or custom NSClipView
overrides. Placeholder is drawn inside the textView so there's no
overlay sibling that could hijack clicks.

Failed generations now extract failureReason / errorMessage / error
fields from the response and show them inline, instead of showing a
generic 'failed' message. Generic message no longer leaks the API
provider name.

LTX 2.3 Pro 4K pulled. The wrapped envelope path was inconsistent
in practice; LTX is 1080p and 1440p only.

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
Polish pass on the Generate pane. Prompt grows properly, failures are honest.

## What's fixed

- Prompt box now actually grows as you type, capped at 5 lines then scrolls. The previous build had this regress.
- Failed generations now show the specific reason from the server when one's available, instead of a generic message.

## Changed

- LTX 2.3 Pro's 4K option pulled. The wrapped envelope path was inconsistent in practice; LTX is 1080p / 1440p only.

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
