#!/bin/bash
# Renders the map scenes offscreen through the OrgSceneTests, OfficeSceneTests and OfficeTexturesTests and saves PNGs to .superpowers/maps for a human to read.
# Usage: scripts/map-snapshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .superpowers/maps
BRAHMA_MAP_SNAPSHOT_DIR="$PWD/.superpowers/maps" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "OrgSceneTests|OfficeSceneTests|OfficeTexturesTests"
echo
echo "map snapshots:"
ls -1 .superpowers/maps/*.png 2>/dev/null || echo "(none written: no Metal device?)"
