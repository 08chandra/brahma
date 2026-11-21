#!/bin/bash
# Builds a debug app and verifies it launches against a seeded temp home, hosts the engine, and coexists with `brahma run`.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/make-app.sh debug
TMP="$(mktemp -d)"
CLI_PID=""
APP_PID=""
cleanup() {
  [ -n "$CLI_PID" ] && kill -INT "$CLI_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
export BRAHMA_HOME="$TMP/home"
# Dev/demo only: keep the owner-key hash in the temp home so nothing here touches the login Keychain (a rebuilt
# ad-hoc-signed binary makes macOS ask for the login password on every Keychain access). The CLI and app refuse
# this for the default data home.
export BRAHMA_OWNER_KEY_STORE=file
export BRAHMA_SECRET_STORE=file
export BRAHMA_WORKSPACES="$TMP/workspaces"
export BRAHMA_CLAUDE="$PWD/scripts/fake-claude.sh"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
scripts/seed-demo.sh >/dev/null

APP=.build/Brahma.app/Contents/MacOS/Brahma
CLI=.build/Brahma.app/Contents/Helpers/brahma
# The lifecycle cases need @ceo's fake turn to run. A Sandboxed turn starts only after the sandbox canary passed for the claude
# that runs it (its fingerprint is in the canary key), and the canary's turn layer needs a real model to run the owner's
# probes: scripts/fake-claude.sh runs none, so it can never pass and a Sandboxed Acme would never take a turn here. Acme runs
# Workspace: this smoke checks the app; `brahma canary run` with a real claude checks the sandbox.
"$CLI" company profile Acme workspace >/dev/null
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$BRAHMA_CLAUDE" "$BIN/claude"

fail() { echo "SMOKE FAILED: $1" >&2; exit 1; }

# SMOKE_CASES=E,F runs only those cases (default: all). Every case stands alone on the seeded home.
want() { case ",${SMOKE_CASES:-A,B,C,D,E,F}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

start_cli() {
  PATH="$BIN:$PATH" "$CLI" run >"$TMP/cli.out" 2>&1 &
  CLI_PID=$!
}

stop_cli() {
  kill -INT "$CLI_PID"
  local status=0
  wait "$CLI_PID" || status=$?
  CLI_PID=""
  [ "$status" -eq 0 ] || fail "brahma run exited $status after SIGINT"
}

if want A; then
# (A) App embeds the engine; quitting pauses it; the bundled MCP helper path works end to end.
# The app is held until @ceo's fake-turn DM is in the log (a first launch after a clean build can take well over a fixed
# hold before the engine's first turn finishes), then released; 90 s is only the upper bound.
$APP --smoke-test --smoke-hold=90 --smoke-release="$TMP/release-a" >"$TMP/app-a.out" 2>&1 &
APP_PID=$!
START=$(date +%s)
SEEN=""
while kill -0 "$APP_PID" 2>/dev/null && [ $(( $(date +%s) - START )) -lt 80 ]; do
  if "$CLI" log Acme @ceo 2>/dev/null | grep -q 'Acknowledged (fake turn).'; then SEEN=1; break; fi
  sleep 0.2
done
touch "$TMP/release-a"
STATUS=0
wait "$APP_PID" || STATUS=$?
APP_PID=""
OUT="$(cat "$TMP/app-a.out")"
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case A exit $STATUS"
[ -n "$SEEN" ] || fail "case A: no fake-turn DM from @ceo within 80 s"
echo "$OUT" | grep -q '^SMOKE OK companies=3 agents=10 engine=embedded.* released=yes' || fail "case A: expected engine=embedded, released"
if "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running'; then fail "case A: agents still running after quit"; fi
"$CLI" log Acme @ceo | grep -q 'Acknowledged (fake turn).' || fail "case A: no fake-turn DM from @ceo"
echo "SMOKE OK case=A fake-turn-dm after $(( $(date +%s) - START ))s"
fi

if want B; then
# (B) A terminal engine holds the lock: the app shows it as external.
start_cli
sleep 2
set +e
OUT="$($APP --smoke-test)"
STATUS=$?
set -e
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case B exit $STATUS"
echo "$OUT" | grep -q '^SMOKE OK companies=3 agents=10 engine=external' || fail "case B: expected engine=external"
stop_cli
fi

if want C; then
# (C) The terminal engine stops while the app runs: the app takes over.
start_cli
sleep 1
$APP --smoke-test --smoke-hold=14 >"$TMP/app.out" 2>&1 &
APP_PID=$!
sleep 3
stop_cli
wait "$APP_PID" || fail "case C: app exited non-zero"
APP_PID=""
cat "$TMP/app.out"
grep -q '^SMOKE OK companies=3 agents=10 engine=embedded' "$TMP/app.out" || fail "case C: expected engine=embedded after takeover"
fi

if want D; then
# (D) Closing the main window keeps the app and engine alive in the menu bar; reopening restores the window.
set +e
OUT="$($APP --smoke-test --smoke-close-window --smoke-hold=2)"
STATUS=$?
set -e
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case D exit $STATUS"
echo "$OUT" | grep -q '^SMOKE OK companies=3 agents=10 engine=embedded.* lifecycle=ok$' || fail "case D: expected lifecycle=ok"
fi

# Starts the app with a lingering fake turn in flight (cases E and F) and waits until the fake claude has recorded its pid: it
# does so once it is lingering (after its MCP DM), so a SIGTERM before that would end it on the spot and prove nothing about the
# stop. Sets APP_PID and RUNNING.
start_lingering_turn() {
  local tag="$1"
  rm -f "$TMP/turn-$tag.pid"
  "$CLI" say Acme @ceo "Status update, please." >/dev/null
  # Turns get an allowlisted environment, so the fake claude reads its settings from this file in the data home.
  printf 'export FAKE_CLAUDE_SLEEP=60\nexport FAKE_CLAUDE_PIDFILE=%q\n' "$TMP/turn-$tag.pid" >"$BRAHMA_HOME/fake-claude.env"
  $APP --smoke-test --smoke-hold=120 >"$TMP/app-$tag.out" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 300); do
    [ -s "$TMP/turn-$tag.pid" ] && "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running' && break
    sleep 0.2
  done
  [ -s "$TMP/turn-$tag.pid" ] || fail "case $tag: fake turn recorded no pid"
  RUNNING="$("$CLI" status | grep -Eo '^  @[a-z0-9_-]+  running' | head -1 | awk '{print $1}')"
  [ -n "$RUNNING" ] || fail "case $tag: no turn in flight"
}

# After the app exited (cases E and F): the fake claude (its bash and its sleep) must be gone, no agent running, the turn interrupted.
check_turn_ended() {
  local tag="$1"
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fail "case $tag: app exited with claude child $pid alive"; fi
  done <"$TMP/turn-$tag.pid"
  if "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running'; then fail "case $tag: agents still running after quit"; fi
  "$CLI" status | grep -Eq "^  $RUNNING  .*last turn: interrupted" || fail "case $tag: $RUNNING's turn not recorded interrupted"
}

if want E; then
# (E) A second SIGTERM while the first quit is stopping the engine forces the exit (Task 9c): the turn's process group is
# killed (the engine's own records only), the turn is recorded interrupted, and the app is gone well inside the 10 s bound.
start_lingering_turn E
kill -TERM "$APP_PID"
sleep 0.1
kill -TERM "$APP_PID" 2>/dev/null || true
START=$(date +%s)
while kill -0 "$APP_PID" 2>/dev/null; do
  [ $(( $(date +%s) - START )) -le 10 ] || fail "case E: app still running 10 s after the second SIGTERM"
  sleep 0.2
done
wait "$APP_PID" || true
APP_PID=""
grep -q '^brahma: second quit request: ' "$TMP/app-E.out" || fail "case E: the app did not take the forced path"
check_turn_ended E
echo "SMOKE OK case=E double-sigterm exited=$(( $(date +%s) - START ))s agent=$RUNNING turn=interrupted"
fi

if want F; then
# (F) One SIGTERM quits through the graceful path (Task 9c fix round 1): the engine's bounded shutdown ends the turn (the fake
# claude lingers 2 s after SIGTERM) and the app exits inside the 10 s bound without the forced path and without the bound passing.
start_lingering_turn F
kill -TERM "$APP_PID"
START=$(date +%s)
while kill -0 "$APP_PID" 2>/dev/null; do
  [ $(( $(date +%s) - START )) -le 10 ] || fail "case F: app still running 10 s after SIGTERM"
  sleep 0.2
done
wait "$APP_PID" || true
APP_PID=""
if grep -q '^brahma: second quit request: ' "$TMP/app-F.out"; then fail "case F: the app took the forced path on one SIGTERM"; fi
if grep -q 'shutdown bound of .* passed' "$TMP/app-F.out"; then fail "case F: the shutdown ran out to its bound"; fi
check_turn_ended F
echo "SMOKE OK case=F single-sigterm exited=$(( $(date +%s) - START ))s agent=$RUNNING turn=interrupted"
fi

echo "SMOKE PASSED"
