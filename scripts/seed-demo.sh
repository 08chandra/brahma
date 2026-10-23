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
# Owner commands need an owner key; `owner init` insists on a terminal, so run it under a pseudo-terminal.
# BRAHMA_OWNER_KEY_STORE=file keeps the owner-key hash in the temp home (dev/demo only; refused for the default data
# home), so seeding never touches the login Keychain, which prompts for the password after every rebuild.
export BRAHMA_OWNER_KEY_STORE=file
if [ ! -f "$BRAHMA_HOME/owner.key" ]; then
  /usr/bin/script -q /dev/null "$B" owner init </dev/null >/dev/null
fi
"$B" company create Acme --goal "Build a todo app" --agents 0
"$B" company create Globex --goal "Plan a newsletter" --agents 0
"$B" hire Acme ceo --role ceo --model opus
"$B" hire Acme cto --role cto --model sonnet
"$B" hire Acme eng1 --role engineer --model sonnet
"$B" hire Acme designer --role designer --model haiku
"$B" company mode Acme balanced
"$B" pause Acme eng1
"$B" company pause Globex
"$B" say Acme '#general' "@ceo please draft a plan and ask @cto for a stack"
"$B" say Acme @cto "What stack do you suggest?"

# Initech: a 12-agent org with the work system seeded (asks need BRAHMA_DEV=1; auto-merge-small stays off).
"$B" company create Initech --goal "Build a habit tracker" --agents 12
W="$BRAHMA_WORKSPACES/initech"
if [ ! -d "$W" ]; then W="$(find "$BRAHMA_WORKSPACES" -maxdepth 1 -iname 'initech*' -type d | head -1)"; fi
mkdir -p "$W/docs"
cat >"$W/docs/prd.md" <<'DOC'
# Habit tracker PRD

Goals for the first release:

- Daily streaks per habit
- Reminders at a time you choose
- A weekly summary

Research notes live at [the shared notes](https://example.com/notes).
DOC
BRAHMA_DEV=1 "$B" dev propose Initech --by cpo --kind prd --title "Habit tracker PRD" --summary "Daily streaks, reminders" \
  --document docs/prd.md >/dev/null
BRAHMA_DEV=1 "$B" dev decide Initech A-1 --by ceo --approve >/dev/null
BRAHMA_DEV=1 "$B" dev propose Initech --by cto --kind other --category pricing --title "Freemium tier" \
  --summary "Free up to 3 habits" >/dev/null
BRAHMA_DEV=1 "$B" dev decide Initech A-2 --by ceo --approve >/dev/null
"$B" items add Initech --type epic --title "Streaks" --description "Daily streak tracking" >/dev/null
"$B" items add Initech --type task --title "Streak counter" --parent INITE-1 --tier s --priority 1 \
  --check "test -f streak.txt" --path . --description "Count consecutive days" >/dev/null
"$B" items add Initech --type bug --title "Reminder fires twice" --owner eng-1 --priority 1 >/dev/null
