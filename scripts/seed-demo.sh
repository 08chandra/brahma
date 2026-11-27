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
  --check "test -f streak.txt" --path streak.txt --description "Count consecutive days" >/dev/null
"$B" items add Initech --type bug --title "Reminder fires twice" --owner eng-1 --priority 1 >/dev/null

# Agent map (Plan 4b): INITE-3 in progress with eng-1 as owner and the CTO as reviewer (a dashed reviewer line on the chart,
# `dev claim` takes the work lease as the agent), and one open ENGINEER seat under the CTO (an `OPEN · ENGINEER` card).
# Not INITE-2: with BRAHMA_DEV=1 the release scenario below links a human task to INITE-2 and blocks it.
"$B" items edit Initech INITE-3 --reviewer cto --status ready --check "test -f reminder.txt" --path reminder.txt >/dev/null
BRAHMA_DEV=1 "$B" dev claim Initech INITE-3 --by eng-1 >/dev/null
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

# Plan 4a: a CLI demo (its sealed output is the DEMO tab's terminal; the engine runs it from main) and three artifacts published
# from the workspace, AR-1..AR-3 in this order (the UI snapshots rely on it). The fixtures are copied into docs/ first (fix 14);
# the clip is Task 9b's and is published only once it exists, so AR-1 and AR-2 keep their numbers either way.
for f in mock.html parts.csv clip-9x16.mp4; do
  [ -f "scripts/fixtures/$f" ] && cp "scripts/fixtures/$f" "$W/docs/$f"
done
"$B" preview set Initech demo --kind cli --demo "printf '\033[32mPASS\033[0m streaks\n'; ls" >/dev/null
"$B" artifacts publish Initech "$W/docs/mock.html" --title "Landing mock" >/dev/null
"$B" artifacts publish Initech "$W/docs/parts.csv" --title "Parts list" >/dev/null
if [ -f "$W/docs/clip-9x16.mp4" ]; then
  "$B" artifacts publish Initech "$W/docs/clip-9x16.mp4" --title "Launch reel" >/dev/null
fi

# Plan ML: Work › Resources — a note (FROM YOU), a PDF from outside (EXTERNAL, scoped to the engineering team) and a link.
D="$(mktemp -d)"
printf '# Habit tracker brand notes\n\nColors: teal and slate. Tone: calm, encouraging.\n' >"$D/brand-notes.md"
printf '%%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' >"$D/competitor-review.pdf"
"$B" resource Initech add "$D/brand-notes.md" >/dev/null
"$B" resource Initech add "$D/competitor-review.pdf" --scope team:engineering >/dev/null
"$B" resource Initech link "https://example.com/habit-research" >/dev/null
rm -rf "$D"

# Plan ML Task 8: the Handbook and memory. @cto owns INITE-4 and writes two Engineering pages through kb_write (one with an
# executives-only section, both linking back to kb:Engineering); @eng-1 remembers the checkout port twice under one key (the
# second contradicts the first) and, after reading a web page, a tainted fact. `dev tool` calls the agent tool directly.
"$B" items add Initech --type task --title "Checkout flow" --owner cto --description "Cart, payment and confirmation" >/dev/null
"$B" say Initech '#general' "The checkout page needs a retry when a payment fails" >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech kb_write --by cto --args '{"path":"Engineering/Environments","item":"INITE-4","body":"# Environments\n\nStaging and production for the habit tracker. Conventions live in [[Engineering]]; the checkout service is described in [[Engineering/Checkout service]].\n\n## Staging\n\nDeploys from main on every merge.\n\n## Credentials policy [restricted]\n\nKeys rotate monthly; only executives hold production keys.\n"}' >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech kb_write --by cto --args '{"path":"Engineering/Checkout service","item":"INITE-4","release":true,"body":"# Checkout service\n\nHandles checkout for the premium plan. Environments: [[Engineering/Environments]]. Conventions: [[Engineering]].\n"}' >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech remember --by eng-1 --args '{"fact":"The checkout service listens on port 4417 in staging","key":"checkout.port","scope":"company"}' >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech remember --by eng-1 --args '{"fact":"The checkout service listens on port 4418 in staging","key":"checkout.port","scope":"company"}' >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech remember --by eng-1 --taint "web page docs.stripe.com" --args '{"fact":"Stripe test cards start with 4242","key":"stripe.testcard"}' >/dev/null

# Plan ML Task 9: Replay — @eng-1 finishes a turn on INITE-3 (a Bash and a Read call, a captured transcript), posts in
# #general and comments on the item; the owner DMs it. `dev turn` records the turn and captures its transcript as a real one.
BRAHMA_DEV=1 "$B" dev turn Initech --by eng-1 --summary "Added the reminder scheduler; one test still flaky" \
  --prompt "Work on INITE-3: reminders fire twice" --say "Reading the scheduler first." \
  --say "The timer was registered on every launch; registering it once fixes the duplicate." --tool Read --tool Bash >/dev/null
"$B" say Initech @eng-1 "Is the duplicate reminder fixed?" >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech comment_work_item --by eng-1 --args '{"key":"INITE-3","text":"Scheduler registers once now; checking the flaky test."}' >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech post_message --by eng-1 --args '{"channel":"general","text":"Reminder fix is up for INITE-3."}' >/dev/null

# Plan ML Task 10: a research page written after reading the web (TAINTED, via `dev tool --taint`; @cto's session is
# tainted from here on, so it writes nothing else below), and the owner's DM drop to @eng-1 (scoped to @eng-1 alone and
# announced in the DM, as the app's DM drop zone does; the CLI's `resource add` has no conversation, hence `dev drop`).
BRAHMA_DEV=1 "$B" dev tool Initech kb_write --by cto --taint "web page example.com/habit-apps" --args '{"path":"Research/Competitors","item":"INITE-4","release":true,"body":"# Competitors\n\nThree habit apps lead the store: Streaks, Habitica and Loop. All three have daily streaks; none sends a weekly summary.\n"}' >/dev/null
D="$(mktemp -d)"
printf 'Standup notes for @eng-1\n\n- Reminder bug: the timer registers on every launch.\n- Pair with QA on the flaky test.\n' >"$D/standup-notes.txt"
BRAHMA_DEV=1 "$B" dev drop Initech --dm eng-1 --message "Notes from this morning's standup" "$D/standup-notes.txt" >/dev/null
rm -rf "$D"

# Plan 4a Task 10: the merge queue. The main check every candidate must pass, then `dev merge-scenario`: INITE-2 (claimed only
# for streak.txt, so it runs beside INITE-3's reminder.txt) is claimed, worked, submitted, checked and approved through the real
# tools and merged by the real queue (M-1, MERGED); a second item written on the old main that touches streak.txt too bounces
# on the conflict (M-2, BOUNCED) and is back with its holder. The app's merge snapshots (`merge`, `item:INITE-2`) rely on it.
# The queue lands nothing while the root checkout has uncommitted changes (3a quarantines them and waits for the owner), so the
# PRD and the fixtures left in docs/ go on main first: the owner's own commit (its identity is the owner's, never the engine's;
# `main accept` is what makes it the record), then `main accept`.
git -C "$W" add docs
git -C "$W" -c user.name=Owner -c user.email=owner@brahma.local -c commit.gpgsign=false commit -q -m "PRD and demo fixtures" >/dev/null
"$B" main accept Initech >/dev/null
"$B" merge settings Initech --main-check "test -f index.html" >/dev/null
"$B" items edit Initech INITE-2 --status ready >/dev/null
BRAHMA_DEV=1 "$B" dev merge-scenario Initech --item INITE-2 --file streak.txt >/dev/null

# Plan L Task 12 (BRAHMA_DEV=1 only): R-1 deployed and R-2 proposed through the real deploy path against the dev host (a
# folder under the data home served on loopback while the command runs; never a provider), plus two pending human tasks.
if [ "${BRAHMA_DEV:-}" = "1" ]; then
  "$B" dev release-scenario Initech --item INITE-2 --expect-text "Habit tracker" >/dev/null
fi

# Plan ML Task 10: one auto-page refresh now (the engine does it every 60 active seconds), so the generated pages (roster,
# org chart, release history, sprint summaries, decisions log) reflect everything seeded above.
BRAHMA_DEV=1 "$B" dev autopages Initech >/dev/null

# Plan C (C7b): sharing, a thread, a file ask, a company resource and a live CHANGES row. Every step goes through the real
# tools or the owner's Store calls the app uses: `dev tool` calls the agent tool directly (`share`, `read_channel`,
# `post_message`); `dev file-ask` is the app's "Ask for a file" (`Store.sendFileAsk`; no owner CLI for it); `resource add` is
# ML's owner drop. @devops-1 and @mgr-1 are untainted sessions (the tainted @eng-1 and @cto write nothing here).
# 1. An agent share: @devops-1 shares lines 1-20 of the landing page with #general (pinned at main's commit).
BRAHMA_DEV=1 "$B" dev tool Initech share --by devops-1 \
  --args '{"refs":["index.html:1-20"],"to":"#general","note":"The landing page header, for the mobile pass"}' >/dev/null
# 2. A diff share: @mgr-1 shares INITE-5's committed diff (the item the merge queue bounced, still leased by @mgr-1).
BRAHMA_DEV=1 "$B" dev tool Initech share --by mgr-1 \
  --args '{"refs":["INITE-5:diff"],"to":"#general","note":"INITE-5 bounced on streak.txt; here is its diff"}' >/dev/null
# 3. A three-message thread: the diff share is its root, two replies. Its msg:<id> is read back the way an agent reads it,
#    the newest message only (`limit: 1`): reading @eng-1's tainted post above would taint @mgr-1's session.
ROOT="$(BRAHMA_DEV=1 "$B" dev tool Initech read_channel --by mgr-1 --args '{"channel":"general","limit":1}' 2>/dev/null \
  | python3 -c 'import json,sys; print([m["id"] for m in json.load(sys.stdin) if m["sender"] == "@mgr-1"][-1])')"
BRAHMA_DEV=1 "$B" dev tool Initech post_message --by devops-1 \
  --args "{\"channel\":\"general\",\"reply_to\":\"$ROOT\",\"text\":\"streak.txt conflicts with the counter from INITE-2; rebase on main first?\"}" >/dev/null
BRAHMA_DEV=1 "$B" dev tool Initech post_message --by mgr-1 \
  --args "{\"channel\":\"general\",\"reply_to\":\"$ROOT\",\"text\":\"Yes: rebasing on main, then resubmitting.\"}" >/dev/null
# 4. The owner asks @devops-1 for a file (a fileAsk DM; it answers with share(..., reply_to) in that thread).
BRAHMA_DEV=1 "$B" dev file-ask Initech --to devops-1 --item INITE-2 "The build log from the last web preview run" >/dev/null
# 5. One owner-dropped company resource (the scope `resource add` gives a file from you: company).
D="$(mktemp -d)"
printf '# Launch checklist\n\n- Streaks count across midnight\n- Reminders fire once\n- The weekly summary lists every habit\n' >"$D/launch-checklist.md"
"$B" resource Initech add "$D/launch-checklist.md" >/dev/null
rm -rf "$D"
# 6. An uncommitted edit in a leased item worktree: @mgr-1's INITE-5, so the CHANGES tab has a live row with + and - lines.
WT="$W/.brahma/wt/INITE-5"
if [ -d "$WT" ]; then
  printf 'Weekly summary: habits done, streaks kept, reminders sent\n' >"$WT/streak-summary.txt"
  printf 'Summary layout\n\n- one row per habit\n- the longest streak first\n' >"$WT/summary-layout.md"
fi
