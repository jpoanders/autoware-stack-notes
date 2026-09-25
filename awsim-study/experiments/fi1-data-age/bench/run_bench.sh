#!/usr/bin/env bash
# run_bench.sh — FI1 Step 0: loopback smoke, NO AWSIM. Deterministic.
# Runs the scenario matrix (control + stuck/old/window x rate) and the SEU check
# on each. Self-contained: builds under bench/build, logs under bench/logs.
set +u
cd "$(dirname "$0")"                       # experiments/fi1-data-age/bench
source /opt/ros/humble/setup.bash 2>/dev/null
export LD_LIBRARY_PATH=/opt/ros/humble/lib/x86_64-linux-gnu:/opt/ros/humble/lib:$LD_LIBRARY_PATH
mkdir -p logs
DUR=${DUR:-6}                              # seconds per scenario (>> 1.5s stuck threshold)
CHK="python3 ../analysis/fi1_seu_check.py"

# build if needed
if [ ! -x build/fi1_stuck_sensor ]; then
  cmake -S . -B build >/dev/null && cmake --build build >/dev/null || { echo "build failed"; exit 1; }
fi

kill_all(){ for p in "$@"; do kill -INT "$p" 2>/dev/null; done; sleep 0.3
            for p in "$@"; do kill -9 "$p" 2>/dev/null; done; }

run_scenario(){
  local name="$1" expect="$2"; shift 2
  local clog="logs/fi1_${name}_consumer.log"
  echo; echo "=== SCENARIO ${name}  (expect: ${expect}) ==="
  ./build/trusting_consumer > "$clog" 2>&1 & local CPID=$!
  sleep 0.4
  "$@" > "logs/fi1_${name}_writer.log" 2>&1 & local WPID=$!
  sleep "$DUR"
  kill_all "$WPID" "$CPID"; sleep 0.3
  echo "consumer received: $(grep -c 'event=SAMPLE' "$clog") samples"
  $CHK "$clog"
}

echo "== FI1 bench (loopback, no AWSIM) — host $(hostname), $(date -Iseconds) =="
run_scenario control         "NONE"           ./build/real_speed_monitor
run_scenario stuck_fresh_1x  "P_stuck"        ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 1
run_scenario stuck_fresh_2x  "P_stuck,P_rate" ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 2
run_scenario stuck_fresh_10x "P_stuck,P_rate" ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 10
run_scenario stuck_old_1x    "P_age,P_stuck"  ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode old --rate-mult 1
run_scenario window_fresh_1x "NONE (evades P_stuck)" ./build/fi1_stuck_sensor --value-mode replay-window --stamp-mode fresh --rate-mult 1
echo; echo "== bench done. Compare each SEU_VERDICT line to its 'expect'. =="
