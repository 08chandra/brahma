#!/bin/bash
# Test double for `claude -p`, used only by the smoke and UI-snapshot scripts. It drains the prompt, has the
# agent DM the owner through the real MCP helper, and prints the three stream-json lines StreamParser reads.
set -u

cat >/dev/null

SID=""
MCP=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --session-id|--resume) SID="$arg" ;;
    --mcp-config) MCP="$arg" ;;
  esac
  prev="$arg"
done

if [ -n "$MCP" ] && [ -f "$MCP" ]; then
  CMD="$(plutil -extract mcpServers.company.command raw -o - "$MCP")"
  DB="$(plutil -extract mcpServers.company.args.2 raw -o - "$MCP")"
  COMPANY="$(plutil -extract mcpServers.company.args.4 raw -o - "$MCP")"
  AGENT="$(plutil -extract mcpServers.company.args.6 raw -o - "$MCP")"
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-claude","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_dm","arguments":{"to":"owner","text":"Acknowledged (fake turn)."}}}'
  } | "$CMD" mcp --db "$DB" --company "$COMPANY" --agent "$AGENT" >/dev/null 2>&1
fi

# FAKE_CLAUDE_SLEEP=<s> keeps the turn in flight (smoke case E). On SIGTERM it lingers FAKE_CLAUDE_TERM_DELAY
# seconds (default 2) before exiting, like a real claude winding down, so the app's stop stays pending long
# enough for a second quit request to arrive during it. FAKE_CLAUDE_PIDFILE=<f> records the turn's pid.
if [ -n "${FAKE_CLAUDE_SLEEP:-}" ]; then
  if [ -n "${FAKE_CLAUDE_PIDFILE:-}" ]; then echo $$ >>"$FAKE_CLAUDE_PIDFILE"; fi
  sleep "$FAKE_CLAUDE_SLEEP" </dev/null >/dev/null 2>&1 &
  SLEEP_PID=$!
  trap 'kill "$SLEEP_PID" 2>/dev/null; sleep "${FAKE_CLAUDE_TERM_DELAY:-2}"; exit 143' TERM INT
  wait "$SLEEP_PID"
fi

EPOCH=$(( $(date +%s) + 10800 ))
echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$SID\",\"model\":\"fake\"}"
echo "{\"type\":\"rate_limit_event\",\"session_id\":\"$SID\",\"rate_limit_info\":{\"status\":\"allowed\",\"resetsAt\":$EPOCH,\"rateLimitType\":\"five_hour\",\"isUsingOverage\":false,\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.38,\"resetsAt\":$EPOCH},\"seven_day\":{\"utilization\":0.12,\"resetsAt\":$EPOCH}}}}"
echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"fake turn done\",\"total_cost_usd\":0,\"api_error_status\":null,\"session_id\":\"$SID\"}"
