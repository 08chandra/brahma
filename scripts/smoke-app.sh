#!/bin/bash
# Builds a debug app and verifies it launches against a seeded temp home.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make-app.sh debug
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BRAHMA_HOME="$TMP/home"
export BRAHMA_WORKSPACES="$TMP/workspaces"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
scripts/seed-demo.sh >/dev/null

set +e
OUT="$(.build/Brahma.app/Contents/MacOS/Brahma --smoke-test)"
STATUS=$?
set -e
echo "$OUT"
if [ "$STATUS" -ne 0 ]; then
  echo "SMOKE FAILED: exit $STATUS" >&2
  exit 1
fi
if ! echo "$OUT" | grep -q '^SMOKE OK companies=2 agents=4'; then
  echo "SMOKE FAILED: unexpected output" >&2
  exit 1
fi
echo "SMOKE PASSED"
