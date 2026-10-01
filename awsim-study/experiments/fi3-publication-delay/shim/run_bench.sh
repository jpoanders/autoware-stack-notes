#!/usr/bin/env bash
# run_bench.sh — FI3 Stage C: shim delay matrix on loopback, NO AWSIM.
# Writer = Module 1's real_speed_monitor under LD_PRELOAD (bare Cyclone; stamps on CLOCK_MONOTONIC
# like the tap, so stamp_age is valid — the rclpy node stamps wall-clock). The rmw path is covered
# by the Stage B probe. Tap = trusting_consumer; SEU = fi1_seu_check.py.
set +u
cd "$(dirname "$0")"                       # experiments/fi3-publication-delay/shim
source /opt/ros/humble/setup.bash 2>/dev/null
export LD_LIBRARY_PATH=/opt/ros/humble/lib/x86_64-linux-gnu:/opt/ros/humble/lib:$LD_LIBRARY_PATH
export CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
mkdir -p logs
DUR=${DUR:-6}
CHK="python3 ../../fi1-data-age/analysis/fi1_seu_check.py"

if [ ! -x build/real_speed_monitor ]; then
  cmake -S . -B build >/dev/null && cmake --build build >/dev/null || { echo "build failed"; exit 1; }
fi

kill_all(){ for p in "$@"; do kill -INT "$p" 2>/dev/null; done; sleep 0.3
            for p in "$@"; do kill -9 "$p" 2>/dev/null; done; }

run_case(){
  local name="$1" expect="$2"; shift 2
  local clog="logs/fi3_${name}_consumer.log" slog="$PWD/logs/fi3_${name}_shim.log"
  rm -f "$slog"
  echo; echo "=== CASE ${name}  (expect: ${expect}) ==="
  ./build/trusting_consumer > "$clog" 2>&1 & local CPID=$!
  sleep 0.4
  env "$@" FI3_LOG="$slog" LD_PRELOAD="$PWD/build/libfi3_delay.so" \
    timeout -s INT "$DUR" ./build/real_speed_monitor > "logs/fi3_${name}_writer.log" 2>&1
  sleep 1                                  # let the queue drain before stopping the tap
  kill_all "$CPID"; sleep 0.3
  echo "consumer received: $(grep -c 'event=SAMPLE' "$clog") samples; shim: $(grep -c ' sent$' "$slog" 2>/dev/null) sent, $(grep -c ' drop' "$slog" 2>/dev/null) dropped"
  $CHK "$clog"
}

echo "== FI3 shim bench (loopback, no AWSIM) — host $(hostname), $(date -Iseconds) =="
run_case control      "NONE"               FI3_MODE=off
run_case fixed80      "NONE"               FI3_MODE=fixed FI3_DELAY_MS=80
run_case fixed250     "P_age"              FI3_MODE=fixed FI3_DELAY_MS=250
run_case jitter       "P_rate"             FI3_MODE=jitter FI3_DELAY_MS=30 FI3_JITTER_MS=25
run_case stall_flush  "P_age,P_rate,STALE" FI3_MODE=stall FI3_STALL_MS=400 FI3_START_S=2
run_case stall_latest "P_rate,STALE"       FI3_MODE=stall FI3_STALL_MS=400 FI3_START_S=2 FI3_STALL_POLICY=latest
run_case stretch10    "P_rate"             FI3_MODE=stretch FI3_RATE_HZ=10
echo; echo "== bench done. Compare each SEU_VERDICT line to its 'expect'. =="
