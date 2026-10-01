#!/usr/bin/env python3
"""fi1_seu_check.py — offline SEU/STL evaluation for FI1 (Data Age Violation).

Reads a trusting_consumer log (TRACE ... event=SAMPLE lines carrying stamp_age_ms
and value_age_ms) and evaluates the four properties the FI1 plan defines. This is
the SEU stand-in: the trusting_consumer itself only *consumes* the data (its
arrival watchdog is deliberately fooled by fresh-stamp injection); the SEU is the
one that must raise the alarm.

Properties:
  P_age    G( t_now - header.stamp <= Delta_expiry )   -> catches --stamp-mode old
  P_stuck  G( time_since_last_value_change <= Delta_stuck ) -> catches fresh-stamp stuck sensor
  P_rate   G( inter_arrival in [rate_lo, rate_hi] )    -> catches 2x/10x over-publication
  STALE    arrival watchdog: tap printed event=STALE, then samples resumed (FI3 gaps)
  P_deadline  observed only: min inter-arrival / peak Hz (deadline pressure, recorded)

Usage:
  fi1_seu_check.py CONSUMER_LOG [--expiry-ms 165] [--stuck-ms 1500]
                   [--rate-lo-ms 25] [--rate-hi-ms 40]
"""
import argparse, re, sys

SAMPLE = re.compile(
    r"event=SAMPLE\s+rx=(\d+)\s+guid=(\S+)\s+lv=([-\d.]+)\s+dt_ms=([-\d.]+)"
    r"\s+stamp_age_ms=([-\d.]+)\s+value_age_ms=([-\d.]+)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--expiry-ms", type=float, default=165.0)
    ap.add_argument("--stuck-ms",  type=float, default=1500.0)
    ap.add_argument("--rate-lo-ms", type=float, default=25.0)
    ap.add_argument("--rate-hi-ms", type=float, default=40.0)
    a = ap.parse_args()

    rows = []
    stale_eps, stale_open = 0, False   # STALE episodes ended by a later sample (mid-stream gaps)
    with open(a.log, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "event=STALE" in line and rows:
                stale_open = True
            m = SAMPLE.search(line)
            if m:
                stale_eps += stale_open; stale_open = False
                rows.append(dict(rx=int(m[1]), guid=m[2], lv=float(m[3]),
                                 dt=float(m[4]), sage=float(m[5]), vage=float(m[6])))
    if not rows:
        print("fi1_seu_check: no SAMPLE rows found in", a.log); sys.exit(3)

    n = len(rows)
    guids = sorted({r["guid"] for r in rows})

    # P_age: any sample older-by-stamp than expiry
    age_viol = [r for r in rows if r["sage"] > a.expiry_ms]
    # P_stuck: value frozen beyond stuck threshold
    stuck_viol = [r for r in rows if r["vage"] > a.stuck_ms]
    # P_rate: inter-arrival outside band (skip rx==0, dt seeded 0; skip huge post-gap dt==0)
    rate_viol = [r for r in rows if r["rx"] > 0 and r["dt"] > 0
                 and (r["dt"] < a.rate_lo_ms or r["dt"] > a.rate_hi_ms)]
    # P_deadline (observed): tightest inter-arrival / peak instantaneous rate
    dts = [r["dt"] for r in rows if r["rx"] > 0 and r["dt"] > 0]
    min_dt = min(dts) if dts else 0.0
    peak_hz = (1000.0/min_dt) if min_dt > 0 else 0.0

    def verdict(name, viol, bound):
        if viol:
            f = viol[0]
            print(f"  {name:9s} VIOLATED  ({len(viol)}/{n} samples)  "
                  f"first: rx={f['rx']} {bound}")
        else:
            print(f"  {name:9s} PASS      (0/{n})")
        return bool(viol)

    print(f"fi1_seu_check: {n} samples, {len(guids)} source GUID(s): {', '.join(guids)}")
    v_age   = verdict("P_age",   age_viol,   f"stamp_age={age_viol[0]['sage']:.1f}ms > {a.expiry_ms:.0f}" if age_viol else "")
    v_stuck = verdict("P_stuck", stuck_viol, f"value_age={stuck_viol[0]['vage']:.1f}ms > {a.stuck_ms:.0f}" if stuck_viol else "")
    v_rate  = verdict("P_rate",  rate_viol,  f"dt={rate_viol[0]['dt']:.2f}ms outside [{a.rate_lo_ms:.0f},{a.rate_hi_ms:.0f}]" if rate_viol else "")
    print(f"  P_deadline OBSERVED  min_inter_arrival={min_dt:.2f}ms  peak={peak_hz:.0f}Hz "
          f"(nominal 30Hz/33.3ms)")
    if dts:   # live AWSIM breaks P_rate even at baseline; compare distributions instead
        s = sorted(dts); q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
        print(f"  DT        p5={q(.05):.1f} p50={q(.5):.1f} p95={q(.95):.1f} p99={q(.99):.1f} "
              f"max={s[-1]:.1f} ms  >40ms={sum(d > 40 for d in s)}  >100ms={sum(d > 100 for d in s)}")

    if stale_eps:
        print(f"  STALE     VIOLATED  ({stale_eps} mid-stream gap(s) > Delta_fresh)")
    else:
        print(f"  STALE     PASS      (0 mid-stream gaps)")

    fired = [n for n, v in (("P_age",v_age),("P_stuck",v_stuck),("P_rate",v_rate),("STALE",stale_eps)) if v]
    print(f"SEU_VERDICT alarms={','.join(fired) if fired else 'NONE'} "
          f"guids={len(guids)} peak_hz={peak_hz:.0f}")

if __name__ == "__main__":
    main()
