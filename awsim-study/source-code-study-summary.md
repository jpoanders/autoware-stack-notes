# AWSIM / Autoware / Cyclone DDS — Temporal-Constraint & STL-Monitor Study Summary

This is a source-code study of the communication stack of an autonomous-driving simulation — AWSIM +
Autoware Core over Eclipse Cyclone DDS — read as the physical layer beneath a *temporal-constraint*
model. Its purpose is to find **where the system's temporal and freshness constraints come from in the
real stack, and how the wire behaviour can satisfy, degrade, or violate them.** It exists to feed the
design of the **SEU — a Safety Enforcement Unit**: a lightweight, event-driven runtime-verification
monitor that derives temporal constraints from data dependencies, formalizes them as **Signal Temporal
Logic (STL)** properties, evaluates system traces against them, and executes a **preemptive safe-stop**
when a critical temporal or freshness constraint is violated `[LSEU-abstract]`.

The pipeline the study serves, end to end `[LSEU-abstract]`:

```
data-centric pub/sub abstraction
  → temporal constraint derived from a data dependency   (actuation frequency + data freshness)
    → STL property for runtime verification
      → event-driven capture & evaluation of the system trace
        → preemptive safe-stop on a critical violation
```

The five mechanism classes this study catalogues — configuration/shutdown, third-party injection,
replay/over-publication, QoS prioritization, and silent disabling — are not "attacks." They are the
**fault-injection mechanisms** that drive off-nominal timing and value traces into the system so the
STL monitor can be exercised and its safe-stop path validated (the abstract's "extreme fault-injection
stress tests" `[LSEU-abstract]`), and the **wire behaviours** that decide whether a derived constraint
can hold at all. The full stack derivation lives in `reports/foundation.md` and is reused here by
reference, not re-derived.

---

## The system under study

Autoware Core runs in a Docker container with host networking (`--net host`); AWSIM (Unity, Shinjuku
map) runs natively on the same host. The two talk over loopback (`lo`), Cyclone DDS domain 0, with
multicast on `lo` carrying discovery. `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` is forced on both sides —
no other DDS vendor is relevant anywhere in this study. Two client bindings sit on the same Cyclone core:
Autoware's `rclcpp` C++ nodes and AWSIM's `ros2cs` (ROS-for-Unity) nodes; both were read from source, so
findings apply to both unless noted.

Load-bearing settings, stated once:

| Setting | Value | Why it matters |
|---|---|---|
| Domain | 0 | Only same-domain processes discover each other |
| Participant index | none | Ports are ephemeral, not fixed |
| Multicast on `lo` | enabled | Required for discovery; disabling it crashes every node |
| Max message size | 65500 B | Fragmentation threshold; bounds per-sample framing on the wire |
| Write History Cache high-water mark (`WhcHigh`) | 500 kB | Back-pressure watermark; caps over-publication rate and is an observable stall event |

Two vehicle-controlling topics ground every finding, both published `transient_local`:
`/system/operation_mode/state` (`mode: 2` = AUTONOMOUS) and `/control/command/gear_cmd` (`command: 2` =
DRIVE). Both feed actuation, so each carries a **freshness** constraint (`G( age(topic) ≤ Δ_fresh )`)
and a **liveness/rate** constraint that the SEU must be able to evaluate. A third topic becomes newly
central: `/clock` at **~90–100 Hz** (setup-guide §6d) is the sim-time reference against which every age
and inter-arrival bound is measured.

**Temporal-constraint model (not a threat model).** The AWSIM/Autoware topology stands in for a real AV
network whose pub/sub data dependencies impose temporal constraints. The study's central artifact is a
catalog of those **temporal/freshness (STL-shaped) properties**, each cross-referenced to the Cyclone
mechanism that establishes it. A **fault source** — the instrument that pushes off-nominal traces into
the system — is a process joining domain 0 on `lo`, via either an ordinary ROS 2 node or a hand-forged
RTPS speaker. Because the container uses host networking, any host process can join with no network
isolation to cross — an artifact of this simulation's co-location, not of the real deployment. On a real
vehicle, the equivalent off-nominal source is a faulty or compromised ECU on automotive Ethernet or CAN,
which must still reach the discovery group and satisfy the same protocol/QoS invariants; those
invariants, not the ease of reaching them, are what determines whether the resulting trace is even
observable to the monitor.

---

## How the stack works, in brief

This is summarized from `reports/foundation.md`; it is the physical layer beneath the STL properties,
and it is where each property's timestamp, freshness clock, and rate are actually set. A publish call
descends five library boundaries before a byte leaves the interface: `rclcpp` → `rcl` →
`rmw` → `rmw_cyclonedds` → Cyclone core → RTPS wire. The vendor split begins exactly at
`rmw_publish → dds_write`. Three facts from this path recur everywhere and each bounds what the monitor
can observe:

- **Serialization is Cyclone-only.** The message becomes CDR bytes for the first time inside Cyclone
  (`ddsi_serdata_from_sample`); every layer above just forwards the native struct.
- **Sequence numbers are per-writer and monotonic**, assigned as `seq = ++wr->seq` at the same point the
  sample is inserted into the writer's **Write History Cache (WHC)**. This sequence number, together with
  a sample's arrival timestamp, is the primary **trace observable** the event-driven monitor keys on:
  inter-arrival and staleness are computed from it. The WHC is what a reliable writer retransmits from on
  NACK, and — for `transient_local` topics — what it replays to a reader that joins late. `WhcHigh`
  (500 kB of unacknowledged data) is the flow-control ceiling on that cache, and its back-pressure stall
  is itself an observable trace event under over-publication.
- **AWSIM shares this exact path below the language binding.** `ros2cs` is a C# binding over the same
  host ROS 2 / Cyclone libraries `rclcpp` uses, so serialization, sequencing, and WHC behavior are
  identical for both client surfaces.

**Matching has three independent gates, all checked at discovery time, before any data is sent** — a
mismatch is a non-connection, not a message dropped later: topic name (mangled with an `rt/` prefix),
type name (plus a type hash, if the build enables type discovery — unverified which way this build was
built), and QoS compatibility under the **Requested/Offered (RxO)** rule: for each policy, the reader's
*requested* value must be satisfiable by the writer's *offered* value. **Durability is the load-bearing
policy**: Cyclone orders `VOLATILE(0) < TRANSIENT_LOCAL(1)`, so a `transient_local` reader never connects
to a volatile-only writer. Both anchor topics' readers request `transient_local`. This gate matters
directly to freshness: **a mismatch means the two endpoints are never coupled, so the reader's freshness
clock never starts — an infinite, silent staleness that a naive consumer cannot distinguish from
"no data yet."** It is also the one gate a fault-injection source must clear to place a trace into the
system at all.

**Discovery** is two-stage multicast over `lo`: SPDP announces participants (30 s interval), then SEDP
announces each endpoint together with its topic, type, and full QoS. Discovery latency therefore bounds
how fast a new or returning source becomes observable — i.e. how quickly a violated **liveness** property
can be re-satisfied after a source recovers. Discovery multicast runs on port 7400 (domain 0); disabling
multicast on `lo` alone crashes every node in the container, which is the basis of the physical-layer
freshness-loss / safe-stop-actuation mechanism described below.

---

## Findings

Each finding below is one fault *class*: a way a temporal or freshness constraint gets stressed, and
the Cyclone mechanism that governs whether the resulting off-nominal trace is observable to the monitor.
Each closes on the three monitor terms — **the property**, **the trace event**, **the safe-stop
decision** — that the SEU is built around.

### 1. Configuration and shutdown → liveness / freshness loss

A source going silent is the strongest freshness violation and the archetypal critical fault that
should trigger a safe-stop. Which shutdown paths exist — and how fast a resulting silence is observable
— therefore decides how the liveness property `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` can be
evaluated and whether the stop it implies is clean or must be inferred from silence.

Configuration splits into three reachability tiers: **launch-time** (domain id, Cyclone XML, node/init
options — fixed, never served over the network), **endpoint** (per-endpoint QoS — announced via SEDP,
readable but not settable by a peer), and **runtime-served** (ROS parameters and, for managed nodes,
lifecycle transitions — exposed as network services).

There are **four distinct shutdown mechanisms**, and only one of them is even *potentially*
network-reachable:

| Mechanism | Blast radius | Reachable from domain 0? |
|---|---|---|
| `rclcpp::shutdown()` | whole process | No — in-process only |
| Node destruction | one node | No — in-process only |
| Lifecycle `change_state` service | one managed node | In principle, yes — no durability barrier on the service's QoS |
| Signal / hard kill | whole process | No — host access only |

**The lifecycle lever doesn't apply here.** Reading the actual node sources: none of the command-topic
owners (`VehicleCmdGate`, `MrmHandler`, `RawVehicleCommandConverterNode`, `MissionPlanner`) are
`LifecycleNode`s — all are plain `rclcpp::Node` components. A full sweep of the checkout finds no
`LifecycleNode` subclass anywhere in Autoware Core or Universe. The consequence for the monitor: **there
is no clean, network-observable "going away" signal for the command nodes** — no lifecycle transition
the SEU could tap as an explicit end-of-liveness event. A silenced command source therefore manifests
only as *absence*, and the monitor can detect it only by timing out on missing arrivals, never by
observing a clean transition.

**A latched `transient_local` sample can mask that absence — a first-class hazard.** Because both anchor
topics are `transient_local`, the writer's WHC replays its last sample to a late-joining reader. A
consumer that reads only "is there a value?" sees the *latched* last command and concludes the source is
alive, even after the publisher is long dead. For a freshness monitor this is the trap: liveness must be
judged on **fresh arrivals with advancing timestamps**, not on the presence of a value.

**The property.** `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` for each command topic, plus
`G( age(topic) ≤ Δ_fresh )` — age measured against `/clock`; `Δ_deadline` bounded by the source's
nominal publish period `[INFERRED]`. **The trace event.** A gap between successive per-writer sequence
numbers / arrival timestamps exceeding `Δ_deadline`, observed at the reader/RTPS layer — *not* the mere
presence of a latched sample. **The safe-stop decision.** Silence on either anchor command topic is
critical: with no clean shutdown signal available, a liveness timeout on a command source is exactly the
condition that should trigger a preemptive safe-stop rather than merely log.

### 2. Injecting data from outside the simulation → the fault-injection harness

This is not an attack surface; it is **the study's test instrument**. To exercise the STL monitor you
must be able to drive off-nominal traces — early, late, stale, or wrong-value samples — into the real
topics so the safe-stop path can be validated (the abstract's "extreme fault-injection stress tests"
`[LSEU-abstract]`). Two carriers can make a legitimate node accept an injected sample.

**Carrier A — an ordinary ROS 2 node.** The simplest harness: configure the same Cyclone settings, and
the injector is discovered as a fully legitimate participant reusing the real publish path with a genuine
GUID and correct CDR. The only thing it must get right is QoS — specifically, **offering
`transient_local`**. Get that wrong (the ROS 2 default is `VOLATILE`) and the injection is silently
dropped: the writer's `publish()` still reports success, the sample lands only in the injector's own WHC,
discovery shows a writer whose durability the reader's RxO check rejects, and the reader's callback never
fires. This is a property of the harness worth stating plainly — **an injected trace only reaches the
monitor if the injector clears the durability gate**; a content-only observer placed after the callback
would see nothing at all, because no sample ever crossed the wire.

**Carrier B — hand-forged raw RTPS, no ROS 2.** The deployment-realistic instrument, since a real
off-nominal ECU need not run ROS 2 at all. It requires two forgeries: a discovery forgery (SPDP + SEDP
announcing a matching writer that offers `transient_local`) and a data forgery (a valid GUID, a fresh
sequence number, and hand-built CDR framing matching Cyclone's XCDR1 encoding). Feasible in principle,
but substantially harder than Carrier A — the difficulty concentrates in reproducing a byte-accurate
discovery handshake, not in the data payload itself. Whether a given hand-built sequence is actually
accepted by this specific build is unverified without a live capture.

**The property.** The harness itself asserts no property; it is what makes properties *testable* — it
produces the traces (controlled staleness, controlled inter-arrival, controlled values) against which
every §1/§3/§5 property is evaluated. **The trace event.** A successfully injected sample is
indistinguishable at the wire from a genuine one: same publish path, genuine GUID, monotonic sequence.
That is precisely what makes it a faithful test stimulus. **The safe-stop decision.** None from the
harness directly; its role is to reach the states in which §1, §3, §4, §5 properties fire, so that the
safe-stop logic can be observed end-to-end. *(A footnote for completeness: the same mechanism could be
misused adversarially; that is not the point here.)*

### 3. Replay and over-publication → flagship: actuation-frequency constraint under stress

This is the study's flagship fault class, and the one that maps directly onto the abstract's **"100x
network over-publication"** stress test `[LSEU-abstract]`: an actuation-frequency constraint
`G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` driven far above `f_max`, and the question of whether
the verifier's evaluation stays linear under that load. What the wire does to such a flood is exactly
what the monitor must see.

**Faithful replay — re-sending the exact original packets — is blocked by the wire itself.** Cyclone's
per-remote-writer reorder buffer (keyed on writer GUID) already advanced its `next_seq` past those numbers
during the original live delivery; a replayed packet under the same GUID and sequence number arrives
below that watermark and is discarded as too-old before it ever reaches the reader cache. A reliable
reader also refuses any data from a writer it hasn't yet seen a HEARTBEAT from, compounding the
requirement. For the monitor this means a naive same-GUID/same-seq replay never becomes a trace event at
all — the reorder buffer filters it before the reader.

**Content reuse is achievable, just not faithful.** Re-publishing the *captured value* from an ROS 2
injector's own writer gets a fresh GUID and a sequence number restarting at 1 — Cyclone treats it as an
ordinary new sample and delivers it normally. Nothing in DDS compares payload content, so this is
indistinguishable from a legitimate first-time publish except for the GUID: a repeated *value* is fully
observable to the monitor as fresh arrivals, but only its rate and freshness betray it, never its content.

**Over-publication self-throttles.** Once a reliable writer's unacknowledged data exceeds `WhcHigh`
(500 kB), Cyclone blocks the writer's *own* subsequent `publish()` calls until the cache drains or a
timeout aborts them — so a flood caps its own rate. This back-pressure stall is itself an observable
trace event. Note that DDS **deadline** is the wrong instrument for the rate bound: it fires on too
*few* samples, not too many, and the command readers leave deadline and lifespan unset entirely — so the
monitor must compute the inter-arrival bound from sequence-number/timestamp deltas itself, not lean on a
QoS deadline callback.

**No de-duplication exists anywhere in this path — DDS or application.** Reading the actual subscriber
callbacks: `VehicleCmdGate`'s operation-mode handler and `MrmHandler`'s gear-command handler both act on
every received value unconditionally, with no timestamp, counter, or equality check. AWSIM's vehicle
input behaves identically. A repeated or over-published command is therefore obeyed as if it were fresh —
the application cannot be relied on to reject it, so the rate/freshness property is the monitor's to
enforce.

**The property.** `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` on each command topic, with `f_max`
set by the source's nominal actuation rate against `/clock` `[INFERRED]`. **The trace event.** Per-writer
sequence-number and arrival-timestamp deltas — the same observables §1 uses, read for *too fast* rather
than *too slow* — plus the WHC back-pressure stall under extreme flood. Because these are computed
incrementally per arrival, evaluation stays **linear in sample count** even under the 100x stress case
`[LSEU-abstract]`. **The safe-stop decision.** A sustained rate violation on a command topic is critical:
an actuation path being driven at 100x its nominal frequency is a fault the SEU should safe-stop on, not
merely log, since no downstream de-duplication will absorb it.

### 4. QoS-based prioritization → timing determinism & mixed-criticality

This is the question of whether the temporal constraints can be met **on the wire at all**, and what
that implies for running the monitor on the abstract's target — a resource-constrained multicore RISC-V
executing mixed-criticality workloads with negligible interference on real-time tasks `[LSEU-abstract]`.
The finding is a constraint on what QoS-based timing determinism is even available to shape latency and
jitter.

**The two policies that would actually let one writer take precedence — transport priority and
ownership/ownership-strength — are absent from the ROS 2 middleware QoS struct entirely.** No `rclcpp`
call, by any node, can set either one; the ceiling is set at the vendor-neutral `rmw` layer, not by
Cyclone.

Cyclone *does* implement both internally — including working exclusive-ownership arbitration, contrary to
a common assumption that Cyclone lacks it — but neither is usable through ROS:

- **Transport priority** only feeds one live mechanism (gating synchronous delivery on the receive side),
  and that mechanism is inert at the default threshold of 0. The feature that would actually route
  high-priority traffic differently (network channels / DSCP marking) is compiled out of standard builds.
- **Ownership arbitration** only arms if the *reader* requests exclusive ownership. Reading the actual
  subscriptions confirms neither Autoware's nor AWSIM's readers on the anchor topics ever do — both stay
  at the default SHARED, so every matched writer's samples are accepted, newest-write-wins.

**The property.** A latency/jitter bound underpins every freshness property — `Δ_fresh` is only
achievable if wire latency plus scheduling jitter stays under it. Because ROS exposes no priority or
ownership lever, the stack offers **no QoS knob to protect a critical topic's timing** from competing
traffic; determinism must come from the history/WHC depth and the reader's own scheduling, not from
prioritized delivery `[INFERRED]`. **The trace event.** End-to-end latency and jitter, observable as the
spread of arrival timestamps relative to `/clock`; there is no priority field to read because the layer
never carries one. **The safe-stop decision.** No property here fires a stop on its own; the finding
bounds *feasibility* — it tells the SEU that timing margin must be budgeted conservatively, and that the
monitor's own <2% CPU footprint and non-interference target `[LSEU-abstract]` cannot be met by leaning
on QoS prioritization the middleware does not provide.

### 5. Disabling an element without a clean shutdown → silent freshness loss + safe-stop actuation

This class is dual-purpose for the SEU. Each mechanism is both (a) a way data freshness is lost *without
a clean shutdown signal* — the hardest case for a liveness monitor, because there is no transition to
observe, only a data flow that stops — and (b) a candidate mechanism by which a **safe-stop could
actually halt a flow** once the monitor decides to act.

**Protocol level.** An endpoint withdrawal is nothing more than a keyed DATA packet carrying a
dispose/unregister status flag and the endpoint's GUID. On receipt, Cyclone deletes the matching proxy
writer by GUID alone — **with no check that the withdrawal's source is authorized to speak for that
endpoint**, unlike the equivalent "alive" registration path, which does verify the owning participant. A
participant-level withdrawal (which kills the whole proxy participant and everything it owns) is nominally
gated by a deletion-allowed check, but on a build without DDS Security that check is a stub that always
returns true, and even the DDS-Security-enabled implementation's own code comment admits it never
verifies the GUID-prefix match for an unauthenticated participant. Read as a fault: this is how a source
can vanish from a reader's view with **no clean liveness signal** — the reader's freshness clock simply
stops advancing, and only a timeout reveals it. Read as an actuator: it is also a precise, GUID-targeted
way for a safe-stop to sever one data flow without touching the rest of the network.

**Physical level — one command on the shared link.** Because both sides live on the loopback interface,
disabling multicast on `lo` (or dropping UDP/7400, or taking `lo` down entirely) kills discovery for every
node in the container at once. This needs host access, not a domain-0 capability. It maps onto the
**broadest safe-stop actuator**: on an actual vehicle bus, an inline device on the physical link can drop
or rate-limit a single source's frames authoritatively — the strongest lever the SEU has to *enact* a
safe-stop, at the cost of being all-or-nothing on a shared link.

**Application level.** No new mechanism — it's the same clean levers from §1 (which do not reach the
command nodes) and the injection harness from §2, viewed as "stopping a flow," noted only to keep the
categories distinct.

**The property.** The liveness property from §1 — `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` —
under the hardest observability case: the source stops with no transition event. **The trace event.**
Absence only: an advancing-timestamp gap past `Δ_deadline`, since the protocol withdrawal produces no
application-visible shutdown and the physical cutoff produces none either. **The safe-stop decision.** A
silent freshness loss on a command topic is maximally critical — it is indistinguishable from a dead
actuator source — and is the canonical trigger for a preemptive safe-stop; these same protocol/physical
mechanisms are then also how that safe-stop is *carried out*.

---

## What this means for the SEU (STL monitor)

Collecting the per-finding closing blocks into the monitor's design constraints:

- **Freshness and liveness are the SEU's core properties, and both must be judged on advancing
  timestamps — never on the presence of a value.** The `transient_local` last-sample latching on both
  anchor topics will otherwise make a dead source look alive; a freshness monitor that checks "is there a
  value?" is defeated by the very durability the topics use.
- **There is no clean shutdown event to tap for the command nodes** — none are lifecycle-managed anywhere
  in Autoware Core/Universe — so end-of-liveness is detectable only as a timeout on missing arrivals. The
  monitor cannot delegate this to a transition callback.
- **The primary trace observable is the pair (per-writer sequence number, arrival timestamp) at the
  reader/RTPS layer.** Freshness, liveness, and the actuation-rate bound are all computed incrementally
  from deltas of these two values — which is why evaluation stays linear even under the 100x
  over-publication stress case `[LSEU-abstract]`.
- **DDS QoS is not a substitute for the monitor.** Deadline fires on too-few, not too-many, and is unset
  on the command readers anyway; no priority or ownership lever is exposed through ROS to protect a
  critical topic's timing. The temporal properties are the SEU's to evaluate, and timing margin
  (`Δ_fresh`) must be budgeted conservatively rather than defended by prioritized delivery.
- **Application-level de-duplication does not exist** — `VehicleCmdGate` and `MrmHandler` obey every
  received value unconditionally — so a repeated or over-published command is not absorbed downstream;
  the rate/freshness property is the monitor's alone.
- **The fault-injection harness (§2) is what makes all of the above testable**, driving controlled
  stale/late/fast/wrong-value traces into the real topics to validate the safe-stop path end-to-end,
  matching the abstract's fault-injection stress methodology `[LSEU-abstract]`.
- **Silent freshness loss is the canonical safe-stop trigger, and the protocol/physical mechanisms of §5
  are also how a safe-stop is enacted** — GUID-targeted proxy-writer deletion at the protocol layer, or
  an inline drop/rate-limit at the physical layer.

The abstract's headline results — <2% CPU, negligible real-time interference, linear complexity under
100x over-publication, preemptive safe-stops that prevent accidents — are the **target behaviour** this
study's mechanism findings are meant to make achievable `[LSEU-abstract]`. This static source study does
not reproduce or measure them; the sim is not run.

---

## What's settled vs. still open

Resolved directly from source in this study, and load-bearing for the monitor: none of the command-topic
owner nodes are lifecycle-managed, and none exist anywhere in Autoware Core/Universe (so liveness has no
clean transition to observe); the application performs no command-value de-duplication (so the
rate/freshness property is the SEU's); the command readers leave deadline and lifespan unset and never
touch ownership (so no QoS deadline callback and no prioritized delivery are available); AWSIM's readers
request the same `transient_local` durability as Autoware's (so the latched-staleness masking hazard
applies on both client surfaces).

Still open, because settling them needs a running system or a packet capture that this static study could
not perform: whether this build was compiled with type-discovery hashing or with DDS Security; whether a
hand-forged RTPS trace (Carrier B) is actually accepted end-to-end; whether a production vehicle build
enables network channels/DSCP that could shape timing determinism; the exact `Δ_fresh` / `Δ_deadline`
bounds (control-layer parameters, `[INFERRED]` here from the `/clock` rate); and the exact latency of a
port-7400 drop or discovery-multicast cutoff as a safe-stop actuator against a live instance.

<!-- SAFETY-REVISION-COMPLETE -->
