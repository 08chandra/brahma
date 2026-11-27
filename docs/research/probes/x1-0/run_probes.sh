#!/bin/bash
# X1-0 probe runner: runs `claude -p` against the loopback stub (stub_anthropic.py) behind the deny-all proxy
# (deny_proxy.py), one leg per behaviour, and leaves every leg's logs under logs/<leg>/:
#   cmd.txt       the argv and the environment variable NAMES (the token's value is never written)
#   status.txt    the exit status (124 = killed by `timeout 120`)
#   stdout.jsonl  claude's stream-json output
#   stderr.txt    claude's stderr
#   stub.log      the stub's request log (credential header values redacted by the stub itself)
#   deny.log      the deny proxy's log (every CONNECT / absolute-form request claude made to anything but the stub)
# Nothing here reads, copies or prints a credential; the default-config-dir legs (h*) only RUN the unmodified `claude`.
# Usage: run_probes.sh [logs-dir] [leg ...]   (no legs = all)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGS="${1:-$HERE/logs}"; shift || true
CLAUDE="${CLAUDE_BIN:-/Users/chandra/.local/bin/claude}"
TIMEOUT="${TIMEOUT_BIN:-/opt/homebrew/bin/timeout}"
PY=/usr/bin/env
mkdir -p "$LOGS"
TOKEN="$(python3 -I -c 'import secrets; print(secrets.token_hex(32))')"   # 64 lowercase hex chars, generated at runtime
PROMPT="Reply with exactly: ok"

start_servers() {  # $1 leg dir, rest: stub args
  local dir="$1"; shift
  rm -f "$dir/stub.port" "$dir/deny.port"
  python3 -I "$HERE/stub_anthropic.py" --log "$dir/stub.log" --port-file "$dir/stub.port" "$@" >"$dir/stub.out" 2>&1 &
  STUB_PID=$!
  python3 -I "$HERE/deny_proxy.py" --log "$dir/deny.log" --port-file "$dir/deny.port" >"$dir/deny.out" 2>&1 &
  DENY_PID=$!
  for _ in $(seq 1 50); do [ -s "$dir/stub.port" ] && [ -s "$dir/deny.port" ] && break; sleep 0.1; done
  SPORT="$(cat "$dir/stub.port")"; DPORT="$(cat "$dir/deny.port")"
}

stop_servers() {
  kill "$STUB_PID" "$DENY_PID" 2>/dev/null
  wait "$STUB_PID" "$DENY_PID" 2>/dev/null
}

# run_claude <leg dir> <config: fresh|default> <with-key: yes|no> <base-url> [extra claude args...]
# Extra environment comes in EXTRA_ENV (array of NAME=VALUE).
run_claude() {
  local dir="$1" config="$2" withkey="$3" base="$4"; shift 4
  local cwd="$dir/cwd"; mkdir -p "$cwd"; echo "hello from the probe cwd" >"$cwd/hello.txt"
  local -a env=(
    "PATH=/Users/chandra/.local/bin:/usr/bin:/bin"
    "HOME=$HOME" "USER=${USER:-chandra}" "LOGNAME=${USER:-chandra}" "LANG=en_US.UTF-8" "TERM=dumb" "TMPDIR=$dir/tmp"
    "HTTPS_PROXY=http://127.0.0.1:$DPORT" "HTTP_PROXY=http://127.0.0.1:$DPORT"
    "https_proxy=http://127.0.0.1:$DPORT" "http_proxy=http://127.0.0.1:$DPORT"
    "NO_PROXY=127.0.0.1,localhost" "no_proxy=127.0.0.1,localhost"
  )
  mkdir -p "$dir/tmp"
  [ -n "$base" ] && env+=("ANTHROPIC_BASE_URL=$base")
  [ "$withkey" = yes ] && env+=("ANTHROPIC_API_KEY=$TOKEN")
  if [ "$config" = fresh ]; then mkdir -p "$dir/cfg"; env+=("CLAUDE_CONFIG_DIR=$dir/cfg"); fi
  env+=("${EXTRA_ENV[@]:-}")
  local -a args=(-p "$PROMPT" --output-format stream-json --verbose "$@")
  {
    echo "cwd: $cwd"
    echo "config: $config   api-key: $withkey (64-hex runtime token, value not recorded)   base: ${base:-<unset>}"
    echo "argv: claude ${args[*]}"
    echo "env names:"
    for e in "${env[@]}"; do
      [ -n "$e" ] || continue
      if [ "${e%%=*}" = ANTHROPIC_API_KEY ]; then echo "  ANTHROPIC_API_KEY (redacted)"; else echo "  $e"; fi
    done
  } >"$dir/cmd.txt"
  local -a clean=(); for e in "${env[@]}"; do [ -n "$e" ] && clean+=("$e"); done
  ( cd "$cwd" && "$TIMEOUT" 120 env -i "${clean[@]}" "$CLAUDE" "${args[@]}" >"$dir/stdout.jsonl" 2>"$dir/stderr.txt" )
  local st=$?
  echo "$st" >"$dir/status.txt"
  echo "[$(date +%H:%M:%S)] $(basename "$dir"): exit $st; stub requests: $(grep -c '"method"' "$dir/stub.log" 2>/dev/null || echo 0); deny requests: $(grep -c '"method"' "$dir/deny.log" 2>/dev/null || echo 0)"
}

leg() {  # leg <name> <stub args...> -- <config> <withkey> <base-or-ROOT|PREFIX|NONE> [claude args...]
  local name="$1"; shift
  local -a stubargs=(); while [ "$1" != "--" ]; do stubargs+=("$1"); shift; done; shift
  local config="$1" withkey="$2" basekind="$3"; shift 3
  local dir="$LOGS/$name"; rm -rf "$dir"; mkdir -p "$dir"
  start_servers "$dir" "${stubargs[@]}"
  local base
  case "$basekind" in
    ROOT) base="http://127.0.0.1:$SPORT" ;;
    PREFIX) base="http://127.0.0.1:$SPORT/t/" ;;
    INVALID) base="http://stub.invalid:1/" ;;
    NONE) base="" ;;
    *) base="$basekind" ;;
  esac
  run_claude "$dir" "$config" "$withkey" "$base" "$@"
  stop_servers
}

session_id() { python3 -I -c '
import json,sys
for line in open(sys.argv[1], encoding="utf-8"):
    try: o=json.loads(line)
    except Exception: continue
    if o.get("type")=="system" and o.get("subtype")=="init" and o.get("session_id"): print(o["session_id"]); break
' "$1"; }

want() { [ $# -eq 0 ] && return 0; for w in "$@"; do [ "$w" = "$LEG" ] && return 0; done; return 1; }
ALL=(a1 a2 b c d e f1 f2 f3 g tool j k2 k3 i h1 h2 h3 h4 cb h1b h2b h3b h4b)
NONESSENTIAL_OFF=("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
for LEG in "${ALL[@]}"; do
  want "$@" || continue
  EXTRA_ENV=()
  case "$LEG" in
    a1) leg a1 --mode ok -- fresh yes ROOT ;;
    a2) leg a2 --mode ok -- fresh yes PREFIX ;;
    b)  EXTRA_ENV=("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"); leg b --mode ok -- fresh yes PREFIX ;;
    c)  leg c --mode 429 -- fresh yes PREFIX ;;
    d)  leg d --mode 400 -- fresh yes PREFIX ;;
    e)  leg e --mode 401 -- fresh yes PREFIX ;;
    f1) EXTRA_ENV=("ANTHROPIC_DEFAULT_HAIKU_MODEL=brahma-fast" "ANTHROPIC_DEFAULT_SONNET_MODEL=brahma-standard" "ANTHROPIC_DEFAULT_OPUS_MODEL=brahma-deep")
        leg f1 --mode ok -- fresh yes PREFIX --model brahma-standard --fallback-model brahma-standard ;;
    f2) leg f2 --mode ok -- fresh yes PREFIX --model brahma-standard ;;
    f3) EXTRA_ENV=("ANTHROPIC_DEFAULT_HAIKU_MODEL=brahma-fast" "ANTHROPIC_DEFAULT_SONNET_MODEL=brahma-standard" "ANTHROPIC_DEFAULT_OPUS_MODEL=brahma-deep")
        leg f3 --mode ok -- fresh yes PREFIX ;;
    g)  leg g --mode ok -- fresh yes INVALID ;;
    tool) leg tool --mode tool-first -- fresh yes PREFIX ;;
    j)  leg j --mode ok --ratelimit-headers -- fresh yes PREFIX ;;
    k2) leg k2 --mode ok --sse-deviation no-message-stop -- fresh yes PREFIX ;;
    k3) leg k3 --mode ok --sse-deviation done-first -- fresh yes PREFIX ;;
    i)  # two runs, same cwd and config dir: the second resumes the first's session
        dir="$LOGS/i"; rm -rf "$dir"; mkdir -p "$dir/run1" "$dir/run2"
        start_servers "$dir/run1" --mode ok
        run_claude "$dir/run1" fresh yes "http://127.0.0.1:$SPORT/t/"
        stop_servers
        SID="$(session_id "$dir/run1/stdout.jsonl")"; echo "session: ${SID:-<none>}" >"$dir/session.txt"
        if [ -n "$SID" ]; then
          start_servers "$dir/run2" --mode ok
          rm -rf "$dir/run2/cwd" "$dir/run2/cfg"; ln -s "$dir/run1/cwd" "$dir/run2/cwd"; ln -s "$dir/run1/cfg" "$dir/run2/cfg"
          run_claude "$dir/run2" fresh yes "http://127.0.0.1:$SPORT/t/" --resume "$SID"
          stop_servers
        fi ;;
    h1) leg h1 --mode ok -- default yes PREFIX ;;
    h2) leg h2 --mode ok -- default no PREFIX ;;
    h3) leg h3 --mode 401 -- default yes PREFIX ;;
    h4) leg h4 --mode 429 -- default yes PREFIX ;;
    # The same with the non-essential traffic switch (the stop-rule legs): does any CONNECT remain?
    cb)  EXTRA_ENV=("${NONESSENTIAL_OFF[@]}"); leg cb --mode 429 -- fresh yes PREFIX ;;
    h1b) EXTRA_ENV=("${NONESSENTIAL_OFF[@]}"); leg h1b --mode ok -- default yes PREFIX ;;
    h2b) EXTRA_ENV=("${NONESSENTIAL_OFF[@]}"); leg h2b --mode ok -- default no PREFIX ;;
    h3b) EXTRA_ENV=("${NONESSENTIAL_OFF[@]}"); leg h3b --mode 401 -- default yes PREFIX ;;
    h4b) EXTRA_ENV=("${NONESSENTIAL_OFF[@]}"); leg h4b --mode 429 -- default yes PREFIX ;;
  esac
done
echo "done: $LOGS"
