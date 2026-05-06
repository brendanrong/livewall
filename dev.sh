#!/bin/bash
# Quick local rebuild + relaunch loop. Run from anywhere in the
# LiveWall repo and it'll do the right thing.
#
#   bash dev.sh
#
# What it does:
#   1. Force-quits any running LiveWall (incl. menu bar process)
#   2. Deletes the previous .app build
#   3. Rebuilds the universal binary
#   4. Launches the binary directly so we see crash output / NSLog
#
# Why directly instead of `open LiveWall.app`: `open` reactivates an
# existing instance instead of relaunching, so a stale binary stays in
# memory if killall didn't take. Launching the binary is unambiguous.

set -euo pipefail

# Always cd to the repo root, so this works regardless of where it's run.
cd "$(dirname "$0")"

echo "→ Killing any running LiveWall…"
pkill -9 -f LiveWall 2>/dev/null || true
sleep 1

echo "→ Removing previous build…"
rm -rf LiveWall.app

echo "→ Building…"
bash build.sh

echo ""
echo "→ Launching LiveWall (output streams to this terminal)…"
echo "   Press Ctrl+C to quit."
echo ""
exec ./LiveWall.app/Contents/MacOS/LiveWall
