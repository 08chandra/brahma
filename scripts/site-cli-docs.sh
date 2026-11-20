#!/bin/bash
# CLI reference for the public site. Usage: scripts/site-cli-docs.sh
# Builds the `brahma` CLI (debug), dumps its help as JSON with swift-argument-parser's
# --experimental-dump-help into site/.reports/cli-dump.json, and generates one Markdown page per
# displayed command into site/src/content/docs/docs/cli/ (gitignored; generated at build time,
# never committed) with site/scripts/gen-cli.mjs. The output directory is emptied first so removed
# commands disappear. Fails when fewer than 50 pages are written (a truncated or empty dump).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

command -v swift >/dev/null || { echo "site-cli-docs: swift not found on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "site-cli-docs: node not found on PATH" >&2; exit 1; }

OUT=site/src/content/docs/docs/cli
DUMP=site/.reports/cli-dump.json

echo "site-cli-docs: building brahma (debug)"
timeout 900 swift build --product brahma

mkdir -p site/.reports
timeout 60 .build/debug/brahma --experimental-dump-help > "$DUMP"

rm -rf "$OUT"
node site/scripts/gen-cli.mjs "$DUMP" "$OUT"

if grep -rl '/Users/' "$OUT" >&2; then
  echo "site-cli-docs: generated pages contain a /Users/ path (listed above)" >&2
  exit 1
fi

N=$(find "$OUT" -type f -name '*.md' | wc -l | tr -d ' ')
echo "cli pages: $N"
if [ "$N" -lt 50 ]; then
  echo "site-cli-docs: expected at least 50 pages, got $N" >&2
  exit 1
fi
