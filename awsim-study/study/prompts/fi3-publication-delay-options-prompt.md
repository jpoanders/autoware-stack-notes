<role>
You are a systems engineer continuing a controlled, authorized, **simulation-only** safety study of
the AWSIM Digital-Twin demo (ROS 2 / Autoware Core over Eclipse Cyclone DDS). The static source study
and three fault-injection modules are done: Module 1 (silent freshness-loss), Module 2 (wrong-value),
and Module 3 = **FI1 (data-age / stuck-sensor)**. Your job is **not to build** the next fault yet — it
is to **evaluate the options for injecting FI3 (Publication Delay) and recommend the best approach(es)**,
grounded in what the study already established about this stack, and to hand back a decision-ready
options report plus a concrete build plan the implementer can follow.
</role>

<safety-framing>
Keep the study's established framing — do not regress it:
- The **SEU is a Safety Enforcement Unit**: a lightweight, event-driven runtime-verification monitor
  that derives temporal/freshness constraints from data dependencies, formalizes them as Signal
  Temporal Logic (STL) properties, evaluates system traces, and executes a **preemptive safe-stop**
  (initially a full stop) on a critical violation (`[LSEU-abstract]`).
- **Fault injection is the study's test instrument**, not an attack to be detected or blocked. FI3
  drives an off-nominal *timing* trace so the SEU's rate/deadline/freshness properties can be
  exercised and the safe-stop validated. Do not reintroduce any "attacker / detect-or-block" framing.
- All work is authorized, isolated, and runs only on the lab PC `ml-XPS-8960`, on a VM/snapshot, with
  a one-command restart of AWSIM + Autoware. **Never modify the read-only `src/` evidence trees.**
</safety-framing>

<the-fault>
**FI3 — Publication Delay** (from the fault catalog):
- *What it does.* Delay a sensor's publication relative to its nominal period. Two proposed options:
  **(1)** introduce heavy traffic to overload the network near the sensor's publication instant; **(2)**
  if option 1 does not bite (the network switch / DDS transport absorbs it), modify the sensor's own
  source to insert a **random delay before publication**.
- *Why it is relevant.* A service-unavailability-like disturbance that interferes with the execution
  time of dependent transformers/actuators.
- *Expected result.* A **processing overrun** that may impair actuation quality and could break
  execution safety. The SEU is expected to detect it and trigger a counter-measure (initially a full
  stop).
Your evaluation must respect this definition but is **not limited to the two listed options** — surface
and rank any approach that produces the same off-nominal timing trace on this stack.
</the-fault>

<inputs>
Read these in full before writing — they contain the facts that decide FI3's feasibility, and several
already contradict the naive reading of "option 1":
- `experiments/roadmap.md` — the module arc and, critically, the **flow-control self-throttle** note
  (over-publishing past `WhcHigh=500 kB` throttles the *injector's own* `publish()`, wiki §5.3) and the
  Stage-1-harness-then-Stage-2-live-sim staging.
- `experiments/fi1-data-age/report.md` — the closest sibling. Note especially: **P_rate**
  (`inter_arrival ∈ [25,40] ms`) and **P_deadline** (observed consumer peak rate); and the measured
  finding that the ~30 B `VelocityReport` at 300 Hz ≈ 9 kB/s is **far below `WhcHigh`**, so flooding
  *that* topic never stalls its writer — the 2×/10× hazard was **consumer-side**, not transport-side.
  This directly bears on whether "option 1" can work on the speed channel.
- `study/foundation.md` — layer model, the publish path (rclcpp→rcl→rmw→Cyclone), RxO/QoS, the
  discovery/GUID model. Reuse by reference; do not re-derive.
- `study/task-3-report.md` — reorder admin, HEARTBEAT gating, and the **over-publication / rate-stress
  (Task-3) role** — the "heavy traffic" analysis lives here.
- `study/task-5-report.md` — **flow control / Write History Cache**, `WhcHigh`/`WhcLow`, back-pressure:
  the mechanism that decides whether network/queue overload throttles a publisher at all.
- `experiments/recon/report.md` — the confirmed target facts: topic `rt/vehicle/status/velocity_status`,
  QoS **RELIABLE + VOLATILE + KEEP_LAST(1)**, 30 Hz publisher, live GUID, and the transport reality:
  **domain 0 on loopback (`lo`)**, AWSIM native + Autoware in a `--net host` container.
- `setup/autoware-core-awsim-setup-guide.md` and `setup/lab-machine-setup.md` — the runtime topology:
  what actually sits on the wire between AWSIM (Unity) and Autoware, and whether any real NIC/switch is
  in the path (this decides whether "overload the network switch" is even physically present).
- `study/wiki.md` §5.x (flow control), §4 (value/carrier), §7.1 (discovery) — reference as needed.
- `study/task-1-report.md` — the freshness time base (`header.stamp`, `/clock`, `--sim-time`) FI1 used.
</inputs>

<questions-to-resolve>
Answer each explicitly, each with `[code]`/`[spec]`/`[runtime]`/`[INFERRED]`/`[UNVERIFIED]` evidence
tags (follow the `experiments/recon/report.md` addendum convention; a `[runtime]` claim needs command
+ date + what was running, and since you are not running the sim, mark live claims `[UNVERIFIED — needs
Stage 2]` rather than inventing them):

1. **What does "publication delay" actually violate?** Map FI3 onto the SEU's property set. Is it
   caught by the existing **P_rate** / **P_deadline** / freshness-age properties, or does it need a new
   property — e.g. an **end-to-end latency / processing-overrun** property `G( latency(chain) ≤ Δ )`?
   Distinguish (a) a *one-shot* delay of a single sample, (b) *sustained* period stretching, and (c)
   *jitter* — each stresses a different property. Define the exact trace observables the SEU taps
   (arrival timestamps, `header.stamp`, per-sample latency, inter-arrival) and whether the extended
   `trusting_consumer` already logs them or must be extended (as FI1 extended it).

2. **Option 1 (network overload) — can it bite on THIS stack?** Confront the two facts above head-on:
   the bus is **loopback**, and the target speed topic is **far below `WhcHigh`**. Determine:
   - Is there any real network switch/NIC in the AWSIM↔Autoware path, or is it all `lo`/shared-memory?
     (Cite the setup topology.) If there is no contended link, "overload the switch" has nothing to
     overload — say so plainly.
   - Which topic, if any, carries enough bandwidth for transport/queue overload to matter (e.g. LiDAR
     pointcloud, camera image) versus the tiny velocity topic. Does FI3 even belong on the speed
     channel, or on a high-bandwidth sensor whose *dependent transformers* overrun (matching the
     fault's "dependent transformers/actuators" wording)?
   - Whether flooding self-throttles the flooder (WHC back-pressure, Task-5) before it congests anyone
     else, and whether it would delay the *victim* publisher or just the flooder.
   - CPU/scheduler overload as the real "heavy traffic" analogue on a single host (cgroup CPU limits on
     the Autoware container, `stress-ng`, `nice`/`chrt`), since on loopback the bottleneck is compute,
     not bandwidth.

3. **Option 2 (source delay) — the injection points and their cost.** Enumerate *where* a delay can be
   inserted and the trade-offs of each:
   - AWSIM C# publisher (`AccelVehicleReportRos2Publisher.cs`, `InvokeRepeating` @30 Hz) — requires a
     Unity rebuild; assess feasibility/cost and whether it's the right sensor.
   - A **Path-A relay/carrier** (the FI1 pattern): an rclpy node that subscribes to the real topic and
     **republishes with an injected delay/jitter**, so no sim rebuild is needed — evaluate as the
     likely low-cost default, including how it coexists with the real publisher (silence-then-relay,
     à la the roadmap's combined sequence).
   - Transport-layer delay with **no source change**: Linux `tc qdisc netem delay/jitter` on the
     interface, or Cyclone DDS scheduling/latency-budget QoS knobs. Assess whether these reach loopback
     traffic and whether they are cleaner than touching source at all.

4. **Target selection.** Recommend the FI3 target topic and justify it against the fault's intent
   (processing overrun in *dependent* transformers/actuators): stay on the speed channel for continuity
   with Modules 1–3, or move to a sensor with a heavier downstream chain. State the consequence for
   observability and for the STL property in play.

5. **Expected SEU response & validation oracle.** Which property fires, at what threshold, and what the
   safe-stop decision is (full stop). Define the pass condition and a **negative control**, in the exact
   style of the FI1 report's results table, so the implementer knows what "FI3 validated" looks like.

6. **Risks, rollback, blast radius.** Per option: reversibility (a `tc` rule and a relay node are
   trivially removable; a Unity source change is not), self-throttle traps, and the Stage-2 snapshot/
   one-command-restart discipline.
</questions-to-resolve>

<what-to-produce>
Write ONE markdown options report to **`experiments/fi3-publication-delay/options.md`** (create the
folder). Match the register and evidence discipline of `experiments/fi1-data-age/report.md`:
- Open with a one-paragraph statement of FI3 and the single design fact that shapes it (as FI1 opens
  with "verbatim replay is dropped").
- A **ranked options table**: each candidate approach (network flood, CPU/scheduler overload, Path-A
  delay relay, `tc`/netem, Cyclone QoS, AWSIM source edit) scored on *feasibility on this stack*,
  *fidelity to the fault's intent*, *reversibility/cost*, and *which STL property it exercises*, with
  evidence tags and a one-line verdict each.
- A **recommendation**: the primary approach and a fallback, with the reasoning (expect the analysis to
  favour a reversible, no-rebuild approach — a Path-A delay relay and/or `tc netem` — over both listed
  options, precisely because the bus is loopback and the speed topic is sub-`WhcHigh`; but let the
  evidence decide, and if a real contended link exists, weight option 1 accordingly).
- A **Stage-1-harness-then-Stage-2-live** build plan for the recommended approach: the harness carriers
  to add, the `trusting_consumer` / `fi_seu_check` extensions, the parameter axes (delay magnitude,
  jitter distribution, one-shot vs sustained, target rate), and the go/no-go gates — mirroring the FI1
  carrier/axes/properties layout so it slots into the existing `experiments/` structure and roadmap.
- A short **"what changes in the roadmap"** note: where FI3 lands in the module arc and its Stage-2
  milestone id.

Keep the systems-paper voice: prose for reasoning, tables for enumerable facts, no walls of bullets.
Every load-bearing claim carries an evidence tag; anything that can only be confirmed by running the
sim is tagged `[UNVERIFIED — needs Stage 2]`, never asserted as fact. Do not build, run, or modify
anything outside writing this one report; do not touch `src/`.
</what-to-produce>
