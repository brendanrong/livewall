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

echo "→ Commit: Featured tab + sidebar reorder + sleep/wake fix"
git add Sources/FeaturedService.swift Sources/PreferencesWindow.swift \
        Sources/SidebarItemButton.swift Sources/WallpaperController.swift \
        docs/index.html prep_featured.sh rename_featured.sh release.sh
git commit -m "feat: Featured tab + sidebar reorder + sleep/wake fix

New Featured tab between Library and Generate. Loads a curated catalog
from docs/featured.json on GitHub Pages. Each card has a thumbnail,
title, category, and a Use button that downloads the video to
~/Movies/LiveWall/Library/Featured/ and sets it as wallpaper. Solves
the cold-start onboarding problem — first-launch user has things to
pick from instantly.

Sidebar reordered so content tabs (Featured / Library / Generate)
come first, config tabs (Display / Playback / General) come after,
About at the bottom. First-launch default lands on Featured.

Wallpaper now recovers cleanly from sleep/wake. WallpaperController
listens for NSWorkspace.didWakeNotification and rebuilds the AVPlayer
pipeline (with a small delay so the display server is back up first).
Fixes the freeze-to-black after closing the lid and reopening.

Landing page v2.3 release block updated.

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
The Featured tab is here. Browse curated wallpapers, click Use, done.

## What's new

- New Featured tab. Browse curated wallpapers, click Use to download and set them. No prompt, no generation, no waiting for a model to render.
- Sidebar reordered so the content tabs (Featured / Library / Generate) come first. First-launch lands on Featured.

## What's fixed

- Wallpaper now recovers cleanly from sleep/wake. No more freeze-to-black after closing the lid and reopening.
- Prompt box now actually grows as you type, capped at 5 lines then scrolls.
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
