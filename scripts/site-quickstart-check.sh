#!/bin/bash
# Runs the quick start's shell files (site/src/content/quickstart/*.sh, the files /start renders verbatim) against the
# fake claude in a temp data home. Exit 0: every documented command works in this tree.
#
# The files are executed as they are, never edited: this script only wraps them (`bash -eu`, so any failing command
# fails its file; a temp PATH dir; env vars; a pseudo-terminal for `owner init`; `brahma run` in the background for 20 s). Usage: scripts/site-quickstart-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
Q="$REPO/site/src/content/quickstart"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

fail() { echo "QUICKSTART CHECK FAILED: $1" >&2; exit 1; }

for f in build.sh connect.sh first-company.sh run.sh watch.sh; do
  [ -f "$Q/$f" ] || fail "missing $Q/$f"
done

TMP="$(mktemp -d)"
RUN_PID=""
# Ctrl-C for run.sh: SIGINT to its child, `brahma run`. (A background job of a non-interactive shell ignores SIGINT, so
# signalling the `bash run.sh` wrapper itself would do nothing.)
stop_run() {
  pkill -INT -P "$RUN_PID" 2>/dev/null || true
}
cleanup() {
  if [ -n "$RUN_PID" ] && kill -0 "$RUN_PID" 2>/dev/null; then
    stop_run
    wait "$RUN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# A temp data home, never the default one. The file stores keep the owner-key hash and secrets in the temp home
# (dev/test only; the CLI refuses them for the default data home), so nothing touches the login Keychain.
export BRAHMA_HOME="$TMP/home"
export BRAHMA_WORKSPACES="$TMP/workspaces"
export BRAHMA_OWNER_KEY_STORE=file
export BRAHMA_SECRET_STORE=file
export BRAHMA_CLAUDE="$REPO/scripts/fake-claude.sh"
mkdir -p "$BRAHMA_HOME" "$BRAHMA_WORKSPACES"

# What the reader types: `brahma` and `claude` on PATH. Here they are this tree's debug build and the fake claude.
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$REPO/.build/debug/brahma" "$BIN/brahma"
ln -s "$BRAHMA_CLAUDE" "$BIN/claude"
export PATH="$BIN:$PATH"

# 1 · Install: build.sh runs from the repository root, as the reader does after cloning.
echo "== build.sh"
bash -eu "$Q/build.sh" || fail "build.sh exited $?"
[ -x "$REPO/.build/debug/brahma" ] || fail "build.sh did not produce .build/debug/brahma"

# 2 · Connect: `owner init` insists on an interactive terminal, so connect.sh runs under a pseudo-terminal.
# With the fake claude the doctor's sandbox items cannot pass (the canary needs a real model), so connect.sh exits 1;
# everything else the doctor checks must pass, and the only failures allowed are sandbox-* items.
echo "== connect.sh"
set +e
/usr/bin/script -q /dev/null bash -eu "$Q/connect.sh" </dev/null >"$TMP/connect.out" 2>&1
CONNECT=$?
set -e
tr -d '\r' <"$TMP/connect.out" >"$TMP/connect.txt"
cat "$TMP/connect.txt"
grep -Eq '[0-9]+\.[0-9]+\.[0-9]+ \(' "$TMP/connect.txt" || fail "connect.sh: claude --version printed nothing"
grep -q '^owner key created at ' "$TMP/connect.txt" || fail "connect.sh: owner init did not create the key"
for item in version flags probe resume-keeps-role tools-present mode-canary; do
  grep -Eq "^PASS +$item " "$TMP/connect.txt" || fail "connect.sh: doctor item $item did not pass"
done
if grep -E '^FAIL ' "$TMP/connect.txt" | grep -Ev '^FAIL +sandbox-' >/dev/null; then
  fail "connect.sh: the doctor failed an item other than the sandbox ones"
fi
[ "$CONNECT" -le 1 ] || fail "connect.sh exited $CONNECT"

# 3 · First company.
echo "== first-company.sh"
bash -eu "$Q/first-company.sh" | tee "$TMP/company.out" || fail "first-company.sh exited $?"
grep -q '^sent to #general' "$TMP/company.out" || fail "first-company.sh: the owner's message was not sent"

# TEST-ONLY step, not on the page: a new company runs Sandboxed, and a Sandboxed turn starts only after the sandbox
# canary passed for the claude that runs it. The fake claude runs no model, so it can never pass the canary (the same
# reason scripts/smoke-app.sh sets this). /start tells real readers the Sandboxed/canary truth instead.
brahma company profile Acme workspace

# 4 · Run: run.sh is `brahma run`, which stays in the foreground until Ctrl-C; here it runs in the background for 20 s,
# then watch.sh (what the reader runs in a second terminal) must show an agent's line.
echo "== run.sh (20 s)"
bash -eu "$Q/run.sh" >"$TMP/run.out" 2>&1 &
RUN_PID=$!
sleep 20
kill -0 "$RUN_PID" 2>/dev/null || { cat "$TMP/run.out"; fail "brahma run exited early"; }
echo "== watch.sh"
bash -eu "$Q/watch.sh" | tee "$TMP/watch.out" || fail "watch.sh exited $?"
stop_run
STATUS=0
wait "$RUN_PID" || STATUS=$?
RUN_PID=""
cat "$TMP/run.out"
[ "$STATUS" -eq 0 ] || fail "brahma run exited $STATUS after Ctrl-C"
grep -q 'turn succeeded' "$TMP/run.out" || fail "brahma run: no turn succeeded"
# An agent line: `HH:MM:SS @handle: text`, from an agent (not @owner). The fake turn DMs the owner.
grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} @[a-z0-9_-]+: ' "$TMP/watch.out" | grep -vq '^[0-9:]* @owner:' \
  || fail "watch.sh: no agent line in the log"

# Commands /start shows inline (in prose, not in a file) must exist in this tree.
for cmd in "canary edit" "canary run" "company profile" "inbox" "status" "log"; do
  # shellcheck disable=SC2086
  brahma help $cmd >/dev/null 2>&1 || fail "brahma $cmd does not exist"
done

echo "QUICKSTART CHECK PASSED"
