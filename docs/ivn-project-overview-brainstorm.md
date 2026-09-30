# INE510006 Project — Overview Brainstorm

> Working notes from the 2026-09-30 brainstorm that defines the course project
> (80% of the INE510006 grade). This is the reasoning behind the project overview,
> not the overview deliverable itself. See also the project memory and
> `seminar/dds-rtps-approach/` (the companion seminar).

## Decision

Go with **Option C, expanded**: a **fault-detection study**, centred on the
**dead-reckoning (DR) detector**, but owning detectors for **all four fault
classes (FI1–FI4)**, not just FI1/FI4. This pulls the injection and timing work
back in and turns "re-implement a 2018 method" into "a complete
detection-coverage system."

The three spines that were weighed:

- **A — Detection-coverage study.** Deliverable = a measured coverage matrix
  (FI1–FI4 × observation layers). Lowest risk, best seminar fit.
- **B — Integrated monitor/observation layer feeding the LSEU.** Highest lab
  value, highest risk (depends on the full AWSIM+Autoware+LSEU stack running on
  the lab PC).
- **C — DR detector as centerpiece.** Narrowest, most clearly student-owned.
  **Chosen, then broadened to cover all four faults** — which makes it converge
  toward A while keeping the DR detector as the distinctive contribution.

## Problem framing

Stack: ROS 2 (Humble) / Cyclone DDS 0.10.5 / AWSIM + Autoware, with the
researcher's **LSEU** (Safety Enforcement Unit — an STL runtime-verification
monitor that derives temporal/freshness constraints, evaluates traces against
them, and fires a preemptive safe-stop).

Thesis: **each fault class has a distinct detectability signature; no single
observation layer catches all four.** Dead-reckoning redundancy is what closes
the FI1/FI4 blind spot.

The four fault classes:

- **FI1 — stale replay.** A stuck sensor republishes its last reading with a
  *fresh* timestamp. Arrives on time, at the right rate → `DEADLINE` satisfied.
  **Invisible to DDS and to a timing monitor.**
- **FI2 — node unresponsiveness.** Physical or logical disconnect.
  Detectable by liveliness/deadline *if configured* — but stock ROS 2 leaves
  those at `DDS_INFINITY`, so in practice a **freshness/data-age** check catches it.
- **FI3 — publication delay.** Network congestion, or a delay inserted before
  `write()`. Detectable via **data-age / latency**.
- **FI4 — intelligent attacker.** Fixed, plausible low speed/acceleration from
  an authorised node. Arrives on time with a plausible value.
  **Invisible to DDS and to a timing monitor.**

"Two clocks": FI1 and FI4 defeat timing-based detection; FI2 and FI3 are visible
to timing — but only if QoS is configured, which stock ROS 2 does not do.

## Detector families (the organizing spine)

| Family | Detects | Mechanism | Signal source |
|---|---|---|---|
| **Temporal / freshness** | FI2, FI3 | data-age bound, inter-arrival/rate, liveness | bus subscription (+ tracepoints) |
| **Value / redundancy (dead-reckoning)** | FI1, FI4 | IMU-integrated prediction vs. reported velocity vs. GNSS; residual test | bus subscription only |

In the shared-with-lab framing, the **LSEU is the temporal detector** (do not
rebuild it); the **DR detector is the net-new contribution** and can *extend*
the LSEU with a value-plausibility signal (advisor-sanctioned).

Topics involved (already tapped or easy to add): `/vehicle/status/velocity_status`,
`/sensing/imu/imu_data`, `/sensing/gnss/pose_with_covariance`, and — for near-free
redundancy — `/localization/kinematic_state` (Autoware's `ekf_localizer` already
fuses IMU+twist+GNSS; its innovation sequence is an analytical-redundancy signal).

## Monitor architecture — resolved

**In ROS 2 there is no privileged "layer."** The system is peers on a DDS bus; a
monitor is just a participant that subscribes (and never actuates, except a
safe-stop command). So "monitoring layer" is a *logical* notion; at runtime it is
node(s) subscribing to topics.

**Chosen packaging: one monitor node, detectors as internal modules, over a
shared observation substrate.**

```
                    ┌──────────────── Monitor node (1 process) ────────────────┐
   DDS bus          │                                                          │
  ─────────►  subscriptions ─► Observation substrate ─► Detector modules ─► verdict
 /velocity_status   │  (callbacks)  (shared buffers,      (plain classes)     aggregator
 /imu/imu_data      │               latest + history,                          │
 /gnss/pose         │               one time base)                             ▼
 /...chain topics   │                                                   /monitor/faults
                    └────────────────────────────────────────────  (+ safe-stop cmd) ──┘
```

Three parts, all one process:

1. **Subscriptions + observation substrate** — callbacks ingest each message
   once and write it into shared, timestamped state (latest value + short
   history, one time base). Detectors never subscribe; they read this state.
   Two signal sources: (a) bus subscription (values + arrival time — all the DR
   detector needs; enough to *detect* FI2/FI3); (b) `ros2_tracing`/LTTng
   tracepoints (per-hop internal latency — measurement refinement, not required
   for detection).
2. **Detector modules** — each a plain class implementing a uniform interface,
   no ROS inside, unit-testable with a synthetic `Observation`:

   ```cpp
   struct Verdict { bool faulted; float score; std::string reason; };
   class Detector {
   public:
     virtual Verdict evaluate(const Observation& obs, rclcpp::Time now) = 0;
     virtual const char* name() const = 0;
   };
   ```

   e.g. `FreshnessDetector` (FI2/FI3), `DeadReckoningDetector` (FI1/FI4).
3. **Aggregator + tick** — a timer callback snapshots the substrate, runs every
   detector, publishes verdicts to `/monitor/faults`, and fires the safe-stop on
   a critical verdict.

Why co-located: one intake, one clock (trivial cross-detector correlation); the
interface is a **class boundary, not a topic**, so any module can later be lifted
into its own node — getting its own subscriptions feeding the same
`Observation` — without changing detector logic. Split out only for process
isolation or multi-machine deployment (neither applies yet). Adding a detector =
writing one `Detector` subclass and registering it, not deploying a node.

## Fault-injection approach

Simulation-only, controllable injectors, one per fault class. Existing lab
machinery: `fi1-data-age/` (FI1), `fi3-publication-delay/` (LD_PRELOAD delay
shim on `dds_write`), `module1-freshness-loss/` (silent freshness loss via forged
SEDP withdrawal), shared tap `_common/consumer/trusting_consumer.c`.

**Prior art — `ros2_fault_injection`** (github.com/reeceholland/ros2_fault_injection,
MIT, ROS 2 Jazzy): a proxy/topic-remap injector framework. Its `twist` injector
already parameterizes `stale_replay_enabled`/`stale_replay_duration_ms` (≈FI1),
`delay_ms` (FI3), `drop_probability` (≈FI2), `linear_x_scale`/`force_stop` (≈FI4);
plus seeds, YAML scenarios with `start`/`duration`, a campaign runner, and report
generation. **Caveat:** it injects at the ROS *application* layer (a relay
republishes mutated messages), so it cannot honestly do FI1/FI2 at the DDS/RTPS
level the way the lab work does — and that difference is a contribution point
("existing injectors relay messages; we inject at the wire level so the fault is
indistinguishable from a genuine failure"). Use it as a **baseline / design
reference / comparison arm**, not a dependency; borrow its scenario+seed+campaign
structure and parameter vocabulary.

## Relationship to the LSEU lab work

Established by the advisor: **the LISHA lab work can serve as the course
project.** So this is one body of work, two framings. Most of the design *is* the
lab's Task-1/Task-2 deliverables:

| Course-project piece | Lab deliverable it is |
|---|---|
| Observation substrate (timestamped intake, `ros2_tracing`/LTTng, data-recording) | Task-1 monitoring/tracing doc + data-recording utilities + tracepoints |
| Fault-injection harness (FI1–FI4) | Task-2 validation instrument for the LSEU safe-stop |
| ROS 2 plumbing (msg defs, adapters, config, launch, wrappers) | Joint student responsibilities |
| Evaluation harness + metrics (detection latency/rate/false-alarm; coverage matrix) | "collect, validate, process, report the experiment metrics" |

**Boundary:** the LSEU (STL monitor + timing rules) is the researcher's code —
**re-implementing it is out of scope.** So the temporal family = *his* monitor
that you feed and drive; the DR family = *your* contribution that extends it.

**Two framings, one handling rule:** the course overview is the public study
(keep injection *parameters* generic per the clearance — types not replay
factors/run counts/detection targets); the lab deliverables hold the real
parameters and measured numbers.

## Proposed topic split for the overview deliverable (week 4)

1. **Problem & context** — the stack, the LSEU's safety role, the thesis.
2. **Fault model** — FI1–FI4 + the "two clocks" observation + QoS-default caveat.
3. **Fault-injection approach** — per-fault mechanism, simulation-only,
   controllable (parameters generic); `ros2_fault_injection` as baseline.
4. **Detection approach** — the two families, which fault each targets and why.
5. **Architecture & design** — one monitor node, detector modules, shared
   substrate (subscription + tracepoints), output → safe-stop, data flow across
   the four-node chain.
6. **Algorithms** — DR residual / chi-squared consistency test and bound choice;
   freshness/age and rate thresholds; metrics (detection latency, rate,
   false-alarm).
7. **Evaluation plan** — the FI × detector coverage matrix, tied to milestones
   (plan wk4 / intermediate wk10 / final wk16).
8. **Scope & division of work** — core vs. stretch; out-of-scope (no LSEU
   re-implementation); the two-student split.

**Natural two-student split:** one owns the temporal family + FI2/FI3 injectors;
the other owns the DR family + FI1/FI4 injectors; shared = the observation
substrate and the evaluation/coverage harness. (Splits by detector family rather
than down the middle of one component.)

## Related literature (Option C scope)

- **Spoofing Detection Using GNSS/INS/Odometer Coupling for Vehicular
  Navigation** (Sensors 2018) — the canonical GNSS vs. IMU/odometer consistency
  check; the published version of the DR residual test.
- **Carrier-phase and IMU based GNSS Spoofing Detection for Ground Vehicles**
  (UT Austin Radionavigation Lab, 2022).
- **Quantifying mobile robot localization safety for an EKF-based SLAM
  estimator** (Joerger, VT) — integrity-monitoring framing (protection levels,
  missed-detection vs. false-alarm); chi-squared innovation testing.
- **Fault Detection and Exclusion for INS/GPS tightly-coupled navigation**
  (Kassas, OSU) — FDE, the step beyond detection.
- **AI-IMU Dead-Reckoning** (Brossard et al.).
- **ros2_fault_injection** (Holland) — closest existing ROS 2 injector.
- **RTAMT** and **ROSMonitoring 2.0** — published STL-on-ROS runtime-verification
  tooling (relevant to the LSEU side).
- **Fault-Tolerant Perception for Automated Driving: A Lightweight Monitoring
  Approach**; **HALO** (fault-tolerant racing) — the "lightweight plausibility
  monitor alongside the stack" architectural role.

**Novelty for this project** (the method itself is table stakes):
1. ROS 2 / Cyclone / Autoware(+AWSIM) implementation & evaluation on the actual
   middleware, not raw GNSS/INS logs.
2. Detection *latency* under injected faults (not just rate), tied to the
   safe-stop deadline.
3. The **evasion boundary for FI4** — the dynamic-consistency budget under which
   a spoof becomes invisible to DR, characterised with a controllable injector.

## Open decisions

- **Core vs. stretch placement** of the DR detector and of wire-level tracing
  (former strand C) — confirm with the advisor.
- **DR as independent integrator vs. monitoring EKF innovation** — pick one.
- Whether to add a **"Relationship to LSEU lab work"** subsection to the overview
  scope section (recommended).
- FI1 injector: does it **refresh the payload timestamp or replay the original**?
  (Open question for the lab; design covers both branches.)
