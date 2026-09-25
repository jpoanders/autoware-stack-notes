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

WHERE IT RUNS: needs autoware_vehicle_msgs on the Python path — i.e. inside the
Autoware Core container (live S2-4) or a host with the msgs overlay sourced. Prefer
--sim-time so header.stamp is stamped against AWSIM's /clock (the correct freshness
time base, study/task-1-report.md §5.4).

  ros2 run ... OR: python3 fi1_stuck_sensor_node.py \
      --value-mode stuck --stamp-mode fresh --rate-mult 1 --stuck-value 5.0 \
      [--backdate-ms 2000] [--duration 10] [--sim-time] [--topic /vehicle/status/velocity_status]
"""
import argparse, sys
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.duration import Duration
from rclpy.qos import (QoSProfile, ReliabilityPolicy, DurabilityPolicy, HistoryPolicy)

VelocityReport = None   # bound in main() after argparse, so --help works without the msgs


class Fi1StuckSensor(Node):
    def __init__(self, a):
        super().__init__('fi1_stuck_sensor')
        if a.sim_time:
            self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        # Recon-confirmed publisher QoS: RELIABLE + VOLATILE + KEEP_LAST(1)
        # (experiments/recon/report.md:45).
        qos = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                         reliability=ReliabilityPolicy.RELIABLE,
                         durability=DurabilityPolicy.VOLATILE)
        self.pub = self.create_publisher(VelocityReport, a.topic, qos)
        self.a = a
        self.windowed = (a.value_mode == 'replay-window')
        self.window = [5.0, 5.5, 6.0, 5.5]
        self.backdate = Duration(seconds=a.backdate_ms / 1000.0) if a.stamp_mode == 'old' else None
        self.seq = 0
        period = (1.0 / 30.0) / max(1, a.rate_mult)   # 30 Hz x rate_mult
        self.t0 = self.get_clock().now()
        self.get_logger().info(
            f"fi1_stuck_sensor up (PATH A): topic={a.topic} value-mode={a.value_mode} "
            f"stamp-mode={a.stamp_mode} rate-mult={a.rate_mult}x ({30*a.rate_mult:.0f} Hz) "
            f"stuck={a.stuck_value} backdate_ms={a.backdate_ms} sim_time={a.sim_time}")
        self.timer = self.create_timer(period, self.tick)

    def tick(self):
        now = self.get_clock().now()
        if self.a.duration > 0 and (now - self.t0) > Duration(seconds=self.a.duration):
            self.get_logger().info(f"done after {self.seq} samples"); rclpy.shutdown(); return
        m = VelocityReport()
        # NEW (or back-dated) header.stamp — the apparent age the SEU reads.
        stamp = (now - self.backdate) if self.backdate else now
        m.header.stamp = stamp.to_msg()
        m.header.frame_id = 'base_link'
        # OLD payload: frozen value, or a looping window of old values.
        m.longitudinal_velocity = float(self.window[self.seq % len(self.window)]
                                         if self.windowed else self.a.stuck_value)
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
    a, _ = ap.parse_known_args()

    global VelocityReport
    try:
        from autoware_vehicle_msgs.msg import VelocityReport as _VR
        VelocityReport = _VR
    except ImportError:
        sys.stderr.write(
            "FATAL: autoware_vehicle_msgs not found. Path A needs the real msgs package.\n"
            "  Run inside the Autoware Core container, or source the msgs overlay first.\n")
        sys.exit(4)

    rclpy.init()
    node = Fi1StuckSensor(a)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if rclpy.ok():
            node.destroy_node(); rclpy.shutdown()


if __name__ == '__main__':
    main()
