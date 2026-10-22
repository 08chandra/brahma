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
export BRAHMA_WORKSPACES="$TMP/workspaces"
export BRAHMA_CLAUDE="$PWD/scripts/fake-claude.sh"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"
scripts/seed-demo.sh >/dev/null

APP=.build/Brahma.app/Contents/MacOS/Brahma
CLI=.build/Brahma.app/Contents/Helpers/brahma
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$BRAHMA_CLAUDE" "$BIN/claude"

fail() { echo "SMOKE FAILED: $1" >&2; exit 1; }

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

# (A) App embeds the engine; quitting pauses it; the bundled MCP helper path works end to end.
set +e
OUT="$($APP --smoke-test --smoke-hold=8)"
STATUS=$?
set -e
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case A exit $STATUS"
echo "$OUT" | grep -q '^SMOKE OK companies=2 agents=4 engine=embedded' || fail "case A: expected engine=embedded"
if "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running'; then fail "case A: agents still running after quit"; fi
"$CLI" log Acme @ceo | grep -q 'Acknowledged (fake turn).' || fail "case A: no fake-turn DM from @ceo"

# (B) A terminal engine holds the lock: the app shows it as external.
start_cli
sleep 2
set +e
OUT="$($APP --smoke-test)"
STATUS=$?
set -e
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case B exit $STATUS"
echo "$OUT" | grep -q '^SMOKE OK companies=2 agents=4 engine=external' || fail "case B: expected engine=external"
stop_cli

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
grep -q '^SMOKE OK companies=2 agents=4 engine=embedded' "$TMP/app.out" || fail "case C: expected engine=embedded after takeover"

# (D) Closing the main window keeps the app and engine alive in the menu bar; reopening restores the window.
set +e
OUT="$($APP --smoke-test --smoke-close-window --smoke-hold=2)"
STATUS=$?
set -e
echo "$OUT"
[ "$STATUS" -eq 0 ] || fail "case D exit $STATUS"
echo "$OUT" | grep -q '^SMOKE OK companies=2 agents=4 engine=embedded.* lifecycle=ok$' || fail "case D: expected lifecycle=ok"

# (E) A second SIGTERM while the first quit is stopping the engine must not skip the bounded stop.
"$CLI" say Acme @ceo "Status update, please." >/dev/null
# Turns get an allowlisted environment, so the fake claude reads its settings from this file in the data home.
printf 'export FAKE_CLAUDE_SLEEP=60\nexport FAKE_CLAUDE_PIDFILE=%q\n' "$TMP/turn-e.pid" >"$BRAHMA_HOME/fake-claude.env"
$APP --smoke-test --smoke-hold=120 >"$TMP/app-e.out" 2>&1 &
APP_PID=$!
for _ in $(seq 1 100); do
  "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running' && break
  sleep 0.2
done
RUNNING="$("$CLI" status | grep -Eo '^  @[a-z0-9_-]+  running' | head -1 | awk '{print $1}')"
[ -n "$RUNNING" ] || fail "case E: no turn in flight"
kill -TERM "$APP_PID"
sleep 0.1
kill -TERM "$APP_PID" 2>/dev/null || true
START=$(date +%s)
while kill -0 "$APP_PID" 2>/dev/null; do
  [ $(( $(date +%s) - START )) -le 15 ] || fail "case E: app still running 15 s after SIGTERM"
  sleep 0.2
done
wait "$APP_PID" || true
APP_PID=""
# The bounded stop waits for the turn's process; an early exit would leave the fake claude still lingering.
[ -s "$TMP/turn-e.pid" ] || fail "case E: fake turn recorded no pid"
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fail "case E: app exited with claude child $pid alive"; fi
done <"$TMP/turn-e.pid"
if "$CLI" status | grep -Eq '^  @[a-z0-9_-]+  running'; then fail "case E: agents still running after quit"; fi
"$CLI" status | grep -Eq "^  $RUNNING  .*last turn: interrupted" || fail "case E: $RUNNING's turn not recorded interrupted"
echo "SMOKE OK case=E double-sigterm exited=$(( $(date +%s) - START ))s agent=$RUNNING turn=interrupted"

echo "SMOKE PASSED"
