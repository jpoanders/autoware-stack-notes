# AWSIM / Autoware / Cyclone DDS — Temporal-Constraint & STL-Monitor Study Summary

This is a source-code study of how the communication stack of an autonomous-driving simulation —
AWSIM + Autoware Core over Eclipse Cyclone DDS — carries the **temporal and freshness constraints**
that a runtime monitor must verify. It reads the stack layer by layer to locate where each data
dependency's constraint — set by **actuation frequency** and **data freshness** — is established, met,
or lost on the wire. It exists to feed the design of the **SEU (Safety Enforcement Unit)**: a
lightweight, event-driven runtime-verification monitor that derives these constraints automatically
from the pub/sub data dependencies, formalizes each as a **Signal Temporal Logic (STL)** property,
evaluates system traces against it, and executes a **preemptive safe-stop** when a critical temporal or
freshness constraint is violated `[LSEU-abstract]`.

Everything below is in service of one question: where do these temporal/freshness properties come from
in the real Cyclone stack, and how can the wire behavior satisfy, degrade, or violate them — so a trace
monitor can observe the violation and decide whether to safe-stop. Where later findings build
injectors, replay, or endpoint-withdrawal mechanisms, they are the study's **fault-injection harness**:
ways to drive off-nominal (early / late / stale / wrong-value / over-published) traces into the system
so the monitor is exercised and its safe-stop path validated — matching the abstract's "extreme
fault-injection stress tests" `[LSEU-abstract]`. The simulation is not run; this is a static source
study, so the abstract's Hardware-in-the-Loop numbers (`<2%` CPU, negligible interference, linear
verification cost, 100× over-publication) are motivation, cited `[LSEU-abstract]`, never reproduced
here.

---

## The system under study

Autoware Core runs in a Docker container with host networking (`--net host`); AWSIM (Unity, Shinjuku
map) runs natively on the same host. The two talk over loopback (`lo`), Cyclone DDS domain 0, with
multicast on `lo` carrying discovery. `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` is forced on both sides —
no other DDS vendor is relevant anywhere in this study. Two client bindings sit on the same Cyclone core:
Autoware's `rclcpp` C++ nodes and AWSIM's `ros2cs` (ROS-for-Unity) nodes; both were read from source, so
findings apply to both unless noted.

Load-bearing settings, stated once:

| Setting | Value | Why it matters for a temporal/freshness monitor |
|---|---|---|
| Domain | 0 | Only same-domain processes discover each other; the monitor taps the same domain |
| Participant index | none | Ports are ephemeral, not fixed |
| Multicast on `lo` | enabled | Required for discovery; disabling it silences every node — a whole-network freshness loss |
| Max message size | 65500 B | Fragmentation limit; relevant to fault-injecting oversized samples |
| Write History Cache high-water mark (`WhcHigh`) | 500 kB | The back-pressure watermark that self-throttles over-publication — a rate-constraint boundary |

Two vehicle-controlling topics ground every finding, both published `transient_local`:
`/system/operation_mode/state` (`mode: 2` = AUTONOMOUS) and `/control/command/gear_cmd` (`command: 2` =
DRIVE). A third topic becomes newly load-bearing here: **`/clock` (~90–100 Hz)** — because actuation
frequency and freshness are measured against sim time, `/clock` is the time base every STL property's
`age()` and `inter_arrival()` is evaluated against.

**Temporal-constraint / fault-injection model.** The topology stands in for a real AV network whose data
dependencies impose temporal constraints. Off-nominal traces are driven into that topology by a process
joining domain 0 on `lo` — an ordinary ROS 2 node or a hand-forged RTPS speaker — to author
early / late / stale / wrong-value / over-published samples and exercise the monitor's safe-stop path.
Because the container uses host networking, any host process can join with no isolation to cross — an
artifact of this simulation's co-location that makes it a convenient **fault-injection harness**, not a
threat claim about the real deployment. *(That the same co-location would also let a compromised ECU
inject faults maliciously is a one-line footnote; it is no longer the organizing idea — the point is
that these mechanisms produce the traces the STL monitor must be able to catch.)*

---

## How the stack works, in brief

A publish call descends five library boundaries before a byte leaves the interface: `rclcpp` → `rcl` →
`rmw` → `rmw_cyclonedds` → Cyclone core → RTPS wire. The vendor split begins exactly at
`rmw_publish → dds_write`. Three facts from this path govern what a trace monitor can observe:

- **Serialization is Cyclone-only.** The message becomes CDR bytes for the first time inside Cyclone
  (`ddsi_serdata_from_sample`); every layer above just forwards the native struct.
- **Sequence numbers are per-writer and monotonic**, assigned as `seq = ++wr->seq` at the same point the
  sample is inserted into the writer's **Write History Cache (WHC)**. The WHC is what a reliable writer
  retransmits from on NACK, and — for `transient_local` topics — what it **latches and replays** to a
  reader that joins late. That latching is a first-class freshness hazard: a latched last sample makes a
  dead publisher look alive to a naive reader (see Finding 1). `WhcHigh` (500 kB of unacknowledged data)
  is the flow-control ceiling on that cache and the natural rate boundary.
- **AWSIM shares this exact path below the language binding.** `ros2cs` is a C# binding over the same
  host ROS 2 / Cyclone libraries `rclcpp` uses, so serialization, sequencing, and WHC behavior are
  identical for both client surfaces.

**Matching has three independent gates, all checked at discovery time, before any data is sent** — a
mismatch is a non-connection, not a message dropped later: topic name (mangled with an `rt/` prefix),
type name (plus a type hash, if the build enables type discovery — unverified which way this build was
built), and QoS compatibility under the **Requested/Offered (RxO)** rule: for each policy, the reader's
*requested* value must be satisfiable by the writer's *offered* value. **Durability is the load-bearing
policy**: Cyclone orders `VOLATILE(0) < TRANSIENT_LOCAL(1)` (`q_qosmatch.c:167`), so a `transient_local`
reader never connects to a volatile-only writer. Both anchor topics' readers request `transient_local`,
so this is the one gate any injected trace must clear — and an injector that misses it leaves the
freshness clock **un-started**, an infinite staleness a naive reader cannot see.

**Discovery** is two-stage multicast over `lo`: SPDP announces participants (30 s interval), then SEDP
announces each endpoint together with its topic, type, and full QoS. Discovery multicast runs on port
7400 (domain 0); disabling multicast on `lo` alone silences every node in the container, which is the
basis of the whole-network freshness loss described in Finding 5.

---

## Findings

Each mechanism is stated once, then closed in monitor terms: the **property** it implies (STL-shaped
over the real topics, `[INFERRED]` from the mechanism against the `/clock` time base), the **trace
event** an event-driven monitor observes, and whether a violation is **safe-stop-critical**.

### 1. Configuration and shutdown → liveness / freshness loss

Configuration splits into three reachability tiers: **launch-time** (domain id, Cyclone XML, node/init
options — fixed, never served over the network), **endpoint** (per-endpoint QoS — announced via SEDP,
readable but not settable by a peer), and **runtime-served** (ROS parameters and, for managed nodes,
lifecycle transitions — exposed as network services).

A source going silent is the strongest freshness violation and the archetypal critical fault. There are
**four distinct shutdown mechanisms**, and only one *announces itself before the silence*:

| Mechanism | Blast radius | Pre-silence trace event? |
|---|---|---|
| `rclcpp::shutdown()` | whole process | No — in-process; monitor sees only endpoints withdrawing, then arrivals stop |
| Node destruction | one node | No — in-process; same |
| Lifecycle `change_state` / `TransitionEvent` | one managed node | Yes in principle — an announced transition before the gap |
| Signal / hard kill | whole process | No — abrupt silence + the ~10 s discovery-lease timeout |

**The one early-warning path doesn't exist here.** Reading the actual node sources: none of the
command-topic owners (`VehicleCmdGate`, `MrmHandler`, `RawVehicleCommandConverterNode`,
`MissionPlanner`) are `LifecycleNode`s — all are plain `rclcpp::Node` components, and a full sweep finds
no `LifecycleNode` subclass anywhere in Autoware Core or Universe. So on the command path the monitor
gets **no announced transition**; liveness must be evaluated on arrival-timestamp gaps alone.

*Closing in monitor terms.* **Property:** liveness `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` and
freshness `G( age(topic) ≤ Δ_fresh )`. **Trace event:** the arrival-timestamp gap against `/clock` —
not DDS liveliness, which neither anchor reader sets. The transient_local latch is the trap here: a
reader replayed the last latched sample still sees a value, so freshness must be judged on the *source
timestamp*, not on "did a sample arrive." **Safe-stop:** **yes** — an actuation topic going silent is
the critical fault the safe-stop exists for.

### 2. Injecting data from outside the simulation → the fault-injection harness

This is the study's **test instrument**: the two ways an off-nominal trace is introduced so a property
fires and the safe-stop path runs — not an attack.

**Carrier A — an ordinary ROS 2 node.** Configure the same Cyclone settings and the injector is
discovered as a legitimate participant reusing the real publish path with a genuine GUID and correct
CDR. The one thing it must get right is QoS — specifically, **offering `transient_local`**. Get that
wrong (the ROS 2 default is `VOLATILE`) and the sample is **uncoupled**: `publish()` reports success,
the sample lands only in the injector's own WHC, and the reader's RxO check rejects the durability
offer at discovery so the callback never fires. This is the study's worked example that an *unmatched
producer leaves the freshness clock un-started* — a trace event that never happens, which a
content-only monitor would miss entirely.

**Carrier B — hand-forged raw RTPS, no ROS 2.** Requires two forgeries: a discovery forgery (SPDP +
SEDP announcing a matching writer that offers `transient_local`) and a data forgery (a valid GUID, a
fresh sequence number, and hand-built CDR framing matching Cyclone's XCDR1 encoding). It reproduces a
source's full wire trace — GUID, sequence, HEARTBEAT — which is exactly what a faithful replay
(Finding 3) or a silent withdrawal (Finding 5) needs. Its enumerated invariants are the knobs the
harness perturbs to author early/late/stale/wrong-value traces. Whether a given hand-built sequence is
accepted by this specific build is `[UNVERIFIED]` without a live capture.

*Closing in monitor terms.* This section sets up the decision rather than making it: the harness's job
is only to reach the reader callback so a property fires and the safe-stop path runs. **Trace event:**
the injected sample's arrival timestamp, sequence number, and source stamp. **Safe-stop:** decided by
the property under test (Findings 3, 5), keyed on the topic's actuation role — the harness itself
triggers nothing.

### 3. Replay and over-publication → rate & value-freshness (the flagship)

This is the abstract's **100× network over-publication** stress case: an actuation-frequency constraint
violated, and the verifier's claimed linear complexity under that load `[LSEU-abstract]`.

**Faithful replay — re-sending the exact original packets — is blocked.** Cyclone's per-remote-writer
reorder buffer (keyed on writer GUID) already advanced its `next_seq` past those numbers during live
delivery; a replayed packet under the same GUID and sequence arrives below that watermark and is
discarded as too-old (`q_radmin.c:1979`) before it reaches the reader cache. A reliable reader also
refuses data from a writer it hasn't seen a HEARTBEAT from.

**Content reuse is achievable, just not faithful.** Re-publishing the *captured value* from a ROS 2
injector's own writer gets a fresh GUID and a sequence restarting at 1 — Cyclone treats it as an
ordinary new sample and delivers it. Nothing in DDS compares payload content, so to the monitor this is
a **fresh sample carrying a stale value**: value-freshness is violated even though DDS accepts the
sample as new, because the reorder/dedup only rejects a bit-identical (GUID, sequence) re-presentation,
never a stale value under a new sequence number.

**Over-publication self-throttles.** Once a reliable writer's unacknowledged data exceeds `WhcHigh`
(500 kB), Cyclone blocks the writer's *own* subsequent `publish()` calls until the cache drains — so a
flood caps its own rate on the *publisher* side. Deadline is the wrong instrument: it fires on too
*few* samples, not too many, and the command readers leave deadline and lifespan unset entirely.

**No de-duplication exists anywhere — DDS or application.** `VehicleCmdGate`'s operation-mode handler
and `MrmHandler`'s gear-command handler act on every received value unconditionally, with no timestamp,
counter, or equality check; AWSIM's vehicle input behaves identically. A repeated or re-presented
command is obeyed as if fresh — so the rate and value-freshness properties **cannot be delegated to the
application**; the monitor must own them.

*Closing in monitor terms.* **Property:** rate `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` and
value-freshness `G( age ≤ Δ_fresh )` even for a re-presented value. **Trace event:** inter-arrival of
successive samples (rate) and the *source* timestamp, not the sequence number (value-freshness). Both
are O(1) scalars per sample, so total evaluation cost stays **linear** even under the 100× flood
`[LSEU-abstract]`. **Safe-stop:** freshness-conditional — a rate spike that carries a stale value on an
actuation topic is safe-stop; a benign burst that stays fresh is a degradation to log.

### 4. QoS message prioritization → timing determinism & mixed-criticality

This finding asks whether the temporal constraints can be met on the wire at all, and what that implies
for running the monitor on a resource-constrained multicore RISC-V without disturbing real-time tasks
`[LSEU-abstract]`.

**The two policies that would let one writer's timing take precedence — transport priority and
ownership/ownership-strength — are absent from the ROS 2 middleware QoS struct entirely.** No `rclcpp`
call can set either; the ceiling is set at the vendor-neutral `rmw` layer, not by Cyclone. Cyclone
implements both internally (including working exclusive-ownership arbitration), but neither is reachable
through ROS:

- **Transport priority** feeds one live mechanism (gating synchronous delivery on receive), inert at
  the default threshold of 0. The path that would actually route high-priority traffic differently
  (network channels / DSCP marking) is compiled out of standard builds.
- **Ownership arbitration** only arms if the *reader* requests exclusive ownership. Neither Autoware's
  nor AWSIM's anchor-topic readers do — both stay at the default SHARED, so every matched writer's
  samples are accepted, newest-write-wins.

*Closing in monitor terms.* **Property:** latency/jitter `G( transit_latency(topic) ≤ Δ_lat )`.
**Trace event:** arrival timestamp minus source timestamp. **Safe-stop:** a **precondition only** — no
ROS-reachable knob shapes `Δ_lat`, so it is whatever best-effort delivery yields; a persistent latency
breach escalates through freshness rather than firing on its own. The deployment concern is that the
monitor itself must run at `<2%` CPU with negligible interference on that RISC-V `[LSEU-abstract]`,
which the linear per-event evaluation makes feasible — not something this static study measures.

### 5. Silent freshness loss + safe-stop actuation

The three layers below are both (a) ways data freshness is lost *without* a clean shutdown signal — the
hardest case for a monitor — and (b) candidate mechanisms by which a safe-stop could actually halt a
data flow.

**Protocol level — a keyed withdrawal, no announced transition.** An endpoint withdrawal is a keyed
DATA packet carrying a dispose/unregister flag and the victim's GUID. On receipt, Cyclone deletes the
matching proxy writer by GUID alone, with no check that the withdrawal's source is authorized to speak
for that endpoint (unlike the "alive" registration path, which verifies the owning participant). To the
monitor this is a freshness loss with **no pre-silence trace event** — arrivals simply stop. Read the
other way, this same keyed packet is the SEU's most **selective safe-stop actuator**: a scalpel that
halts exactly one compromised flow.

**Physical level — one command on the shared link.** Because both sides live on `lo`, disabling
multicast on `lo` (or dropping UDP/7400, or taking `lo` down) silences discovery for every node at
once. This needs host access, not a domain-0 capability. As a *fault* it is the worst-case whole-network
freshness loss; as *actuation* it is the SEU's **bluntest safe-stop** — an authoritative, inline cut on
the physical link, exactly the position an inline device holds on a real vehicle bus.

**Application level.** No new mechanism — the clean levers from Finding 1 (which do not reach the
command nodes) and the harness from Finding 2, noted only to keep the categories distinct. As
actuation, this is the cleanest but most conditional safe-stop, dependent on lifecycle/parameter
reachability that this deployment largely lacks.

*Closing in monitor terms.* **Property:** liveness/freshness (P2/P1 above), violated with no announced
transition. **Trace event:** the arrival-timestamp gap against `/clock` — the only observable, since no
DDS-level withdrawal precedes a hard kill or `lo` cut. **Safe-stop:** **yes** — this is the archetypal
critical fault (an actuation topic going silent), and it is also where the SEU's *actuation* half lives:
a safe-stop that must halt a compromised flow can pull the protocol withdrawal (scalpel) or the physical
cut (blunt), chosen by how much of the system the fault has compromised.

---

## The property catalog

What the study surfaces for the runtime STL monitor is a **catalog of temporal/freshness (STL-shaped)
properties**, each cross-referenced to the mechanism that establishes, satisfies, or violates it, the
trace event that lets an event-driven monitor evaluate it, and whether a violation is safe-stop-critical.
Every property is `[INFERRED]` from the cited mechanism against the `/clock` time base; the concrete
bounds (`Δ_fresh`, `Δ_deadline`, `f_max`/`f_min`, `Δ_lat`) are control-layer parameters not fixed in the
checkout.

| # | STL-shaped property (over the anchor topics) | Mechanism that establishes / violates it | Trace event | Safe-stop? |
|---|---|---|---|---|
| P1 freshness | `G( age(/control/command/gear_cmd) ≤ Δ_fresh )`; same for `/system/operation_mode/state` | Publish path stamps + WHC latching (Finding 1); readers set no lifespan (Finding 3) | per-(topic,GUID) source timestamp vs `/clock` now | **Yes** |
| P2 liveness | `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` | Any Finding 1 shutdown or Finding 5 silent freshness loss | arrival-timestamp gap | **Yes** |
| P3 rate | `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` | Over-publication vs. WHC back-pressure (Finding 3) | inter-arrival of successive samples | freshness-conditional |
| P4 value-freshness | `G( age ≤ Δ_fresh )` even for a *re-presented* value | Replay/over-pub deliver a stale value under a new seq (Finding 3) | source timestamp, not sequence number | **Yes** |
| P5 latency/jitter | `G( transit_latency(topic) ≤ Δ_lat )` | No wire prioritization knob reachable (Finding 4) | arrival − source timestamp | precondition only |

The consistent theme across all five: on this stack **neither DDS nor the Autoware application
freshness-gates, de-duplicates, or rate-limits the command path** — the callbacks act on each value with
no stamp, counter, or equality guard — so every one of these properties must be owned by the monitor
itself. Two structural facts sharpen that: the command-topic owners are plain `rclcpp::Node`s with no
lifecycle transition to announce a shutdown, so P1/P2 get **no early warning** and rest on
arrival-timestamp gaps; and the transient_local latch can make a dead publisher look alive, so freshness
must always be judged on the *source* timestamp, never on mere sample arrival.

---

## What's settled vs. still open

Resolved directly from source in this study: none of the command-topic owner nodes are
lifecycle-managed, and none exist anywhere in Autoware Core/Universe (so no shutdown announces itself
before the silence on the command path); the application performs no command-value de-duplication (so
P3/P4 cannot be delegated to it); the command readers leave deadline and lifespan unset and never touch
ownership (so P1's freshness clock has no DDS-level lifespan and P5 has no reachable timing knob); AWSIM's
readers request the same `transient_local` durability as Autoware's (so the latch hazard applies on both
surfaces).

Still open, because settling them needs a running system or a packet capture this static study could not
perform: the concrete numeric bounds for each property (`Δ_fresh`, `Δ_deadline`, `f_max`/`f_min`,
`Δ_lat` are control-layer parameters, not wire constants); whether this build was compiled with
type-discovery hashing or with DDS Security; whether a hand-forged RTPS trace (Carrier B) is actually
accepted end-to-end when authoring a fault; and the exact timing of a `/clock`-relative freshness breach
against a live instance. The abstract's Hardware-in-the-Loop results (`<2%` CPU, negligible interference,
linear verification cost under 100× over-publication) are target behavior cited `[LSEU-abstract]`, not
measured here.

<!-- SAFETY-REVISION-COMPLETE -->
