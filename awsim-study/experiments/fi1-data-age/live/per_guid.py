# per-GUID value age: the tap's value_age is global across writers, so an
# interleaved coexisting stream resets it; recompute it per source writer.
import re, sys, collections
R = re.compile(r"TRACE t=(\d+) event=SAMPLE rx=\d+ guid=(\S+) lv=([-\d.]+)")
by = collections.defaultdict(list)
for l in open(sys.argv[1], errors="replace"):
    m = R.search(l)
    if m: by[m[2]].append((int(m[1]), float(m[3])))
for g, rows in by.items():
    last_v, last_c, vmax = None, None, 0.0
    for t, v in rows:
        if v != last_v: last_v, last_c = v, t
        vmax = max(vmax, (t - last_c) / 1e6)
    span = (rows[-1][0] - rows[0][0]) / 1e9
    vals = sorted({v for _, v in rows})
    hz = (len(rows) - 1) / span if span > 0 else 0
    print(f"  per-guid {g[-17:]}: n={len(rows)} ~{hz:.0f}Hz max_value_age={vmax:.0f}ms "
          f"P_stuck(1500ms)={'VIOLATED' if vmax > 1500 else 'pass'} values={vals[:6]}{'...' if len(vals)>6 else ''}")
