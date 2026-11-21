#!/usr/bin/env bash
# Build the public website in site/: run the generators (when present), then
# install pinned dependencies, build and run the site checks.
#
# Usage: scripts/site-build.sh [--skip-generators] [--skip-lighthouse]
#
#   --skip-generators   skip the screenshot, CLI-reference and API-reference
#                       generators for fast content iteration. The built site
#                       then lacks their output; the link checker tolerates
#                       the missing /api/ reference only, and the generated-
#                       output check (which would fail by construction) is
#                       skipped with a warning.
#   --skip-lighthouse   skip `npm run check:lighthouse` (about three minutes;
#                       ten Lighthouse runs). The other checks still run.
set -euo pipefail
cd "$(dirname "$0")/.."

skip_generators=0
skip_lighthouse=0
for arg in "$@"; do
  case "$arg" in
    --skip-generators) skip_generators=1 ;;
    --skip-lighthouse) skip_lighthouse=1 ;;
    *)
      echo "site-build: unknown argument: $arg" >&2
      echo "usage: scripts/site-build.sh [--skip-generators] [--skip-lighthouse]" >&2
      exit 2
      ;;
  esac
done

# run_step <label> <command> [args…]: announce a step, run it, stop on failure.
run_step() {
  local label=$1
  shift
  echo "== $label"
  if ! "$@"; then
    echo "site-build: step failed: $label" >&2
    exit 1
  fi
}

generators=(
  scripts/site-screenshots.sh
  scripts/site-cli-docs.sh
  scripts/site-api-docs.sh
)

if [[ $skip_generators -eq 1 ]]; then
  echo "site-build: WARNING: --skip-generators set; screenshots, CLI reference and API reference are not regenerated" >&2
else
  for step in "${generators[@]}"; do
    if [[ -x "$step" ]]; then
      run_step "$step" "$step"
    fi
  done
fi

cd site
run_step "npm ci" npm ci
run_step "npx playwright install chromium" npx playwright install chromium
run_step "npm run og" npm run og
run_step "npm run build" npm run build
if [[ $skip_generators -eq 1 ]]; then
  echo "site-build: WARNING: --skip-generators set; skipping npm run check:generated" >&2
  run_step "npm run check:links" npm run check:links
  run_step "npm run check:forbidden" npm run check:forbidden
  run_step "npm run check:ui" npm run check:ui
else
  run_step "npm run check" npm run check
fi
if [[ $skip_lighthouse -eq 1 ]]; then
  echo "site-build: WARNING: --skip-lighthouse set; skipping npm run check:lighthouse" >&2
else
  run_step "npm run check:lighthouse" npm run check:lighthouse
fi
