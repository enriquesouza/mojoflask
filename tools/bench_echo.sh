#!/bin/sh
# bench_echo.sh — the 1-vs-N worker distribution harness driver.
#
# Boots bench_echo at WORKERS=1 and WORKERS=16 on isolated ports, drives
# wrk -t8 -c100 -d15s --latency against /echo-static (prebuilt buffer path)
# and /echo-dyn (fresh per-request resolver payload), samples established-
# connection counts mid-run to expose keep-alive persistence vs churn, and
# prints one compact matrix line per cell.
#
# Usage: pixi run bench-echo            (or: sh tools/bench_echo.sh [dir])
set -u

PORT1=18195
PORT16=18196
DUR=${BENCH_DUR:-15s}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BENCH_BIN:-$HERE/bench_echo}"
[ -x "$BIN" ] || { echo "build first: pixi run build-bench-echo" >&2; exit 1; }

stop_tree() {
    pkill -f "bench_echo" 2>/dev/null
    sleep 1
}

wait_up() {
    i=0
    while [ $i -lt 150 ]; do
        if curl -sf "http://127.0.0.1:$1/healthz" >/dev/null 2>&1; then return 0; fi
        # no /health route registered on purpose; fall back to any-path probe
        if curl -s -o /dev/null "http://127.0.0.1:$1/"; then return 0; fi
        sleep 0.2; i=$((i+1))
    done
    echo "server on :$1 never came up" >&2; return 1
}

run_cell() {
    port=$1; label=$2; route=$3
    wrk -t8 -c100 -d"$DUR" --latency "http://127.0.0.1:$port/$route" > "/tmp/bench_echo_${label}.txt" 2>&1 &
    wrkpid=$!
    sleep 7
    est=$(netstat -an -p tcp | grep "\.$port " | grep -c ESTABLISHED)
    tw=$(netstat -an -p tcp | grep "\.$port " | grep -c TIME_WAIT)
    wait $wrkpid
    rps=$(grep 'Requests/sec' "/tmp/bench_echo_${label}.txt" | awk '{print $2}')
    p50=$(awk '/Latency Distribution/{getline; print $2}' "/tmp/bench_echo_${label}.txt")
    p99=$(awk '/Latency Distribution/{n++; if (n==4) print $4}' "/tmp/bench_echo_${label}.txt")
    errs=$(grep -c 'socket errors' "/tmp/bench_echo_${label}.txt")
    errline=$(grep 'socket errors' "/tmp/bench_echo_${label}.txt")
    printf "%-16s %8s rps  p50=%sms p99=%sms est=%s timewait=%s %s\n" \
        "$label" "$rps" "$p50" "$p99" "$est" "$tw" "$errline"
}

echo "== mojoflask bench_echo $(date +%H:%M:%S) dur=$DUR =="
for W in 1 16; do
    stop_tree
    if [ "$W" = "1" ]; then PORT=$PORT1; else PORT=$PORT16; fi
    MOJOFLASK_PORT=$PORT MOJOFLASK_WORKERS=$W "$BIN" >/tmp/bench_echo_server_$W.log 2>&1 &
    if ! wait_up "$PORT"; then stop_tree; exit 1; fi
    run_cell "$PORT" "w${W}-static" "echo-static"
    run_cell "$PORT" "w${W}-dyn" "echo-dyn"
done
stop_tree
echo "== done; raw outputs in /tmp/bench_echo_*.txt =="
