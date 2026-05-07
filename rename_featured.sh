#!/bin/bash
# Renames the four current featured assets in
# ~/Desktop/featured/_featured_assets/ to short clean slugs, and
# prints out a clean featured.json block for you to paste in.
#
# Run from anywhere:
#   bash rename_featured.sh

set -euo pipefail

DIR="$HOME/Desktop/featured/_featured_assets"

if [ ! -d "$DIR" ]; then
    echo "❌ Folder not found: $DIR"
    exit 1
fi

cd "$DIR"

# Edit the slugs / titles here if you want different names. Format:
#   "long-current-name|new-slug|Pretty Title|Category"
#
# `long-current-name` must match the existing filenames in $DIR
# (without the .mp4 / .jpg extension).
RENAMES=(
"veo-3.1-fast-generate-001-cinematic-4k-wallpaper-a-radiant-golden-solar-bloom-opening-slowly-in-deep-space-0|solar-bloom|Solar Bloom|Ambient"
"veo-3.1-generate-001-4k-ultra-detailed-abstract-wallpaper-liquid-black-marble-ocean-with-silver-and-d-0|black-marble-ocean|Black Marble Ocean|Abstract"
"veo-3.1-generate-001-ultra-hd-4k-abstract-wallpaper-flowing-silk-fabric-suspended-underwater-glowing-0|underwater-silk|Underwater Silk|Abstract"
"veo-3.1-generate-001-ultra-premium-4k-cinematic-wallpaper-deep-black-background-with-flowing-crimson-0|crimson-flow|Crimson Flow|Cinematic"
)

ASSET_BASE="https://github.com/brendanrong/livewall/releases/download/featured-v1"
JSON_ENTRIES=()

echo ""
echo "→ Renaming files in: $DIR"
echo ""

for line in "${RENAMES[@]}"; do
    IFS='|' read -r old slug title category <<< "$line"

    for ext in mp4 jpg; do
        if [ -f "${old}.${ext}" ]; then
            mv "${old}.${ext}" "${slug}.${ext}"
            echo "✓ ${slug}.${ext}"
        else
            echo "⚠ Missing: ${old}.${ext}"
        fi
    done

    JSON_ENTRIES+=(
"$(cat <<EOF
    {
      "id": "${slug}",
      "title": "${title}",
      "category": "${category}",
      "video_url": "${ASSET_BASE}/${slug}.mp4",
      "thumbnail_url": "${ASSET_BASE}/${slug}.jpg"
    }
EOF
)"
)
done

DATE=$(date +%Y-%m-%d)
JOINED=$(IFS=','; echo "${JSON_ENTRIES[*]}")

echo ""
echo "─────────────────────────────────────────────────"
echo "  PASTE THIS INTO docs/featured.json"
echo "─────────────────────────────────────────────────"
echo ""

cat <<EOF
{
  "version": 1,
  "updated": "${DATE}",
  "items": [
${JOINED}
  ]
}
EOF

echo ""
echo "─────────────────────────────────────────────────"
echo ""
echo "Next:"
echo "  1. Go back to your draft GitHub Release page"
echo "  2. Delete all the existing attached files (the X next to each)"
echo "  3. Drag the renamed files from $DIR back in"
echo "  4. Publish (with 'Set as latest release' UNCHECKED)"
echo "  5. Paste the JSON above into docs/featured.json"
echo ""
