#!/bin/bash
# Real app screenshots for the public site. Usage: scripts/site-screenshots.sh [--rebuild]
# Builds .build/Brahma.app (debug) when it is missing or older than Sources/ (always with --rebuild), takes the seven
# site screenshots with scripts/ui-snapshot.sh and writes the optimised PNGs to site/public/screenshots/ (gitignored;
# generated at build time, never committed).
#
# Every shot runs against a fresh demo home seeded by scripts/seed-demo.sh under /private/tmp/brahma-site-shots (removed on
# exit), handed to ui-snapshot.sh with BRAHMA_SNAPSHOT_REUSE_HOME=1; ui-snapshot.sh and seed-demo.sh both refuse the real
# data home, and the engine only ever runs the fake claude (scripts/fake-claude.sh). A home under /private/tmp rather than
# ui-snapshot.sh's own mktemp home for two reasons: a mktemp home lies inside the Darwin per-user temp dir, which every
# sandboxed turn may read, so the engine refuses each turn as "sandbox scope overlaps the protected path" and the console
# fills with failures; and the app's dev/demo banner prints the home's path, which must not name the build machine
# (/var/folders/<hash>/...). The demo companies run the Workspace profile because the fake claude can never pass the
# sandbox canary a Sandboxed turn waits for (see scripts/smoke-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REBUILD=0
case "${1:-}" in
  --rebuild) REBUILD=1 ;;
  "") ;;
  *) echo "usage: scripts/site-screenshots.sh [--rebuild]" >&2; exit 2 ;;
esac

APP_BIN=.build/Brahma.app/Contents/MacOS/Brahma
if [ "$REBUILD" = 1 ] || [ ! -x "$APP_BIN" ] || [ -n "$(find Sources -type f -newer "$APP_BIN" -print -quit)" ]; then
  echo "site-screenshots: building .build/Brahma.app (debug)"
  timeout 1200 scripts/make-app.sh debug
else
  echo "site-screenshots: .build/Brahma.app is newer than Sources/, skipping build"
fi

ROOT=/private/tmp/brahma-site-shots
CLI=.build/Brahma.app/Contents/Helpers/brahma
export BRAHMA_HOME="$ROOT/home"
export BRAHMA_WORKSPACES="$ROOT/workspaces"
export BRAHMA_OWNER_KEY_STORE=file
export BRAHMA_SECRET_STORE=file
export BRAHMA_SNAPSHOT_REUSE_HOME=1
trap 'rm -rf "$ROOT"' EXIT

seed_home() {
  rm -rf "$ROOT"
  mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
  timeout 600 scripts/seed-demo.sh >/dev/null 2>&1
  for company in Acme Initech; do
    timeout 60 "$CLI" company profile "$company" workspace >/dev/null 2>&1
  done
}

# ui-snapshot.sh with the CLI's per-process dev/demo store warnings filtered out; its own exit status is kept.
snap() {
  timeout 300 scripts/ui-snapshot.sh "$@" 2>&1 | grep -v 'dev/demo' || [ "${PIPESTATUS[0]}" = 0 ]
}

# name:select — an empty select is the default console (mission-control) view. `map` is selected by the app but is not
# in ui-snapshot.sh's Initech list, so the 12-agent company is forced; the work screens, Handbook and Resources are
# routed to Initech by ui-snapshot.sh itself.
SHOTS=(console: inbox:inbox backlog:backlog board:board map:map handbook:handbook resources:resources)
for shot in "${SHOTS[@]}"; do
  name="${shot%%:*}"
  sel="${shot#*:}"
  echo "site-screenshots: $name (select: ${sel:-default})"
  seed_home
  if [ "$name" = map ]; then
    BRAHMA_SNAPSHOT_COMPANY=Initech snap "$name" "$sel"
  elif [ -n "$sel" ]; then
    snap "$name" "$sel"
  else
    snap "$name"
  fi
  [ -s ".superpowers/ui/$name.png" ] || { echo "site-screenshots: missing or empty snapshot: .superpowers/ui/$name.png" >&2; exit 1; }
done

node site/scripts/optimize-screenshots.mjs .superpowers/ui site/public/screenshots
