# fi1_ros2_ws — FI1 Path A workspace

The **Path A** carrier for FI1 (Data Age Violation): a genuine ROS 2 node that reuses the real
`rclpy → rcl → rmw → Cyclone` publish path, so every sample gets a fresh, monotonic sequence number
and clears the reader's reorder admin (which drops verbatim replay `seq < next_seq` as
`NN_REORDER_TOO_OLD`). It re-emits an **old payload with a new timestamp** — a stuck sensor. The
default target is `/vehicle/status/velocity_status` (`VelocityReport`). With `--msg-type` it can target
any topic whose message has a `std_msgs/Header`, e.g. `/localization/kinematic_state` (`nav_msgs/Odometry`). See `../report.md` for the full FI1 write-up and
`../../stage2-run-plan.md` (milestone S2-4) for the live run.

For the host-only, no-msgs smoke test use the bench instead: `../run_fi1.sh bench`.

## Packages

- **`fi1_injection`** (ament_python) — the injector node `fi1_stuck_sensor`. Publishes the
  `--msg-type` message (default `autoware_vehicle_msgs/msg/VelocityReport`) with the recon-confirmed
  writer QoS (RELIABLE + VOLATILE + KEEP_LAST(1)). The type is resolved at runtime with
  `rosidl_runtime_py.utilities.get_message`, so any msgs package on the Python path works.
- **`autoware_vehicle_msgs`** (ament_cmake) — a **minimal vendored overlay** defining only
  `VelocityReport.msg` (`std_msgs/Header` + 3× `float32`). It is wire-faithful to the real Autoware
  type (discovery is name-only), so the node built against it interoperates with real AWSIM/Autoware.
  Its only purpose is to let Path A build on a bare host, where the real package is absent.

## Build

**On the bare host** (build both — the overlay satisfies the msgs import):
```bash
source /opt/ros/humble/setup.bash
cd fi1_ros2_ws
colcon build
source install/setup.bash
```

**Inside the Autoware Core container** — the container does **not** see this repo unless you mount it,
so `colcon build --packages-select fi1_injection` from `~` fails with
`ignoring unknown package 'fi1_injection'`. Mount the `src/` (read-only) and build in an ephemeral
workspace inside the container, so `build/install/log` stay in the container (gone on `--rm`) and never
land on the host with the container user's uid:

```bash
# add to the `docker run` in setup/scripts/launch-autoware-container.sh:
-v <ABS_PATH>/fi1_ros2_ws/src:/home/aw/fi1_ws/src:ro
#   <ABS_PATH> = .../awsim-study/experiments/fi1-data-age

# then, inside the container — build from HOME, not from the mount. Docker creates the mount's
# parent (/home/aw/fi1_ws) as root, so colcon cannot write build/log there, and src is :ro.
source /opt/ros/humble/setup.bash          # if the entrypoint has not already
cd ~
colcon build --base-paths /home/aw/fi1_ws/src --packages-select fi1_injection   # uses the REAL autoware_vehicle_msgs on the underlay
source install/setup.bash
```

`--packages-select fi1_injection` skips the vendored overlay on purpose: inside the container the real
`autoware_vehicle_msgs` is already available, so the node binds to the genuine type. The overlay exists
only for the bare-host build above.

## Run

```bash
ros2 run fi1_injection fi1_stuck_sensor [options]
```

Options:

| Flag | Values / default | Meaning |
|---|---|---|
| `--value-mode` | `stuck` (default) \| `replay-window` | frozen old value, or a looping window of old values |
| `--value-source` | `synthetic` (default) \| `capture` | made-up payload (`--stuck-value` / fixed window), or the real writer's own recent samples |
| `--capture-n` | int, `1` for `stuck`, `30` for `replay-window` | how many real samples to capture (`stuck` replays the last one) |
| `--capture-timeout` | seconds, `5` | give up (exit 5) if the real writer sends nothing in this time |
| `--stamp-mode` | `fresh` (default) \| `old` | `header.stamp = now` (defeats freshness-by-stamp) or back-dated (age > expiry) |
| `--rate-mult` | `1` (default) \| `2` \| `10` | publish at 30 / 60 / 300 Hz (jitter → deadline pressure) |
| `--stuck-value` | float, `5.0` | the frozen `longitudinal_velocity` (m/s) |
| `--backdate-ms` | float, `2000` | back-date amount for `--stamp-mode old` |
| `--duration` | seconds, `0` = until Ctrl-C | run length |
| `--sim-time` | flag | use `/clock` (sim time) for `header.stamp` — **use this against live AWSIM** |
| `--topic` | `/vehicle/status/velocity_status` | target topic |
| `--msg-type` | `autoware_vehicle_msgs/msg/VelocityReport` | fully-qualified type of `--topic`; anything other than `VelocityReport` requires `--value-source capture` |

Example — the stuck-sensor case (old value, fresh stamp), 10 s against the live sim:
```bash
ros2 run fi1_injection fi1_stuck_sensor --value-mode stuck --stamp-mode fresh --sim-time --duration 10
```

Or drive it (node + shared tap + SEU check) through the experiment driver:
```bash
cd .. && ./run_fi1.sh ros --stamp-mode fresh --rate-mult 1     # host/container
cd .. && ./run_fi1.sh live [--silence]                          # S2-4 against live AWSIM (gated)
```

With `--value-source capture` the node first subscribes to the topic, records the last `--capture-n`
real samples, **destroys the subscription**, and only then creates its publisher (so it can never
capture its own output). It re-emits those genuine payloads — every field, including `frame_id`,
`lateral_velocity`, `heading_rate` — with only `header.stamp` rewritten. It needs a live writer on the
topic, so it fails (exit 5) in a bare `./run_fi1.sh ros` run with nothing else publishing.
`--duration` counts from the end of the capture. For the live driver: `SRC=capture ./run_fi1.sh live`.

## Target: `/localization/kinematic_state` (old ego state)

`/localization/kinematic_state` (`nav_msgs/msg/Odometry`, written by the EKF) feeds control and planning
directly, so it is the tightest loop to stale. Synthetic values are `VelocityReport`-only, so this
target **must** use `--value-source capture`: the node records real EKF output, then re-emits it.

```bash
# inside the container, with the vehicle DRIVING (a capture taken at standstill replays a standstill)
ros2 run fi1_injection fi1_stuck_sensor --sim-time --duration 15 \
    --topic /localization/kinematic_state --msg-type nav_msgs/msg/Odometry \
    --value-source capture --value-mode stuck --stamp-mode fresh
```

- `--stamp-mode fresh` = the stuck sensor (old pose/twist, current stamp). `--stamp-mode old
  --backdate-ms 2000` also back-dates the stamp, which consumers that check stamp age should reject.
- `--value-mode replay-window --capture-n 50` loops the last ~1 s of EKF output instead of freezing one sample.
- This is **coexist** only: the EKF keeps publishing at its own rate, so consumers see real and replayed
  samples interleaved. The injector publishes at 30 Hz × `--rate-mult`.

### Without building (plain `python3`)

The node needs only `rclpy` and the target msgs package, so it also runs straight from the source tree
(inside the container, from the `:ro` mount):

```bash
source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash
python3 /home/aw/fi1_ws/src/fi1_injection/fi1_injection/fi1_stuck_sensor_node.py --sim-time --duration 15 \
    --topic /localization/kinematic_state --msg-type nav_msgs/msg/Odometry \
    --value-source capture --value-mode stuck --stamp-mode fresh
```

Exit codes: `4` = message type not importable (source the Autoware setup), `5` = nothing captured
within `--capture-timeout` (the stack is not publishing on the topic).

## Notes

- **Always pass `--sim-time` against live AWSIM** so `header.stamp` is stamped on `/clock` — the correct
  freshness time base (`../../../study/task-1-report.md §5.4`).
- **Clock caveat for the C tap.** The shared tap (`experiments/_common/consumer/trusting_consumer.c`)
  computes arrival age on `CLOCK_MONOTONIC`, while this node stamps `header.stamp` on the ROS/sim epoch
  clock. Their bases differ, so the tap's `P_age` (stamp-freshness) reads a nonsense value against a
  ROS-stamped source; `P_stuck` (value-age) is clock-agnostic and works regardless. Use `P_stuck` as the
  reliable detector here until the tap is taught to compare `header.stamp` against `CLOCK_REALTIME`.
- `build/`, `install/`, `log/` are gitignored.
