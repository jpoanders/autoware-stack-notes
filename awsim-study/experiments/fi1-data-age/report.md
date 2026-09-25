# FI1 — Data Age Violation: injecting old data and the SEU properties that catch it

> **Read the [shared foundation](foundation.md) first.** This report reuses the layer model,
> publish path, RxO/durability rule, and discovery/GUID model **by reference**, and reuses the
> Phase-2 PoC harness under `experiments/`. It is the FI1 module of the fault catalog: **Module 3**,
> milestone **S2-4** in [`poc-stage2-run-plan.md`](poc-stage2-run-plan.md). Evidence tags follow the
> `poc-recon.md` addendum: `[code]`/`[spec]`/`[INFERRED]`/`[UNVERIFIED]`, plus `[runtime]` (command +
> date + what was running).

## 1. What FI1 is, and the one design fact that shapes it

**FI1 (Data Age Violation)** introduces *old data* onto the speed channel — a previous sample
replayed at 1×/2×/10× — to show that (a) a naive feedforward consumer uses stale data improperly, and
(b) the SEU's STL monitor detects data older than expiry and can drive a preemptive safe-stop. The
2×/10× variants additionally stress the actuation rate / pipeline deadline.

The load-bearing fact that dictates *how* FI1 must inject is already established in the study:

- **Verbatim replay is dropped before delivery.** Each reader's per-proxy-writer reorder admin
  remembers `next_seq` and discards any DATA with `seq < next_seq` as `NN_REORDER_TOO_OLD`, so a
  packet-level capture-and-resend never becomes a trace event `[code]`
  (`study/task-3-report.md:37-64,126`). A faithful replay is therefore *useless* against this stack.

That is exactly why FI1's method is "replay old data **with new timestamps**": the old **payload** is
re-emitted through a **live writer** (Path A, `study/task-2-report.md:113-185`), which is assigned a
fresh, monotonic sequence number automatically — so it clears the reorder admin — while the **value**
is stale. There are two timestamps and the SEU keys on the message one:

- the DDS `source_timestamp` (SampleInfo) is stack-assigned and honest;
- the message's `header.stamp` field is ordinary application data the publisher fills in, and the
  freshness property is written over that field `[code]` (`study/task-1-report.md:696-700`).

So a Path A writer controls the sample's *apparent age* purely by what it writes into `header.stamp`,
with **no hand-forged RTPS needed** for either FI1 variant `[INFERRED from the two code facts]`.

## 2. The injector and the three axes

FI1 is a **Path A** injection (`study/task-2-report.md:113-185`) — a legitimate writer that reuses
the real publish path and gets fresh sequence numbers, so it needs nothing below ROS. There are two
interchangeable carriers, same three axes and same wire result:

- **`experiments/fi1-data-age/fi1_ros2_ws/src/fi1_injection/fi1_injection/fi1_stuck_sensor_node.py`** — the true Path A carrier, an **rclpy node**
  publishing the real `autoware_vehicle_msgs/msg/VelocityReport` through `rclcpp→rcl→rmw→Cyclone`. Use
  `--sim-time` so `header.stamp` is stamped against AWSIM's `/clock` (the correct freshness time base,
  `study/task-1-report.md §5.4`). **This is the live-run carrier.** It needs the msgs package, so it
  runs inside the Autoware Core container (or a host with the msgs overlay sourced), not on the bare host.
- **`experiments/fi1-data-age/bench/src/fi1_stuck_sensor.c`** — a bare **Cyclone (ddsc)** writer using the shared harness
  IDL. Wire-equivalent (name-only discovery, matching mangled type name), needs no msgs package, so it
  is the **host bench** carrier used for the deterministic Step-0 smoke below.

Both publish on `rt/vehicle/status/velocity_status` with the recon-confirmed writer QoS **RELIABLE +
VOLATILE + KEEP_LAST(1)** (`experiments/recon/report.md:45`), parameterized on:

| Axis | Values | Effect |
|---|---|---|
| `--value-mode` | `stuck` \| `replay-window` | frozen old value, or a looping window of old values |
| `--value-source` | `synthetic` \| `capture` | made-up payload, or the live writer's own recent samples captured off the topic (Path A node only) |
| `--stamp-mode` | `fresh` \| `old` | `header.stamp = now` (defeats freshness-by-stamp) or back-dated by `--backdate-ms` (age > expiry) |
| `--rate-mult` | `1` \| `2` \| `10` | emit at 30/60/300 Hz (jitter → deadline pressure) |

The SEU stand-in is `experiments/fi1-data-age/analysis/fi1_seu_check.py`, an offline evaluator over the consumer
trace. The trusting_consumer (`experiments/_common/consumer/trusting_consumer.c`) was extended to log two new
per-sample observables next to the existing arrival-age watchdog: `stamp_age_ms = t_now −
header.stamp` and `value_age_ms = t_now − t_last_value_change`.

### The four properties

- **P_age (stamp freshness)** — `G( t_now − header.stamp ≤ Δ_expiry )`. Δ_expiry = 165 ms `[INFERRED]`
  (≈5×33 ms; reuse of the Δ_fresh anchor, foundation §0). Catches `--stamp-mode old`.
- **P_stuck (value-age / information liveness)** — `G( time_since_last_change(value) ≤ Δ_stuck )`,
  Δ_stuck = 1500 ms `[INFERRED]` (well above the nominal ~1 s value-update cadence of the stand-in
  writer). The property that catches the fresh-stamp stuck sensor **which P_age and the arrival
  watchdog cannot see**.
- **P_rate (actuation frequency)** — `G( inter_arrival ∈ [25, 40] ms )` `[INFERRED]`. Catches 2×/10×.
- **P_deadline** — observed, not asserted: min inter-arrival / peak consumer rate under flood.

## 3. Bench run (Step 0) — results `[runtime]`

**`[runtime]`** — `cd poc-harness && DUR=6 ./run_fi1.sh --bench`, **2026-09-24**, on **ml-XPS-8960**,
**bench harness only (no AWSIM, loopback domain 0)**. Six 6-second scenarios; the extended
trusting_consumer is the tap, `fi1_seu_check.py` is the SEU.

| Scenario | Injector | Expected alarms | SEU verdict | Match |
|---|---|---|---|---|
| control | `real_speed_monitor` (nominal, changing value, fresh stamp, 30 Hz) | NONE | `NONE` | ✓ |
| stuck_fresh_1x | stuck value, fresh stamp, 30 Hz | P_stuck | `P_stuck` | ✓ |
| stuck_fresh_2x | stuck value, fresh stamp, 60 Hz | P_stuck, P_rate | `P_stuck,P_rate` (61 Hz) | ✓ |
| stuck_fresh_10x | stuck value, fresh stamp, 300 Hz | P_stuck, P_rate | `P_stuck,P_rate` (312 Hz) | ✓ |
| stuck_old_1x | stuck value, back-dated 2 s, 30 Hz | P_age, P_stuck | `P_age,P_stuck` | ✓ |
| window_fresh_1x | 4-value replay window, fresh stamp, 30 Hz | NONE (evades P_stuck) | `NONE` | ✓ |

### 3.1 The headline: the fresh-stamp stuck sensor is invisible to freshness monitors

`stuck_fresh_1x` consumer trace `[runtime]` — `stamp_age_ms` stays ~0.1 ms (fresh) while `value_age_ms`
climbs without bound, and the arrival watchdog emits **zero** `STALE` events:

```
event=SAMPLE rx=0   lv=5.000 dt_ms=0.00  stamp_age_ms=0.1 value_age_ms=0.0
event=SAMPLE rx=45  lv=5.000 dt_ms=33.30 stamp_age_ms=0.1 value_age_ms=1500.0   <- P_stuck trips
event=SAMPLE rx=139 lv=5.000 dt_ms=33.32 stamp_age_ms=0.1 value_age_ms=4633.3
# grep -c event=STALE  ->  0   (arrival-freshness watchdog never fires)
```

This is FI1's point: the value is stale but every freshness signal a naive monitor has — arrival
inter-arrival, and even the sample's own `header.stamp` — looks perfectly fresh. Only **P_stuck**, a
value-age property, catches it. A feedforward consumer that trusts arrival cadence consumes the stale
speed improperly (the accident the SEU prevents).

### 3.2 Back-dated stamp is caught directly by P_age

`stuck_old_1x` first sample `[runtime]`: `stamp_age_ms=2000.1` from `rx=0` → **P_age** fires on the
first sample. The literal "older than expiry" case needs only the stamp property.

### 3.3 Over-publication (2×/10×) → rate + deadline

At 2×/10× the consumer sees 61 Hz / 312 Hz `[runtime]`; **P_rate** fires (`dt` 16.6 ms / 3.2 ms, both
outside the [25, 40] ms band) and the peak-rate observation records the deadline pressure on the
consumer side. **The 10× flood did not trip the writer's WHC back-pressure**: all 1793 writes returned
`write_rc=OK` `[runtime]`, because the `VelocityReport` payload (~30 B) at 300 Hz ≈ 9 kB/s is far below
`WhcHigh=500 kB` (`study/task-5-report.md`). So on this topic the 2×/10× hazard is **consumer-side
deadline/jitter**, not writer self-throttle — a useful correction to the roadmap's flow-control note
for small-payload topics.

### 3.4 A limitation the bench also exposed

`window_fresh_1x` replays a *window* of old values with fresh stamps: the value changes every sample,
so `value_age_ms` stays 0 and **P_stuck is evaded** (SEU verdict `NONE`) `[runtime]`. A stuck-at
property catches a *frozen* sensor but **not** old data whose value still varies. Catching a windowed
replay of stale-but-varying data would need a content-semantic or cross-signal property (e.g. speed
inconsistent with other motion signals) — flagged for the SEU design, out of FI1's scope.

## 4. Live plan (S2-4) — what remains, and why it stops here

The bench (Step 0) validates the mechanism and every property deterministically without the sim. The
**live run is gated on human-driven, safety-critical steps** that cannot be automated and are recorded
in [`poc-stage2-run-plan.md`](poc-stage2-run-plan.md) §6:

1. **S2-0 bring-up** (human): launch AWSIM + Autoware Core, set pose → NVTL → goal → engage autonomous
   (RViz). Capture `ros2 topic info -v` / `ros2 topic hz /vehicle/status/velocity_status` as `[runtime]`.
2. **Safety gate**: snapshot / one-command restart of both halves; **re-capture the ephemeral live
   writer GUID (B5)**; a human watching the vehicle.
3. **S2-4 injection** — Path A rclpy node, run inside the Autoware container
   (`experiments/fi1-data-age/run_fi1.sh --live [--silence]`, or `run_fi1.sh --ros [node args]` for a single shot):
   - **Coexist** — FI1 writer joins as a second (foreign-GUID) writer; confirm the consumer logs the
     stuck value under a foreign GUID and P_stuck fires while the arrival watchdog stays quiet.
   - **Silence-then-inject** — fire Module 1's dispose (`inject/forge_withdraw.py`) against the
     recaptured real GUID, then FI1 supplies the only live samples: the correlated "real source stale +
     foreign writer takes over with old data" pattern (parallels S2-3 for wrong-value).
   - Rate sweep 1×→2×→10×; back-dated variant; **record the driving stack's reaction** (does anything
     safe-stop today, absent the SEU?) — the Stage-2-only observation this whole study defers to the sim.

The `--live`/`--ros` paths are wired in `run_fi1.sh`; they refuse to run without `autoware_vehicle_msgs`
importable (i.e. off the container/overlay), `--live` refuses to run off `ml-XPS-8960`, and both leave
the GUID recapture + dispose manual on purpose (a mistyped GUID disposes the wrong proxy).

### 4.1 Live run (S2-4, coexist) — results `[runtime]`

**Run:** 2026-09-25 12:53–13:12 on `ml-XPS-8960`. AWSIM-Demo-Lightweight + `autoware:core-humble`
container, both on Cyclone over `lo`. The Path A node ran inside the container
(`ros2 run fi1_injection fi1_stuck_sensor --sim-time …`). The tap ran on the host, and a rosbag was
recorded in the container. The harness is in `live/`
(`run_case.sh NAME DUR [node args | --baseline]`, `reset_aw.sh`, `engage.sh`). Raw logs and bags are in
`logs/live/` (gitignored). The bring-up was scripted: the initial pose is published at the GNSS position
(NDT's align converges the heading to 33.8°, NVTL 3.18), the goal is placed 80 m ahead, and autonomous
mode is engaged with the latched mode/gear topics from setup-guide §8. The stack was restarted and the
vehicle teleported back to spawn before every case.
**Load caveat:** another user's CARLA (Epic, offscreen) and a Python AV stack shared the GPU/CPU for
the whole run, so the timing numbers (P_rate, achieved rate) are pessimistic.

**S2-0 facts settled.** The real writer is node `AWSIM`, RELIABLE / VOLATILE / KEEP_LAST(1). The only
Autoware reader is `/sensing/vehicle_velocity_converter`, RELIABLE / VOLATILE / KEEP_LAST(10). The
converter feeds `twist_with_covariance` into the EKF, so the velocity channel reaches **localization**
before it reaches control.

Only the **coexist** case was run. Silence-then-inject was not run: the dispose is still manual by
design.

| Case | Injected (the rest is the real AWSIM writer) | Tap SEU (combined stream) | Per-GUID P_stuck on injector | Autoware reaction (bag) |
|---|---|---|---|---|
| S0 parked, baseline | — | P_stuck **and** P_rate fire | — | none; NVTL 3.15–3.20 |
| S1 parked, synthetic stuck | 5.0 m/s, fresh stamp | same as S0 | VIOLATED | **EKF v → 5.0 m/s, EKF pose drifts 67.8 m, NVTL 3.18 → 1.55 and does not recover; control_cmd a = −10 m/s²; init_state stays INITIALIZED** |
| S2 parked, capture stuck | real 0.0, fresh stamp | same as S0 | VIOLATED | none |
| S3 parked, capture ×10 | real 0.0, asked 300 Hz, **got ~43 Hz** | same as S0 | VIOLATED | none |
| S4 parked, capture back-dated 2 s | real 0.0 | same as S0 | VIOLATED | none (stamp age ignored) |
| D0 driving, baseline | — | P_stuck pass; P_rate fires | — | none; NVTL ≥ 2.99 |
| D1 driving, capture stuck | real 4.183 m/s held for 8 s | **P_stuck pass** | VIOLATED (8 s) | mild: NVTL min 2.66, recovers |
| D2 driving, capture replay-window | loop of 30 real samples (3.94–4.10) | P_stuck pass | **pass** | none: NVTL ≥ 3.04 |
| D3 driving, capture back-dated 2 s | real 3.957 m/s, stamp −2 s | P_stuck pass | VIOLATED | none: NVTL ≥ 3.01 (stamp age ignored) |

What the live run shows beyond the bench:

1. **Autoware has no data-age defence on this channel.** In S1 a false speed silently corrupted
   localization: 68 m of dead-reckoned drift on a parked car, and NVTL below the ~2.3 safety threshold.
   Nothing changed `initialization_state` or raised a failure. Pose re-init did not recover it; only a
   stack restart did. Back-dated stamps (S4, D3) got no reaction at all, because the converter does not
   check `header.stamp` age. The preemptive safe-stop §5 asks for does not exist today.
2. **The bench thresholds do not transfer to the live stream.** Parked, the real writer legitimately
   holds 0.0, so P_stuck fires on the uninjected baseline. The real AWSIM stream also has gaps up to
   81 ms and bursts down to 1.3 ms apart, so P_rate [25, 40] ms fires on both baselines. P_stuck needs
   an "unless the vehicle is stationary" guard (e.g. a cross-check against wheel or IMU motion), and
   P_rate needs bounds measured from the live channel.
3. **Coexistence masks P_stuck at the tap.** The tap's `value_age` spans all writers. Interleaved
   real samples keep resetting it, so the fresh-stamp stuck sensor passes (D1, D3). It is caught
   only when value age is computed **per source GUID** (`live/per_guid.py`). A foreign second writer
   on a single-writer topic is itself the stronger signal.
4. **Replay-window from captured data evades every value property** (D2): per-GUID P_stuck passes too.
   This confirms §3.4 live with genuine values.
5. **Faithful capture is less harmful than a made-up value.** Replaying the real current value
   (S2, D1–D3) barely moves the stack. The damage in S1 came from the value **disagreeing** with the
   vehicle's true motion. The disruptive FI1 variant is therefore a *divergent* stale value, e.g.
   captured at speed and replayed after the vehicle stops.
6. **P_age remains unusable live** (as expected, see the clock caveat in `fi1_ros2_ws/README.md`).
   Every sample reads a stamp age of ~80 000 s.

Two bugs in the injector were found and fixed during this run. **With `--sim-time`, the node stopped
after 0 samples**, because `t0` was read before `/clock` arrived. Separately, `--duration` left the
process hung after "done". Any earlier `--sim-time` live run would have injected nothing.

## 5. What FI1 hands the SEU

1. **Property.** FI1 exercises **P_stuck** (the fresh-stamp stuck sensor — the case no arrival- or
   stamp-based freshness catches), **P_age** (back-dated stamp), and **P_rate**/**P_deadline** (2×/10×).
2. **Trace event.** Per-sample `(arrival t, source GUID, value, dt, stamp_age, value_age)` — the tap
   the SEU reads. Fresh-stamp injection is distinguished from Module 1 by: age bounded, value_age
   diverging.
3. **Safe-stop validation.** The bench proves positive (injection → correct alarm) and negative
   (nominal → zero alarms) controls; the live S2-4 run is what confirms the end-to-end preemptive
   safe-stop against the real actuation path.

## 6. Confidence

| Claim | Confidence | Basis |
|---|---|---|
| Verbatim replay dropped ⇒ FI1 must re-emit via a live writer | HIGH | `[code]` reorder admin (`task-3-report.md:37-64`) |
| SEU controls apparent age via `header.stamp`; no Path B needed | HIGH | `[code]` timestamp rule (`task-1-report.md:696-700`) + `[runtime]` (stamp_age tracks the injected stamp exactly) |
| P_stuck catches the fresh-stamp stuck sensor that P_age/arrival miss | HIGH | `[runtime]` bench (§3.1): stamp_age~0, 0 STALE, P_stuck trips |
| 10× flood is consumer-side deadline, not writer WHC stall (small payload) | MEDIUM | `[runtime]` (1793/1793 writes OK) + `[code]` WhcHigh; specific to this ~30 B topic |
| Windowed replay evades a stuck-at property | HIGH | `[runtime]` (§3.4) + live D2 (§4.1) |
| Autoware Core has no data-age/plausibility defence on velocity_status; a false speed corrupts localization unflagged | HIGH | `[runtime]` live S1, S4, D3 (§4.1) |
| Bench P_stuck/P_rate thresholds false-alarm on the uninjected live stream | HIGH | `[runtime]` live S0, D0 (§4.1); P_rate magnitude may partly be host load |
| Tap's global value_age masks a coexisting stuck writer; per-GUID catches it | HIGH | `[runtime]` live D1, D3 (§4.1) |
| rclpy injector cannot sustain 10× (300 Hz) in the container | MEDIUM | `[runtime]` live S3 (~43 Hz); measured under CARLA load |
| Live downstream safe-stop reaction | UNVERIFIED | requires S2-4 on the live sim (§4) |

<!-- REPORT-COMPLETE -->
