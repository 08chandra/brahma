#!/bin/bash
# Seeds BRAHMA_HOME with two demo companies. Refuses to touch the default data home.
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULT_HOME="$HOME/Library/Application Support/Brahma"
if [ -z "${BRAHMA_HOME:-}" ] || [ -z "${BRAHMA_WORKSPACES:-}" ] || [ "$BRAHMA_HOME" = "$DEFAULT_HOME" ]; then
  echo "set BRAHMA_HOME and BRAHMA_WORKSPACES to temp dirs" >&2
  exit 1
fi

B=.build/Brahma.app/Contents/Helpers/brahma
"$B" company create Acme --goal "Build a todo app"
"$B" company create Globex --goal "Plan a newsletter"
"$B" hire Acme ceo --role ceo --model opus
"$B" hire Acme cto --role cto --model sonnet
"$B" hire Acme eng1 --role engineer --model sonnet
"$B" hire Acme designer --role designer --model haiku
"$B" company mode Acme balanced
"$B" pause Acme eng1
"$B" company pause Globex
"$B" say Acme '#general' "@ceo please draft a plan and ask @cto for a stack"
"$B" say Acme @cto "What stack do you suggest?"
