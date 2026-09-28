# FI3 — Publication Delay: how to inject it on a loopback stack, and which SEU property it exercises

> **Read the [shared foundation](../../study/foundation.md) first, then the sibling
> [FI1 report](../fi1-data-age/report.md).** This options report reuses the layer model, the publish
> path (`rclcpp→rcl→rmw→Cyclone`), the RxO/QoS rule, discovery/GUID, and the FI1 Path-A carrier + tap
> **by reference**. It is the FI3 module of the fault catalog — **Module 4** in the roadmap arc, live
> milestone **S2-5** (proposed). It is a *decision document*, not a build: it ranks the ways to inject
> a publication delay, recommends one, and hands the implementer a Stage-1-then-Stage-2 plan. Evidence
> tags follow the `recon/report.md` addendum convention: `[code]`/`[spec]`/`[runtime]` (command + date
> + what was running) / `[INFERRED]` / `[UNVERIFIED]`. Anything confirmable only by running the sim is
> tagged **`[UNVERIFIED — needs Stage 2]`** and is never asserted as fact.

## 1. What FI3 is, and the one design fact that shapes it

**FI3 (Publication Delay)** holds a sensor's samples back relative to their nominal period — a one-shot
late sample, a sustained period stretch, or added jitter — so a dependent transformer's input arrives
late and its processing overruns. The fault catalog proposes two ways to cause it: **(1)** flood the
network near the publication instant so transport congestion delays the sample, or, if that does not
bite, **(2)** edit the sensor's source to sleep before `publish()`.

The load-bearing fact that decides *how* FI3 must inject is already settled in this study, and it kills
option 1 as literally written:

- **There is no network to overload, and the target topic is far below the one queue that could
  back up.** AWSIM runs native on the host and Autoware runs in a `--net host` container; the two talk
  **UDP over `lo`, domain 0**, with **no shared-memory transport configured**
  (`study/foundation.md:152-153,276`; setup-guide §0) `[code]`/`[runtime]`. There is **no NIC and no
  switch anywhere in the AWSIM↔Autoware path** — "overload the switch" has nothing to overload
  (setup-guide §0; `lab-machine-setup.md:33-36`) `[runtime]`. And the speed topic carries a ~30 B
  `VelocityReport` at 30 Hz ≈ 0.9 kB/s (300 Hz ≈ 9 kB/s under a 10× flood), two-plus orders of
  magnitude below `WhcHigh = 500 kB`, so flooding *that* topic never fills a write-history cache — the
  FI1 10× run confirmed this directly: **all 1793 writes returned `write_rc=OK`, zero WHC stalls**
  (`fi1-data-age/report.md §3.3`) `[runtime]`.

So FI3 cannot be produced by "heavy traffic" on this stack the way the catalog imagines. It must be
produced by an **explicit delay** — inserted in a relay, in the transport queue, or in the scheduler —
and the honest analogue of "heavy traffic" on a single loopback host is **CPU/scheduler contention on
Cyclone's shared transmit/recv path**, not link congestion (§3). This is the same correction the FI1
report already applied to the roadmap's flow-control note for small-payload topics
(`fi1-data-age/report.md §3.3`); FI3 extends it from *over*-publication to *delayed* publication.

## 2. What "publication delay" actually violates — mapping FI3 onto the SEU property set

FI3 is not one fault but three timing shapes, and each stresses a different property. The distinction
matters because two of the three are caught by properties FI1 already built, and only the third needs a
genuinely new one.

| FI3 variant | Timing signature at the tap | Property that fires | New property needed? |
|---|---|---|---|
| **(a) one-shot delay** of a single sample | one long `dt` gap, then a catch-up sample; `age` spikes for one interval then recovers | arrival-freshness watchdog / **P_age** *iff* delay > Δ_fresh (165 ms); otherwise only a lone `dt` outlier | No — reuses FI1's arrival watchdog + P_rate |
| **(b) sustained period stretch** (e.g. 30→15 Hz) | every `dt` above the nominal band; sustained `age` climb if severe | **P_rate** on its **upper** edge (`dt > 40 ms`), i.e. the deadline/rate property | No — P_rate already brackets both edges |
| **(c) jitter** (delay drawn from a distribution) | `dt` variance widens; individual samples may stay in-band while the distribution does not | **P_rate** on outliers; wants a variance/jitter statistic to score cleanly | Marginal — a jitter accumulator on top of P_rate |

The **existing properties nearly cover FI3.** `P_rate = G( inter_arrival ∈ [25,40] ms )`
(`fi1-data-age/report.md §2`) is symmetric: FI1 tripped its *lower* edge with 2×/10× over-publication
(`dt` 16.6 / 3.2 ms); FI3's period-stretch trips its *upper* edge (`dt > 40 ms`). A one-shot delay
larger than Δ_fresh trips the same arrival watchdog FI1 and Module 1 already use (`STALE` then
`RECOVER`, `_common/consumer/trusting_consumer.c:101-104`) `[code]`. DDS DEADLINE is the in-band twin
of P_rate's upper edge and is *compiled in* but **unarmed by default** in this stack
(`task-5-report.md §7.1`) `[code]` — so, exactly as for every other module, the rate/deadline bound is
the SEU's to evaluate, not the middleware's.

**The one property FI3 motivates that the others do not express** is the fault's own headline —
*processing overrun in a dependent transformer*: an **end-to-end latency** property

```
G( latency(chain) ≤ Δ_latency ),  latency = t_consumed_downstream − t_produced_at_sensor
```

This is distinct from inter-arrival *at the sensor*: a stretched period can be within P_rate yet still
push a downstream transformer's execution past its own deadline, and conversely a transformer can
absorb jitter its input rate never revealed. Measuring it needs a **per-sample latency observable**
pairing the sensor's production instant with the downstream consumption instant — which is only fully
observable with the real dependent chain running, i.e. **`[UNVERIFIED — needs Stage 2]`**.

**Trace observables the SEU taps, and what the tap already logs.** The extended FI1 consumer
(`_common/consumer/trusting_consumer.c`) already emits, per sample, `arrival t`, source `guid`, `lv`,
`dt_ms` (inter-arrival), `stamp_age_ms` (`t − header.stamp`) and `value_age_ms`
(`trusting_consumer.c:80-97`) `[code]`. FI3 reuses `dt_ms` directly for variants (a)–(c) and the
`STALE`/`RECOVER` watchdog for the one-shot gap — **no tap change is needed for the rate/freshness
facet**. Two extensions are needed only for the latency facet: (i) the relay must **preserve** the
original `header.stamp` (the exact opposite of FI1, which *rewrote* it), so `stamp_age_ms` then reads
the injected delay plus transport latency directly; and (ii) `fi_seu_check` gains a jitter accumulator
(running mean/max `dt`, count outside band) and a one-shot-gap detector. **Caveat carried from FI1:**
`stamp_age`/P_age is **unusable live** because AWSIM's `/clock` and the tap's clock are not co-based —
every live sample read `stamp_age ≈ 80 000 s` (`fi1-data-age/report.md §4.1 pt 6`) `[runtime]`.
Therefore the **live** FI3 observable must be the **arrival-side `dt_ms`/gap** (wall-clock at the tap,
independent of `header.stamp`), and the `stamp_age`-based latency measurement is a **Stage-1 bench**
result only unless a common time base is established. `[UNVERIFIED — needs Stage 2]`

## 3. Can option 1 (network overload) bite on this stack? — the four sub-questions, answered

**Is there a contended link?** No. Both halves share one host network namespace; traffic is UDP on
`lo` (MTU 65536), no NIC, no switch, no shared-memory segment (setup-guide §0; `foundation.md:276`;
`lab-machine-setup.md:33-36`) `[runtime]`/`[code]`. "Overload the network switch" is not merely hard
here — the object it names is **physically absent**. State it plainly: on this deployment there is
nothing to congest at the link layer.

**Which topic could carry enough to matter?** Not the speed topic (~0.9–9 kB/s ≪ `WhcHigh`,
`fi1-data-age/report.md §3.3`) `[runtime]`. The only traffic that approaches the one queue that exists
— the shared Cyclone transmit path and the `net.core.rmem_max`/`MaxMessageSize=65500B` tuning the setup
guide adds *for* it — is **bulk sensor data: the LiDAR pointcloud and camera image**
(setup-guide §4; `task-5-report.md §5.1`) `[code]`. So if FI3 were to ride transport coupling at all,
it would have to target a **high-bandwidth sensor whose dependent transformer (NDT / perception)
overruns**, which is also the better match for the fault's "dependent transformers/actuators" wording
(§4). The tiny velocity topic is the wrong place for a transport-overload story.

**Does the flooder self-throttle before it congests anyone?** Yes, on any topic big enough to matter.
Past `WhcHigh`, Cyclone calls `throttle_writer` and blocks the **flooder's own `publish()`** until the
WHC drains or `max_blocking_time` expires (`task-3-report.md §6`; `task-5-report.md §7.2`) `[code]`.
And a flood is delivered to the **flooder's own proxy writer** on the reader side — it does **not**
delay the *victim* publisher's samples, which travel their own writer's sequence space
(`task-3-report.md §4,§6 "cost and asymmetry"`) `[code]`. So flooding delays the *flooder*, not the
victim: it is structurally the wrong tool for injecting a delay into someone else's stream.

**What is the real loopback analogue of "heavy traffic"?** **CPU/scheduler contention.** With network
channels compiled out, *all* writers share one transmit path and one event queue, and delivery runs on
Cyclone's `recv`/`dq`/`tev` threads which run at **OS default scheduling** here (no `<Threads>` element
in the XML) — so a command sample is "load-coupled" behind whatever else is on that shared path
(`task-5-report.md §5.1,§5.3`) `[code]`. On a single host the bottleneck is compute, so the faithful
way to reproduce "service unavailability delays publication" is to **starve the publisher/transformer
of CPU** — `stress-ng`, a cgroup CPU quota on the Autoware container, or `nice`/`chrt` deprioritising
the target node. This *is* the fault's "execution-time interference," but its magnitude on `lo` is
**unquantified and `[UNVERIFIED — needs Stage 2]`**, and it is coarse and hard to aim at one topic.

**Verdict on option 1:** as literally framed (overload a switch/transport near the speed topic) it
**cannot bite** — no switch, sub-`WhcHigh` payload, flooder self-throttles, and the flood delays the
wrong writer. Its only physically real cousin here is CPU/scheduler contention, which is a legitimate
*Stage-2 realism* variant on a heavy-chain sensor but is not a clean, deterministic injector.

## 4. Ranked options

Scored on **feasibility on this stack**, **fidelity to the fault's intent** (a controllable
publication delay causing a downstream overrun), **reversibility/cost**, and **which STL property each
exercises**. Verdicts are one line each.

| # | Approach | Feasibility here | Fidelity to intent | Reversibility / cost | STL property exercised | Verdict |
|---|---|---|---|---|---|---|
| **1** | **Path-A delay relay** (rclpy/ddsc node: subscribe real topic → republish with delay+jitter, `header.stamp` preserved) | **High** — pure FI1 Path-A pattern, no rebuild; needs the msgs pkg (in-container) or the bench IDL (host) `[INFERRED from FI1]` | **High** — directly and precisely produces one-shot / sustained / jitter delay on the chosen topic | **Trivial** — stop the node; `[code]`-clean like the FI1 carrier | P_rate (both edges), arrival watchdog, and (bench) end-to-end latency via preserved stamp | **Primary.** Deterministic, reversible, reuses the whole FI1 harness. |
| **2** | **`tc qdisc netem delay/jitter` on `lo`** (no source change) | **Medium** — UDP-over-`lo` is reachable by netem `[INFERRED from foundation:276]`; needs NET_ADMIN (no sudo → a `--cap-add NET_ADMIN` container, the `lab-machine-setup.md:198-202` route) `[UNVERIFIED — needs Stage 2]` | Medium — real transport delay, but **global**: `lo` root qdisc delays *all* loopback traffic incl. `/clock` and discovery; DDS' dynamic ports make per-topic filtering hard | **Trivial** — one `tc qdisc del`; but large blast radius while active | P_rate / arrival watchdog (as an untargeted, whole-bus jitter source) | **Fallback.** Cleanest *transport-layer* delay, but coarse and bus-wide; good for a "jitter the whole channel" variant, poor for aiming at one topic. |
| **3** | **CPU/scheduler overload** (`stress-ng`, cgroup CPU quota on the container, `nice`/`chrt`) | Medium — the only real "heavy traffic" analogue on a single host (§3) | **High to intent** — literally execution-time interference / processing overrun; but non-deterministic and hard to target one topic | Easy — kill the stressor / remove the quota; blast radius = whole host/container | Latency/overrun (downstream), P_rate indirectly | **Stage-2 realism complement.** Best demonstrates the *overrun* story; too blunt to be the deterministic oracle. |
| **4** | **Network flood** (option 1 as written) | **None on the speed topic** — no switch, sub-`WhcHigh`, self-throttles, delays the flooder not the victim (§3) | Low — wrong writer, wrong layer | Easy to stop | none reliably | **Reject** for the speed channel. Only conceivable on a bulk sensor topic, and even there self-throttles with unquantified effect. |
| **5** | **Cyclone QoS latency knobs** (`latency_budget`, `SynchronousDeliveryPriorityThreshold`) | Low — inert by default; reachable only out-of-band (XML + C API), and `latency_budget`'s only teeth are ANDed with `transport_priority`, which rclcpp cannot set (`task-5-report.md §5.2,§7.2`) `[code]` | Low — these *shape* delivery scheduling; they cannot *inject* a chosen delay magnitude | n/a | none — not an injector | **Reject as an injector.** Relevant only as context: the stack declares no timing contract. |
| **6** | **AWSIM C# source edit** (`AccelVehicleReportRos2Publisher.cs`, sleep before the `InvokeRepeating`@30 Hz publish) | Low — requires a **Unity rebuild**; touches the read-only real sensor | Highest — delays the genuine sensor writer at the source | **Poor** — a rebuild to insert and another to revert; not reversible in place | Same properties as the relay, but on the real writer's GUID | **Last resort.** Only if delaying the *authentic* sensor writer (not a relay) is essential; otherwise the relay dominates it on every axis but source-authenticity. |

## 5. Recommendation

**Primary: a Path-A delay relay** (option 1 in the table). It is the FI1 carrier with the transform
changed from "rewrite value/stamp" to "hold and re-emit late": an rclpy node (live, in-container) or a
bare-ddsc node (host bench) that subscribes to `rt/vehicle/status/velocity_status`, buffers each
sample, and republishes it after a delay `d` (optionally jittered), **preserving the original
`header.stamp`**. It gets a fresh writer GUID and monotonic sequence numbers automatically, so it
clears the reorder admin exactly as FI1 does (`task-3-report.md §4`) `[code]`; it needs nothing below
ROS; it is deterministic and parameterizable; and it is removed by stopping one process. It coexists
with the real writer as a second (foreign-GUID) source, and pairs with **Module 1's dispose** for a
silence-then-relay sequence (the roadmap's combined pattern) so the relay becomes the *only* live
source and the delay is unmasked at the tap.

**Fallback: `tc netem` on `lo`** (option 2) for a transport-layer, zero-ROS-code variant — best when
the goal is to jitter the *whole* channel rather than one topic, accepting that on `lo` it delays all
loopback traffic including `/clock` and discovery. **Complement, not fallback: CPU/scheduler overload**
(option 3) as the Stage-2 realism cross-check that most faithfully embodies the fault's "processing
overrun" wording, run on a heavy-chain sensor.

The reasoning is exactly the design fact of §1: because the bus is loopback and the speed topic is
sub-`WhcHigh`, both listed catalog options (flood, then source-edit) are dominated — the flood cannot
bite, and the source edit's realism is not worth a Unity rebuild when a reversible relay produces the
identical off-nominal timing trace. **Were a real contended link present** (an on-vehicle automotive
Ethernet bus), option 1 would deserve real weight and the ranking would shift; on *this* stack it does
not. `[INFERRED from the loopback topology + WHC facts]`

## 6. Target selection

**Recommend the speed channel (`rt/vehicle/status/velocity_status`) for Stage-1 mechanism validation**,
for continuity with Modules 1–3 and to reuse the FI1 tap and properties wholesale — its downstream is
`vehicle_velocity_converter → EKF` (localization), a light transformer (`fi1-data-age/report.md §4.1`)
`[runtime]`. On this channel FI3 exercises **P_rate (upper edge)** and the **arrival watchdog**, and
the latency observable is a bench-only reading (clock caveat, §2).

**For the *processing-overrun* facet specifically, the fidelity-maximising target is a high-bandwidth
sensor with a heavy dependent chain** — the LiDAR pointcloud into NDT/perception — because that is
where a late input plausibly pushes a transformer past its execution deadline, and it is the only place
the transport-coupling story (§3) could even partly hold. The consequence for observability and STL: a
heavy-chain target requires a **new tap and a new `G(latency ≤ Δ_latency)` property** (no reuse of the
FI1 velocity tap) and its result is **`[UNVERIFIED — needs Stage 2]`** end to end. The recommended split
is therefore: **prove the timing-trace mechanism on the speed channel at Stage 1; demonstrate the
overrun property on a heavy-chain sensor at Stage 2.**

## 7. Expected SEU response and the validation oracle

Mirroring the FI1 results-table style, the pass condition is "the injected timing shape produces
exactly the expected alarm set, and the negative control produces none." The safe-stop decision on a
critical, sustained violation is a **full stop** (`[LSEU-abstract]`; roadmap §"STL properties").

| Scenario | Injector (relay) | Expected alarms | Pass condition |
|---|---|---|---|
| **control** | delay 0, jitter 0, 30 Hz, stamp preserved | NONE | zero `STALE`, P_rate pass, mean `dt ≈ 33 ms` |
| **oneshot_gap** | one sample held +250 ms (> Δ_fresh 165) | `STALE`→`RECOVER`, one `dt` outlier | watchdog fires for that gap iff delay > Δ_fresh; recovers |
| **oneshot_small** | one sample held +80 ms (< Δ_fresh) | one `dt` outlier only | P_rate flags the outlier; watchdog stays quiet (the sub-threshold case) |
| **stretch_15hz** | sustained 30→15 Hz (`dt ≈ 66 ms`) | **P_rate** (upper edge) | every `dt` above the band → P_rate VIOLATED |
| **jitter** | delay ~ U/Gaussian, mean 20 ms σ 30 ms | P_rate on outliers | fraction of `dt` outside band and max `dt` recorded and non-zero |
| **latency (bench)** | +100 ms, stamp preserved | `stamp_age ≈ 100 ms + transport` | end-to-end latency observable tracks injected delay (bench-only; clock caveat live) |

The **negative control is the delay-0 relay** — it must pass every property, isolating the delay as the
sole cause of any alarm (as FI1's `control` row does). "FI3 validated" = each positive scenario emits
its expected alarm set deterministically on the bench, and (Stage 2) the downstream stack's reaction is
recorded and the SEU's preemptive full-stop fires on the sustained/critical cases.

## 8. Build plan — Stage-1 harness, then Stage-2 live

Slots into the existing `experiments/` layout, mirroring FI1's carrier / axes / properties structure.

**Stage 1 — bench (deterministic, no sim).**
- **Carrier to add:** `fi3-publication-delay/bench/src/fi3_delay_relay.c` — a bare Cyclone (ddsc)
  node reusing the shared IDL (`_common/idl`), subscribing on `rt/vehicle/status/velocity_status`
  (RELIABLE + VOLATILE + KEEP_LAST(1), the recon QoS) and republishing each sample late. Drive it with
  the existing `real_speed_monitor` as source and the extended `trusting_consumer` as tap. An rclpy
  twin (`fi3_delay_relay_node.py`) is the live carrier, exactly as FI1 kept a C bench + rclpy live pair.
- **Tap / oracle extensions:** extend `fi_seu_check` (copy `fi1-data-age/analysis/fi1_seu_check.py`)
  with a **jitter accumulator** (mean/max `dt`, count outside `[25,40] ms`) and a **one-shot-gap
  detector**; keep the arrival watchdog and P_rate as-is. Add a latency reading off `stamp_age_ms` for
  the stamp-preserved bench case. No change to `trusting_consumer.c` for the rate/freshness facet.
- **Parameter axes:**

| Axis | Values | Effect |
|---|---|---|
| `--delay-ms` | `0` \| `80` \| `250` \| … | magnitude; crosses Δ_fresh at 165 ms |
| `--jitter-ms` + `--dist` | `0` \| `uniform:σ` \| `gauss:σ` \| `burst` | jitter shape |
| `--mode` | `one-shot` \| `sustained` | single late sample vs. continuous hold |
| `--target-rate` | `30` \| `15` \| … Hz | period stretch (hold/drop to re-clock) |
| `--stamp-mode` | `preserve` \| `restamp` | preserve = latency measurable; restamp = FI1-style (defeats stamp age) |

- **Go/no-go gate → Stage 2:** the control scenario passes clean **and** every positive scenario in §7
  emits its expected alarm set on the bench. Do **not** proceed on a flaky oracle.

**Stage 2 — live (lab PC `ml-XPS-8960`, S2-5).** Gated on the same human-driven safety steps FI1 used
(`fi1-data-age/report.md §4`): S2-0 bring-up (pose→NVTL→goal→engage), **snapshot + one-command
restart**, **recapture the ephemeral live writer GUID**, a human watching the vehicle. Then: run the
relay in-container (coexist), then **silence-then-relay** via Module 1's dispose against the recaptured
real GUID; sweep delay/jitter/rate; **record the driving stack's reaction** (does anything overrun or
safe-stop today, absent the SEU?). The `--live` path refuses to run off `ml-XPS-8960` and leaves the
GUID recapture + dispose manual, exactly as FI1's does. Live measurement uses the **arrival-side `dt`**,
not `stamp_age` (clock caveat). All Stage-2 outcomes are `[UNVERIFIED — needs Stage 2]` until run.

## 9. What changes in the roadmap

- **FI3 lands as Module 4** in the arc (Module 1 freshness-loss → Module 2 wrong-value → Module 3 =
  FI1 data-age → **Module 4 = FI3 publication-delay**), a new **Phase 3c** paralleling FI1's Phase 3b,
  with live milestone **S2-5** (after FI1's S2-4).
- **The flow-control self-throttle note gains a delay clause.** The roadmap already warns that
  over-publishing past `WhcHigh` throttles the injector's own `publish()`. FI3 adds the dual: **do not
  attempt to induce a publication delay by flooding the sub-`WhcHigh` speed topic** — it self-throttles,
  delivers to the flooder's own writer, and there is no switch to overload; inject an **explicit delay**
  (relay or `tc netem`) instead. This generalises the FI1 §3.3 correction from over- to under-cadence.
- **A new STL property is registered for FI3:** the end-to-end latency / processing-overrun property
  `G( latency(chain) ≤ Δ_latency )`, whose full validation is deferred to Stage 2 on a heavy-chain
  sensor; on the speed channel FI3 reuses P_rate (upper edge) and the arrival watchdog.

## 10. Risks, rollback, blast radius

| Approach | Reversibility | Self-throttle / trap | Blast radius | Discipline |
|---|---|---|---|---|
| Path-A delay relay | stop the process | avoid inducing delay by flooding (§3) — inject it directly | one extra foreign-GUID writer on one topic | recapture GUID per run; silence-then-relay dispose stays manual (mistyped GUID disposes the wrong proxy) |
| `tc netem` on `lo` | one `tc qdisc del` | none | **whole loopback bus** incl. `/clock`, discovery — can destabilise the stack; apply briefly, scoped | needs NET_ADMIN via a `--cap-add` container (no sudo); verify it reaches DDS traffic before trusting it — `[UNVERIFIED — needs Stage 2]` |
| CPU/scheduler overload | kill stressor / remove quota | n/a | whole host or container | keep short; watch for starving unrelated safety-critical steps |
| AWSIM source edit | **rebuild to revert** — not reversible in place | n/a | the real sensor | avoid unless source-authentic delay is essential; never modify read-only `src/` |

All Stage-2 work runs authorized, isolated, on `ml-XPS-8960`, on a VM/snapshot with a one-command
restart of both halves. No changes to the read-only `src/` evidence trees.

## 11. Confidence

| Claim | Confidence | Basis |
|---|---|---|
| No NIC/switch in the path; UDP over `lo`, no shared memory | HIGH | `[runtime]` setup-guide §0 + `[code]` `foundation.md:276`, `lab-machine-setup.md:33-36` |
| Flooding the speed topic cannot delay the victim (self-throttle; wrong writer; sub-`WhcHigh`) | HIGH | `[code]` `task-3-report.md §4,§6` + `[runtime]` FI1 §3.3 (1793/1793 OK) |
| P_rate (upper edge) + arrival watchdog cover FI3 variants (a)–(c) with no tap change | HIGH | `[code]` `trusting_consumer.c:80-104`; symmetric band `fi1-data-age/report.md §2` |
| The end-to-end latency/overrun property is genuinely new and Stage-2-bound | MEDIUM | `[INFERRED]` from the fault's intent + the light speed-channel chain; latency needs the real dependent chain |
| `stamp_age`-based latency works on the bench but not live (clock caveat) | HIGH | `[runtime]` FI1 §4.1 pt 6 (live `stamp_age ≈ 80 000 s`) |
| Path-A delay relay is the low-cost, reversible primary | HIGH | `[code]`/`[runtime]` FI1 Path-A precedent (`fi1-data-age/report.md §2,§4`) |
| `tc netem` on `lo` reaches DDS traffic and is applyable without sudo via a `--cap-add` container | LOW | `[INFERRED]` reachability (UDP/`lo`), `[UNVERIFIED — needs Stage 2]` for effect + the no-sudo route |
| CPU/scheduler contention is the real loopback analogue of "heavy traffic"; magnitude unknown | MEDIUM | `[code]` `task-5-report.md §5.1,§5.3`; magnitude `[UNVERIFIED — needs Stage 2]` |
| Live downstream overrun / safe-stop reaction | UNVERIFIED | requires S2-5 on the live sim (§8) |

<!-- REPORT-COMPLETE -->
