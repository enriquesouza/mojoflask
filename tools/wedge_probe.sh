#!/bin/sh
# wedge_probe.sh — regression probe for the parent-side connection-distribution
# wedge reported by QA after a ~160-request paced capture followed by a burst.
#
# Mechanism under test (root cause, see v0.7.0 release notes):
#   Every mojoflask socket is BLOCKING (no fcntl reachable via variadic FFI).
#   The supervised acceptor therefore has exactly two ways to freeze the WHOLE
#   tree while the listen port stays open: parking inside accept() past the
#   last pending connect, or parking inside sendmsg(SCM_RIGHTS) onto a
#   socketpair whose worker stopped draining. This probe forces the second
#   condition deterministically: phase 1 replays the paced sequential capture,
#   phase 2 SIGSTOPs one worker (its pair stops draining; same observable as a
#   worker wedged in a synchronous database call or a zero-window peer) while
#   wrk floods fresh connections at high reconnect rate, and phase 3 samples
#   a canary URL continuously. A healthy engine answers canary probes
#   throughout (other 15 workers keep draining); the defect serves nothing
#   until the stalled process resumes, even though the port still listens.
#
# Usage: sh tools/wedge_probe.sh [binary]   (default ./bench_echo)
# Env:   WEDGE_PORT (18197) · WEDGE_WORKERS (16) · BURST_SECS (15)
set -u

PORT=${WEDGE_PORT:-18197}
WORKERS=${WEDGE_WORKERS:-16}
BURST_SECS=${BURST_SECS:-15}
SEQ_REQS=${SEQ_REQS:-160}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$HERE/bench_echo}"
[ -x "$BIN" ] || { echo "no binary: $BIN (build first)" >&2; exit 1; }
OUT=/tmp/wedge_probe_$$.txt

stop_tree() {
    pkill -CONT -f "$BIN" 2>/dev/null
    pkill -9 -f "$BIN" 2>/dev/null
    sleep 0.5
}

wait_up() {
    i=0
    while [ $i -lt 150 ]; do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && return 0
        sleep 0.2; i=$((i+1))
    done
    echo "server never came up" >&2; return 1
}

# --- phase 1: paced sequential mixed keep-alive (the capture replay) --------
paced_capture() {
    n=0
    while [ "$n" -lt "$SEQ_REQS" ]; do
        if [ $((n % 2)) -eq 0 ]; then HC="Connection: close"; else HC="Connection: keep-alive"; fi
        curl -s -o /dev/null --max-time 2 -H "$HC" "http://127.0.0.1:$PORT/echo-static"
        curl -s -o /dev/null --max-time 2 -H "$HC" "http://127.0.0.1:$PORT/echo-dyn"
        n=$((n+2)); sleep 0.04
    done
}

stop_tree
MOJOFLASK_PORT=$PORT MOJOFLASK_WORKERS=$WORKERS "$BIN" >/tmp/wedge_server.log 2>&1 &
SPID=$!
if ! wait_up; then stop_tree; exit 1; fi
VICTIM=$(pgrep -P "$SPID" | head -1)
echo "== wedge_probe bin=$(basename "$BIN") port=$PORT workers=$WORKERS victim_pid=$VICTIM =="

paced_capture
echo "phase1 paced capture done (${SEQ_REQS} reqs)"

# --- phase 2+3: stall one worker, burst fresh connects, watch the canary ----
kill -STOP "$VICTIM"
(
    wrk -t4 -c200 -d"${BURST_SECS}s" -H 'Connection: close' \
        "http://127.0.0.1:$PORT/echo-static" >"$OUT.wrk" 2>&1
) &
BPID=$!
START=$(date +%s)
CONSEC=0 MAX_DARK=0 DARK_TOTAL=0 LAST_OK=$START PROBES=0 FAILTOTAL=0 END=$((START + BURST_SECS + 5))
while [ "$(date +%s)" -lt "$END" ]; do
    NOW=$(date +%s)
    if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/echo-dyn"; then
        CONSEC=0
        LAST_OK=$NOW
    else
        CONSEC=$((CONSEC+1)); FAILTOTAL=$((FAILTOTAL+1))
        GAP=$((NOW - LAST_OK))
        [ "$GAP" -gt "$MAX_DARK" ] && MAX_DARK=$GAP
    fi
    PROBES=$((PROBES+1))
    sleep 0.25
done
wait $BPID 2>/dev/null
kill -CONT "$VICTIM" 2>/dev/null
FINAL_GAP=$(($(date +%s) - LAST_OK))
[ "$FINAL_GAP" -gt "$MAX_DARK" ] && MAX_DARK=$FINAL_GAP
DARK_TOTAL=$((FAILTOTAL / 4))
echo "phase23 probes=$PROBES failed=$FAILTOTAL (~${DARK_TOTAL}s dark) longest_unanswered_gap=${MAX_DARK}s"

# --- teardown watchdog proof: -9 the parent; workers must self-exit --------
kill -9 "$SPID" 2>/dev/null
sleep 1.5
SURVIVORS=$(pgrep -f "$BIN" | wc -l | tr -d ' ')
echo "teardown kill-9 parent -> survivors after 1.5s: $SURVIVORS (expect 0)"
stop_tree
[ "$SURVIVORS" = "0" ] || echo "teardown WATCHDOG FAIL: orphaned survivors remain"

VERDICT=WEDGES
if [ "$MAX_DARK" -le 3 ]; then VERDICT=SERVICES_THROUGH_STALL; fi
echo "verdict: $VERDICT (wedge = longest unanswered gap > 3s while port listens)"
rm -f "$OUT.wrk"
