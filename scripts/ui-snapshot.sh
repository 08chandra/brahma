#!/bin/bash
# Usage: scripts/ui-snapshot.sh <name> [select]. Assumes .build/Brahma.app exists.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: ui-snapshot.sh <name> [select]}"
SELECT="${2:-}"
mkdir -p .superpowers/ui
OUT=".superpowers/ui/$NAME.png"
rm -f "$OUT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BRAHMA_HOME="$TMP/home"
export BRAHMA_WORKSPACES="$TMP/workspaces"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
scripts/seed-demo.sh >/dev/null

ARGS=(--ui-snapshot "$OUT")
if [ -n "$SELECT" ]; then ARGS+=(--select "$SELECT"); fi
.build/Brahma.app/Contents/MacOS/Brahma "${ARGS[@]}"
if [ ! -s "$OUT" ]; then
  echo "snapshot missing or empty: $OUT" >&2
  exit 1
fi
echo "$OUT"
