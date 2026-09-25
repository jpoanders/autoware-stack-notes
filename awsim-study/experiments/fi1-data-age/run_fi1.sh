#!/usr/bin/env bash
# run_fi1.sh — FI1 (Data Age Violation) top driver. Thin dispatcher over the
# self-contained pieces of this experiment:
#
#   ./run_fi1.sh bench            Step 0 loopback smoke (bare-Cyclone carrier, no msgs).
#                                 -> bench/run_bench.sh
#   ./run_fi1.sh ros [node args]  Path A: rclpy node (fi1_ros2_ws) on the topic, observed
#                                 by the shared tap. Needs autoware_vehicle_msgs (ws overlay
#                                 built+sourced, or the container's real msgs).
#   ./run_fi1.sh live [--silence] Step 3 (S2-4): same, against LIVE AWSIM+Autoware. --silence
#                                 first fires Module 1's dispose (silence-then-inject).
#                                 REQUIRES bring-up + snapshot + a human watching (safety gate).
#                                 SRC=capture replays the live writer's own last real sample
#                                 (default SRC=synthetic: the fixed --stuck-value).
set +u
cd "$(dirname "$0")"                         # experiments/fi1-data-age
source /opt/ros/humble/setup.bash 2>/dev/null
export LD_LIBRARY_PATH=/opt/ros/humble/lib/x86_64-linux-gnu:/opt/ros/humble/lib:$LD_LIBRARY_PATH
DUR=${DUR:-6}
CHK="python3 analysis/fi1_seu_check.py"
TAP=bench/build/trusting_consumer            # shared tap (built by the bench)
NODE_PY=fi1_ros2_ws/src/fi1_injection/fi1_injection/fi1_stuck_sensor_node.py

kill_all(){ for p in "$@"; do kill -INT "$p" 2>/dev/null; done; sleep 0.3
            for p in "$@"; do kill -9 "$p" 2>/dev/null; done; }

ensure_tap(){ [ -x "$TAP" ] || { echo "building shared tap via bench..."; \
  cmake -S bench -B bench/build >/dev/null && cmake --build bench/build >/dev/null; }; }

# run the Path A node: prefer `ros2 run` if the ws is sourced, else the script directly
run_node(){ if command -v ros2 >/dev/null && ros2 pkg executables fi1_injection 2>/dev/null | grep -q fi1_stuck_sensor; then
    ros2 run fi1_injection fi1_stuck_sensor "$@"; else python3 "$NODE_PY" "$@"; fi; }

case "$1" in
  bench) exec bench/run_bench.sh ;;

  ros)
    shift
    echo "== FI1 PATH A (rclpy node) — host $(hostname), $(date -Iseconds) =="
    if ! python3 -c "import autoware_vehicle_msgs" 2>/dev/null; then
      echo "REFUSE: autoware_vehicle_msgs not importable."
      echo "  Build+source the ws:  (cd fi1_ros2_ws && colcon build && . install/setup.bash)"
      echo "  or run inside the Autoware container. Host-only smoke needs no msgs: ./run_fi1.sh bench"
      exit 4
    fi
    ensure_tap; mkdir -p logs
    "$TAP" > logs/fi1_ros_consumer.log 2>&1 & CPID=$!
    sleep 0.6
    run_node --duration "$DUR" "$@" > logs/fi1_ros_writer.log 2>&1 & WPID=$!
    sleep "$((DUR+1))"; kill_all "$WPID" "$CPID"; sleep 0.3
    echo "consumer received: $(grep -c 'event=SAMPLE' logs/fi1_ros_consumer.log) samples"
    $CHK logs/fi1_ros_consumer.log ;;

  live)
    echo "== FI1 LIVE (S2-4) — host $(hostname), $(date -Iseconds) =="
    [ "$(hostname)" = "ml-XPS-8960" ] || { echo "REFUSE: live runs only on ml-XPS-8960"; exit 1; }
    if ! python3 -c "import autoware_vehicle_msgs" 2>/dev/null; then
      echo "REFUSE: autoware_vehicle_msgs not importable — run live inside the Autoware container."; exit 4; fi
    echo "PRECONDITIONS (human-confirmed): S2-0 bring-up done; snapshot taken; vehicle watched."
    ensure_tap; mkdir -p logs
    "$TAP" > logs/fi1_live_consumer.log 2>&1 & CPID=$!
    sleep 1.0
    if [ "$2" = "--silence" ]; then
      echo "--silence: recapture the LIVE writer GUID, then fire Module 1 dispose (B5)."
      echo "  ros2 topic info -v /vehicle/status/velocity_status   # get live GUID"
      echo "  python3 ../module1-freshness-loss/inject/forge_withdraw.py --target <LIVE_GUID> ..."
      echo "  (left manual on purpose — a mistyped GUID disposes the wrong proxy)"
    fi
    echo "Starting FI1 injector (PATH A) on the live topic for ${DUR}s..."
    # capture runs before the --duration clock starts; allow for its timeout
    CAP=0; [ "${SRC:-synthetic}" = capture ] && CAP=5
    run_node --value-mode stuck --stamp-mode fresh --rate-mult "${RATE:-1}" --sim-time --duration "$DUR" \
      --value-source "${SRC:-synthetic}" --capture-timeout "$CAP" \
      > logs/fi1_live_writer.log 2>&1 & WPID=$!
    sleep "$((DUR+CAP))"; kill_all "$WPID" "$CPID"; sleep 0.3
    echo "consumer received: $(grep -c 'event=SAMPLE' logs/fi1_live_consumer.log) samples"
    $CHK logs/fi1_live_consumer.log
    echo "RECORD the vehicle/stack reaction as [runtime] (command+date+what-was-running)." ;;

  *) echo "usage: $0 bench | ros [node args] | live [--silence]"; exit 2 ;;
esac
