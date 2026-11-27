#!/bin/bash
# Usage: scripts/ui-snapshot.sh <name> [select]. Assumes .build/Brahma.app exists.
# Always uses a fresh seeded temp home, because it runs the engine with the FAKE claude. Set
# BRAHMA_SNAPSHOT_REUSE_HOME=1 to use the caller's BRAHMA_HOME (and BRAHMA_WORKSPACES) instead; the default
# data home is always refused. A reused home uses whatever BRAHMA_OWNER_KEY_STORE the caller exports (unset = Keychain).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: ui-snapshot.sh <name> [select]}"
SELECT="${2:-}"
mkdir -p .superpowers/ui
OUT=".superpowers/ui/$NAME.png"
rm -f "$OUT"

TMP="$(mktemp -d)"
# Item 20: the app runs as a throwaway harness copy, so nothing here writes the owner's dev.brahma.app defaults.
. scripts/harness-app.sh
trap 'harness_app_cleanup; rm -rf "$TMP"' EXIT
harness_app_prepare "$TMP"
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
  # Fresh seeded temp home only: its owner-key hash lives in the home, not the login Keychain (which prompts for the
  # password after every rebuild). The CLI and app refuse this for the default data home. A REUSED home may be
  # Keychain-keyed, so the file store is never forced onto it (export BRAHMA_OWNER_KEY_STORE=file yourself if it
  # was seeded that way).
  export BRAHMA_OWNER_KEY_STORE=file
  export BRAHMA_SECRET_STORE=file
  export BRAHMA_HOME="$TMP/home"
  export BRAHMA_WORKSPACES="$TMP/workspaces"
  mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
  scripts/seed-demo.sh >/dev/null
fi
export BRAHMA_CLAUDE="$PWD/scripts/fake-claude.sh"

ARGS=(--ui-snapshot "$OUT")
if [ -n "$SELECT" ]; then ARGS+=(--select "$SELECT"); fi
# The work screens, the Handbook, memory and search are seeded in Initech; everything else keeps the first company.
# BRAHMA_SNAPSHOT_COMPANY overrides.
COMPANY="${BRAHMA_SNAPSHOT_COMPANY:-}"
case "$SELECT" in backlog|board|inbox|grants|digest|settings|resources|handbook|memory|budget|merge|merge-settings|item:*|kb:*|search:*|replay:*|preview:*|artifact:*) [ -n "$COMPANY" ] || COMPANY=Initech ;; esac
if [ -n "$COMPANY" ]; then ARGS+=(--company "$COMPANY"); fi
# Order matters: AppKit mis-parses a bare "--flag=value" before a "--flag value" pair as a file to open.
"$HARNESS_APP" "${ARGS[@]}" --smoke-hold=4
if [ ! -s "$OUT" ]; then
  echo "snapshot missing or empty: $OUT" >&2
  exit 1
fi
echo "$OUT"
