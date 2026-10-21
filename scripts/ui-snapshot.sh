#!/bin/bash
# Usage: scripts/ui-snapshot.sh <name> [select]. Assumes .build/Brahma.app exists.
# Always uses a fresh seeded temp home, because it runs the engine with the FAKE claude. Set
# BRAHMA_SNAPSHOT_REUSE_HOME=1 to use the caller's BRAHMA_HOME (and BRAHMA_WORKSPACES) instead; the default
# data home is always refused.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: ui-snapshot.sh <name> [select]}"
SELECT="${2:-}"
mkdir -p .superpowers/ui
OUT=".superpowers/ui/$NAME.png"
rm -f "$OUT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEFAULT_HOME="$HOME/Library/Application Support/Brahma"
if [ "${BRAHMA_SNAPSHOT_REUSE_HOME:-}" = "1" ] && [ -n "${BRAHMA_HOME:-}" ]; then
  RESOLVED="$BRAHMA_HOME"
  if [ -d "$BRAHMA_HOME" ]; then RESOLVED="$(cd "$BRAHMA_HOME" && pwd -P)"; fi
  REAL_DEFAULT="$DEFAULT_HOME"
  if [ -d "$DEFAULT_HOME" ]; then REAL_DEFAULT="$(cd "$DEFAULT_HOME" && pwd -P)"; fi
  if [ "${BRAHMA_HOME%/}" = "$DEFAULT_HOME" ] || [ "$RESOLVED" = "$REAL_DEFAULT" ]; then
    echo "ui-snapshot.sh: refusing to run the fake engine against the real data home: $DEFAULT_HOME" >&2
    exit 1
  fi
else
  export BRAHMA_HOME="$TMP/home"
  export BRAHMA_WORKSPACES="$TMP/workspaces"
  mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
  scripts/seed-demo.sh >/dev/null
fi
export BRAHMA_CLAUDE="$PWD/scripts/fake-claude.sh"

ARGS=(--ui-snapshot "$OUT")
if [ -n "$SELECT" ]; then ARGS+=(--select "$SELECT"); fi
# Order matters: AppKit mis-parses a bare "--flag=value" before a "--flag value" pair as a file to open.
.build/Brahma.app/Contents/MacOS/Brahma "${ARGS[@]}" --smoke-hold=4
if [ ! -s "$OUT" ]; then
  echo "snapshot missing or empty: $OUT" >&2
  exit 1
fi
echo "$OUT"
