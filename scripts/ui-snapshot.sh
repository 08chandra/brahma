#!/bin/bash
# Usage: scripts/ui-snapshot.sh <name> [select]. Assumes .build/Brahma.app exists.
# If BRAHMA_HOME is already set by the caller, that home (and its BRAHMA_WORKSPACES) is used as is.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: ui-snapshot.sh <name> [select]}"
SELECT="${2:-}"
mkdir -p .superpowers/ui
OUT=".superpowers/ui/$NAME.png"
rm -f "$OUT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -z "${BRAHMA_HOME:-}" ]; then
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
