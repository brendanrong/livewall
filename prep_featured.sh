#!/bin/bash
# Prep a folder of .mp4 wallpapers for the Featured catalog.
#
# Usage:
#   bash prep_featured.sh /path/to/folder/of/mp4s
#
# What it does for each .mp4 it finds:
#   1. Generates a 1280x800 .jpg thumbnail from the 1-second mark
#   2. Prints a JSON entry block you can paste into docs/featured.json
#
# It does NOT upload anything — that's a separate step you do via the
# GitHub web UI (creating a Release and dragging files into it).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: bash prep_featured.sh /path/to/folder/of/mp4s"
    exit 1
fi

FOLDER="$1"
OUT="$FOLDER/_featured_assets"

if [ ! -d "$FOLDER" ]; then
    echo "❌ Folder not found: $FOLDER"
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "❌ ffmpeg not installed. Install with:"
    echo "    brew install ffmpeg"
    exit 1
fi

mkdir -p "$OUT"

# Edit this once you've created the GitHub Release. Replace
# 'featured-v1' with whatever tag you used.
RELEASE_TAG="featured-v1"
ASSET_BASE="https://github.com/brendanrong/livewall/releases/download/$RELEASE_TAG"

echo ""
echo "→ Processing .mp4 files in: $FOLDER"
echo "→ Thumbnails will land in:  $OUT"
echo ""

ENTRIES=()

for f in "$FOLDER"/*.mp4; do
    [ -e "$f" ] || continue   # skip if no matches
    base=$(basename "$f" .mp4)

    # Slugify: lowercase, spaces/underscores -> hyphens, strip non
    # alphanumeric / hyphen / dot.
    slug=$(echo "$base" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[ _]/-/g' \
        | sed 's/[^a-z0-9.-]//g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//')

    # Pretty title: replace hyphens/underscores with spaces and
    # capitalise each word.
    title=$(echo "$base" \
        | sed 's/[-_]/ /g' \
        | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))} 1')

    thumb="$OUT/${slug}.jpg"
    video_dest="$OUT/${slug}.mp4"

    # Copy the video alongside the thumbnail so you've got everything
    # in one folder to drag into the GitHub Release.
    cp "$f" "$video_dest"

    # Extract a thumbnail at 1s, scaled to 1280x800 (matches landing
    # page hero ratio), high quality JPEG.
    ffmpeg -y -loglevel error -i "$f" -ss 00:00:01 -frames:v 1 \
        -vf "scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2" \
        -q:v 3 "$thumb"

    echo "✓ $slug"
    echo "    video: $video_dest"
    echo "    thumb: $thumb"
    echo ""

    # Build the JSON entry for this video. Category defaults to
    # "Ambient" — edit by hand in featured.json after pasting if you
    # want something else.
    ENTRY=$(cat <<EOF
    {
      "id": "${slug}",
      "title": "${title}",
      "category": "Ambient",
      "video_url": "${ASSET_BASE}/${slug}.mp4",
      "thumbnail_url": "${ASSET_BASE}/${slug}.jpg"
    }
EOF
)
    ENTRIES+=("$ENTRY")
done

if [ ${#ENTRIES[@]} -eq 0 ]; then
    echo "❌ No .mp4 files found in $FOLDER"
    exit 1
fi

# Print the full featured.json. The user pastes this into
# docs/featured.json (or merges into the existing items array).
echo ""
echo "─────────────────────────────────────────────────"
echo "  PASTE THIS INTO docs/featured.json"
echo "─────────────────────────────────────────────────"
echo ""

JOINED=$(IFS=','; echo "${ENTRIES[*]}")
DATE=$(date +%Y-%m-%d)

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
echo "  1. Go to https://github.com/brendanrong/livewall/releases/new"
echo "  2. Tag: ${RELEASE_TAG}"
echo "  3. Title: Featured assets v1"
echo "  4. Drag every .mp4 and .jpg from $OUT into the assets uploader"
echo "  5. Click 'Publish release'"
echo "  6. Paste the JSON above into docs/featured.json"
echo "  7. Commit + push: docs/featured.json"
echo ""
