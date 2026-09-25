#!/usr/bin/env python3
"""fi1_stuck_sensor_node.py — FI1 (Data Age Violation) injector, PATH A (ROS 2 node).

This is the study's "Path A" carrier: a genuine rclpy node that reuses the entire
legitimate ROS -> rcl -> rmw -> Cyclone publish path (study/task-2-report.md:113-185).
Because a real writer assigns a fresh, monotonic sequence number to every sample, it
clears the reader's reorder admin (which drops verbatim-replay seq < next_seq as
NN_REORDER_TOO_OLD, study/task-3-report.md:37-64) — so re-emitting an OLD payload
with a NEW timestamp is delivered, exactly the FI1 method.

FI1 needs nothing below ROS: it only sets the message's header.stamp field and the
value, both ordinary application data. The SEU keys freshness on header.stamp
(study/task-1-report.md:696-700), so this node controls apparent age directly.

WHERE IT RUNS: needs the target message package on the Python path — i.e. inside the
Autoware Core container (live S2-4) or a host with the msgs overlay sourced. Prefer
--sim-time so header.stamp is stamped against AWSIM's /clock (the correct freshness
time base, study/task-1-report.md §5.4).

TARGET TYPE: --msg-type selects the message (default autoware_vehicle_msgs/msg/
VelocityReport, the original FI1 target). Any type with a std_msgs/Header `header`
works, e.g. nav_msgs/msg/Odometry for --topic /localization/kinematic_state (the
tightest control loop — see experiments/recon + the kinematic_state consumer graph).
The synthetic value source only knows VelocityReport's speed scalar, so for other
types use --value-source capture (below), which replays real fields verbatim.

VALUE SOURCE: --value-source synthetic (default) emits a made-up payload
(--stuck-value, or a hardcoded window); VelocityReport only. --value-source capture
first SUBSCRIBES to the topic, records the last --capture-n real samples from the live
writer, then re-emits those genuine payloads (all fields) with only header.stamp
rewritten — a true "previous sample replayed", and the only source valid for
non-VelocityReport types. The subscription is torn down before the publisher is
created, so the node never captures its own output.

  ros2 run ... OR: python3 fi1_stuck_sensor_node.py \
      --value-mode stuck --stamp-mode fresh --rate-mult 1 --stuck-value 5.0 \
      [--msg-type nav_msgs/msg/Odometry] [--value-source synthetic|capture] \
      [--capture-n N] [--capture-timeout 5] \
      [--backdate-ms 2000] [--duration 10] [--sim-time] [--topic /vehicle/status/velocity_status]

  # tightest-loop target (replay old ego state into control + planning):
  ros2 run fi1_injection fi1_stuck_sensor --sim-time --duration 15 \
      --topic /localization/kinematic_state --msg-type nav_msgs/msg/Odometry \
      --value-source capture --value-mode stuck --stamp-mode old --backdate-ms 2000
"""
import argparse, sys, time
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.duration import Duration
from rclpy.qos import (QoSProfile, ReliabilityPolicy, DurabilityPolicy, HistoryPolicy)

MsgType = None   # the target message class, bound in main() after argparse


def _summ(m):
    """Type-agnostic one-line summary of a captured sample for the log.
    Pulls the field FI1 cares about when present, else a compact fallback."""
    if hasattr(m, 'longitudinal_velocity'):          # VelocityReport
        return round(m.longitudinal_velocity, 3)
    if hasattr(m, 'pose') and hasattr(m, 'twist'):   # nav_msgs/Odometry
        p, v = m.pose.pose.position, m.twist.twist.linear
        return {'xy': (round(p.x, 2), round(p.y, 2)), 'vx': round(v.x, 3)}
    return type(m).__name__


class Fi1StuckSensor(Node):
    def __init__(self, a):
        super().__init__('fi1_stuck_sensor')
        if a.sim_time:
            self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.a = a
        self.windowed = (a.value_mode == 'replay-window')
        self.window = [5.0, 5.5, 6.0, 5.5]
        self.captured = []   # real samples, filled by capture()
        self.done = False

    def capture(self):
        """Record the last capture_n real samples from the live writer. Runs BEFORE
        the publisher exists, so our own output can never be captured."""
        a = self.a
        qos = QoSProfile(depth=max(10, a.capture_n), history=HistoryPolicy.KEEP_LAST,
                         reliability=ReliabilityPolicy.RELIABLE,
                         durability=DurabilityPolicy.VOLATILE)
        sub = self.create_subscription(MsgType, a.topic,
                                       lambda m: self.captured.append(m), qos)
        self.get_logger().info(f"capturing {a.capture_n} real sample(s) from {a.topic} "
                               f"(timeout {a.capture_timeout}s)...")
        deadline = time.monotonic() + a.capture_timeout   # wall time: /clock may be paused
        while len(self.captured) < a.capture_n and time.monotonic() < deadline:
            rclpy.spin_once(self, timeout_sec=0.1)
        self.destroy_subscription(sub)
        if not self.captured:
            return False
        self.captured = self.captured[-a.capture_n:]
        self.get_logger().info(f"captured {len(self.captured)} sample(s); "
                               f"summary={[_summ(m) for m in self.captured]}")
        return True

    def start(self):
        a = self.a
        # Recon-confirmed publisher QoS: RELIABLE + VOLATILE + KEEP_LAST(1)
        # (experiments/recon/report.md:45).
        qos = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                         reliability=ReliabilityPolicy.RELIABLE,
                         durability=DurabilityPolicy.VOLATILE)
        self.pub = self.create_publisher(MsgType, a.topic, qos)
        self.backdate = Duration(seconds=a.backdate_ms / 1000.0) if a.stamp_mode == 'old' else None
        self.seq = 0
        period = (1.0 / 30.0) / max(1, a.rate_mult)   # 30 Hz x rate_mult
        self.t0 = None   # set on the first tick: with --sim-time, now() is 0 until /clock arrives
        self.get_logger().info(
            f"fi1_stuck_sensor up (PATH A): topic={a.topic} msg-type={a.msg_type} value-mode={a.value_mode} "
            f"value-source={a.value_source} stamp-mode={a.stamp_mode} rate-mult={a.rate_mult}x ({30*a.rate_mult:.0f} Hz) "
            f"stuck={a.stuck_value} backdate_ms={a.backdate_ms} sim_time={a.sim_time}")
        self.timer = self.create_timer(period, self.tick)

    def tick(self):
        now = self.get_clock().now()
        if self.t0 is None:
            self.t0 = now
        if self.a.duration > 0 and (now - self.t0) > Duration(seconds=self.a.duration):
            self.get_logger().info(f"done after {self.seq} samples"); self.done = True; return
        if self.captured:
            # OLD payload, captured: the last real sample (stuck), or loop over all of
            # them (replay-window). Every field is the genuine one except the stamp.
            m = (self.captured[self.seq % len(self.captured)] if self.windowed
                 else self.captured[-1])
        else:
            # synthetic is VelocityReport-only (guarded in main()).
            m = MsgType()
            m.header.frame_id = 'base_link'
            # OLD payload, synthetic: frozen value, or a looping window of old values.
            m.longitudinal_velocity = float(self.window[self.seq % len(self.window)]
                                             if self.windowed else self.a.stuck_value)
        # NEW (or back-dated) header.stamp — the apparent age the SEU reads.
        stamp = (now - self.backdate) if self.backdate else now
        m.header.stamp = stamp.to_msg()   # every supported type carries a std_msgs/Header
        self.pub.publish(m)
        self.seq += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--value-mode', choices=['stuck', 'replay-window'], default='stuck')
    ap.add_argument('--stamp-mode', choices=['fresh', 'old'], default='fresh')
    ap.add_argument('--rate-mult', type=int, default=1)
    ap.add_argument('--stuck-value', type=float, default=5.0)
    ap.add_argument('--backdate-ms', type=float, default=2000.0)
    ap.add_argument('--duration', type=float, default=0.0)   # 0 = until Ctrl-C
    ap.add_argument('--sim-time', action='store_true')
    ap.add_argument('--topic', default='/vehicle/status/velocity_status')
    ap.add_argument('--msg-type', default='autoware_vehicle_msgs/msg/VelocityReport',
                    help='fully-qualified message type, e.g. nav_msgs/msg/Odometry')
    ap.add_argument('--value-source', choices=['synthetic', 'capture'], default='synthetic')
    ap.add_argument('--capture-n', type=int, default=None)   # default: 1 stuck, 30 replay-window
    ap.add_argument('--capture-timeout', type=float, default=5.0)
    a, _ = ap.parse_known_args()
    if a.capture_n is None:
        a.capture_n = 30 if a.value_mode == 'replay-window' else 1
    if a.capture_n < 1:
        ap.error('--capture-n must be >= 1')

    is_velocity_report = a.msg_type == 'autoware_vehicle_msgs/msg/VelocityReport'
    if a.value_source == 'synthetic' and not is_velocity_report:
        # synthetic only knows VelocityReport's speed scalar; anything else must replay.
        ap.error(f'--value-source synthetic supports only VelocityReport; use '
                 f'--value-source capture for {a.msg_type}')

    global MsgType
    try:
        from rosidl_runtime_py.utilities import get_message
        MsgType = get_message(a.msg_type)   # resolves & imports the msg package
    except (ImportError, ModuleNotFoundError, ValueError, KeyError) as e:
        sys.stderr.write(
            f"FATAL: could not load message type '{a.msg_type}': {e}\n"
            "  Path A needs the real msgs package on PYTHONPATH. Run inside the\n"
            "  Autoware Core container, or source the msgs overlay first.\n")
        sys.exit(4)

    rclpy.init()
    node = Fi1StuckSensor(a)
    if a.value_source == 'capture' and not node.capture():
        sys.stderr.write(f"FATAL: captured no samples on {a.topic} within "
                         f"{a.capture_timeout}s — is the real writer publishing?\n")
        node.destroy_node(); rclpy.shutdown(); sys.exit(5)
    node.start()
    try:
        # not rclpy.spin(): shutting down from inside the timer callback left spin blocked
        while rclpy.ok() and not node.done:
            rclpy.spin_once(node, timeout_sec=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        if rclpy.ok():
            node.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
