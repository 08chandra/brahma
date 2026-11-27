#!/bin/bash
# The owner-run 72-hour soak of one company (Plan X6a Task 7). It runs the company for real: real agent turns, real usage.
#
#   BRAHMA_LIVE=1 scripts/soak/run-72h.sh <company> [--hours 72] [--kill-at <h>] [--state <dir>] [--resume]
#
# What it does:
#   - starts `brahma run` itself and records its pid in <state>/engine.pid (there is no engine service on this tree);
#   - keeps the Mac awake for its own lifetime (`caffeinate -i -w <this script>`);
#   - takes a checkpoint every hour: `brahma measure <co> --soak-checkpoint <state>/checkpoints/hNN.json`;
#   - at --kill-at (default 24) checks that the recorded pid's command line is `brahma run`, sends SIGKILL to that pid only
#     (a crash), starts `brahma run` again, and after the settle time runs `--soak-verify` against the hour's checkpoint;
#   - at hour 48 prints the reboot instruction and exits; after the reboot and login, `--resume` verifies against the last
#     checkpoint and carries on;
#   - at the end stops its engine (SIGTERM to that pid, after the same command-line check), prints `--mission` over the soak's
#     days and every verdict.
# It writes only under --state (default ~/.brahma-soak/<company>) and signals no process but the engine it started.
# Never run by tests (the suite only checks that it refuses without BRAHMA_LIVE=1).
set -euo pipefail

if [ "${BRAHMA_LIVE:-}" != "1" ]; then
    echo "run-72h.sh: refusing to start: a soak runs a real company with real agent turns for days, and that spends your plan's usage." >&2
    echo "run-72h.sh: set BRAHMA_LIVE=1 to confirm you want that, then run it again." >&2
    exit 3
fi

usage() {
    echo "usage: BRAHMA_LIVE=1 $0 <company> [--hours 72] [--kill-at <h>] [--state <dir>] [--resume]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
CO="$1"; shift
case "$CO" in -*|"") usage ;; esac
HOURS=72
KILL_AT=24
REBOOT_AT=48
STATE=""
RESUME=0
while [ $# -gt 0 ]; do
    case "$1" in
        --hours) [ $# -ge 2 ] || usage; HOURS="$2"; shift 2 ;;
        --kill-at) [ $# -ge 2 ] || usage; KILL_AT="$2"; shift 2 ;;
        --state) [ $# -ge 2 ] || usage; STATE="$2"; shift 2 ;;
        --resume) RESUME=1; shift ;;
        *) usage ;;
    esac
done
for n in "$HOURS" "$KILL_AT"; do
    case "$n" in ''|*[!0-9]*) echo "run-72h.sh: --hours and --kill-at take whole hours" >&2; exit 2 ;; esac
done
[ "$HOURS" -ge 1 ] || usage
[ -n "$STATE" ] || STATE="$HOME/.brahma-soak/$CO"
BRAHMA="${BRAHMA_BIN:-brahma}"
command -v "$BRAHMA" >/dev/null 2>&1 || { echo "run-72h.sh: '$BRAHMA' not found (set BRAHMA_BIN to the built brahma)" >&2; exit 2; }
command -v caffeinate >/dev/null 2>&1 || { echo "run-72h.sh: caffeinate not found (macOS only)" >&2; exit 2; }

# Wall seconds the engine runs before a verdict is asked for; the verdict itself waits (exit 3) until the engine has settled.
SETTLE=330
# How long a `wait` verdict is asked again before the soak records it as not settled.
VERIFY_PATIENCE=1800

mkdir -p "$STATE/checkpoints" "$STATE/verdicts"
chmod 700 "$STATE"
LOG="$STATE/soak.log"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

# The Mac stays awake while this script runs (idle sleep only; the owner's own sleep and the h48 reboot still happen).
caffeinate -i -w $$ &

# The recorded engine's pid, if that pid is still a `brahma run` (its command line checked), else nothing.
engine_pid() {
    local pid cmd
    [ -f "$STATE/engine.pid" ] || return 0
    pid="$(cat "$STATE/engine.pid")"
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
        *brahma\ run|*brahma\ run\ *) echo "$pid" ;;
        *) ;;
    esac
}

start_engine() {
    "$BRAHMA" run >>"$STATE/engine.log" 2>&1 &
    echo $! > "$STATE/engine.pid"
    sleep 5
    if [ -z "$(engine_pid)" ]; then
        # It exited at once: most often another engine (the Brahma app, another `brahma run`) holds the data home.
        log "brahma run exited at once; see $STATE/engine.log (quit the Brahma app or any other 'brahma run' first)"
        exit 2
    fi
    log "started brahma run (pid $(cat "$STATE/engine.pid"))"
}

# Waits until `pid` has exited, up to `seconds`; returns 1 if it is still there.
wait_gone() {
    local pid="$1" seconds="$2" i=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$i" -ge "$seconds" ] && return 1
        sleep 1; i=$((i + 1))
    done
    return 0
}

checkpoint() {
    local h file
    h="$(printf '%02d' "$1")"
    file="$STATE/checkpoints/h$h.json"
    if "$BRAHMA" measure "$CO" --soak-checkpoint "$file" >>"$LOG" 2>&1; then
        echo "$file" > "$STATE/last-checkpoint"
        log "checkpoint h$h written"
    else
        log "checkpoint h$h FAILED (see $LOG)"
    fi
}

# Asks for the verdict against `$1` until it is no longer `wait` (exit 3), then records it as `$2`.
verify() {
    local cp="$1" name="$2" out="$STATE/verdicts/$2.txt" waited=0 status
    sleep "$SETTLE"
    while :; do
        set +e
        "$BRAHMA" measure "$CO" --soak-verify "$cp" >"$out" 2>&1
        status=$?
        set -e
        [ "$status" -ne 3 ] && break
        [ "$waited" -ge "$VERIFY_PATIENCE" ] && break
        sleep 60; waited=$((waited + 60))
    done
    case "$status" in
        0) log "verdict $name: pass" ;;
        1) log "verdict $name: FAIL" ;;
        3) log "verdict $name: still waiting after $((SETTLE + VERIFY_PATIENCE)) s (the engine never settled)" ;;
        *) log "verdict $name: could not verify (exit $status)" ;;
    esac
}

# Sleeps until the soak's hour `$1` (wall time since the soak started), a minute at a time.
sleep_until_hour() {
    local due=$((START + $1 * 3600))
    while [ "$(date +%s)" -lt "$due" ]; do sleep 60; done
}

if [ "$RESUME" -eq 1 ]; then
    [ -f "$STATE/started-at" ] && [ -f "$STATE/hour" ] || { echo "run-72h.sh: nothing to resume in $STATE" >&2; exit 2; }
    START="$(cat "$STATE/started-at")"
    HOUR="$(cat "$STATE/hour")"
    log "resuming at hour $HOUR after the reboot"
    if [ -n "$(engine_pid)" ]; then log "an engine from before the reboot is still running (pid $(engine_pid))"; else start_engine; fi
    verify "$(cat "$STATE/last-checkpoint")" "reboot-h$HOUR"
else
    [ -f "$STATE/started-at" ] && { echo "run-72h.sh: $STATE already holds a soak; use --resume or another --state" >&2; exit 2; }
    START="$(date +%s)"
    echo "$START" > "$STATE/started-at"
    date -u +%Y-%m-%d > "$STATE/started-day"
    HOUR=0
    log "soak of $CO: $HOURS h, kill at h$KILL_AT, reboot at h$REBOOT_AT, state $STATE"
    [ -n "$(engine_pid)" ] || start_engine
    checkpoint 0
fi

while [ "$HOUR" -lt "$HOURS" ]; do
    HOUR=$((HOUR + 1))
    sleep_until_hour "$HOUR"
    echo "$HOUR" > "$STATE/hour"
    if [ -z "$(engine_pid)" ]; then
        # The engine died by itself: a crash the soak did not cause. Started again (what launchd would do) and judged.
        log "brahma run is gone at hour $HOUR without being killed; starting it again"
        start_engine
        verify "$(cat "$STATE/last-checkpoint")" "crash-h$HOUR"
    fi
    checkpoint "$HOUR"
    if [ "$HOUR" -eq "$KILL_AT" ]; then
        PID="$(engine_pid)"
        if [ -z "$PID" ]; then
            log "kill at h$HOUR skipped: the recorded pid is not a running 'brahma run'"
        else
            log "kill -9 $PID (brahma run) at h$HOUR"
            kill -KILL "$PID"
            wait_gone "$PID" 60 || log "pid $PID still there 60 s after SIGKILL"
            start_engine
            verify "$(cat "$STATE/last-checkpoint")" "kill-h$HOUR"
        fi
    fi
    if [ "$HOUR" -eq "$REBOOT_AT" ] && [ "$RESUME" -eq 0 ] && [ "$HOURS" -gt "$REBOOT_AT" ]; then
        log "hour $HOUR: reboot"
        echo "Reboot the Mac now, log in, and run: BRAHMA_LIVE=1 $0 $CO --resume --state $STATE"
        exit 0
    fi
done

PID="$(engine_pid)"
if [ -n "$PID" ]; then
    log "stopping brahma run (pid $PID) with SIGTERM"
    kill -TERM "$PID"
    wait_gone "$PID" 120 || log "pid $PID still there 120 s after SIGTERM; stop it yourself (Ctrl-C in its terminal or SIGTERM)"
fi
echo
echo "== mission =="
"$BRAHMA" measure "$CO" --mission --since "$(cat "$STATE/started-day")" || true
echo
echo "== verdicts =="
for v in "$STATE"/verdicts/*.txt; do
    [ -e "$v" ] || continue
    echo "-- $(basename "$v" .txt)"
    cat "$v"
done
