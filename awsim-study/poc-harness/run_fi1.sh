#!/usr/bin/env bash
# run_fi1.sh — FI1 (Data Age Violation) driver.
#
#   ./run_fi1.sh --bench   Step 0: loopback smoke, NO AWSIM. Deterministic. Runs the
#                          scenario matrix (control + stuck/old/window x rate) and the
#                          SEU check on each. Must pass before any live step.
#   ./run_fi1.sh --live [--silence]  Step 3 (S2-4): observe the LIVE topic while the FI1
#                          injector runs; --silence first fires Module 1's dispose against
#                          the recaptured real writer GUID (silence-then-inject). REQUIRES
#                          AWSIM + Autoware up and a human watching (plan safety gate).
set +u
cd "$(dirname "$0")"
source /opt/ros/humble/setup.bash 2>/dev/null
export LD_LIBRARY_PATH=/opt/ros/humble/lib/x86_64-linux-gnu:/opt/ros/humble/lib:$LD_LIBRARY_PATH
mkdir -p logs
DUR=${DUR:-6}                       # seconds per scenario (>> 1.5s stuck threshold)
CHK="python3 inject/fi1_seu_check.py"

kill_all(){ for p in "$@"; do kill -INT "$p" 2>/dev/null; done; sleep 0.3
            for p in "$@"; do kill -9 "$p" 2>/dev/null; done; }

# run_scenario NAME EXPECT  -- writer command follows in global array WCMD
run_scenario(){
  local name="$1" expect="$2"; shift 2
  local clog="logs/fi1_${name}_consumer.log"
  echo; echo "=== SCENARIO ${name}  (expect: ${expect}) ==="
  ./build/trusting_consumer > "$clog" 2>&1 & local CPID=$!
  sleep 0.4
  "$@" > "logs/fi1_${name}_writer.log" 2>&1 & local WPID=$!
  sleep "$DUR"
  kill_all "$WPID" "$CPID"; sleep 0.3
  local rx; rx=$(grep -c 'event=SAMPLE' "$clog")
  echo "consumer received: ${rx} samples"
  $CHK "$clog"
}

if [ "$1" = "--bench" ]; then
  echo "== FI1 bench (loopback, no AWSIM) — host $(hostname), $(date -Iseconds) =="
  # 1) negative control: real changing value, fresh stamp, 30 Hz -> zero alarms
  run_scenario control        "NONE"           ./build/real_speed_monitor
  # 2) stuck sensor, fresh stamp -> P_stuck only (arrival/stamp age fooled)
  run_scenario stuck_fresh_1x "P_stuck"        ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 1
  # 3-4) + over-publication -> P_stuck + P_rate (+ deadline pressure at 10x)
  run_scenario stuck_fresh_2x "P_stuck,P_rate" ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 2
  run_scenario stuck_fresh_10x "P_stuck,P_rate" ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult 10
  # 5) back-dated stamp -> P_age fires directly (also P_stuck, value frozen)
  run_scenario stuck_old_1x   "P_age,P_stuck"  ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode old --rate-mult 1
  # 6) windowed replay, fresh stamp -> value changes each sample: stuck-at property EVADED
  run_scenario window_fresh_1x "NONE (evades P_stuck)" ./build/fi1_stuck_sensor --value-mode replay-window --stamp-mode fresh --rate-mult 1
  echo; echo "== bench done. Compare each SEU_VERDICT line to its 'expect'. =="
  exit 0
fi

if [ "$1" = "--live" ]; then
  echo "== FI1 LIVE (S2-4) — host $(hostname), $(date -Iseconds) =="
  [ "$(hostname)" = "ml-XPS-8960" ] || { echo "REFUSE: live runs only on ml-XPS-8960"; exit 1; }
  echo "PRECONDITIONS (human-confirmed): S2-0 bring-up done; snapshot taken; vehicle watched."
  # observe the live topic
  ./build/trusting_consumer > logs/fi1_live_consumer.log 2>&1 & CPID=$!
  sleep 1.0
  if [ "$2" = "--silence" ]; then
    echo "--silence: recapture the LIVE writer GUID, then fire Module 1 dispose (B5)."
    echo "  run: ros2 topic info -v /vehicle/status/velocity_status  # get live GUID"
    echo "  then: python3 inject/forge_withdraw.py --target <LIVE_GUID> ...  (see run_module1.sh)"
    echo "  (left manual on purpose — the GUID is ephemeral and mis-targeting disposes the wrong proxy)"
  fi
  echo "Starting FI1 injector on the live topic (foreign GUID) for ${DUR}s..."
  ./build/fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --rate-mult "${RATE:-1}" \
      --duration "$DUR" > logs/fi1_live_writer.log 2>&1 & WPID=$!
  sleep "$DUR"; kill_all "$WPID" "$CPID"; sleep 0.3
  echo "consumer received: $(grep -c 'event=SAMPLE' logs/fi1_live_consumer.log) samples"
  $CHK logs/fi1_live_consumer.log
  echo "RECORD the vehicle/stack reaction as [runtime] (command+date+what-was-running)."
  exit 0
fi

echo "usage: $0 --bench | --live [--silence]"; exit 2
