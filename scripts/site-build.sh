#!/usr/bin/env bash
# Build the public website in site/: run the generators (when present), then
# install pinned dependencies, build and run the site checks.
#
# Usage: scripts/site-build.sh [--skip-generators]
#
#   --skip-generators   skip the screenshot, CLI-reference and API-reference
#                       generators for fast content iteration. The built site
#                       then lacks their output; the link checker tolerates
#                       the missing /api/ reference only.
set -euo pipefail
cd "$(dirname "$0")/.."

skip_generators=0
for arg in "$@"; do
  case "$arg" in
    --skip-generators) skip_generators=1 ;;
    *)
      echo "site-build: unknown argument: $arg" >&2
      echo "usage: scripts/site-build.sh [--skip-generators]" >&2
      exit 2
      ;;
  esac
done

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
      echo "== $step"
      if ! "$step"; then
        echo "site-build: step failed: $step" >&2
        exit 1
      fi
    fi
  done
fi

cd site
for step in "npm ci" "npm run build" "npm run check"; do
  echo "== $step"
  if ! $step; then
    echo "site-build: step failed: $step" >&2
    exit 1
  fi
done
