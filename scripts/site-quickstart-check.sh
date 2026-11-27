#!/bin/bash
# Runs the quick start's shell files (site/src/content/quickstart/*.sh, the files /start renders verbatim) against the
# fake claude in a temp data home. Exit 0: every documented command works in this tree.
#
# The files are executed as they are, never edited: this script only wraps them (`bash -eu`, so any failing command
# fails its file; env vars; a pseudo-terminal for `owner init`; `brahma run` in the background for 20 s).
#
# PATH is the reader's: `brahma` is never put on it by this script. Steps 1-4 share one terminal, so the files after
# build.sh get the PATH build.sh leaves behind; watch.sh runs in a fresh second terminal and must find `brahma` itself.
# Usage: scripts/site-quickstart-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
Q="$REPO/site/src/content/quickstart"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

fail() { echo "QUICKSTART CHECK FAILED: $1" >&2; exit 1; }

for f in build.sh connect.sh first-company.sh run.sh watch.sh; do
  [ -f "$Q/$f" ] || fail "missing $Q/$f"
done

# Under /tmp, not $TMPDIR: the sandbox refuses a data home inside the per-user temp folder it protects, which would
# fail the doctor's sandbox-backend item for a reason no reader has.
TMP="$(mktemp -d /tmp/brahma-qs.XXXXXX)"
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

# A fresh terminal's PATH: the system directories and `claude` (here the fake). No `brahma`.
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$BRAHMA_CLAUDE" "$BIN/claude"
FRESH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$FRESH" command -v brahma >/dev/null; then fail "a brahma is already on the system PATH; the check cannot tell"; fi

# 1 · Install: build.sh runs from the repository root, as the reader does after cloning. It runs in a shell that then
# reports its PATH: what the reader's first terminal holds for steps 2-4.
echo "== build.sh"
PATH="$FRESH" bash -eu -c '. "$1"; printf "%s" "$PATH" >"$2"' build.sh "$Q/build.sh" "$TMP/term1.path" \
  || fail "build.sh exited $?"
TERM1="$(cat "$TMP/term1.path")"
[ "$(PATH="$TERM1" command -v brahma)" = "$REPO/.build/debug/brahma" ] \
  || fail "after build.sh, brahma is not this tree's .build/debug/brahma"

# 2 · Connect: `owner init` insists on an interactive terminal, so connect.sh runs under a pseudo-terminal.
# The doctor must report no failure. Its canary items only warn here (no probe lines yet, as for a new reader), and
# are not required to pass: the canary's second layer needs a real model, which the fake claude does not run.
echo "== connect.sh"
set +e
PATH="$TERM1" /usr/bin/script -q /dev/null bash -eu "$Q/connect.sh" </dev/null >"$TMP/connect.out" 2>&1
CONNECT=$?
set -e
tr -d '\r' <"$TMP/connect.out" >"$TMP/connect.txt"
cat "$TMP/connect.txt"
grep -Eq '[0-9]+\.[0-9]+\.[0-9]+ \(' "$TMP/connect.txt" || fail "connect.sh: claude --version printed nothing"
grep -q '^owner key created at ' "$TMP/connect.txt" || fail "connect.sh: owner init did not create the key"
for item in version flags probe resume-keeps-role tools-present sandbox-backend mode-canary; do
  grep -Eq "^PASS +$item " "$TMP/connect.txt" || fail "connect.sh: doctor item $item did not pass"
done
if grep -Eq '^FAIL ' "$TMP/connect.txt"; then fail "connect.sh: the doctor reported a failure"; fi
[ "$CONNECT" -eq 0 ] || fail "connect.sh exited $CONNECT"

# 3 · First company.
echo "== first-company.sh"
PATH="$TERM1" bash -eu "$Q/first-company.sh" | tee "$TMP/company.out" || fail "first-company.sh exited $?"
# The file's comment says "five agents and one open seat".
grep -q '^hired 5 of 6; 1 seats vacant' "$TMP/company.out" || fail "first-company.sh: the default org is not 5 of 6 seats"
grep -q '^sent to #general' "$TMP/company.out" || fail "first-company.sh: the owner's message was not sent"

# TEST-ONLY step, not on the page: a new company runs Sandboxed, and a Sandboxed turn starts only after the sandbox
# canary passed for the claude that runs it. The fake claude runs no model, so it can never pass the canary (the same
# reason scripts/smoke-app.sh sets this). /start tells real readers the Sandboxed/canary truth instead.
PATH="$TERM1" brahma company profile Acme workspace

# 4 · Run: run.sh is `brahma run`, which stays in the foreground until Ctrl-C; here it runs in the background for 20 s,
# then watch.sh, which the reader runs in a fresh second terminal (no `brahma` on PATH), must show an agent's line.
echo "== run.sh (20 s)"
PATH="$TERM1" bash -eu "$Q/run.sh" >"$TMP/run.out" 2>&1 &
RUN_PID=$!
sleep 20
kill -0 "$RUN_PID" 2>/dev/null || { cat "$TMP/run.out"; fail "brahma run exited early"; }
echo "== watch.sh"
PATH="$FRESH" bash -eu "$Q/watch.sh" | tee "$TMP/watch.out" || fail "watch.sh exited $?"
stop_run
STATUS=0
wait "$RUN_PID" || STATUS=$?
RUN_PID=""
cat "$TMP/run.out"
[ "$STATUS" -eq 0 ] || fail "brahma run exited $STATUS after Ctrl-C"
grep -q 'turn succeeded' "$TMP/run.out" || fail "brahma run: no turn succeeded"
# An agent line: `HH:MM:SS @handle: text`, from an agent (not @owner). The fake turn DMs the owner.
grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} @[a-z0-9_-]+: ' "$TMP/watch.out" | grep -v '^[0-9:]* @owner:' >/dev/null \
  || fail "watch.sh: no agent line in the log"

# Commands /start shows outside the files (the canary block and prose) must exist in this tree. `brahma help` exits 0
# even for an unknown subcommand, so the test is its USAGE line.
for cmd in "canary edit" "canary run" "company profile"; do
  # shellcheck disable=SC2086
  PATH="$TERM1" brahma help $cmd 2>&1 | grep "^USAGE: brahma $cmd" >/dev/null || fail "brahma $cmd does not exist"
done

echo "QUICKSTART CHECK PASSED"
