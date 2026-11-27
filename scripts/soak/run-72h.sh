#!/bin/bash
# The owner-run 72-hour soak of one company (Plan X6a Task 7). It runs the company for real: real agent turns, real usage.
#
#   BRAHMA_LIVE=1 scripts/soak/run-72h.sh <company> [--hours 72] [--kill-at <h>] [--state <dir>] [--resume]
#
# What it does:
#   - starts `brahma run` itself, in a process group of its own (so a Ctrl-C on this script never reaches the engine), and
#     records its pid and start time (<state>/engine.pid, engine.lstart); a process is treated as that engine only while both
#     match and its command line is `brahma run` (there is no engine service on this tree);
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
# The company names a directory under ~/.brahma-soak by default: no path separators, no parent references.
case "$CO" in -*|""|*/*|*..*) echo "run-72h.sh: the company must be a plain name or slug (no '/' or '..')" >&2; usage ;; esac
HOURS=72
KILL_AT=24
REBOOT_AT=48
STATE=""
RESUME=0
HOURS_GIVEN=0
KILL_GIVEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --hours) [ $# -ge 2 ] || usage; HOURS="$2"; HOURS_GIVEN=1; shift 2 ;;
        --kill-at) [ $# -ge 2 ] || usage; KILL_AT="$2"; KILL_GIVEN=1; shift 2 ;;
        --state) [ $# -ge 2 ] || usage; STATE="$2"; shift 2 ;;
        --resume) RESUME=1; shift ;;
        *) usage ;;
    esac
done
# Exits 2 unless `$2` is a whole number; `$1` names where it came from.
whole() {
    case "$2" in ''|*[!0-9]*) echo "run-72h.sh: $1 must be a whole number, not '$2'" >&2; exit 2 ;; esac
}
whole --hours "$HOURS"
whole --kill-at "$KILL_AT"
[ "$HOURS" -ge 1 ] || usage
[ -n "$STATE" ] || STATE="$HOME/.brahma-soak/$CO"
BRAHMA="${BRAHMA_BIN:-brahma}"
command -v "$BRAHMA" >/dev/null 2>&1 || { echo "run-72h.sh: '$BRAHMA' not found (set BRAHMA_BIN to the built brahma)" >&2; exit 2; }
command -v caffeinate >/dev/null 2>&1 || { echo "run-72h.sh: caffeinate not found (macOS only)" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "run-72h.sh: perl not found (it starts the engine in its own process group)" >&2; exit 2; }

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

# The recorded engine's pid, if that pid is still the process this script started: its command line is `brahma run` AND its
# start time is the one recorded with it (a recycled pid has another), else nothing.
engine_pid() {
    local pid cmd started
    [ -f "$STATE/engine.pid" ] && [ -f "$STATE/engine.lstart" ] || return 0
    pid="$(cat "$STATE/engine.pid")"
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    started="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
    [ -n "$started" ] && [ "$started" = "$(cat "$STATE/engine.lstart")" ] || return 0
    case "$cmd" in
        *brahma\ run|*brahma\ run\ *) echo "$pid" ;;
        *) ;;
    esac
}

# `brahma run` in a process group of its own: perl makes itself a group leader and execs the engine in place, so `$!` (perl's
# pid) is the engine's pid, and its start time is the one `ps` reads now. A Ctrl-C at the terminal signals the script's group
# only; the engine is stopped by the SIGTERM this script sends, or by the owner.
start_engine() {
    perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$BRAHMA" run >>"$STATE/engine.log" 2>&1 &
    echo $! > "$STATE/engine.pid"
    ps -o lstart= -p $! > "$STATE/engine.lstart" 2>/dev/null || true
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

# Ctrl-C or a TERM stops the soak, never the engine (it runs in its own process group, out of the terminal's reach): say what
# is left running and how to go on.
on_signal() {
    local pid
    pid="$(engine_pid)"
    if [ -n "$pid" ]; then
        log "soak script stopped by a signal; brahma run (pid $pid, its own process group) keeps running. Stop it with: kill -TERM $pid; or go on with --resume"
    else
        log "soak script stopped by a signal; no engine of this soak is running"
    fi
    exit 130
}
trap on_signal INT TERM

if [ "$RESUME" -eq 1 ]; then
    [ -f "$STATE/started-at" ] && [ -f "$STATE/hour" ] && [ -f "$STATE/params" ] && [ -f "$STATE/last-checkpoint" ] || { echo "run-72h.sh: nothing to resume in $STATE" >&2; exit 2; }
    START="$(cat "$STATE/started-at")"
    HOUR="$(cat "$STATE/hour")"
    whole "$STATE/started-at" "$START"
    whole "$STATE/hour" "$HOUR"
    # The run's own --hours and --kill-at, unless given again now. `read` fails on a file without a final newline: not fatal,
    # each value is checked on its own below.
    SAVED_HOURS=""; SAVED_KILL=""
    read -r SAVED_HOURS SAVED_KILL < "$STATE/params" || true
    [ "$HOURS_GIVEN" -eq 1 ] || HOURS="$SAVED_HOURS"
    [ "$KILL_GIVEN" -eq 1 ] || KILL_AT="$SAVED_KILL"
    whole "--hours (or the first number in $STATE/params)" "$HOURS"
    whole "--kill-at (or the second number in $STATE/params)" "$KILL_AT"
    [ "$HOURS" -ge 1 ] || usage
    log "resuming at hour $HOUR after the reboot ($HOURS h, kill at h$KILL_AT)"
    # A pid from before the reboot names nothing of ours now.
    rm -f "$STATE/engine.pid" "$STATE/engine.lstart"
    start_engine
    verify "$(cat "$STATE/last-checkpoint")" "reboot-h$HOUR"
else
    [ -f "$STATE/started-at" ] && { echo "run-72h.sh: $STATE already holds a soak; use --resume or another --state" >&2; exit 2; }
    # The start day in the owner's time zone (ownerSettings), the zone `--mission --since` reads; the system zone may differ.
    DAY="$("$BRAHMA" measure "$CO" --print-day)" || { echo "run-72h.sh: brahma measure $CO --print-day failed" >&2; exit 2; }
    case "$DAY" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo "run-72h.sh: brahma measure --print-day printed '$DAY', not a day" >&2; exit 2 ;;
    esac
    START="$(date +%s)"
    echo "$START" > "$STATE/started-at"
    echo "$HOURS $KILL_AT" > "$STATE/params"
    echo "$DAY" > "$STATE/started-day"
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
            kill -KILL "$PID" 2>/dev/null || log "pid $PID already gone"
            wait_gone "$PID" 60 || log "pid $PID still there 60 s after SIGKILL"
            start_engine
            verify "$(cat "$STATE/last-checkpoint")" "kill-h$HOUR"
        fi
    fi
    if [ "$HOUR" -eq "$REBOOT_AT" ] && [ "$RESUME" -eq 0 ] && [ "$HOURS" -gt "$REBOOT_AT" ]; then
        log "hour $HOUR: reboot"
        printf 'Reboot the Mac now, log in, and run: BRAHMA_LIVE=1 %q %q --resume --state %q\n' "$0" "$CO" "$STATE"
        exit 0
    fi
done

PID="$(engine_pid)"
if [ -n "$PID" ]; then
    log "stopping brahma run (pid $PID) with SIGTERM"
    kill -TERM "$PID" 2>/dev/null || log "pid $PID already gone"
    wait_gone "$PID" 120 || log "pid $PID still there 120 s after SIGTERM; stop it yourself: kill -TERM $PID"
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
