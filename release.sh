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

echo "→ Commit: LTX 4K + Veo 3.1 Fast v2 endpoint + audio on"
git add Sources/LeonardoService.swift Sources/Info.plist \
        docs/index.html release.sh
git commit -m "feat: LTX 2.3 Pro 4K + Veo 3.1 Fast v2 endpoint

LTX 2.3 Pro now offers 4K. The v2 endpoint accepts real 3840x2160
dimensions with mode=RESOLUTION_2160 directly, no wrapped envelope
needed (that earlier path was inconsistent and was pulled).

Veo 3.1 Fast switched from the v1 endpoint to the v2 endpoint using
the hyphenated model id \`veo-3.1-fast-generate-001\`. The v2 path
supports 4K; the older v1 path with VEO3_1FAST was 1080p-capped.
Body shape now matches LTX. The v1 endpoint branch and
usesV1Endpoint property are gone since nothing routes through them.

Generated videos now include audio (\`audio: true\` on LTX and Veo).
The wallpaper player still defaults to muted, so playback is silent
unless the user unmutes from the Playback pane.

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
4K across the board. LTX 2.3 Pro and Veo 3.1 Fast both go full 4K now.

## What's new

- LTX 2.3 Pro now offers 4K output alongside 1080p and 1440p.
- Veo 3.1 Fast now supports 4K (switched to a different API path that accepts native 3840x2160 dimensions).
- Generated videos now include audio. Wallpaper playback still defaults to muted — flip the mute toggle in Playback to hear it.

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
