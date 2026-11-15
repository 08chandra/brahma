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
# Same for secrets: the seeded test key goes to a file vault in the temp home, never the login Keychain.
export BRAHMA_SECRET_STORE=file
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

# Agent map (Plan 4b): INITE-2 in progress with eng-1 as owner and the CTO as reviewer (a dashed reviewer line on the chart,
# `dev claim` takes the work lease as the agent), and one open ENGINEER seat under the CTO (an `OPEN · ENGINEER` card).
"$B" items edit Initech INITE-2 --owner eng-1 --reviewer cto --status ready >/dev/null
BRAHMA_DEV=1 "$B" dev claim Initech INITE-2 --by eng-1 >/dev/null
"$B" org vacancy add Initech --role engineer --manager cto --note "Backend, streaks service" >/dev/null

# Access Center (Plan 5-lite): a pending web_domain ask from @eng-1 on INITE-2, one active role grant (G-1) and one revoked
# grant (G-2), the test secret STRIPE_TEST_KEY (value in the dev file vault, BRAHMA_SECRET_STORE=file), and a stored digest.
BRAHMA_DEV=1 "$B" dev access Initech --by eng-1 --kind web_domain --value docs.stripe.com \
  --reason "Read the webhook signing docs for the reminder service" --item INITE-2 --scope item --duration sprint >/dev/null
BRAHMA_DEV=1 "$B" dev access Initech --by devops-1 --kind web_domain --value docs.github.com --reason "Actions reference" >/dev/null
"$B" access approve Initech A-4 --scope role --duration always --note "docs only" >/dev/null
BRAHMA_DEV=1 "$B" dev access Initech --by devops-1 --kind network_domain --value api.stripe.com --reason "Hit the test API" >/dev/null
"$B" access approve Initech A-5 --scope agent --duration sprint >/dev/null
"$B" grants revoke Initech G-2 >/dev/null
printf 'sk_test_51SeedOnlyNotARealKey0000\n' | "$B" secret set Initech STRIPE_TEST_KEY --test >/dev/null
BRAHMA_DEV=1 "$B" dev digest Initech >/dev/null

# Plan L: a web preview (python's http.server on the engine's port), a committed page on main, and hosting. The page is
# committed with the engine identity and then accepted through the engine (`main accept` records mainCommit, PR-31): a
# plain commit on main would otherwise trip the main guard.
"$B" preview set Initech web --run "python3 -m http.server {port} --bind 127.0.0.1" --url "http://127.0.0.1:{port}/" >/dev/null
cat >"$W/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Habit tracker</title></head>
<body><h1>Habit tracker</h1><p>Daily streaks, reminders and a weekly summary.</p></body></html>
HTML
git -C "$W" add index.html
git -C "$W" -c user.name=Brahma -c user.email=engine@brahma.local -c commit.gpgsign=false commit -q -m "Habit tracker landing page" >/dev/null
"$B" main accept Initech >/dev/null
"$B" hosting set Initech --provider cloudflare-pages --project initech-demo --account-id 0123456789abcdef0123456789abcdef >/dev/null

# Plan L Task 12 (BRAHMA_DEV=1 only): R-1 deployed and R-2 proposed through the real deploy path against the dev host (a
# folder under the data home served on loopback while the command runs; never a provider), plus two pending human tasks.
if [ "${BRAHMA_DEV:-}" = "1" ]; then
  "$B" dev release-scenario Initech --item INITE-2 --expect-text "Habit tracker" >/dev/null
fi
