#!/bin/bash
# Usage: scripts/map-demo.sh [agents] [extra Brahma flags, e.g. --map-bench=5, --map-skin=office]
# --map-skin=office opens the demo in the office (Plan 4c) without unlocking or persisting anything.
# Builds the debug app and opens the read-only agent-map demo (a synthetic company of [agents] agents, default 300).
# Always runs in a fresh temp home with the file key stores: it never touches the real data home or the Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

AGENTS="${1:-300}"
shift || true

scripts/make-app.sh debug >/dev/null

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BRAHMA_OWNER_KEY_STORE=file
export BRAHMA_SECRET_STORE=file
export BRAHMA_HOME="$TMP/home"
export BRAHMA_WORKSPACES="$TMP/workspaces"
export BRAHMA_CLAUDE="$PWD/scripts/fake-claude.sh"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"

# Order matters: AppKit mis-parses a bare "--flag=value" before a "--flag value" pair as a file to open.
.build/Brahma.app/Contents/MacOS/Brahma --map-demo --map-demo-agents="$AGENTS" "$@"
