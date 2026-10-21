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

echo "SMOKE PASSED"
