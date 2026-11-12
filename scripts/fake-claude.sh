#!/bin/bash
# Test double for `claude -p`, used only by the smoke and UI-snapshot scripts. It drains the prompt, has the
# agent DM the owner through the real MCP helper, and prints the three stream-json lines StreamParser reads.
set -u

# `brahma doctor` / the app's startup check run these two first; answer like a minimal real claude at the doctor's
# minimum version (`Doctor.minimumVersion`), with every flag in `Doctor.requiredFlags` in its --help.
case "${1:-}" in
  --version) echo "2.1.312 (Claude Code)"; exit 0 ;;
  --help)
    for f in -p --output-format --verbose --resume --session-id --mcp-config --strict-mcp-config --model \
             --fallback-model --append-system-prompt --permission-mode --allowed-tools --disallowed-tools \
             --add-dir --settings --setting-sources --disable-slash-commands --effort --max-budget-usd \
             --restricted --tools --plugin-dir --permission-prompts; do
      echo "  $f <value>  fake"
    done
    exit 0 ;;
esac

# The doctor's mode-canary (no model call): `--input-format stream-json` plus control requests on stdin; answer
# initialize, get_settings and get_usage like a minimal real claude, echoing back the --model and --effort it was given.
case " $* " in
  *" --input-format stream-json "*)
    M=""; E=""; p=""
    for a in "$@"; do
      [ "$p" = "--model" ] && M="$a"
      [ "$p" = "--effort" ] && E="$a"
      p="$a"
    done
    while IFS= read -r line; do
      id="$(printf '%s' "$line" | sed -n 's/.*"request_id" *: *"\([^"]*\)".*/\1/p')"
      case "$line" in
        *'"initialize"'*) body='{"fast_mode_state":"off","agents":[{"name":"general-purpose"},{"name":"Explore"}]}' ;;
        *'"get_settings"'*) body="{\"applied\":{\"model\":\"$M\",\"effort\":\"$E\",\"ultracode\":false,\"advisor\":null},\"effective\":{\"disableWorkflows\":true,\"fastMode\":false}}" ;;
        *'"get_usage"'*) body='{"subscription_type":"max_5x"}' ;;
        *) continue ;;
      esac
      echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":$body}}"
    done
    exit 0 ;;
esac

PROMPT="$(cat)"

# Turns run with an allowlisted environment, so the smoke script's FAKE_CLAUDE_* settings arrive through this
# file in the data home (BRAHMA_HOME is one of the engine-set variables). The doctor's probe turns ignore it.
case "$PROMPT" in
  "Reply with the single word OK."|"Reply with the codeword only.") ;;
  *) if [ -n "${BRAHMA_HOME:-}" ] && [ -f "$BRAHMA_HOME/fake-claude.env" ]; then . "$BRAHMA_HOME/fake-claude.env"; fi ;;
esac

SID=""
MCP=""
SYSTEM=""
TOOLS_ARG=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --session-id|--resume) SID="$arg" ;;
    --mcp-config) MCP="$arg" ;;
    --append-system-prompt) SYSTEM="$arg" ;;
    --tools) TOOLS_ARG="$arg" ;;
  esac
  prev="$arg"
done

if [ -n "$MCP" ] && [ -f "$MCP" ] && plutil -extract mcpServers.company.command raw -o - "$MCP" >/dev/null 2>&1; then
  CMD="$(plutil -extract mcpServers.company.command raw -o - "$MCP")"
  # The server's environment comes from the MCP config's env entry, as claude would pass it to the server: the per-turn
  # token, and the dev home's file secret store (without it the server cannot load the home's secrets and refuses writes).
  for V in BRAHMA_TURN_TOKEN BRAHMA_SECRET_STORE BRAHMA_MCP_REVIEW_ITEM BRAHMA_MCP_AUDIT; do
    if VAL="$(plutil -extract "mcpServers.company.env.$V" raw -o - "$MCP" 2>/dev/null)"; then export "$V=$VAL"; fi
  done
  DB="$(plutil -extract mcpServers.company.args.2 raw -o - "$MCP")"
  COMPANY="$(plutil -extract mcpServers.company.args.4 raw -o - "$MCP")"
  AGENT="$(plutil -extract mcpServers.company.args.6 raw -o - "$MCP")"
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-claude","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_dm","arguments":{"to":"owner","text":"Acknowledged (fake turn)."}}}'
  } | "$CMD" mcp --db "$DB" --company "$COMPANY" --agent "$AGENT" >/dev/null 2>&1
fi

# FAKE_CLAUDE_SLEEP=<s> (set in $BRAHMA_HOME/fake-claude.env) keeps the turn in flight (smoke case E). On SIGTERM it lingers FAKE_CLAUDE_TERM_DELAY
# seconds (default 2) before exiting, like a real claude winding down, so the app's stop stays pending long
# enough for a second quit request to arrive during it. FAKE_CLAUDE_PIDFILE=<f> records the turn's pid.
if [ -n "${FAKE_CLAUDE_SLEEP:-}" ]; then
  if [ -n "${FAKE_CLAUDE_PIDFILE:-}" ]; then echo $$ >>"$FAKE_CLAUDE_PIDFILE"; fi
  sleep "$FAKE_CLAUDE_SLEEP" </dev/null >/dev/null 2>&1 &
  SLEEP_PID=$!
  trap 'kill "$SLEEP_PID" 2>/dev/null; sleep "${FAKE_CLAUDE_TERM_DELAY:-2}"; exit 143' TERM INT
  wait "$SLEEP_PID"
fi

# The doctor's resume check: the appended system prompt names a codeword and the second turn asks for it.
RESULT="fake turn done"
case "$PROMPT" in
  "Reply with the single word OK.") RESULT="OK" ;;
  "Reply with the codeword only.") RESULT="$(printf '%s' "$SYSTEM" | grep -Eo 'BRAHMA-PROBE-[0-9]+' | head -1)" ;;
esac

EPOCH=$(( $(date +%s) + 10800 ))
# The init event lists the session's built-in tools, as a real claude does: exactly the --tools it was given, else the
# Sandboxed profile's set (`BuiltinTools.sandboxed`), which the doctor's tools-present item checks for.
TOOLS='"Bash","Read","Edit","Write","NotebookEdit","Skill","ToolSearch","WebFetch","WebSearch"'
if [ -n "$TOOLS_ARG" ]; then TOOLS="\"$(printf '%s' "$TOOLS_ARG" | sed 's/,/","/g')\""; fi
echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$SID\",\"model\":\"fake\",\"agents\":[\"Explore\",\"general-purpose\"],\"tools\":[$TOOLS]}"
echo "{\"type\":\"rate_limit_event\",\"session_id\":\"$SID\",\"rate_limit_info\":{\"status\":\"allowed\",\"resetsAt\":$EPOCH,\"rateLimitType\":\"five_hour\",\"isUsingOverage\":false,\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.38,\"resetsAt\":$EPOCH},\"seven_day\":{\"utilization\":0.12,\"resetsAt\":$EPOCH}}}}"
echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"$RESULT\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"total_cost_usd\":0,\"api_error_status\":null,\"session_id\":\"$SID\"}"
