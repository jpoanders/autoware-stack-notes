# Index — AWSIM / Autoware Core / Cyclone DDS: Temporal-Constraint & STL-Monitor Study

This is the entry point to a six-document study. Read this index for orientation, then the
**[shared foundation](foundation.md)**, then the five task reports in dependency order. Every report
is self-contained for a reader arriving by search, but each *reuses the foundation by reference* and
does not re-derive it. This index adds nothing new about the mechanisms; it fixes the objective and
the **safety / temporal-constraint model**, holds the study's central artifact — a **catalog of the
temporal/freshness (STL-shaped) properties** cross-referenced to the mechanism that establishes each —
lists the reports and their dependencies, and holds the **one shared glossary** every report links
back to.

**Source-class tags** (identical across all reports): `[repo]` = a file in this checkout under
`src/`, cited `path:line`; the Eclipse Cyclone DDS core **is in the checkout** at `src/cyclonedds/`,
so its findings are `[repo]`, not vendor guesses. `[spec]` = the OMG DDS / DDSI-RTPS specification (an
external claim). `[INFERRED]` = a temporal/freshness bound derived from the code's timing mechanism,
not measured. `[LSEU-abstract]` = a claim, definition, or target number that comes from the SEU
abstract (below), not from the source tree — never a number this static study measured.
`[UNVERIFIED]` = would require running the sim or a packet capture. `setup-guide §N` = the
authoritative record of the runtime configuration, which stands in for runtime observation because the
simulation cannot be executed.

---

## 1. Objective and the safety / temporal-constraint model

**Objective.** This is a controlled, academic source-code study of the AWSIM Digital-Twin demo — a
ROS 2 / Autoware autonomous-driving simulation — conducted entirely from source. Its purpose is to
supply the **physical half** of a runtime-verification pipeline: *where do an autonomous vehicle's
temporal and freshness constraints come from in the real Cyclone DDS stack, and how can the wire
behaviour satisfy, degrade, or violate them.* It catalogues, at each layer of the stack (rclcpp → rcl
→ rmw → rmw_cyclonedds_cpp → Cyclone DDS core → RTPS on the wire), how a data flow is timestamped,
matched, kept fresh, starved, over-published, or silently lost. The end goal it feeds is a **Safety
Enforcement Unit (SEU)**: a lightweight, event-driven runtime monitor that derives temporal
constraints from data dependencies, formalizes them as **Signal Temporal Logic (STL)** properties,
evaluates system traces against them, and executes a **preemptive safe-stop** when a critical temporal
or freshness constraint is violated `[LSEU-abstract]`. Every report therefore ends with the same
three-part closing block — **the property** (STL-shaped over the real topics), **the trace event** the
monitor observes to evaluate it, and **the safe-stop decision** (critical → halt, or degradation →
log/flag).

**The pipeline the study serves** (established once in `foundation §0`, reused by reference):

```
data-centric pub/sub abstraction
  → temporal constraint derived from a data dependency   (actuation frequency + data freshness)
    → STL property for runtime verification
      → event-driven capture & evaluation of the system trace
        → preemptive safe-stop on a critical violation
```

**The system under study (topology).** The deployment is concrete and fixed (setup-guide §0). It
stands in for a **real AV network** whose data dependencies impose the temporal constraints the SEU
verifies:

- **Autoware Core** runs in a Docker container (`ghcr.io/autowarefoundation/autoware:core-humble`)
  launched with `--net host`, so it **shares the host's network namespace**.
- **AWSIM** (the Unity simulator, Lightweight/URP build, Shinjuku map) runs **natively on the host**.
- The two communicate over ROS 2 / DDS across host↔container via the **loopback interface `lo`**, on
  **Cyclone DDS domain 0**, with **multicast on `lo`** load-bearing for discovery (setup-guide §3, §9;
  foundation §5). Discovery latency on this path bounds how fast a new or returning source becomes
  observable — i.e. how quickly a liveness property can be re-satisfied.
- The DDS vendor is **Eclipse Cyclone DDS**, forced on both sides via
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (setup-guide §6a, §9). No Fast DDS assumptions are carried
  over anywhere in this study.
- Two client surfaces sit above the same Cyclone layer: Autoware's rclcpp (C++) nodes and AWSIM's
  Unity nodes (ROS2-for-Unity / `ros2cs`, **not** in the checkout, so claims about AWSIM's own
  publishing are `[UNVERIFIED]`).
- **Sim time is the clock freshness is measured against.** The bridge publishes `/clock` at a steady
  **~90–100 Hz** (setup-guide §6d); every freshness bound `Δ_fresh` and rate window `[1/f_max,
  1/f_min]` in this study is expressed against that timeline.

**The worked targets.** Two real, vehicle-controlling command topics ground every task, because both
are published with `transient_local` durability and the vehicle obeys them (setup-guide §8). Their
actuation role is what makes a freshness or liveness violation on them a *critical* fault rather than a
loggable degradation:

| Topic | Type | Key value |
|---|---|---|
| `/system/operation_mode/state` | `autoware_adapi_v1_msgs/msg/OperationModeState` | `mode: 2` = AUTONOMOUS |
| `/control/command/gear_cmd` | `autoware_vehicle_msgs/msg/GearCommand` | `command: 2` = DRIVE |

**The fault-injection element (the test instrument).** Several reports build a process **outside the
simulation** that joins Cyclone domain 0 on `lo`. It is not modelled as an attacker: it is the study's
**fault-injection harness**, the way off-nominal (early / late / stale / wrong-value / over-published)
traces are driven *into* the system so the STL monitor is exercised and its safe-stop path validated —
the abstract's "extreme fault-injection stress tests," including the 100× over-publication case
`[LSEU-abstract]`. Two carriers recur: an ordinary rclcpp node (Cyclone-configured), and a
hand-forged RTPS speaker with no ROS 2 at all.

**The simulation caveat (binds every report).** Because the container is `--net host` and AWSIM is
native, both on Cyclone domain 0 bound to `lo`, any host process that joins domain 0 is discovered and
matched with **no network isolation to cross**. That makes driving a fault trace into the system
trivial in the sim, but it is a **simulation artifact**: it lets the study *reach* the wire behaviour
cheaply, so the derived temporal properties and the monitor's observables can be pinned to real code
paths. The bounds themselves are what transfer to a real vehicular network; the ease of injection does
not. Any timing/freshness fault the harness induces could *also* arise from an ordinary component
fault (a hung node, a starved core, a dropped link) — which is precisely why a runtime monitor is
needed regardless of adversary. Where a fault could additionally be induced *maliciously*, that is at
most a one-line aside in the report, not the point.

---

## 2. Central artifact — catalog of temporal/freshness (STL-shaped) properties

This is the study's core deliverable as an index: every temporal or freshness property the reports
surface, written STL-shaped over the real topics, cross-referenced to the **mechanism that establishes
it** (with its `path:line` home in the report) and to whether violating it is **safe-stop-critical**.
Concrete bounds are given where the code/config fixes them; bounds derived from mechanism are
`[INFERRED]`; the SEU's own targets are `[LSEU-abstract]`. The properties are the same shape the SEU
derives automatically from data dependencies `[LSEU-abstract]`; this study's contribution is showing
*where each one is set, satisfied, or lost in Cyclone*.

| # | Property (STL-shaped) | Class | Mechanism that establishes / threatens it | Where | Safe-stop? |
|---|---|---|---|---|---|
| P1 | `G( age(/control/command/gear_cmd) ≤ Δ_fresh )` | Freshness | Sample timestamp + per-writer sequence assigned on the publish path (`++wr->seq`); the reader's freshness clock starts only once delivery matching couples writer↔reader. `Δ_fresh` `[INFERRED]` in tens of ms from the `/clock` ~90–100 Hz cadence. | foundation §3, §4; task-1 §7 | **Critical** — actuation obeys the latest gear command |
| P2 | `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` | Liveness | A source going silent — clean (`rclcpp::shutdown()`, node destruction, lifecycle transition, process kill) or unclean (endpoint dispose, `lo` drop) — ends the pub stream. Deadline/liveliness QoS bound how fast absence is observable; `transient_local` latching can **mask** it. | task-1 §4, §7; task-4 §4 | **Critical** on command topics |
| P3 | `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` | Rate / actuation-frequency | Upper edge (`f_max`) violated by over-publication; the reader's `(GUID, seq)` reorder/RHC path and the `WhcHigh=500kB` back-pressure bound what the flood can do and keep detection linear-cost `[LSEU-abstract]`. Lower edge (`f_min`) is the starvation case of P2. | task-3 §4–§6, §7 | **Critical** if it starves/floods the actuation consumer |
| P4 | coupling precondition: reader matches writer ⇒ freshness clock exists | Freshness (enabling) | The RxO durability gate — a `transient_local` reader will **not match** a default VOLATILE writer (`q_qosmatch.c:167`). An unmatched pair means the freshness clock **never starts**: infinite staleness a naive reader cannot see. | foundation §4.3; task-2 §4 | **Critical** — silent no-data is the worst freshness failure |
| P5 | `G( seq strictly increases per (writer GUID) )` — no stale re-delivery | Ordering / de-duplication | Cyclone's per-proxy-writer **reorder admin** delivers each seq once, in order; a seq below `next_seq` is dropped `NN_REORDER_TOO_OLD` (`-1`). Faithful replay is blocked here; fresh-GUID replay is accepted as new. | task-3 §3, §5 | Degradation to flag (dup/replayed value), unless it drives a wrong actuation |
| P6 | freshness-masking hazard: a latched sample can satisfy P1 after the source is dead | Freshness (soundness) | `transient_local` keeps and resends the last sample to late joiners; a naive age check on that latched sample reads "fresh" though the publisher is gone. A monitor must key freshness on *observed arrivals*, not cache contents. | task-1 §4, §7 | **Critical** — this is the case a monitor must not miss |
| P7 | wire feasibility: can `Δ_fresh` / jitter bounds be met on this stack at all? | Timing determinism | Cyclone QoS shaping (deadline, latency budget, history/WHC, priority) — but `TRANSPORT_PRIORITY`/`OWNERSHIP` are **absent** from `rmw_qos_profile_t`, so jitter shaping is unreachable through rclcpp; only Cyclone XML/C-API and synchronous-delivery gating remain. Bounds the monitor's own budget on a RISC-V multicore `[LSEU-abstract]`. | task-5 §3–§7, §8 | n/a (feasibility input to all bounds) |

**How to read the catalog.** P1–P3 are the three property *shapes* the abstract names (freshness,
liveness, rate). P4–P6 are the Cyclone-specific subtleties that decide whether those shapes can be
*soundly evaluated* — an unmatched pair (P4) or a masking latch (P6) is where a naive monitor is wrong,
and each is the flagship finding of its report. P7 is the feasibility envelope: whether the wire can
meet the bounds and whether the monitor can run within budget. The trace-event and safe-stop columns
are summarized here; each report develops them in full in its three-part closing block.

---

## 3. The reports, their summaries, and dependencies

Reading and writing order is by dependency, not list order: **Foundation → Task 1 → Task 2 → Task 3 →
Task 5 → Task 4**. Task 4 is a synthesis and comes last.

```
foundation.md
   └─> task-1  (elements & shutdown → liveness / freshness loss)
        └─> task-2  (fault-injection harness; builds the external injector + the durability-match rule)
             └─> task-3  (replay / over-publication; reuses the Task 2 harness, adds seq/GUID dedup)
                  └─> task-5  (QoS → timing determinism; a lever Task 4 cites)
                       └─> task-4  (silent freshness loss + safe-stop actuation; SYNTHESIS of 1 + 2 + 5)
```

| Document | One-line summary | Depends on |
|---|---|---|
| **[foundation.md](foundation.md)** | The shared stack plus the new §0 temporal-constraint layer (data dependency → temporal constraint → STL property → trace event → safe-stop): layer map and entry point at each crossing, the publish path to the wire (where CDR, the timestamp, the sequence number, and the WHC happen), the delivery-matching rules (topic-name mangling, type matching, the QoS Requested/Offered rule and the `transient_local` durability gate that decides whether a freshness clock even starts), discovery (SPDP/SEDP on `lo` multicast, domain 0, GUIDs, ports), and the seed glossary. | setup-guide |
| **[task-1-report.md](task-1-report.md)** | **Liveness / freshness loss.** A source going silent is the strongest freshness violation and the archetypal critical fault a safe-stop must catch. Enumerates the configurable elements and keeps four shutdown mechanisms distinct — `rclcpp::shutdown()` (whole context), Node destruction (one node, in-process), lifecycle `change_state` (the one network-reachable clean lever, if managed), and signal/kill — each with a distinct freshness-loss signature and how fast it is observable, plus the hazard that a latched `transient_local` sample masks a dead publisher (P6). | foundation |
| **[task-2-report.md](task-2-report.md)** | **The fault-injection harness.** Two ways an outside process gets an *accepted* sample onto a command topic to drive an off-nominal trace into the system: PATH A, an external rclcpp node whose one load-bearing requirement is offering `transient_local`; PATH B, hand-forged RTPS reproducing discovery + CDR by hand. Includes the required *dropped-injection* trace (a volatile writer that never matches the `transient_local` reader — the P4 coupling failure made concrete). | foundation, task-1 |
| **[task-3-report.md](task-3-report.md)** | **Rate / over-publication — flagship.** The abstract's 100× over-publication stress case: an actuation-frequency (P3) constraint driven off-nominal. Faithful replay is **blocked** by the reader's reorder admin (`NN_REORDER_TOO_OLD`), forcing a pivot to over-publication, whose flood self-throttles at the `WhcHigh=500kB` watermark — the very mechanism that keeps the monitor's detection linear-cost under load `[LSEU-abstract]`. | foundation, task-2, task-5 |
| **[task-5-report.md](task-5-report.md)** | **Timing determinism & mixed-criticality.** Whether the temporal constraints can be met on the wire at all, and whether the monitor can run on a resource-constrained multicore RISC-V without disturbing real-time tasks `[LSEU-abstract]`. Finding: prioritization is **not reachable through rclcpp** — neither `TRANSPORT_PRIORITY` nor `OWNERSHIP` is in `rmw_qos_profile_t` or set by the binding; Cyclone implements both but only via its C API / XML, the network-channels/DSCP path is compiled out, and the one live lever is synchronous-delivery gating. | foundation |
| **[task-4-report.md](task-4-report.md)** | **Silent freshness loss + safe-stop actuation.** Losing a data flow *without* a clean shutdown signal, at three layers — the hardest case for a monitor, and also the candidate mechanisms by which a safe-stop could halt a flow: **protocol** (forge an SEDP/SPDP dispose — deletion is keyed on the payload GUID with no ownership check, and the participant-deletion guard degenerates on this non-secure stack); **physical** (kill `lo` — multicast off, iptables, tc/netem, link down); **application** (lifecycle/parameter, cross-ref Task 1). | foundation, task-1, task-2, task-3, task-5 |

---

## 4. Shared glossary

Every internal term is defined here **once**. Reports link back to this table rather than redefining a
term. The "canonical treatment" column points to where the term is developed in depth (the foundation
seed glossary is `foundation §6`). Ordered roughly bottom-of-stack to top, then protocol, cache, QoS,
rclcpp, and study terms.

### Stack layers and serialization

| Term | Definition (as used in this study) | Canonical treatment |
|---|---|---|
| **rclcpp** | The ROS 2 C++ client library — the API Autoware nodes write against. Publisher/Subscription/Node live here. | foundation §1, §6 |
| **rcl** | The ROS 2 C client library beneath rclcpp; thin, language-agnostic. Validates and forwards to rmw; does **not** serialize. | foundation §6 |
| **rmw** | ROS MiddleWare — the vendor-neutral C interface every DDS binding implements (`rmw_publish`, `rmw_qos_profile_t`). A policy absent from rmw is invisible to every ROS 2 middleware — and so cannot shape a temporal constraint from the client layer. | foundation §6; task-5 §4 |
| **rmw_cyclonedds_cpp** | The rmw binding for Cyclone DDS. Translates ROS calls/QoS into Cyclone `dds_*` calls; owns topic-name mangling and type-name construction. | foundation §4, §6 |
| **Cyclone DDS** | Eclipse Cyclone DDS, the DDS implementation, in-checkout at `src/cyclonedds/`. **ddsc** = its public C API (`dds_write`); **ddsi** = its RTPS protocol engine. | foundation §6 |
| **DDS** | Data Distribution Service — the OMG pub/sub standard with typed topics and QoS. | foundation §6 |
| **DDSI / RTPS** | DDSI = the DDS Interoperability wire protocol; **RTPS** (Real-Time Publish-Subscribe) is its concrete packet format (DATA, HEARTBEAT, ACKNACK, GAP). The byte layout is `[spec]`. | foundation §6 |
| **CDR** | Common Data Representation — the binary encoding DDS uses on the wire. Produced in Cyclone by `ddsi_serdata_from_sample`. | foundation §3, §6 |
| **XCDR1** | The specific CDR representation rmw_cyclonedds emits for ROS messages (4-byte encapsulation header `CDR_LE` + aligned body, no key handling for ROS types). What a forged-RTPS fault sample must reproduce. | task-2 §5.2 |

### Entities and identity

| Term | Definition | Canonical treatment |
|---|---|---|
| **DomainParticipant** | A process's membership in a DDS domain; owns writers/readers and the builtin discovery endpoints. | foundation §5, §6 |
| **DataWriter / DataReader** | The endpoints that send / receive samples on a topic. A publish is a write on a DataWriter; each write stamps the sample and advances the writer's sequence number — the raw material of a freshness/rate trace. | foundation §6 |
| **Topic** | A named, typed channel. The DDS topic name is the *mangled* ROS name, e.g. `rt/control/command/gear_cmd`. | foundation §4.1, §6 |
| **Domain (domain id)** | An isolation scope; only same-domain participants discover each other. Here effectively **0** (`Domain Id="any"`, setup-guide §2). | foundation §5, §6 |
| **GUID** | Globally Unique Identifier of a DDS entity: 12-byte participant prefix + 4-byte entity id = 16 bytes. A joining process gets a fresh, locally generated prefix — why a replayed trace re-published under a new GUID is accepted as new (P5). | foundation §5, §6 |
| **Proxy writer / proxy participant** | Cyclone's local shadow of a *remote* writer/participant, keyed by GUID. Each proxy writer owns one reorder admin; withdrawing a proxy endpoint (dispose) ends the data flow the monitor was tracking. | task-3 §3; task-4 §4.2 |

### Discovery and protocol

| Term | Definition | Canonical treatment |
|---|---|---|
| **Discovery** | How participants and endpoints learn of each other; two stages, SPDP then SEDP. Its latency bounds how fast a returning source becomes observable — i.e. how quickly a liveness property (P2) can be re-satisfied. | foundation §5, §6 |
| **SPDP** | Simple Participant Discovery Protocol — periodic multicast announcement of a participant (builtin writer id `0x100c2`), default interval 30 s. | foundation §5, §6 |
| **SEDP** | Simple Endpoint Discovery Protocol — announcement of each writer/reader with its topic, type, and full QoS (builtin writer ids `0x3c2` publications / `0x4c2` subscriptions). The QoS a writer offers is visible here before any data sample — so QoS-driven mismatch (P4) is observable pre-data. | foundation §5, §6 |
| **Multicast** | One-to-many delivery; discovery here uses ASM multicast on `lo` (SPDP/metatraffic port 7400, user-data 7401, domain 0). Disabling it on `lo` breaks the whole system — a physical route to silent freshness loss. | foundation §5, §6; task-4 |
| **Sequence number** | A per-writer, monotonically increasing sample counter (`seq = ++wr->seq`). Readers track `(writer GUID, sequence number)` to order and de-duplicate — the observable the monitor keys on for rate (P3) and ordering (P5). | foundation §3, §6; task-3 §4–§5 |
| **HEARTBEAT / ACKNACK / GAP** | RTPS control submessages of reliable delivery: a writer announces its available sequence range (HEARTBEAT); a reader acknowledges received and negatively-acknowledges missing sequence numbers (ACKNACK); a writer marks sequence numbers as irrelevant (GAP). A reliable reader must have seen a HEARTBEAT before it accepts data. | task-3 §5, §6 |
| **Reorder admin** | Cyclone's per-proxy-writer buffer that delivers each sequence number once, in order, tracking the next expected `next_seq`. A sequence number below `next_seq` is discarded as `NN_REORDER_TOO_OLD` (`-1`) — why faithful replay cannot re-inject a stale trace (P5). | task-3 §3, §5 |
| **Dispose / unregister** | The "this endpoint/instance is gone" announcement: a keyed RTPS DATA on a builtin SEDP/SPDP writer whose `statusinfo` bits are DISPOSE\|UNREGISTER. On receipt Cyclone deletes the proxy endpoint keyed on the payload GUID — with no ownership check on the dead path. A route to silent freshness loss without a clean shutdown signal. | task-4 §4.1–§4.3 |
| **statusinfo** | The RTPS parameter carrying DISPOSE/UNREGISTER status bits on a sample; distinguishes a withdrawal from a live announcement. Byte layout `[spec]`; that Cyclone sets the bits is `[repo]`. | task-4 §4.1 |

### Caches and flow control

| Term | Definition | Canonical treatment |
|---|---|---|
| **WHC** | Write History Cache — Cyclone's per-writer store of published samples, used for reliable retransmission and for resending history to late `transient_local` joiners. Bounded here by `WhcHigh=500kB` (setup-guide §4). | foundation §3, §6; task-3 §6 |
| **RHC** | Reader History Cache — the reader-side store; on `KeepLast(1)` it keeps only the newest sample per instance, so a burst collapses to "the latest one." Also where Cyclone's exclusive-ownership arbitration lives. | task-3 §6; task-5 §6 |
| **Throttle / back-pressure** | When unacked bytes exceed `WhcHigh`, Cyclone blocks the *writer's own* `publish()` (`throttle_writer`) until the WHC drains or `max_blocking_time` expires — so a reliable over-publication flood self-limits, and the monitor's rate-check stays linear-cost under it `[LSEU-abstract]`. | task-3 §6 |

### QoS policies

| Term | Definition | Canonical treatment |
|---|---|---|
| **QoS** | Quality-of-Service policies (reliability, durability, history, deadline, liveliness, …) that govern delivery and matching — and thereby whether a temporal constraint can be met on the wire. | foundation §4, §6 |
| **RxO (Requested/Offered)** | The asymmetric rule that a reader's requested QoS must be satisfiable by the writer's offered QoS, per policy, or the two **do not match** and no data flows (a non-match, not a late drop). When it fails, the freshness clock never starts (P4). | foundation §4.3, §6 |
| **Durability** | Whether samples are kept for late-joining readers. **VOLATILE** = not kept; **TRANSIENT_LOCAL** = the writer keeps recent samples and resends them. Enum order VOLATILE(0) < TRANSIENT_LOCAL(1) in Cyclone. | foundation §4.3, §6 |
| **transient_local** | The durability the command topics require. A `transient_local` reader will **not match** a volatile-only writer (P4); and a latched last sample can mask a dead publisher from a naive freshness check (P6). | foundation §4.3, §6; task-2 §4; task-1 §7 |
| **Reliability** | RELIABLE (retransmit until acknowledged, via HEARTBEAT/ACKNACK) vs BEST_EFFORT (fire-and-forget). RELIABLE readers use NORMAL reorder mode. | foundation §6; task-3 §4 |
| **History / KeepLast / depth** | Whether the cache keeps the last N samples (KeepLast, depth) or all (KeepAll). Command topics are KeepLast(1). | foundation §4.3; task-3 §6 |
| **Deadline** | A *contract and alarm*: max expected inter-sample period; raises `DEADLINE_MISSED` on starvation. The closest native analogue to a liveness/rate bound (P2/P3) — but not a scheduler, and not triggered by over-publication. | foundation §4.3; task-5 §7; task-3 §6 |
| **Latency budget** | A *hint* about acceptable delay. In this build its only teeth are the synchronous-delivery gate, ANDed with transport priority. | task-5 §5.2, §7 |
| **Liveliness (+ lease duration)** | Declares a writer not-alive when it stops asserting (AUTOMATIC = asserted by participant SPDP presence). Default participant `lease_duration` 10 s. A native — but coarse — observable for a liveness violation (P2). | foundation §4.3; task-4 §4.4 |
| **Lifespan** | Expires samples older than a bound (`drop_expired_samples`); left at default (effectively infinite) on the command topics — so the cache does **not** self-enforce freshness, and P1 must be checked by the monitor. | task-3 §6 |
| **Ownership / ownership strength** | Arbitration, not latency: under EXCLUSIVE ownership the highest-strength writer owns an instance and lower-strength writers are dropped. Cyclone implements it in the RHC, but ROS readers stay SHARED, so it never arms; an EXCLUSIVE writer also fails the RxO ownership-kind match. | task-5 §6 |
| **Transport priority** | A per-writer integer intended for higher-priority transport paths. Absent from rmw/rclcpp; in this build it only feeds synchronous-delivery gating (the network-channels/DSCP path is compiled out) — so jitter shaping for P7 is unreachable from the client layer. | task-5 §3, §5 |
| **Network channels / DSCP / DiffServ** | Cyclone's XML feature routing writers to dedicated threads and marking the IP DiffServ Code Point (DSCP) by transport priority. Guarded by `DDS_HAS_NETWORK_CHANNELS`, which is **compiled out** of standard builds — so no DSCP marking here. | task-5 §5.1 |
| **Synchronous delivery** | Delivering a matched proxy writer's samples straight off the receive thread (lower latency) when its transport priority meets a configured threshold. The one live transport-priority lever, inert at the default threshold 0. | task-5 §5.2 |

### rclcpp control surfaces

| Term | Definition | Canonical treatment |
|---|---|---|
| **Node / Context** | A Node is one participant-ish unit owning publishers/subscriptions; the Context is the shared, process-wide object `rclcpp::shutdown()` tears down. | foundation §6; task-1 §4.1 |
| **NodeOptions / InitOptions** | Process-launch configuration objects (intra-process comms, parameter overrides, `shutdown_on_signal`, domain id); read once at startup, never served on the network. | task-1 §3 |
| **`rclcpp::shutdown()`** | Shuts down the whole **context** — every node on it in that process — from *inside* the process. No DDS endpoint; not network-invokable. A liveness-loss (P2) mechanism with a whole-context blast radius. | task-1 §4.1 |
| **Lifecycle node** | A ROS 2 managed node with a configure/activate/deactivate/shutdown state machine exposed as network **services**. Whether Autoware Core uses these is `[UNVERIFIED]` (node sources absent). | foundation §6; task-1 §4.3 |
| **change_state** | The lifecycle transition service (`~/change_state`), default QoS RELIABLE + VOLATILE, so an external client matches with **no durability barrier**. The one network-reachable *clean* way to stop a flow — and, dually, a candidate safe-stop actuation lever (Task 4). | task-1 §4.3; task-4 §6 |
| **TransitionEvent** | The event a lifecycle node publishes when it transitions — a self-announced trace event the monitor can watch to confirm a clean stop versus a silent one. | task-1 §4.3 |
| **Parameter services** | Per-node services (`set_parameters`, etc.) that are matchable on domain 0; a parameter can disable a behaviour without restart, bounded by what the node declared and validates. | task-1 §3 |

### Study terms

| Term | Definition | Canonical treatment |
|---|---|---|
| **SEU** | **Safety Enforcement Unit** — the end-goal monitor this study feeds: a lightweight, event-driven runtime-verification unit that derives temporal constraints from data dependencies, formalizes them as STL properties, evaluates system traces, and executes a preemptive safe-stop on a critical violation `[LSEU-abstract]`. | this index §1; every report's closing block |
| **STL property** | A Signal Temporal Logic formula the SEU evaluates over a trace — freshness `G(age ≤ Δ)`, liveness `G(pub → F pub)`, rate `G(inter_arrival ∈ […])` — derived automatically from a data dependency `[LSEU-abstract]`. | this index §2; foundation §0 |
| **Temporal constraint** | The requirement a data dependency imposes on timing, fixed by **actuation frequency** and **data freshness** `[LSEU-abstract]`; formalized as an STL property. | foundation §0 |
| **Trace event** | The observable the event-driven monitor records to evaluate a property — a sample's arrival timestamp and sequence number, a missed deadline, a WHC stall — tagged with the stack layer at which it is visible. | every report's closing block |
| **Safe-stop** | The preemptive halt the SEU actuates when a *critical* temporal/freshness property is violated (as opposed to a degradation it logs/flags) `[LSEU-abstract]`. | this index §2; task-4 |
| **Fault injection** | Driving an off-nominal (early / late / stale / wrong-value / over-published) trace into the system to exercise the monitor and validate its safe-stop path — the study's test instrument, not an attack. | task-2, task-3 |
| **Over-publication** | Emitting samples above the nominal rate to violate the rate/actuation-frequency bound (P3); the abstract's 100× stress case `[LSEU-abstract]`. | task-3 §6 |
| **Replay** | Re-sending previously-seen traffic; faithful replay is blocked by the reorder admin (P5), so it degrades to fresh-GUID over-publication. | task-3 |

---

## 5. Pointer to the foundation

The **[shared foundation](foundation.md)** is the single derivation of the stack that all five tasks
reuse by reference, now topped by the §0 temporal-constraint layer. Its sections, and the tasks that
lean on each:

| Foundation section | Content | Most used by |
|---|---|---|
| §0 Temporal-constraint layer | data dependency → temporal constraint (actuation frequency + freshness) → STL property → trace event → safe-stop; the worked freshness/liveness example on `gear_cmd`. | all tasks (the closing block) |
| §2 Layer map | The entry-point function at each crossing (`publish → rcl_publish → rmw_publish → dds_write → … → nn_xpack_send`). | all tasks |
| §3 Publish path | Where CDR is produced, where the sample is timestamped, where the sequence number is assigned (`++wr->seq`), where the WHC is filled — the origin of every freshness/rate observable. | task-2, task-3 |
| §4.1 Topic-name mangling | The `rt` prefix: `/control/command/gear_cmd` → `rt/control/command/gear_cmd`. | task-2, task-4 |
| §4.2 Type matching | DDS type name `autoware_vehicle_msgs::msg::dds_::GearCommand_`; name-vs-hash `[UNVERIFIED]`. | task-2 |
| §4.3 QoS RxO rule | The Requested/Offered comparison and the `transient_local` durability gate that decides whether a freshness clock even starts (P4). | task-1, task-2, task-3, task-5 |
| §5 Discovery | SPDP/SEDP on `lo` multicast, domain 0, GUIDs, ports 7400/7401; its latency bounds how fast a liveness property can be re-satisfied. | task-2, task-3, task-4 |
| §6 Seed glossary | Superseded by the shared glossary in §4 above, which extends it with every task's new terms. | — |

---

## 6. Cross-report consistency notes

**Cross-references verified.** Every inter-report pointer resolves to a real section: Task 1's
references to Task 4's protocol/physical layers; Task 2's to Tasks 3/4/5; Task 3's to Task 2's harness
and Task 5 §6–§7; Task 4's to Task 1 §3/§4, Task 2 §5/§6, Task 3's reorder path, and Task 5 §5/§6; Task
5's to Tasks 2/3/4. No broken cross-reference was found, so none was edited.

**Terminology is consistent** across reports on every load-bearing identifier: the builtin entity ids
(`0x100c2`, `0x3c2`, `0x4c2`), the ports (7400 SPDP/metatraffic multicast, 7401 user-data multicast),
the durability enum order (VOLATILE 0 < TRANSIENT_LOCAL 1), the QoS-match citation
(`q_qosmatch.c:167`), the sequence-number assignment (`q_transmit.c:1286`), the WHC watermark
(`WhcHigh=500kB`), and the reorder discard (`NN_REORDER_TOO_OLD = -1`). Each STL-shaped property (P1–P7
above) is used with the same bound and the same `[INFERRED]`/`[LSEU-abstract]` tagging in the report
that owns it. No term is used before it is defined once the glossary above is in hand.

**Nothing is re-derived.** Spot-checks confirm the reuse discipline: every report's closing block
reuses `foundation §0`'s property/trace-event/safe-stop schema rather than restating it; Task 2 §4
cites the publish path and durability rule from the foundation rather than re-tracing them; Task 3 §6
cross-references Task 5 for the KeepLast/DEADLINE/flow-control facts instead of re-deriving them; Task 4
§6 defers the clean shutdown levers to Task 1 and adds only the new silent-freshness-loss framing.

**Minor inconsistencies recorded (not fixed, to avoid rewriting the reports):**

- In `foundation.md` §2, the Mermaid diagram labels the `rmw_publish → dds_write` crossing
  `rmw_node.cpp:1817`, while the same section's table and §3 step 4 cite `rmw_node.cpp:1825-1834`. The
  table/prose value is the one the other reports rely on; the diagram label is a stale line number.
- The `rmw_qos_profile_t` struct is cited as `rmw/types.h:471-512` in `foundation.md` §4.3 and as
  `:471-513` / `:468-513` in `task-5-report.md`. These are the same struct; the one-line range
  differences do not affect the finding that `transport_priority` and `ownership` are absent (P7).

Both are trivial citation-range discrepancies within single reports, not broken cross-references, and
neither changes any behavioral claim.

---

## 7. Out of scope — follow-on safety-reframe work

This revision sweep reframed only the six study documents (foundation, the five task reports, and this
index; plus `wiki.md`, `wiki_summary.md`, and `source-code-study-summary.md`). The following still
carry the **old Security-Enforcement-Unit framing** and each needs its own safety reframe as separate
follow-on work — they were deliberately **not** touched here:

- **`teach/`** — the self-contained `/teach` course (HTML lessons + quiz) built to learn `wiki.md`. Its
  lessons still teach the SEU as a network guard and must be re-cut to the STL-monitor / safe-stop
  narrative, in lesson order, once the wiki reframe settles.
- **The attacker-PoC line** — the `awsim-seu-poc-roadmap` memory and `poc-recon.md`. Framed as building
  a kill+spoof attack against the ego-speed monitor; the whole line needs recasting as a
  fault-injection *harness* that drives off-nominal traces to validate the safe-stop path (its own
  reframe, not a marker swap).
- **`CLAUDE.md`** — the repo's project instructions still describe a Security Enforcement Unit and a
  security/threat objective; the ground rules there should be re-pointed at the safety/STL purpose.
- **The master five-tasks prompt** (`prompts/awsim-fault-injection-five-tasks-prompt.md`) — still
  specifies the tasks around attacks/enforcement and the old closing block; the generator spec should
  be updated so a fresh run produces safety-framed reports directly.
- **`run-study.sh`** — the orchestrator and its completion-marker contract (`<!-- REPORT-COMPLETE -->`)
  are unchanged; if the safety framing becomes the canonical generation target, the runner and its
  markers should be aligned with this sweep's `<!-- SAFETY-REVISION-COMPLETE -->` convention.

<!-- SAFETY-REVISION-COMPLETE -->
