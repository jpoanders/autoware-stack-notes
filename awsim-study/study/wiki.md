# AWSIM / Autoware / Cyclone DDS Temporal-Constraint & STL-Monitor Study

A controlled, academic study of how the communication stack of an autonomous-driving simulation
carries the temporal and freshness constraints that a runtime monitor must verify — where each
constraint comes from in the real stack, and how the wire behaviour can satisfy, degrade, or violate
it — read through configuration, shutdown, external injection, replay/over-publication, QoS timing,
and silent freshness loss.

Abstract. This study examines the AWSIM Digital-Twin demo, an autonomous-driving simulation built
on the Robot Operating System 2 (ROS 2) and the Autoware self-driving software stack, communicating
over Eclipse Cyclone DDS (an implementation of the Data Distribution Service messaging standard). The
analysis is conducted from the open-source code of that stack rather than from a running system.
Working layer by layer, from the application's C++ publish call down to the raw packets on the wire,
it locates where each data dependency's *temporal constraint* — set by actuation frequency and data
freshness — is established, met, or lost on the Cyclone DDS wire. The end goal it serves is the
Safety Enforcement Unit (SEU): a lightweight, event-driven runtime-verification monitor that derives
these constraints automatically from the pub/sub data dependencies, formalizes each as a Signal
Temporal Logic (STL) property, evaluates system traces against it, and executes a preemptive
safe-stop when a critical temporal or freshness constraint is violated `[LSEU-abstract]`. Every
section therefore closes by translating its mechanism into monitor terms — the property it implies,
the trace event that lets an event-driven monitor evaluate that property, and whether a violation is
critical enough to trigger a safe-stop — and those are gathered in one place near the end. Where
later sections build injectors, replay, or endpoint-withdrawal mechanisms, they are the study's
**fault-injection harness**: ways to drive off-nominal (early / late / stale / wrong-value /
over-published) traces into the system so the monitor is exercised and its safe-stop path validated,
matching the abstract's "extreme fault-injection stress tests" `[LSEU-abstract]`.

---

## Table of contents

1. [Scope, safety/temporal-constraint model, and how to read this](#1-scope-safetytemporal-constraint-model-and-how-to-read-this)
2. [Background: the communication stack](#2-background-the-communication-stack)
   - [2.1 A primer for newcomers](#21-a-primer-for-newcomers)
   - [2.2 Layer map](#22-layer-map)
   - [2.3 The publish path to the wire](#23-the-publish-path-to-the-wire)
   - [2.4 Delivery-matching rules](#24-delivery-matching-rules)
   - [2.5 Discovery](#25-discovery)
3. [Configurable elements and shutting an element down](#3-configurable-elements-and-shutting-an-element-down)
4. [Injecting data from outside the simulation](#4-injecting-data-from-outside-the-simulation)
5. [Replay and over-publication](#5-replay-and-over-publication)
6. [QoS message prioritization](#6-qos-message-prioritization)
7. [Disabling an element without a clean shutdown](#7-disabling-an-element-without-a-clean-shutdown)
8. [Safety Enforcement Unit implications, gathered](#8-safety-enforcement-unit-implications-gathered)
9. [Glossary](#9-glossary)
10. [Open questions and unverified items](#10-open-questions-and-unverified-items)

How claims are marked. Every technical claim below carries one of four evidence tags, so a reader
can tell a verified fact from a reasoned expectation:

- `[code]` — confirmed by reading the open-source code of the named component (Cyclone DDS,
  `rmw_cyclonedds`, `rclcpp`, `rcl`, `rmw`, or the Autoware message packages), cited as `file:line`.
- `[spec]` — defined by the Object Management Group's DDS / DDSI-RTPS specification; an external
  standard, not something visible in this stack's own code.
- `[INFERRED]` — a reasoned conclusion drawn from cited code, flagged as an inference rather than a
  direct reading.
- `[UNVERIFIED]` — could only be settled by running the simulation or capturing live packets, which
  this study could not do.
- `[LSEU-abstract]` — a claim, number, or definition drawn from the (unpublished) Safety Enforcement
  Unit abstract this study feeds — its motivation and target behaviour, *not* something this static
  source study measured. Its Hardware-in-the-Loop results (`<2%` CPU, negligible interference, linear
  verification cost, 100× over-publication) are context only; the simulation is not run here.

A note on file citations. File paths such as `dds_write.c:566` refer to the source of the named
open-source component at the versions studied. All of these projects are public; the paths let a
reader locate the exact code behind a claim. The prose is written so that it reads cleanly even if
every path citation were removed.

---

## 1. Scope, safety/temporal-constraint model, and how to read this

The data-centric north star. An autonomous vehicle is a data-flow machine: components exchange
samples, and a downstream actuator behaves safely only if the data it depends on arrives *often
enough* and is *fresh enough*. Those two quantities — **actuation frequency** and **data freshness** —
turn each data dependency into a **temporal constraint** `[LSEU-abstract]`. The Safety Enforcement
Unit derives such constraints automatically from the pub/sub data dependencies, formalizes each as a
**Signal Temporal Logic (STL)** property, evaluates system traces against it, and executes a
preemptive **safe-stop** when a critical property is violated `[LSEU-abstract]`. This study supplies
the missing physical half of that pipeline: the Cyclone DDS mechanism that decides whether a given
property *can* hold on the wire.

```
data-centric pub/sub abstraction
  → temporal constraint derived from a data dependency   (actuation frequency + data freshness)
    → STL property for runtime verification
      → event-driven capture & evaluation of the system trace
        → preemptive safe-stop on a critical violation
```

What the study asks. For this specific stack, and from its source code: where is each element's
timing behaviour configured; how does a source going silent manifest, and how fast is it observable;
how can off-nominal traces be driven *into* the system to exercise the monitor; how do replay and
over-publication distort a rate/freshness constraint; how does QoS shape latency and jitter (and can
the constraints be met on the wire at all); and how is data freshness lost *without* a clean shutdown
signal — the hardest case for a monitor? Each answer closes by translating the mechanism into the
STL property it implies, the trace event that lets an event-driven monitor evaluate it, and the
safe-stop decision it forces.

The system under study. The pieces and how they are wired together are fixed and concrete:

- Autoware — the open-source autonomous-driving software — runs inside a Docker container. The
  container is launched with host networking (`--net host`), so it shares the host machine's network
  namespace rather than being isolated on its own.
- AWSIM — the Unity-based driving simulator (the Lightweight build, on the Shinjuku city map) —
  runs natively on the host, not in a container.
- The two halves talk to each other over ROS 2 / DDS across the host-to-container boundary using the
  loopback network interface, on Cyclone
  DDS domain 0, with multicast on `lo` carrying the discovery traffic that lets the two sides
  find each other.
- The DDS vendor is Eclipse Cyclone DDS, forced on both sides by setting the environment variable
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`. No assumptions from any other DDS vendor are carried
  anywhere in this study.
- Two different client surfaces sit on top of the same Cyclone layer: Autoware's C++ nodes (written
  against the `rclcpp` client library), and AWSIM's Unity nodes (written against a separate
  ROS-for-Unity binding, `ros2cs`). Both surfaces have now been read from source, so claims about either side's
  publishing and subscription QoS are `[code]`, and only behaviour that would need a live run remains
  `[UNVERIFIED]`.

The deployment configuration studied. A handful of concrete settings are load-bearing and are
referred to throughout, so they are stated once here:

| Setting | Value in this deployment | Why it matters |
|---|---|---|
| DDS vendor | `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`  | All wire behaviour is Cyclone's |
| DDS domain |  **0** (Cyclone configured with `Domain Id="any"`) | Only same-domain processes discover each other |
| Participant index | `ParticipantIndex=none` | Unicast ports are ephemeral, not fixed |
| Multicast | Enabled on `lo`; load-bearing for discovery | Turning it off breaks the whole system |
| Max message size | `MaxMessageSize=65500B` | The fragmentation limit bounding a malformed/over-large sample |
| Write-history-cache limit | `WhcHigh=500kB` | The back-pressure watermark that throttles over-publication |

The worked targets. Two real, vehicle-controlling command topics ground every section, chosen
because both are published with `transient_local` durability (a delivery mode explained in
[§2.4](#24-delivery-matching-rules)) and the vehicle actually obeys them — so a temporal or freshness
violation on either is a candidate safe-stop trigger:

| Topic | Message type | Key value that commands the vehicle |
|---|---|---|
| `/system/operation_mode/state` | `autoware_adapi_v1_msgs/msg/OperationModeState` | `mode: 2` = AUTONOMOUS |
| `/control/command/gear_cmd` | `autoware_vehicle_msgs/msg/GearCommand` | `command: 2` = DRIVE |

The enum constant `DRIVE = 2` is defined at `autoware_vehicle_msgs/msg/GearCommand.msg:3` `[code]`, and
`AUTONOMOUS = 2` at `autoware_adapi_v1_msgs/operation_mode/msg/OperationModeState.msg:4` `[code]`.

The time base. A third topic, `/clock`, becomes newly load-bearing under the safety framing:
age and inter-arrival are measured against **sim time**, which the bridge publishes on `/clock` at a
steady **~90–100 Hz** (setup-guide §6d). Every freshness bound `Δ_fresh` and rate bound in this study
is expressed against that clock, not against wall time.

The fault-injection model. The study's test instrument is a process outside the simulation that
joins Cyclone domain 0 on `lo` and drives off-nominal traces into the system so the monitor's
safe-stop path can be exercised. Two carriers recur throughout: an ordinary ROS 2 (`rclcpp`) process
configured for Cyclone, and a hand-forged RTPS speaker that runs no ROS 2 at all and emits raw wire
packets. These are the abstract's "extreme fault-injection stress tests" `[LSEU-abstract]`; where the
same trace could *also* be induced maliciously, that is a one-line aside, not the point.

The topology caveat — it binds every section, and is stated once here. Because the container uses
host networking and AWSIM is native, both sides sit on Cyclone domain 0 bound to `lo`, so any
process on the host that joins domain 0 is discovered and matched with no network isolation to
cross. That makes fault injection *cheap to set up* in this simulation — but that ease is a
simulation artifact, convenient for a test harness. What matters for the monitor is not the ease of
injection but what the injected trace does to a temporal/freshness property and how observable the
violation is. The deployment target is a real AV network — components on automotive Ethernet or a
Controller Area Network (CAN) bus — whose data dependencies impose the same class of temporal
constraints; the SEU runs there as a lightweight event-driven monitor `[LSEU-abstract]`. Throughout,
"easy because it is all on loopback in one domain" is kept distinct from "what the wire mechanism does
to a constraint the monitor must verify," wherever a realism judgment depends on it. Later sections
refer back to this caveat rather than restating it.

---

## 2. Background: the communication stack

In short: two programs can exchange data only after
discovery lets them learn about each other, and only if three
matching gates pass: the topic name, the message type, and Quality-of-Service compatibility.

### 2.1 A primer for newcomers

If the layers below are unfamiliar, this is the minimum to follow the rest.

- ROS 2 (Robot Operating System 2) is a framework for building robot and vehicle software out of
  many small programs called nodes. Nodes do not call each other directly; instead they publish
  and subscribe to named channels called topics (for example `/control/command/gear_cmd`). A node
  that publishes a `GearCommand` on that topic does not know or care who is listening.
- Publish / subscribe is that decoupled style of messaging: a publisher sends typed messages
  to a topic; any subscriber to the same topic receives them. Each side attaches
  Quality-of-Service (QoS) settings — reliability, how much history to keep, whether late joiners
  get old messages, and so on — and the two sides only connect if their settings are compatible.
- DDS (Data Distribution Service) is the industry standard that actually moves those messages
  across the network. ROS 2 does not implement its own networking; it delegates to a DDS product
  underneath. Cyclone DDS is the specific DDS implementation used here.
- RTPS (Real-Time Publish-Subscribe), sometimes called DDSI, is the wire protocol DDS speaks — the
  concrete format of the packets that travel between machines. Its main packet kinds are DATA (a
  message), and the control packets HEARTBEAT, ACKNACK, and GAP that make reliable delivery work.
- Discovery is how two DDS programs find each other on the network without being told in advance:
  they periodically announce themselves and their topics via multicast, then automatically connect any
  publisher and subscriber whose topic, type, and QoS are compatible.
- The software is built in layers, each a thin wrapper over the one below: an Autoware node calls
  the `rclcpp` C++ library, which calls the `rcl` C library, which calls the vendor-neutral `rmw`
  interface, which calls the Cyclone-specific binding `rmw_cyclonedds`, which calls the Cyclone DDS
  core, which finally emits RTPS packets. The next subsection traces that path exactly.

### 2.2 Layer map

A single `publisher->publish(msg)` call in an Autoware node descends through five library boundaries
before a byte reaches the loopback interface. The word "publish" appears at three of those layers, so
what matters is the exact function called at each crossing:


The vendor-specific part begins precisely at the `rmw_publish → dds_write` crossing: above that line
the code is vendor-neutral, below it is Cyclone. Each crossing, cited: `Publisher::publish` →
`do_inter_process_publish` → `rcl_publish`
 → `rmw_publish` → `dds_write`
 → `the Cyclone protocol engine via`
`dds_write_impl` → `write_sample_gc` → `write_sample_eot` → `nn_xpack_send`
.

### 2.3 The publish path to the wire

This traces one message — a `GearCommand{command: 2}` on `/control/command/gear_cmd` — from the
`rclcpp` call to an RTPS DATA packet leaving `lo`. Three facts from this path are reused everywhere:
where the message is serialized to CDR, where it gets a sequence number, and where it enters the
write history cache (WHC). The upper layers (`rclcpp`, `rcl`, `rmw`) are pass-through plumbing that
forward the still-native message struct downward; no serialization happens until Cyclone.

1. rclcpp entry. `Publisher<T>::publish` calls `do_inter_process_publish` for the inter-process
   case (`publisher.hpp:257`) `[code]`.
2. rclcpp → rcl. It calls `rcl_publish` and throws on error, except it silently returns if the
   context is already shut down (`publisher.hpp:456,462-465`) `[code]` — relevant to
   [shutdown](#3-configurable-elements-and-shutting-an-element-down).
3. rcl → rmw. `rcl_publish` validates, then forwards to `rmw_publish`
   (`rcl/src/rcl/publisher.c:236,248-252`) `[code]`. `rcl` does not serialize.
4. rmw → Cyclone. The binding checks the implementation identifier is Cyclone's, then calls
   `dds_write` (`rmw_node.cpp:1825-1834`) `[code]`. (A mismatched DDS vendor fails exactly here — the
   reason both sides must set `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`.)
5. Cyclone dispatch. `dds_write` → `dds_write_impl` → `dds_write_impl_plain`
   (`dds_write.c:45,55,589,599`) `[code]`.
6. Serialization to CDR. `dds_write_impl_plain` calls `ddsi_serdata_from_sample` — the first and
   only point the message becomes CDR (Common Data Representation) bytes (`dds_write.c:566`)
   `[code]`. The hand-forged-RTPS branch of the fault-injection harness ([§4.3](#43-carrier-b-hand-forged-rtps-without-ros-2))
   must reproduce this CDR by hand to emit a well-formed off-nominal sample.
7. Sequence number + WHC. Descending through `write_sample_eot`, the writer's sequence number
   is advanced as `seq = ++wr->seq;` and the sample is stored via `insert_sample_in_whc`
   (`q_transmit.c:1286,1299`) `[code]`. Sequence numbers are per-writer and monotonic — the fact
   the [replay analysis](#5-replay-and-over-publication) turns on.
8. Onto the wire. `deliver_data_network` flushes via `nn_xpack_send` (`dds_write.c:258-259`)
   `[code]`; the bytes are an RTPS DATA packet whose field layout is defined by the specification
   `[spec]`.

Two reused facts follow from this path. First, `transient_local` durability uses the same WHC as
its store for late-joining readers, so a late-arriving injector can still be matched and served — and
the `WhcHigh=500kB` watermark is the back-pressure knob the [replay section](#5-replay-and-over-publication)
relies on. Second, with writer batching off (the default here, `[INFERRED]` because the configuration
contains no batching element), one publish is approximately one wire send.

The AWSIM client shares this path below the language binding. AWSIM does not use `rclcpp`; its Unity
scripts publish through `ros2cs`, wrapped by a thin project layer (`AwsimRos2Node.CreatePublisher<T>`,
`src/awsim/Assets/Awsim/Scripts/Common/Ros2/AwsimRos2Node.cs:66-68`; spun by `Ros2cs.SpinOnce`,
`.../Ros2ForUnity/Scripts/ROS2UnityCore.cs:128`) `[code]`. But `ros2cs` is a C# binding over the host's
own ROS 2 libraries — the setup guide confirms AWSIM's plugins are compiled against Humble and link
`/opt/ros/humble/lib` (`setup-guide §2`), and that a DDS-vendor mismatch breaks them exactly as it would
`rclcpp` (`setup-guide §9`). So an AWSIM `Publish()` enters the same `rcl` → `rmw_cyclonedds` →
`dds_write` → RTPS descent from step 3 onward; only the top binding differs, and serialization,
sequence numbering, and the WHC are identical. Every wire-, matching-, and replay-level finding below
therefore applies to AWSIM's traffic unchanged `[INFERRED: from the shared host libraries, since the
`rcl`-and-below source is the same for both bindings]`.

### 2.4 Delivery-matching rules

Three independent gates must all pass. They are enforced by Cyclone's `qos_match_mask_p`
(`ddsi/src/q_qosmatch.c:158-267`) `[code]` at discovery time, before any data sample is sent — so a
mismatch is a *non-connection*, not a message dropped later.

Topic-name mangling. The DDS topic name is not identical to the ROS name: the Cyclone binding
prepends `rt` for topics (and `rq`/`rr` for service request/reply), so `/control/command/gear_cmd`
becomes `rt/control/command/gear_cmd` on the wire (`make_fqtopic`, `rmw_node.cpp:2282`; prefix
constant `namespace_prefix.hpp:18-20`) `[code]`. Name equality is a byte-for-byte comparison
(`q_qosmatch.c:160`) `[code]`.

Type matching. The DDS type name is `<namespace>::dds_::<MessageName>_` — for example
`autoware_vehicle_msgs::msg::dds_::GearCommand_` (`create_type_name`, `serdata.cpp:663-672`)
`[code]`. Whether matching also needs a type *hash* or only the type *name* string depends on whether
the build was compiled with type discovery enabled (`q_qosmatch.c:216-267`) `[code]`; which way this
particular container was built is `[UNVERIFIED]`.

QoS compatibility — the Requested/Offered (RxO) rule. Compatibility is asymmetric: for each
policy, the reader's requested value must be satisfiable by the writer's offered value, or the
two never connect and no data flows. The comparisons, read from the code:

| Policy | Cyclone check (reader `rd` vs writer `wr`) | Fails (no match) when | Cited |
|---|---|---|---|
| Reliability | `rd.reliability.kind > wr.reliability.kind` | reader RELIABLE(1) > writer BEST_EFFORT(0) | `q_qosmatch.c:163` |
| **Durability** | `rd.durability.kind > wr.durability.kind` | **reader TRANSIENT_LOCAL(1) > writer VOLATILE(0)** | `q_qosmatch.c:167` |
| Deadline | `rd.deadline.deadline < wr.deadline.deadline` | reader wants a tighter period than writer offers | `q_qosmatch.c:183` |
| Latency budget | `rd.latency_budget.duration < wr.latency_budget.duration` | reader budget tighter | `q_qosmatch.c:187` |
| Ownership | `rd.ownership.kind != wr.ownership.kind` | kinds differ | `q_qosmatch.c:191` |
| Liveliness | `rd.liveliness.kind > wr.liveliness.kind` or lease too short | reader stricter | `q_qosmatch.c:195,199` |

The durability enum ordering is what makes this rule bite: in Cyclone `VOLATILE = 0 <
TRANSIENT_LOCAL = 1` (`dds_public_qosdefs.h:77-80`) `[code]`. So a `transient_local` reader (kind 1)
and a volatile writer (kind 0) trip `rd(1) > wr(0)` → `true`, the function returns `false`, and the
endpoints never connect (`q_qosmatch.c:167-169`) `[code]`. This gate matters to the monitor for a
reason beyond matching: **a mismatch means the freshness clock never starts** — the consumer is
coupled to no producer, so `age(topic)` is unbounded (infinite staleness) while a naive reader sees
only "no samples yet," indistinguishable from startup. Any harness writer that is meant to reach the
reader must therefore offer `transient_local` durability or stronger; the dropped-injection trace in
[§4](#4-injecting-data-from-outside-the-simulation) follows exactly this failure, and is the study's
worked example of a silent, uncoupled producer.

How the ROS layers map onto these values. The middleware QoS profile carries exactly nine members
— history, depth, reliability, durability, deadline, lifespan, liveliness, liveliness lease duration,
and a namespace flag (`rmw/include/rmw/types.h:471-513`) `[code]`. The Cyclone binding's
`create_readwrite_qos` translates these and additionally sets a durability-service QoS for
`transient_local` (`rmw_node.cpp:2010-2104`, especially `2057-2068`) `[code]`. Two consequences
reused later: there is no `transport_priority` and no `ownership` setter anywhere in the binding
or the middleware struct — the seed of the [prioritization finding](#6-qos-message-prioritization); and
the binding disables writer auto-dispose (`dds_qset_writer_data_lifecycle(qos, false)`,
`rmw_node.cpp:2016`) `[code]`.

### 2.5 Discovery

Before any gate can be checked, the two sides must find each other via a two-stage protocol carried as
ordinary RTPS over `lo`. SPDP (Simple Participant Discovery Protocol) announces participants;
SEDP (Simple Endpoint Discovery Protocol) announces each participant's endpoints together with
their topic, type, and full QoS. Each process hosts a DomainParticipant with a random 12-byte
GUID prefix; every writer and reader has a GUID (Globally Unique Identifier) equal to that
prefix plus a 4-byte entity id (`ddsi_guid.h:21-31`) `[code]`. Discovery uses well-known builtin
entity ids: participant announcements use writer id `0x100c2`, endpoint publications `0x3c2`, and
endpoint subscriptions `0x4c2` (`q_rtps.h:41,43,45`) `[code]`.

- SPDP is a periodic multicast announcement, default interval 30 seconds
  (`spdp_interval = 30000000000` ns, `defconfig.c:36`) `[code]`, so a late-joining participant is
  discovered within one SPDP period.
- SEDP carries exactly the QoS that the matching function later compares — so the durability a new
  producer offers, and therefore whether it will *couple* to a given consumer at all, is visible on
  the wire before a single data sample is sent. For the monitor this is the earliest trace event that
  bounds a liveness property: a SEDP publication is when a new source becomes eligible to satisfy
  `pub(topic)`.

Domain 0 and the ports. The effective domain is 0. For domain 0
(`defconfig.c:37-42`; `ddsi_portmapping.c`) `[code]`:

| Traffic | Port (domain 0) |
|---|---|
| SPDP / metatraffic multicast (discovery) | **7400** |
| User-data multicast | **7401** |
| Unicast (metatraffic / user) | **ephemeral** — because participant index is unset |

The fixed multicast discovery port (7400) is the rendezvous both sides need, which is why an identical
Cyclone configuration must be present on host and container; ports 7400/7401 are the targets for a
port-level kill discussed in the [disabling section](#7-disabling-an-element-without-a-clean-shutdown).

Why `lo` multicast is load-bearing. The SPDP-multicast path is guarded by a configuration check
for multicast being allowed (`q_ddsi_discovery.c:314`) `[code]`. If `lo` is not multicast-capable,
Cyclone disables multicast and cannot complete discovery, producing the observed crash "Failed to find
a free participant index for domain 0." In this deployment, disabling multicast on `lo` alone crashes
every container node — the basis of the one-command link kill in the
[disabling section](#7-disabling-an-element-without-a-clean-shutdown).

GUID as a trace key. Every sample and every discovery record is keyed by the writer's GUID (a
locally generated 12-byte prefix plus entity id). The monitor uses that key to attribute a trace to a
*source* — `pub(topic)` and `age(topic)` are always evaluated per (topic, writer GUID) — which is why
a returning or newly-injected source, carrying a fresh prefix, starts a fresh liveness clock rather
than continuing the old one. (Where a fault is induced maliciously, an unexpected prefix is also an
identity signal; that is a footnote, not the property.)

---

## 3. Configurable elements and shutting an element down

*(Reframed as: liveness / freshness loss — a source going silent.)*

Motivation. A source going silent is the strongest freshness violation and the archetypal critical
fault a safe-stop must catch: once a command topic stops publishing, `age(topic)` grows without bound
and the actuator is acting on stale data. This section maps *where* an element's timing behaviour is
set (so a monitor knows what a nominal trace should look like) and the distinct *ways* a source can
stop producing — each of which leaves a different trace signature and takes a different time to become
observable.

Question answered. Which elements of the stack can be configured or controlled to change their
behaviour, lifetime, or presence — and how can a single element be shut down? The direct
answer: configuration splits into settings fixed at launch, settings announced but not changeable, and
settings served live over the network; and there are four distinct shutdown mechanisms, of which
only one is reachable from the network, and even that one only if the node is a managed
"lifecycle" node — which, read from source, none of the command-topic owners here are (§3.2), so
no command node has a network-reachable clean shutdown at all. For the monitor, each mechanism is a
different *freshness-loss signature*: which trace events (if any) precede the silence, and how many
publish periods elapse before the absence is unambiguous.

### 3.1 Configurable elements

The *moment* a knob is set determines whether a network peer can touch it. There are three
configuration surfaces: launch-time config (init options, node options, domain id, the Cyclone XML
file) read once and never served on the network; endpoint-creation config (per-endpoint QoS,
announced read-only via SEDP); and runtime-served config (node parameters and, if the node is
managed, lifecycle transitions) exposed as ROS services and therefore reachable over the network.

| Element | Where configured | Fixed at build/launch or served at runtime? | Reachable by a network peer on domain 0? | Effect |
|---|---|---|---|---|
| **Node parameters** via parameter services | `parameter_service.cpp:36-90`; names `parameter_service_names.hpp:23-28` `[code]` | Runtime | **Yes** — service endpoints matchable by any peer | Change a declared parameter without restart, if the node declared and permits it |
| **QoS profiles** (per endpoint) | `create_readwrite_qos` (`rmw_node.cpp:2010-2104`) `[code]` | Build/launch | **Announced, not settable** — visible in SEDP, not changeable by a peer | Governs matching/delivery; the `transient_local` request is the injector's gate |
| **Node options** | `node.cpp:112-117` `[code]` | Build/launch | No | Per-node construction behaviour |
| **Init options** incl. shutdown-on-signal, domain id | `context.cpp:191-257`; signal path `signal_handler.cpp:262` `[code]` | Launch | No | Whether a termination signal tears the context down |
| **Domain id** | `context.cpp:282-291` `[code]`; effective **0** | Launch | No (but defines the shared namespace) | Isolation scope |
| **Lifecycle state** (managed nodes) | change-state machine + services (§3.2) | Runtime | **Yes, if a managed node — but no command-topic owner here is one (§3.2)** | Move a managed node between configure/activate/deactivate/shutdown |
| **Cyclone XML knobs** (participant index, interface, multicast, max message size, WHC limit) | the Cyclone config file | Launch | No — but changes DDS behaviour for **every element at once** | Interface binding, multicast, max sample size, flow-control back-pressure |

A subtlety. "Reachable by a network peer" for parameters means the *service is matchable*, not that
any value is settable: the node's own callback still enforces which parameters were declared and
validates the value (`parameter_service.cpp:76-90`) `[code]`.

### 3.2 Four distinct shutdown mechanisms

The names invite conflation, so they are kept strictly apart. Only one crosses the process boundary
from the network.

- `rclcpp::shutdown()` — the whole context, from inside the process. It runs pre-shutdown
  callbacks, invalidates the context, runs on-shutdown callbacks, and interrupts every blocking
  sleep/executor (`context.cpp:321-376`) `[code]`. Live publishers do not crash: a `publish()` call
  silently returns on a shut-down context (see [§2.3](#23-the-publish-path-to-the-wire) step 2).
  Blast radius: the whole process's ROS layer. Reachable from domain 0? No — there is no DDS
  endpoint for it. Reversible? No (needs a new context). Signature: a correlated,
  whole-participant SEDP withdrawal.
- Destroying one node. The node destructor resets the node's sub-interfaces in order
  (`node.cpp:267-279`) `[code]`, deleting only that node's DDS writers and readers. Blast radius:
  one node — the scalpel the previous mechanism is not. Reachable? No (an in-process reset).
  Signature: a partial withdrawal while the participant and sibling nodes remain.
- Lifecycle `change_state` — the one network-reachable clean lever, if the node is managed. A
  managed (lifecycle) node exposes a `~/change_state` ROS service
  (`lifecycle_node_interface_impl.hpp:119-134`; name `com_interface.c:41`) `[code]` whose QoS is the
  default for services: keep-last-10, RELIABLE, and VOLATILE (`service.c:214`;
  `qos_profiles.h:64-75`) `[code]`. Because it is VOLATILE, not `transient_local`, an external
  default-QoS client matches it with no durability barrier (the RxO rule,
  [§2.4](#24-delivery-matching-rules)). A `deactivate` request stops a lifecycle publisher from
  publishing; `shutdown` terminates the managed lifecycle; the transition self-announces a
  `TransitionEvent` (`lifecycle_node_interface_impl.hpp:406-431,446`) `[code]`. But this lever does
  not apply to the command-topic owners in this deployment — which matters because it is the one
shutdown that self-announces (a `TransitionEvent` trace event) *before* the topic goes quiet, and it
is absent on the command path. Read from the node sources, the nodes that
  own the two anchor command topics are all plain `rclcpp::Node`s, not
  `rclcpp_lifecycle::LifecycleNode`s: `VehicleCmdGate`, which produces `/control/command/gear_cmd` and
  reads `/system/operation_mode/state`, derives from `rclcpp::Node`
  (`autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.hpp:100`) `[code]`; so do the other command-topic
  consumers `MrmHandler` (`autoware_mrm_handler/include/autoware/mrm_handler/mrm_handler_core.hpp:73`),
  `RawVehicleCommandConverterNode`
  (`autoware_raw_vehicle_cmd_converter/include/autoware_raw_vehicle_cmd_converter/node.hpp:80`), and
  `MissionPlanner` (`autoware_mission_planner_universe/src/mission_planner/mission_planner.hpp:71`)
  `[code]`. This is not a local quirk: a base-class sweep of the whole checkout finds no
  `LifecycleNode` subclass anywhere in Autoware Core or Universe — 282 classes derive from
  `rclcpp::Node` and the single `rclcpp_lifecycle` reference is an unrelated third-party `negotiated`
  example `[code]`. The command-topic owners are instead launched as composable components
  (`RCLCPP_COMPONENTS_REGISTER_NODE`, `autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp:995`) `[code]`,
  which have no lifecycle state machine and expose no `~/change_state` service. What *is* verified is the
  mechanism: where a managed node exists, `change_state` is a network-reachable clean-shutdown lever with
  no durability barrier — but no command-topic owner here is such a node, so that lever is
  unavailable against them. Reversible? `deactivate` yes (via `activate`); `shutdown` no. Monitor
  note: because the announced, pre-silence `change_state`/`TransitionEvent` path does not exist for
  these nodes, a freshness monitor gets no early warning from this mechanism — the command topics can
  only lose freshness through the in-process shutdowns or the protocol withdrawal of
  [§7.1](#71-protocol-level--making-the-middleware-believe-the-element-is-gone), none of which
  announce themselves ahead of the silence.
- Process signals / hard kill. The ROS signal handler funnels a termination signal into the
  whole-context shutdown for every context configured to shut down on signal
  (`signal_handler.cpp:254-284`) `[code]`; a hard kill skips all of it. Reachable from domain 0? No
  — signals need host/operating-system access, not a DDS endpoint, so this freshness loss produces no
  DDS-observable transition the monitor could key on. Freshness-loss signature: a
  graceful signal produces a clean withdrawal like the context shutdown; a hard kill produces no clean
  withdrawal, and peers only reap the participant when its discovery lease expires.

| Mechanism | Blast radius | Reachable from domain 0? | Clean? | Reversible? | Signature |
|---|---|---|---|---|---|
| `rclcpp::shutdown()` | whole process | No | Yes | No | correlated whole-participant withdrawal |
| Node destruction | one node | No | Yes | Re-create only | partial withdrawal, participant stays |
| Lifecycle `change_state` | one managed node | **No for the command nodes — none are managed (§3.2)** | Yes | `deactivate` yes / `shutdown` no | `TransitionEvent` + foreign-GUID service client |
| Signal / hard kill | whole process | No (host only) | graceful yes / hard no | No | graceful clean / hard silence + lease timeout |

Closing block — §3 in monitor terms.

1. The property. A liveness/freshness pair per actuation-feeding topic:
   `G( age(/control/command/gear_cmd) ≤ Δ_fresh )` and
   `G( pub(/control/command/gear_cmd) → F_[0,Δ_deadline] pub(/control/command/gear_cmd) )`, and the
   same over `/system/operation_mode/state`. Every shutdown mechanism in §3 violates the liveness
   property; `Δ_deadline` and `Δ_fresh` are derived from the topic's nominal publish period against
   the `/clock` base, not from any DDS setting, because the command readers configure no deadline at
   all ([§5.3](#53-over-publication-and-cyclones-flow-control)) `[INFERRED]`.
2. The trace event. Primarily **sample arrival** — the per-(topic, writer GUID) arrival timestamp,
   from which age and inter-arrival both follow, visible at every layer from ddsi upward. The only
   *pre-silence* event is the `TransitionEvent` of a managed node — which the command owners are not
   (§3.2) — so on the command path the monitor has no early warning and must key on arrival gaps. A
   **first-class hazard** here: a `transient_local` writer's last sample is latched in the WHC and
   re-served to a late-joining reader, so a naive reader that keys on "did a sample ever arrive" will
   see a **dead publisher as alive** — the freshness monitor must therefore evaluate age against the
   sample's own timestamp, never against mere presence of a latched value.
3. The safe-stop decision. **Safe-stop.** These topics feed actuation and none of the mechanisms
   self-heals within an actuation period (the in-process shutdowns need a restart, the protocol
   withdrawal needs re-discovery). The only differentiator is *latency of detection*: one sample
   transit if a `TransitionEvent` precedes (managed nodes only), roughly one publish period if the
   monitor watches arrivals, and up to the 10-second participant lease if it instead trusts DDS
   liveness — which is why arrival timestamps, not DDS liveliness, must carry the property.

---

## 4. Injecting data from outside the simulation

*(Reframed as: the fault-injection harness — how off-nominal traces are driven in to exercise the monitor.)*

Motivation. To exercise a runtime STL monitor you must be able to inject off-nominal traces —
early, late, stale, or wrong-value samples — into a live topic and see whether the monitor's property
fires and its safe-stop path runs. This section is the study's **test instrument**: the two ways an
out-of-simulation process can get a sample *accepted* by a legitimate reader (its callback runs with
the injected value), which is exactly what is needed to author a controlled fault trace against a real
`transient_local` command topic. It matches the abstract's "extreme fault-injection stress tests"
`[LSEU-abstract]`.

Question answered. What are the viable ways for the harness to publish a sample that a legitimate
node *accepts* — meaning its callback actually runs with the injected value — and how do the carriers
compare on how faithfully they reproduce a real source's trace? The direct answer: two carriers. An
ordinary ROS 2 node is trivial and works as long as it offers `transient_local` durability; a
hand-forged RTPS speaker reproduces a source's wire trace faithfully but is much harder, with the
difficulty concentrated in faking discovery. "Accept" is load-bearing: the bytes must clear discovery,
topic-name matching, type matching, and QoS compatibility — and only an accepted sample changes the
trace the monitor evaluates.

The acceptance chain both carriers must clear, assembled as the harness checklist:

### 4.1 Carrier A — an external ROS 2 node

The cheapest harness carrier is an ordinary ROS 2 (Humble) C++ program on the host, configured with
the same `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and the same Cyclone configuration file. From DDS's
point of view it is just another participant, discovered within one SPDP period. It reuses the entire
publish path ([§2.3](#23-the-publish-path-to-the-wire)) — nothing is forged; the injector *is* a real
DDS writer with a genuine GUID, sequence numbers starting from 1, and correct CDR. The one thing it
must get right is the QoS:

```cpp
// Run with: RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
rclcpp::init(argc, argv);
auto node = std::make_shared<rclcpp::Node>("not_the_sim");
// THE load-bearing line: offer transient_local, or the reader never matches.
rclcpp::QoS qos = rclcpp::QoS(rclcpp::KeepLast(1)).reliable().transient_local();
auto pub = node->create_publisher<autoware_adapi_v1_msgs::msg::OperationModeState>(
    "/system/operation_mode/state", qos);
autoware_adapi_v1_msgs::msg::OperationModeState m;
m.mode = 2;  // AUTONOMOUS
pub->publish(m);          // descends the §2.3 path to a real RTPS DATA on lo
rclcpp::spin_some(node);
```

The `transient_local()` call sets transient-local durability (`qos.hpp:198-200`) `[code]`; without it
the QoS defaults to VOLATILE (`qos.hpp:115-119`) `[code]`, which is the dropped case below. With
durability offered as `transient_local`, the reader's RxO durability test `rd(1) > wr(1)` is false, all
gates pass, and the sample is delivered — and because the topics are `transient_local`, the injector's
write history cache even resends the value to a reader that joins *after* it.

### 4.2 The dropped injection

This is the default outcome of the sketch above with `transient_local()` removed: an injection
*emitted* but never *accepted*. The writer is announced via SEDP carrying VOLATILE durability
(`dds_public_qosdefs.h:77`) `[code]`; the Autoware reader requested `transient_local` (kind 1). On
discovery, the matching function evaluates `rd.durability(1) > wr.durability(0)` → true, records the
reason as the durability policy, and returns `false` (`q_qosmatch.c:167-169`) `[code]`. The
endpoints never connect; the reader's callback never fires. Crucially, `publish()` on the injector
still succeeds — the sample goes into its own write history cache and nowhere else. The harness
reports success and the vehicle trace is unchanged. This is the study's worked example of an
**uncoupled producer**: the only wire trace is a SEDP announcement of a writer whose durability does
not satisfy the reader, so no sample ever crosses and the consumer's `age(topic)` clock never starts
(the [§2.4](#24-delivery-matching-rules) point). A monitor that keys only on delivered content sees
nothing here; the freshness property is what catches it, because the coupled source stays silent.

### 4.3 Carrier B: hand-forged RTPS without ROS 2

Carrier A suffices to author a value/timing fault in the *simulation*; Carrier B is the carrier that
reproduces a source's full *wire* trace faithfully — a fresh writer GUID, its own sequence numbers and
HEARTBEAT — which is what the replay analysis ([§5](#5-replay-and-over-publication)) needs, and models
a producer (e.g. an ECU) that runs no ROS 2 at all. It is two forgeries: a discovery forgery (make
Cyclone believe a matching writer exists) and a data forgery (a well-formed DATA packet carrying
valid CDR under that writer's GUID and a fresh sequence number). What it must reproduce:

| # | Requirement | Evidence |
|---|---|---|
| 1 | Domain 0, `lo`, the ports (SPDP/meta 7400, user-data 7401, unicast ephemeral) | `[code]` (ports) |
| 2 | SPDP participant announcement (12-byte GUID prefix + builtin id `0x100c2`) | `[code]` id / `[spec]` framing |
| 3 | SEDP endpoint announcement (id `0x3c2`) declaring the mangled topic name, the type name, and a QoS list that **offers `transient_local`** | `[code]` ids / `[spec]` list |
| 4 | Type agreement (name, plus a type hash if type discovery is enabled) | `[code]` + `[UNVERIFIED]` flag |
| 5 | QoS on the wire passing every RxO check, durability foremost | `[code]` (rule) |
| 6 | CDR framing: 4-byte encapsulation header (`CDR_LE`, options `0x0000`) + aligned body | `[spec]` header + `[code]` encoding flag |
| 7 | A valid writer GUID (matching step 3) + a fresh sequence number | `[code]` seq model / `[spec]` DATA header |

Cyclone serializes ROS messages in a specific representation (the XCDR1 encoding, `serdata.cpp:703`)
with no key handling for ROS types (`serdata.cpp:590,605-628`) `[code]`. For a `GearCommand` — a
timestamp (int32 seconds, uint32 nanoseconds) followed by a `uint8 command` — the forged payload is:

```
serializedPayload (inside the RTPS DATA submessage):
  +0  00 01        representation_id  = CDR_LE          [spec]
  +2  00 00        representation_opts = 0              [spec]
  --- CDR body (aligned) ---                            [code: encoding flag]
  +4  ss ss ss ss  int32  stamp.sec
  +8  nn nn nn nn  uint32 stamp.nanosec
  +12 02           uint8  command = 2 (DRIVE)           [code: DRIVE=2]
```

Verdict. Carrier B is feasible in principle but substantially harder than Carrier A, and the
difficulty is concentrated in the discovery forgery (items 1–3), not the data forgery; reproducing a
byte-accurate SPDP/SEDP handshake that Cyclone accepts is where an off-the-shelf forger fails. Whether
a hand-built sequence is accepted by this specific build, and whether a type hash is required, are
`[UNVERIFIED]` (would need a live capture). The value of the enumeration is twofold: each item is an
invariant a *faithful* trace must satisfy, and each is a knob the harness can deliberately perturb to
author a specific off-nominal trace.

Closing block — §4 in monitor terms.

1. The property. §4 does not itself impose a constraint; it is the instrument that *violates* one on
   demand. By choosing the injected sample's timestamp and rate it drives whichever property is under
   test — freshness `G( age(/system/operation_mode/state) ≤ Δ_fresh )`, a wrong-value trace on
   `mode`/`command`, or (via a burst) the rate bound `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )`.
   The one hard precondition is coupling: an injector that does not offer `transient_local` is
   uncoupled (§4.2) and changes no trace at all.
2. The trace event. Every accepted injection is an ordinary **sample arrival** on the target topic —
   an (arrival timestamp, source timestamp, writer GUID, sequence number) tuple, visible from ddsi
   upward. Carrier A restarts sequence numbers from 1 under a fresh GUID; Carrier B can reproduce an
   arbitrary GUID/sequence/HEARTBEAT trace. The dropped injection (§4.2) produces only a SEDP
   record and no sample event — the monitor sees it as *continued silence*, not as an arrival.
3. The safe-stop decision. This section sets up the decision rather than making it: the harness's
   job is to confirm that when it drives an out-of-bound age, rate, or value onto an actuation topic,
   the monitor's property fires and the safe-stop path runs. Whether a given injected trace *should*
   trigger safe-stop is decided by the property under test (§3, §5, §7), keyed on the topic's role in
   actuation.

---

## 5. Replay and over-publication

Motivation — the flagship fault class. This is the study's flagship for the monitor, because it is
the abstract's headline stress case: **100× network over-publication** — a *rate / actuation-frequency*
constraint driven far off-nominal — under which the verifier's cost must stay **linear**
`[LSEU-abstract]`. The question is how the wire behaves when a topic is flooded (or a stale value is
re-presented), and therefore what an event-driven monitor observes and must evaluate cheaply as the
trace rate explodes. Two distinct violations live here: a *freshness* violation (an old value
re-presented as current) and a *rate* violation (samples arriving faster than `1/f_max`).

Question answered. Can the harness replay traffic — capture legitimate messages on a command topic
and re-present them so a subscriber treats them *as fresh* — and if not, can it at least over-publish
(emit many samples without capturing any)? The direct answer, preserving the shape of the
investigation: replay is examined first. A *faithful* replay that re-sends the original packets
verbatim is blocked by the reader's duplicate/ordering filter — a wire-level fact with direct
consequences for what the monitor can and cannot delegate to DDS. That forces a pivot to
over-publication, which works but self-throttles under Cyclone's flow control.

What "accept as fresh" requires. A replayed sample must clear two reader-side stages that a
single-shot injection never had to consider:


The proxy writer is Cyclone's local shadow of a remote writer, keyed by GUID; each owns one reorder
buffer whose `next_seq` remembers the next sequence number expected from that writer. Which GUID the
replay carries selects which `next_seq` it is compared against — and that decides everything.

### 5.1 Replay via a ROS 2 injector — achievable, but not faithful

When the ROS 2 injector re-publishes the captured *content*, it authors a new sample on its own
data writer, with its own GUID and its own counter starting from 1. So:

1. Its writer gets a fresh proxy writer with `next_seq = 1` (`q_radmin.c:1682`) `[code]`.
2. Reliable readers put that proxy writer in normal reorder mode
   (`ddsi_proxy_endpoint.c:171-182,277`) `[code]`.
3. The replayed sample carries sequence number 1 (`q_transmit.c:1286`) `[code]`.
4. Stage 1 accepts it: `s->min (1) == reorder->next_seq (1)`, delivered, `next_seq` advances
   (`q_radmin.c:1938-1966`; routed at `q_receive.c:2430`) `[code]`.
5. Stage 2 keeps it: reader-cache depth 1 on keep-last-1 (`dds_rhc_default.c:613`) `[code]`; there is
   no content comparison anywhere — the reader cache keys on instance and sequence, never on payload
   equality.
6. The callback fires with the injected value (`[INFERRED]` from steps 1–5; the firing itself is
   `[UNVERIFIED]`).

This satisfies the study's definition of replay (re-presenting previously-seen content) but is not
faithful: the original writer's GUID and sequence numbers are gone, replaced by the injector's. To the
monitor the trace is simply a *fresh sample under a new source GUID carrying an old value* — the
per-(topic, writer GUID) freshness clock restarts, so the stale value arrives looking current. ROS 2
gives no control over the writer GUID or sequence number, so a wire-faithful replay is only conceivable
on the direct-RTPS path — which is where it dies.

### 5.2 Faithful direct-RTPS replay — blocked

A verbatim capture-and-resend (Carrier B, original GUID and sequence numbers intact) is routed to the
*original* writer's proxy writer, whose `next_seq` has already advanced past those numbers during live
delivery:

1. Live delivery already set `reorder->next_seq = n+1` (`q_radmin.c:1966`) `[code]`.
2. The forged DATA carrying GUID `G` routes to `G`'s existing proxy writer (`q_receive.c:2430`)
   `[code]`.
3. The replayed `s->min (n) < reorder->next_seq (n+1)` takes the stale branch (`q_radmin.c:1979`)
   `[code]`.
4. It is discarded as too-old (the reorder code's `NN_REORDER_TOO_OLD`, value `-1`, `q_radmin.h:207`),
   returned without storing (`q_radmin.c:1979-1985`) `[code]`.
5. Delivery happens only when the reorder result is positive (`q_receive.c:2445`) `[code]`; `-1` fails,
   so the callback never runs — dropped at Stage 1, before the reader cache.
6. Even *advancing* the sequence number under GUID `G` does not deliver immediately: normal mode buffers
   it pending the missing numbers (`q_radmin.c:1938-1940,1987+`) `[code]`, and the reliable reader then
   negatively-acknowledges the gap, which the forger cannot satisfy without also forging the intervening
   samples.

A compounding prerequisite: a reliable reader accepts no data from a proxy writer until it has seen a
HEARTBEAT from it (`q_receive.c:2363-2368`) `[code]`, so a faithful-replay forger must also
reproduce a consistent HEARTBEAT whose announced range lines up with what it replays.

Verdict and forced pivot. Faithful direct-RTPS replay is blocked by the reorder buffer's
`(writer GUID, next_seq)` state. To deliver at all, the harness must abandon wire-faithfulness in one
of two ways — use a fresh writer GUID (a new proxy writer, `next_seq = 1`, exactly what the ROS 2 path
does for free) or advance the sequence numbers past the reader's window with a matching HEARTBEAT/GAP.
Either way the delivered samples are *new samples carrying old content*, which is over-publication.
This is decisive for the monitor: DDS's own reorder/dedup logic rejects an *identical* (GUID,
sequence) re-presentation, but it does **not** protect against a stale *value* re-presented under a new
sequence number — so freshness-by-value cannot be delegated to the wire; the monitor must evaluate age
against the sample's own timestamp.

### 5.3 Over-publication and Cyclone's flow control

Every accepted sample is delivered, but a *flood* meets Cyclone's flow control. On a reliable writer,
each unacknowledged sample stays in the write history cache (WHC) until the reader acknowledges it:

1. Each publish retains a sample via `insert_sample_in_whc` (`q_transmit.c:1286,1299`) `[code]`.
2. Before the next sequence number, `write_sample_eot` tests whether unacknowledged bytes exceed the
   high-water mark (`q_transmit.c:1252`) `[code]` — that mark is the `WhcHigh=500kB` from the
   configuration.
3. Over the mark, it calls `throttle_writer`, which forces out a HEARTBEAT and blocks the
   over-publishing writer's own `publish()` until the cache drains or a timeout (`q_transmit.c:1257-1105`) `[code]`.
4. The timeout is the reliability max-blocking-time; on expiry the publish aborts with a timeout code
   (`q_transmit.c:1053,1266-1271`) `[code]`. So a reliable flood self-throttles; past the watermark
   the over-publishing writer's own publishes stall and can fail.
5. Even for delivered samples, keep-last-1 means the reader cache keeps only the newest per instance
   (`dds_rhc_default.c:613`) `[code]` — a burst of N identical commands collapses to "the latest one."
6. Lifespan and deadline are left at their defaults (unset) on the command readers, so
   neither expires a flooded sample nor would flooding *cause* a deadline miss — deadline fires on too
   *few* samples, not too many. This is now read directly from the subscription QoS: the command
   readers declare only depth and durability — `VehicleCmdGate`'s operation-mode reader is
   `rclcpp::QoS(1).transient_local()` (`autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp:110-111`)
   `[code]`, and the polling readers for gear and operation-mode state take the library default
   `rclcpp::QoS{1}` (`autoware_utils_rclcpp/.../polling_subscriber.hpp:206`) `[code]` — and neither
   sets deadline or lifespan, leaving both at the rmw default (unset). None of these nodes wire up a
   `qos_overriding_options` hook on those subscriptions `[code]`, so there is no runtime parameter that
   re-introduces a deadline or lifespan either. The same declarations *confirm* (they do not re-derive)
   the foundation's matching premise ([§2.4](#24-delivery-matching-rules)): these readers are keep-last
   depth 1 and default RELIABLE, and `VehicleCmdGate`'s operation-mode reader explicitly requests
   `transient_local` durability — so a `transient_local` writer (as the command publishers are,
   `autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp:60-61,70`;
   `autoware_command_mode_decider/src/command_mode_decider_base.cpp:94-95`) `[code]` satisfies the RxO
   durability gate exactly as the injection argument assumes. The behaviour-driving *gear* reader in
   this demo is AWSIM's Unity vehicle interface, and its QoS is now confirmed from source:
   `AccelVehicleRos2Input` subscribes to `/control/command/gear_cmd` (and `control_cmd`,
   `turn_indicators_cmd`, `hazard_lights_cmd`, `emergency_cmd`) with a single shared profile of
   RELIABLE, TRANSIENT_LOCAL, KEEP_LAST depth 1
   (`src/awsim/Assets/Awsim/Scripts/Entity/Vehicle/AccelVehicle/Input/AccelVehicleRos2Input.cs:43-46,84-88`)
   `[code]`. So the AWSIM gear reader requests `transient_local` just as `VehicleCmdGate`'s does — a
   `transient_local` writer matches it, and a volatile-only injector would be dropped at the RxO
   durability gate exactly as in [§4.2](#42-the-dropped-injection). AWSIM expresses QoS through its own
   `QosSettings` wrapper, which exposes only reliability, durability, history, and depth and sets
   nothing else on the `ros2cs` profile
   (`src/awsim/Assets/Awsim/Scripts/Common/Ros2/QosSettings.cs:30-50,65-73`) `[code]` — so, like
   `rclcpp`, the AWSIM binding leaves deadline, lifespan, and ownership at their DDS defaults on every
   reader and writer (a repo-wide search finds no ownership, deadline, or lifespan setter used anywhere
   in AWSIM's C#) `[code]`.

Where the flood's cost lands. The watermark is paid by the *over-publishing writer*, not the
reader. Flooding over-writes the command value at high rate but cannot, by volume alone, displace a
legitimate writer — Cyclone offers no prioritization or ownership arbitration on these SHARED,
ROS-created readers (see the [prioritization section](#6-qos-message-prioritization)). Over-publication
is therefore a *rate/freshness* fault, not a takeover: it corrupts the timing of the command stream,
which is exactly what a rate-bound STL property is written to catch. The DDS layer imposes no content
de-duplication — and, read now from the node sources,
neither does the Autoware application. The two anchor-topic consumers act on each received value
without comparing it to the last: `VehicleCmdGate`'s operation-mode callback stores the sample verbatim,
`[this](const OperationModeState::SharedPtr msg) { current_operation_mode_ = *msg; }`, with no
stamp, counter, or equality guard (`autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp:110-112`) `[code]`;
and `MrmHandler` reads the latest gear sample and passes its `command` straight through —
`msg.command = (gear == nullptr) ? last_gear_command_ : gear->command;` — again with no freshness or
duplicate check (`autoware_mrm_handler/src/mrm_handler/mrm_handler_core.cpp:163-165`) `[code]`. The
polling readers these nodes use keep only the newest sample and never compare payloads
(`autoware_utils_rclcpp/.../polling_subscriber.hpp:244-257`) `[code]`, so a repeated identical command
is simply the current value when the node next runs. There is no monotonic field, timestamp-freshness
gate, or rate limit on the command path. This ties back to the replay finding in
[§5.1](#51-replay-via-a-ros-2-injector--achievable-but-not-faithful): the application does not blunt
a replayed command — it accepts the replayed value as fresh, exactly as it accepts any new sample. The
AWSIM client behaves identically: `AccelVehicleRos2Input`'s gear callback overwrites its state with each
sample, `_gearInput = ...Ros2ToUnityGear(msg)`, and its control callback overwrites acceleration and
steering the same way, with no freshness or duplicate check
(`src/awsim/Assets/Awsim/Scripts/Entity/Vehicle/AccelVehicle/Input/AccelVehicleRos2Input.cs:77-88`)
`[code]`; `UpdateInputs()` then actuates whatever the latest sample left behind (`:97-106`) `[code]`. So
a replayed gear or control command is actuated as fresh on the AWSIM side too.

Closing block — §5 in monitor terms.

1. The property. A rate bound and a freshness bound on each command topic:
   `G( inter_arrival(/control/command/gear_cmd) ∈ [1/f_max, 1/f_min] )` and
   `G( age(/control/command/gear_cmd) ≤ Δ_fresh )`. Over-publication (up to the abstract's 100× case
   `[LSEU-abstract]`) violates the upper rate bound; a re-presented stale value violates freshness even
   while the rate looks nominal. Bounds are `[INFERRED]` from the topic's nominal period against
   `/clock`, since the readers set no deadline/lifespan (confirmed below).
2. The trace event. A per-(topic, writer GUID) stream of **(arrival timestamp, source timestamp,
   sequence number)** tuples — inter-arrival gives the rate, source-timestamp-vs-now gives the age.
   These are cheap, per-event scalars: evaluating the rate/freshness property is O(1) per sample, so
   total cost is linear in the trace length even under a 100× flood — the mechanism behind the
   abstract's claimed linear verification complexity `[LSEU-abstract]`. Cyclone's own reorder logic
   supplies a bonus observable (an already-seen (GUID, sequence) pair is dropped as too-old,
   `q_radmin.c:1979`), but that only catches *bit-identical* replays, not stale values under new
   sequence numbers.
3. The safe-stop decision. Depends on which bound broke. A **freshness** violation on an actuation
   topic is safe-stop (the vehicle would act on stale data — and, as the node sources confirm, neither
   DDS nor the Autoware application de-duplicates or freshness-gates: `VehicleCmdGate`'s and
   `MrmHandler`'s callbacks act on each value with no stamp/counter/equality guard
   (`vehicle_cmd_gate.cpp:110-112`; `mrm_handler_core.cpp:163-165`) `[code]`, and AWSIM's
   `AccelVehicleRos2Input` actuates whatever the latest sample left behind
   (`AccelVehicleRos2Input.cs:77-88,97-106`) `[code]`). A pure **rate** excess with fresh, consistent
   values is a degradation to flag unless it also breaches freshness or starves a real-time task — but
   because rate-and-freshness rejection cannot be delegated to the application (it obeys every
   re-presented value), the monitor must own both properties itself.

---

## 6. QoS message prioritization

*(Reframed as: timing determinism & mixed-criticality — whether the temporal constraints can be met on the wire at all.)*

Motivation. A temporal constraint can only be *satisfied* if the wire delivers samples with
bounded, predictable latency and jitter; and the monitor itself has to run on a resource-constrained
multicore RISC-V executing mixed-criticality workloads, consuming `<2%` of core capacity with
negligible interference on real-time tasks `[LSEU-abstract]`. Both concerns turn on the same question
this section answers: what timing/scheduling levers does Cyclone QoS actually expose — deadline,
latency budget, transport priority, ownership, history/WHC — and which of them are reachable at all
in this build? If the levers that would shape latency and prioritize critical flows are unreachable,
then the wire offers no determinism guarantee and the monitor must treat every command topic's timing
as best-effort — which is precisely what the freshness/rate properties are for.

Question answered. How can Cyclone DDS Quality-of-Service settings be used to prioritize or
timing-shape messages, and how much of that is reachable through ROS 2 versus only through Cyclone's
own configuration? The direct answer, stated plainly: the two policies that would actually
prioritize — transport priority and ownership — are not exposed by the ROS middleware at all, so
prioritization is unreachable from the ROS QoS API. Cyclone implements both internally, but only its C
API (and, partly, its XML) can reach them, and the one XML path that would shape the wire is compiled
out of standard builds. For the monitor, the consequence is that on the stock stack there is **no
wire-level timing determinism knob** in reach — latency and jitter are whatever best-effort delivery
yields.

Central finding. Neither transport priority nor ownership is present in the ROS middleware QoS
profile or set anywhere in the Cyclone binding, so prioritization is not reachable through the ROS 2
QoS API. Cyclone itself *does* implement both — including working exclusive-ownership
arbitration, contrary to a common expectation that Cyclone lacks it — but only through its C DDS API
or, for transport priority, partly through XML. The one XML mechanism that would shape the wire,
network channels, is compiled out of standard builds, leaving a single live lever: synchronous
delivery gated on transport priority, which still needs the C API to set the priority.

### 6.1 The exact ROS-reachable surface

A policy that is not a *field* cannot be set. The ROS middleware QoS profile has exactly nine members
and no transport-priority and no ownership/ownership-strength member (`rmw/include/rmw/types.h:471-513`)
`[code]`. The `rclcpp` QoS class exposes setters for exactly those fields (`qos.hpp:151-236`) `[code]`
and has no transport-priority or ownership setter — it could not, since its only backing store is the
middleware profile it returns. A search of the whole Cyclone binding finds no call to
`dds_qset_ownership`, `dds_qset_ownership_strength`, or `dds_qset_transport_priority` `[code]`. Because
the middleware layer is the vendor-neutral contract, a policy absent there is invisible to every ROS 2
DDS vendor — the ceiling is set at the middleware, not the vendor. Consequence: every writer and
reader on the ROS path — including any harness node — carries transport priority 0 and SHARED
ownership, so no ROS-created flow can be given latency precedence over another. Timing determinism, if
needed, cannot come from the ROS QoS layer.

### 6.2 Transport priority — where it lives, and where it is dead

Cyclone gives the value a home (`ddsi_xqos.h:329`, default 0 at `ddsi_plist.c:3459`) and serializes it
into the SEDP QoS list (`ddsi_plist.c:1907`, not behind any feature guard) `[code]` — so it is
announced before data flows. It is consumed in exactly two places:

- Network channels (the priority-to-network-path feature) — compiled out. Channel selection
  (`ddsi_endpoint.c:887-894`), channel lookup (`q_misc.c:145-162`), and the DiffServ (DSCP) IP marking
  (`ddsi_udp.c:553-561`) are all guarded by a network-channels build flag `[code]`. That flag is not a
  supported build option — the build's CMake list has no option for it, and a comment lists it among
  flags that merely "linger in the sources" (`cyclonedds CMakeLists.txt:25-32,66-68`) `[code]`. So in
  any standard build (the container's stock image, `[INFERRED]`), transport priority produces no
  dedicated network path and no DSCP marking, and the configuration defines no channels.
- Synchronous delivery gated on transport priority — the only live lever. On the receive side, a
  proxy writer is delivered synchronously if its latency budget is within a configured bound and its
  transport priority meets a configured threshold (`ddsi_proxy_endpoint.c:222-231`) `[code]`. But the
  threshold defaults to `0` (`ddsi_cfgelems.h:1252`) and the latency bound to infinity
  (`defconfig.c:55`) `[code]`, and the configuration sets neither — so every writer passes and the
  threshold does not discriminate. Using it would require raising the threshold in the configuration
  and giving the privileged writer a matching transport priority via the C API. Even fully
  configured it shapes *latency* (which thread delivers), not *arbitration*, and lives on the receive
  side keyed on the remote writer's advertised priority — so it cannot give a critical command flow
  guaranteed precedence, and a stray high-priority sample gains none either.

### 6.3 Ownership — implemented, but ROS readers never arm it

Cyclone implements exclusive-ownership arbitration in its default reader cache: it records whether the
reader requested exclusive ownership (`dds_rhc_default.c:610`) and, for an instance owned by a live
higher-strength writer, drops weaker writers' samples (`dds_rhc_default.c:1041-1064`) `[code]`. The
values travel on the wire (`ddsi_plist.c:1902-1903`) and the C-API setters exist
(`dds_public_qos.h:276-288`) `[code]`. So the common "Cyclone lacks exclusive ownership" caveat does
not hold here. But the arbitration is gated on the reader requesting exclusive ownership, and no
ROS path sets ownership — the Autoware readers keep the default SHARED, so exclusive-ownership mode
is off and every matched writer's samples are accepted, newest-wins. Reading the actual command-reader
declarations confirms this directly: the subscriptions to the two anchor topics construct their QoS from
`rclcpp::QoS(1).transient_local()` and the polling-subscriber default `rclcpp::QoS{1}`
(`autoware_vehicle_cmd_gate/src/vehicle_cmd_gate.cpp:110-111`;
`autoware_utils_rclcpp/.../polling_subscriber.hpp:206`) `[code]` — and neither touches ownership,
because the `rclcpp` QoS class has no ownership setter to call (§6.1). No command reader here takes a
Cyclone C-API or direct-DDS path that could set it out of band; every one is an ordinary `rclcpp`
subscription, so all stay SHARED. The AWSIM client reaches the same conclusion by the same route: its
`QosSettings` wrapper has no ownership setter and its command readers request only reliability,
durability, and history (§6.1), so AWSIM's readers stay SHARED too — the newest-wins, no-arbitration
behaviour holds across both client surfaces. A writer that reached the C API to set exclusive
ownership with high strength would gain nothing, and worse would fail to match the SHARED reader (an
RxO ownership-kind mismatch, `q_qosmatch.c:191`) `[code]` and deliver nothing — a variant of the
uncoupled-producer trace, on ownership kind rather than durability. Making ownership usable — e.g. to
let a designated safe-stop actuator's command dominate — would require changing the Autoware reader's
QoS to exclusive and setting the privileged writer's strength via the C API, a coordinated, build-time
change to both endpoints, not a runtime action.

### 6.4 True prioritization vs. latency shaping

The ROS-reachable policies influence timing but do not set priority between writers: deadline is a
contract and alarm, not a scheduler (the [freshness-loss section](#7-disabling-an-element-without-a-clean-shutdown)
reads its *violation* as a freshness trace event); latency budget is a hint whose only teeth are the §6.2
synchronous-delivery gate, ANDed with a transport priority ROS cannot set; reliability, history, and
depth govern whether and how many samples survive — flow control (see the
[replay section](#5-replay-and-over-publication)), not who wins.

| QoS policy | Reachable via ROS 2? | Reachable via Cyclone config / C API? | Prioritization role |
|---|---|---|---|
| **Transport priority** | **No** | C API; XML only via network channels (compiled out) | Only the sync-delivery gate works here |
| **Ownership / strength** | **No** | C API; reader cache implements exclusive mode | Real "whose command wins" — but reader must request exclusive |
| **Deadline** | Yes | Yes | None (contract, not scheduler) |
| **Latency budget** | Yes | Teeth only via §6.2 | Latency shaping, not priority |
| **Reliability / history / depth** | Yes | Yes | Flow control, not priority |
| **Durability (transient_local)** | Yes | Yes | The match gate, not priority |

Closing block — §6 in monitor terms.

1. The property. A latency/jitter constraint underlies every freshness and rate property:
   `G( transit_latency(topic) ≤ Δ_lat )` and bounded jitter, so that `age` and `inter_arrival` stay
   within their bounds. §6's finding is that the stack provides **no wire knob** to *guarantee* this
   `Δ_lat` — transport priority and ownership are unreachable on the ROS path, network-channels/DSCP is
   compiled out — so `Δ_lat` is whatever best-effort delivery yields and the constraint is monitored,
   not enforced, at the QoS layer `[INFERRED]`.
2. The trace event. The same per-sample **(arrival timestamp, source timestamp)** the freshness
   property uses; their difference is transit latency and its variation is jitter. No extra observable
   is needed — and none is available, since the prioritization levers that would tag or reorder flows
   are inert here (transport priority 0, SHARED ownership on every endpoint).
3. The safe-stop decision. QoS misconfiguration is not itself a safe-stop; it is a *precondition*
   that decides whether the freshness/rate properties can be met at all, so a persistent latency-bound
   breach is escalated through the freshness property (§3/§5), not flagged on its own. The deployment
   angle is the mixed-criticality one: the monitor runs on a resource-constrained multicore RISC-V and
   must add `<2%` CPU with negligible interference on real-time tasks `[LSEU-abstract]` — which the §5
   linear, O(1)-per-event evaluation makes feasible; this static study does not measure it.

---

## 7. Disabling an element without a clean shutdown

Motivation — the hardest case, and the actuator. §3 covered freshness lost through a *clean*
shutdown, which at least sometimes announces itself. This section covers freshness lost **without** a
clean shutdown signal — the hardest case for a monitor, because the source stops feeding a reader with
no announced transition to key on. The same three layers are also read a second way: as candidate
mechanisms by which a **safe-stop could itself halt a data flow** — the actuation side of the SEU.
Protocol, physical, and application each cut the flow differently, and each leaves (or fails to leave)
a different trace.

Question answered. Short of the clean shutdown covered in
[§3](#3-configurable-elements-and-shutting-an-element-down), how can a source stop reaching its
consumer — at the protocol layer, the physical/transport (loopback) layer, and the application layer?
The direct answer: at the protocol layer, a forged endpoint-withdrawal packet makes the middleware
delete a live endpoint with no authorization check (silent freshness loss, no announced transition);
at the physical layer, one command on `lo` takes the whole system down; at the application layer, the
clean levers already described apply. This section draws its application layer from
[§3](#3-configurable-elements-and-shutting-an-element-down), its discovery/forging
mechanics from [§4](#4-injecting-data-from-outside-the-simulation) and the
[background](#2-background-the-communication-stack), and its QoS reasoning from
[§6](#6-qos-message-prioritization). Its one genuinely new mechanism is the endpoint withdrawal.


The protocol layer needs a small keyed packet but no control of the link; the physical layer needs
control of `lo` but forges nothing; the application layer needs a request the node obeys. Read as
*fault* they are ways freshness silently disappears; read as *actuation* they are the levers a
safe-stop could pull.

### 7.1 Protocol level — making the middleware believe the element is gone

An endpoint withdrawal is an ordinary keyed DATA packet with a status flag. When a Cyclone node
deletes its own writer, it routes to the endpoint-withdrawal path carrying a record with only the
endpoint's 16-byte GUID (`q_ddsi_discovery.c:1358-1367,1113-1133`) `[code]`, and the withdrawal becomes
distinguishable only by a status-info flag:

```c
serdata = ddsi_serdata_from_sample(wr->type, alive ? SDK_DATA : SDK_KEY, ps);
serdata->statusinfo = alive ? 0 : (NN_STATUSINFO_DISPOSE | NN_STATUSINFO_UNREGISTER);
```
(`q_ddsi_discovery.c:520-522`) `[code]`. The RTPS byte encoding of the status-info field is `[spec]`;
that Cyclone *sets* the bits is `[code]`.

On receipt, deletion is keyed on the payload GUID, with no ownership check. Following a forged
withdrawal for the `gear_cmd` writer GUID: the discovery handler dispatches on the status-info bits to
the dead-endpoint path (`q_ddsi_discovery.c:1851,1867-1880`); a structural check confirms only that the
entity id is a *writer* id — not an authorization check (`q_ddsi_discovery.c:1745,1480-1493`); it
then deletes the proxy writer using the GUID taken from the injected payload
(`q_ddsi_discovery.c:1747-1748`); the writer is looked up purely by GUID and removed, and the receive
path is told to stop feeding readers from it (`ddsi_proxy_endpoint.c:419,430,444`) — all `[code]`. No
source-versus-target check exists on this dead path, unlike the alive path, which derives and checks
the owning participant (`q_ddsi_discovery.c:1502-1506`) `[code]`. Net effect for the monitor: the
publishing node still calls `publish()` successfully, but its `gear_cmd` no longer reaches the AWSIM
reader — **freshness is lost with no announced transition and no clean withdrawal**, the hardest silent
case. (Read the other way, this same keyed packet is a candidate *actuator* for a safe-stop that needs
to halt one specific flow.)

The participant-level kill and the guard that does not guard here. A participant-level withdrawal
writes a dispose on the participant-discovery builtin writer (`q_ddsi_discovery.c:569-576`); on receipt
the handler deletes the proxy participant and all its endpoints — but only if a
deletion-allowed guard passes (`q_ddsi_discovery.c:645-660`) `[code]`. On this non-secure stack the
guard does not gate the deletion: without DDS Security compiled in it is a stub that returns `true`
unconditionally (`ddsi_security_omg.h:1183-1186`); with security compiled in but an unauthenticated
participant (this stack configures no security), it still allows deletion of the unauthenticated
participant, its own code comment flagging the missing GUID-prefix check (`ddsi_security_omg.c:2052-2068`)
`[code]`. Which build compiles is `[UNVERIFIED]`, but the outcome is the same for an unauthenticated
participant. This has a strictly larger blast radius than the endpoint withdrawal.

What the harness must first reproduce. A withdrawal is only deliverable if its builtin writer is an
established, in-order, reliable source — so it must first be discovered (SPDP,
[§4.3](#43-carrier-b-hand-forged-rtps-without-ros-2)) and clear the reorder/HEARTBEAT gating, which is
trivial for a *fresh* writer (sequence numbers from 1, its own HEARTBEAT vouching for them). It must
also know the target endpoint's exact GUID, learned passively from the target's own announcements. The
chain is: observe discovery → learn the GUID → emit one keyed withdrawal. This is the study's
instrument for driving a *silent* freshness-loss trace (no transition, no lease wait) so the monitor's
absence-detection and safe-stop path can be exercised against the worst case.

Liveliness and deadline are weak, indirect levers. They are *matching* policies, not switches: DDS
liveliness declares a writer not-alive only when *the writer itself* stops asserting, and a deadline
miss fires only when samples fail to arrive — so freshness is lost through the mechanism, not through
these, which merely *report* it after the fact (and slowly). The one indirect path to force them is
blocking discovery keepalives so the participant lease (default 10 seconds, `defconfig.c:45`) expires
(`[INFERRED]`) — a 10-second detection floor, which is exactly why the monitor must key on
arrival-timestamp gaps rather than DDS liveliness. Discovery-multicast overload and malformed-packet
destabilization are mention-level: plausible but resting on parser robustness and operating-system
buffering, bounded by the `MaxMessageSize=65500B` limit and the IP fragmentation limits, and
irreducibly `[UNVERIFIED]`.

### 7.2 Physical level — cutting the simulated link (`lo`)

Beneath every DDS gate is one interface: the loopback `lo`. Anyone with host access can halt
communication under the whole application, forging nothing — the bluntest way freshness is lost, and
(on the deployment bus) the bluntest safe-stop actuator.

| Method | What it disrupts | Reachable from domain 0? | Reversible? |
|---|---|---|---|
| `ip link set lo multicast off` | All container DDS discovery → every node crashes | No — host/link control | Yes: re-enable + relaunch |
| `iptables -A INPUT -i lo -p udp --dport 7400 -j DROP` | Kills SPDP/metatraffic discovery (port 7400) | No — host control | Yes: delete rule |
| `tc qdisc add dev lo ... netem loss/delay` | Degrades *all* `lo` traffic; cannot target one topic | No — host control | Yes: remove qdisc |
| `ip link set lo down` | Kills all loopback traffic | No — host control | Yes: bring up |

The one-command "multicast off" kill is documented behaviour in this deployment, grounded in the
SPDP-multicast gate at `q_ddsi_discovery.c:314` ([§2.5](#25-discovery)). None of these halts *one*
flow selectively — that selectivity is exactly what the protocol withdrawal offers. For the safe-stop
reading this matters: the physical layer is an all-or-nothing actuator (it stops the whole vehicle
network), whereas the protocol withdrawal is a scalpel that halts a single flow — the SEU would choose
between them by how much of the system the fault has compromised. On the deployment bus the physical
equivalent is cutting an automotive Ethernet segment or CAN bus, which needs switch-level control that
an inline SEU has and a stray fault source does not.

### 7.3 Application level (new points only)

The clean paths already covered, with only what is new for the freshness-loss framing: lifecycle
deactivate/shutdown over `~/change_state` would be the only network-reachable *clean, announced* way to
stop a flow, but it requires a managed node and — read from source
([§3.2](#32-four-distinct-shutdown-mechanisms)) — none of the command-topic owners are managed (all are
plain `rclcpp::Node` components), so this path is simply absent here; a parameter change that gates a
behaviour leaves the endpoint present in discovery, so the freshness clock keeps ticking on a topic
whose values have silently stopped changing — a monitor watching only discovery would miss it, and it
shows only as a parameter-events entry; and publishing a countermanding command is the fault-injection
of [§4](#4-injecting-data-from-outside-the-simulation), a value fault rather than a freshness loss,
noted only to keep the boundary clear.

Closing block — §7 in monitor terms.

1. The property. The same liveness/freshness pair as §3, now with the emphasis that the source can
   go silent with **no** announced transition:
   `G( pub(/control/command/gear_cmd) → F_[0,Δ_deadline] pub(/control/command/gear_cmd) )` and
   `G( age(/control/command/gear_cmd) ≤ Δ_fresh )`, over both anchor topics. The endpoint withdrawal,
   the `lo` cut, and the silent parameter-gate all violate liveness/freshness without a `TransitionEvent`
   or clean SEDP withdrawal to precede them `[INFERRED]`.
2. The trace event. **Arrival-timestamp gaps carry the property**, because the cheaper events are
   absent or late here: a forged withdrawal produces a *dispose* SEDP record (`q_ddsi_discovery.c:520-522`)
   but no clean whole-participant withdrawal; the `lo` cut produces nothing until the 10-second lease
   expiry (`defconfig.c:45`); the parameter-gate produces only a parameter-events entry and no DDS
   change at all. So the monitor must key on *missing* sample arrivals against `/clock`, not on any
   positive DDS signal.
3. The safe-stop decision. **Safe-stop** — this is the archetypal critical fault: an actuation topic
   whose freshness is lost and which does not self-heal within an actuation period. §7 also supplies
   the *actuation* half: a safe-stop that must halt a compromised flow can pull the protocol withdrawal
   (one flow, scalpel) or the physical cut (whole network, blunt), chosen by blast radius. The decisive
   robustness note is that DDS Security (authentication) flips the deletion guard to reject
   unauthenticated withdrawals (`ddsi_security_omg.c:2052-2068`) `[code]` — closing the silent-withdrawal
   fault at its source on the deployment build.

---

## 8. Safety Enforcement Unit implications, gathered

This section gathers what the study surfaces for the runtime STL monitor: the **catalog of
temporal/freshness (STL-shaped) properties** the mechanisms establish, each cross-referenced to the
mechanism that defines, satisfies, or violates it, the trace event that lets an event-driven monitor
evaluate it, and whether a violation is safe-stop-critical. Every property is `[INFERRED]` from the
cited mechanism against the `/clock` time base; the concrete bounds (`Δ_fresh`, `Δ_deadline`,
`f_max`/`f_min`) are control-layer parameters not fixed in the checkout. The consistent theme: on this
stack **neither DDS nor the Autoware application freshness-gates, de-duplicates, or rate-limits the
command path**, so every one of these properties must be owned by the monitor itself.

Property catalog.

| # | STL-shaped property (over the anchor topics) | Mechanism that establishes/violates it | Trace event | Safe-stop? |
|---|---|---|---|---|
| P1 freshness | `G( age(/control/command/gear_cmd) ≤ Δ_fresh )`; same for `/system/operation_mode/state` | Publish path stamps + WHC latching (§2.3); readers set no lifespan (§5.3) | per-(topic,GUID) source timestamp vs `/clock` now | **Yes** |
| P2 liveness | `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )` | Any §3 shutdown or §7 silent freshness loss | arrival-timestamp gap | **Yes** |
| P3 rate | `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )` | Over-publication vs. WHC back-pressure (§5.3) | inter-arrival of successive samples | freshness-conditional |
| P4 value-freshness | `G( age ≤ Δ_fresh )` even for a *re-presented* value | Replay/over-pub deliver stale value under new seq (§5) | source timestamp, not sequence number | **Yes** |
| P5 latency/jitter | `G( transit_latency(topic) ≤ Δ_lat )` | No wire prioritization knob reachable (§6) | arrival − source timestamp | precondition only |

Element shutdown → liveness (P2).
- The lifecycle `change_state`/`TransitionEvent` is the only shutdown that *announces itself before*
  the silence — a pre-silence trace event — but it does not exist for the command-topic owners here:
  read from source ([§3.2](#32-four-distinct-shutdown-mechanisms)), every one is a plain `rclcpp::Node`
  component, not a managed lifecycle node, and there is no `LifecycleNode` subclass anywhere in
  Autoware Core or Universe. So on the command path the monitor gets **no early warning** and P2 must be
  evaluated on arrival-timestamp gaps.
- `rclcpp::shutdown()` and node destruction are in-process calls with no DDS endpoint — the monitor
  sees only their *effect* (endpoints withdrawing, then arrivals stop). Signals and hard kills are
  host-level; a hard kill leaves no clean withdrawal and is only visible as abrupt silence plus the
  10-second discovery-lease timeout — again why arrival gaps, not DDS liveliness, carry P2.

Fault-injection harness (how the properties get exercised).
- Carrier A drives an accepted off-nominal sample with one constraint: it must offer `transient_local`
  or it is *uncoupled* (§4.2) and changes no trace — the study's worked example that an unmatched
  producer leaves P1's freshness clock un-started (infinite staleness a naive reader cannot see).
- Carrier B reproduces a source's full wire trace (GUID, sequence, HEARTBEAT), which is what a
  faithful replay or a silent withdrawal (§7.1) needs. Its enumerated invariants are the knobs the
  harness perturbs to author early/late/stale/wrong-value traces against P1–P4.

Replay and over-publication → rate (P3) and value-freshness (P4).
- ROS-carried replay re-presents old content under a fresh GUID with sequence numbers from 1: to the
  monitor it is a fresh sample carrying a stale value — **P4 is violated even though DDS accepts it as
  new**, because Cyclone's reorder/dedup only rejects a *bit-identical* (GUID, sequence) re-presentation
  (`q_radmin.c:1979`), never a stale value under a new sequence number.
- Over-publication is a per-(topic, writer) **P3** violation, self-limiting at the `WhcHigh=500kB`
  watermark on the *publisher* side. Deadline is the wrong instrument — it fires on starvation, not
  excess, and the command readers leave deadline/lifespan unset anyway
  ([§5.3](#53-over-publication-and-cyclones-flow-control)). Because P3/P4 evaluation is O(1) per sample
  (inter-arrival and age are scalars), total cost stays **linear** even under the abstract's 100× flood
  `[LSEU-abstract]`. Neither DDS nor the application de-duplicates (the callbacks act on each value with
  no stamp/counter/equality guard), so P3 and P4 cannot be delegated to Autoware.

Prioritization → latency/jitter (P5).
- No ROS-reachable QoS knob prioritizes or timing-shapes a flow — every endpoint carries transport
  priority 0 and SHARED ownership (§6.1), and the network-channels/DSCP path is compiled out (§6.2). So
  `Δ_lat` is whatever best-effort delivery yields; **P5 is a monitored precondition, not an enforceable
  guarantee**, and a persistent latency breach escalates through P1 rather than firing on its own. The
  deployment concern is that the monitor itself must run on a resource-constrained multicore RISC-V at
  `<2%` CPU with negligible interference `[LSEU-abstract]`, which the linear per-event evaluation makes
  feasible — not something this static study measures.

Silent freshness loss + safe-stop actuation (§7).
- The endpoint withdrawal, the `lo` cut, and the silent parameter-gate all violate **P2/P1 with no
  announced transition** — the hardest case, caught only by arrival-timestamp gaps against `/clock`.
- Read as *actuation*, the same three layers are how a safe-stop halts a flow: the protocol withdrawal
  is a scalpel (one flow), the physical cut is blunt (whole network), the application lever is clean but
  conditional on lifecycle/parameter reachability — the SEU chooses by how much of the system the fault
  has compromised.
- The decisive robustness note for the deployment build: DDS Security (authentication) flips the
  deletion guard to reject unauthenticated withdrawals (`ddsi_security_omg.c:2052-2068`) `[code]`,
  closing the silent-withdrawal fault at its source.

The unifying conclusion: the wire mechanisms determine *whether each property can hold and how its
violation becomes observable*, but they enforce none of them. The monitor derives P1–P5 from the data
dependencies, evaluates them per-event against `/clock`, and safe-stops on a critical freshness or
liveness violation — the pipeline the whole study feeds `[LSEU-abstract]`.

---

## 9. Glossary

Every term is defined here once; the sections above link back rather than redefining. Ordered roughly
bottom-of-stack to top, then protocol, cache, QoS, ROS control surfaces, and study terms.

### Stack layers and serialization

| Term | Definition |
|---|---|
| **rclcpp** | The ROS 2 C++ client library — the interface Autoware nodes are written against. Publisher, Subscription, and Node live here. |
| **rcl** | The ROS 2 C client library beneath `rclcpp`; thin and language-agnostic. Validates and forwards to the middleware layer; does not serialize. |
| **rmw** | The ROS MiddleWare interface — the vendor-neutral C contract every DDS binding implements. A policy absent from `rmw` is invisible to every ROS 2 DDS vendor. |
| **rmw_cyclonedds_cpp** | The `rmw` binding for Cyclone DDS. Translates ROS calls and QoS into Cyclone calls; owns topic-name mangling and type-name construction. |
| **Cyclone DDS** | Eclipse Cyclone DDS, the DDS implementation used here. Its public C API centres on `dds_write`; its protocol engine implements RTPS. |
| **DDS** | Data Distribution Service — the Object Management Group's publish/subscribe standard, with typed topics and QoS. |
| **DDSI / RTPS** | DDSI is the DDS Interoperability wire protocol; RTPS (Real-Time Publish-Subscribe) is its concrete packet format (DATA, HEARTBEAT, ACKNACK, GAP). The byte layout is defined by the specification `[spec]`. |
| **CDR** | Common Data Representation — the binary encoding DDS uses on the wire. Produced by `ddsi_serdata_from_sample`. |
| **XCDR1** | The specific CDR encoding this binding emits for ROS messages (a 4-byte encapsulation header plus an aligned body, with no key handling for ROS types). What a forged-RTPS payload must reproduce. |

### Entities and identity

| Term | Definition |
|---|---|
| **DomainParticipant** | A process's membership in a DDS domain; owns its writers, readers, and the builtin discovery endpoints. |
| **DataWriter / DataReader** | The endpoints that send and receive samples on a topic. A publish is a write on a DataWriter. |
| **Topic** | A named, typed channel. The DDS topic name is the *mangled* ROS name, e.g. `rt/control/command/gear_cmd`. |
| **Domain (domain id)** | An isolation scope; only participants in the same domain discover each other. Here effectively **0**. |
| **GUID** | Globally Unique Identifier of a DDS entity: a 12-byte participant prefix plus a 4-byte entity id, 16 bytes total. A joining process gets a fresh, locally generated prefix — the basis of the "foreign GUID" signature. |
| **Proxy writer / proxy participant** | Cyclone's local shadow of a *remote* writer or participant, keyed by GUID. Each proxy writer owns one reorder buffer; a forged withdrawal deletes a proxy endpoint by the payload GUID. |

### Discovery and protocol

| Term | Definition |
|---|---|
| **Discovery** | How participants and endpoints learn of each other; two stages, SPDP then SEDP. |
| **SPDP** | Simple Participant Discovery Protocol — a periodic multicast announcement of a participant (builtin writer id `0x100c2`), default interval 30 seconds. |
| **SEDP** | Simple Endpoint Discovery Protocol — an announcement of each writer/reader with its topic, type, and full QoS (builtin writer ids `0x3c2` for publications, `0x4c2` for subscriptions). The QoS an injector offers is visible here before any data sample. |
| **Multicast** | One-to-many delivery; discovery here uses multicast on `lo` (SPDP/metatraffic port 7400, user-data 7401, domain 0). Disabling it on `lo` breaks the whole system. |
| **Sequence number** | A per-writer, monotonically increasing sample counter (`seq = ++wr->seq`). Readers track `(writer GUID, sequence number)` to order and de-duplicate — central to the replay verdict. |
| **HEARTBEAT / ACKNACK / GAP** | RTPS control packets for reliable delivery: a writer announces its available sequence range (HEARTBEAT); a reader acknowledges received and negatively-acknowledges missing sequence numbers (ACKNACK); a writer marks sequence numbers irrelevant (GAP). A reliable reader must have seen a HEARTBEAT before it accepts data. |
| **Reorder buffer (reorder admin)** | Cyclone's per-proxy-writer buffer that delivers each sequence number once, in order, tracking the next expected `next_seq`. A sequence number below `next_seq` is discarded as too-old — the block on faithful replay. |
| **Dispose / unregister (withdrawal)** | The "this endpoint or instance is gone" announcement: a keyed RTPS DATA packet on a builtin discovery writer whose status-info bits mark it as dispose/unregister. On receipt, Cyclone deletes the proxy endpoint keyed on the payload GUID — with no ownership check on the dead path. |
| **statusinfo** | The RTPS field carrying dispose/unregister status bits on a sample. Its byte layout is `[spec]`; that Cyclone sets the bits is `[code]`. |

### Caches and flow control

| Term | Definition |
|---|---|
| **WHC (Write History Cache)** | Cyclone's per-writer store of published samples, used for reliable retransmission and for resending history to late `transient_local` joiners. Bounded here by `WhcHigh=500kB`. |
| **RHC (Reader History Cache)** | The reader-side store; on keep-last-1 it keeps only the newest sample per instance, so a burst collapses to "the latest one." Also where Cyclone's exclusive-ownership arbitration lives. |
| **Throttle / back-pressure** | When unacknowledged bytes exceed `WhcHigh`, Cyclone blocks the *writer's own* `publish()` until the cache drains or the maximum blocking time expires — so a reliable flood self-limits. |

### QoS policies

| Term | Definition |
|---|---|
| **QoS** | Quality-of-Service policies (reliability, durability, history, deadline, liveliness, …) that govern delivery and matching. |
| **RxO (Requested/Offered)** | The asymmetric rule that a reader's requested QoS must be satisfiable by the writer's offered QoS, per policy, or the two do not connect and no data flows (a non-connection, not a late drop). |
| **Durability** | Whether samples are kept for late-joining readers. **VOLATILE** = not kept; **TRANSIENT_LOCAL** = the writer keeps recent samples and resends them. Enum order VOLATILE(0) < TRANSIENT_LOCAL(1) in Cyclone. |
| **transient_local** | The durability the command topics require. A `transient_local` reader will **not connect** to a volatile-only writer — the rule an injector must satisfy. |
| **Reliability** | RELIABLE (retransmit until acknowledged, via HEARTBEAT/ACKNACK) vs BEST_EFFORT (fire-and-forget). RELIABLE readers use the normal reorder mode. |
| **History / keep-last / depth** | Whether the cache keeps the last N samples (keep-last, depth) or all of them (keep-all). Command topics are keep-last-1. |
| **Deadline** | A contract and alarm: the maximum expected time between samples; raises a deadline-missed event on starvation. Not a scheduler, and not triggered by over-publication. |
| **Latency budget** | A hint about acceptable delay. In this build its only teeth are the synchronous-delivery gate, ANDed with transport priority. |
| **Liveliness (+ lease duration)** | Declares a writer not-alive when it stops asserting (in automatic mode, asserted by the participant's discovery presence). Default participant lease 10 seconds. A weak external disable lever. |
| **Lifespan** | Expires samples older than a bound; left at default (effectively infinite) on the command topics. |
| **Ownership / ownership strength** | Arbitration, not latency: under exclusive ownership the highest-strength writer owns an instance and lower-strength writers are dropped. Cyclone implements it in the reader cache, but ROS readers stay SHARED, so it never arms; an exclusive-ownership writer also fails the RxO ownership-kind match. |
| **Transport priority** | A per-writer integer meant to select a higher-priority transport path. Absent from the middleware and ROS layers; in this build it only feeds synchronous-delivery gating (the network-channels/DSCP path is compiled out). |
| **Network channels / DSCP / DiffServ** | A Cyclone XML feature routing writers to dedicated threads and marking the IP DiffServ Code Point by transport priority. Guarded by a build flag that is **compiled out** of standard builds — so no DSCP marking here. |
| **Synchronous delivery** | Delivering a matched proxy writer's samples straight off the receive thread (lower latency) when its transport priority meets a configured threshold. The one live transport-priority lever, inert at the default threshold 0. |

### ROS control surfaces

| Term | Definition |
|---|---|
| **Node / Context** | A Node owns publishers and subscriptions; the Context is the shared, process-wide object that `rclcpp::shutdown()` tears down. |
| **Node options / init options** | Launch-time configuration objects (intra-process comms, parameter overrides, shutdown-on-signal, domain id); read once at startup, never served on the network. |
| **`rclcpp::shutdown()`** | Shuts down the whole **context** — every node on it in that process — from inside the process. No DDS endpoint; not invokable over the network. |
| **Lifecycle node** | A ROS 2 managed node with a configure/activate/deactivate/shutdown state machine exposed as network **services**. Read from source, Autoware does **not** use these: the command-topic owners are all plain `rclcpp::Node` components, and no `LifecycleNode` subclass exists anywhere in Autoware Core or Universe (§3.2). |
| **change_state** | The lifecycle transition service (`~/change_state`), default QoS RELIABLE + VOLATILE, so an external client matches it with no durability barrier. The only network-reachable *clean* disable — but only on a managed node, and no command-topic owner here is managed (§3.2), so it is absent on the command path. |
| **TransitionEvent** | The event a lifecycle node publishes when it transitions — a self-announced signal the SEU can watch. |
| **Parameter services** | Per-node services (set-parameters and the like) matchable on domain 0; a parameter can disable a behaviour without a restart, bounded by what the node declared and validates. |

### Study terms

| Term | Definition |
|---|---|
| **SEU (Safety Enforcement Unit)** | The end-goal runtime monitor this study feeds: a lightweight, event-driven unit that derives temporal/freshness constraints from data dependencies, formalizes them as STL properties, evaluates system traces, and executes a preemptive safe-stop on a critical violation `[LSEU-abstract]`. |
| **STL (Signal Temporal Logic)** | The formalism in which each derived temporal/freshness constraint is written as a property (`G(...)`, `F_[a,b](...)`) evaluated against a trace. |
| **Temporal constraint** | A bound a data dependency imposes, set by actuation frequency and data freshness — the thing an STL property encodes `[LSEU-abstract]`. |
| **Freshness / age** | `age(topic)` = time since the currently-held sample's own source timestamp, measured against `/clock`; the core quantity of the freshness properties. |
| **Trace event** | The observable an event-driven monitor consumes to evaluate a property — here a sample's (arrival timestamp, source timestamp, writer GUID, sequence number), a missed deadline, or a WHC stall. |
| **Safe-stop** | The preemptive halt the SEU actuates when a critical temporal/freshness property is violated. |
| **Fault injection** | Driving an off-nominal (early/late/stale/wrong-value/over-published) trace into a topic so the monitor is exercised and its safe-stop path validated — the study's test instrument, not an attack. |
| **Replay** | Re-presenting *previously-seen* content so a subscriber treats it as fresh — a freshness (P4) fault, since the value's age exceeds the bound though DDS accepts it as a new sample. |
| **Over-publication** | Emitting many (possibly synthetic) samples without capture; a rate (P3) fault, and the abstract's 100× stress case. |

---

## 10. Open questions and unverified items

These load-bearing `[UNVERIFIED]` and `[INFERRED]` items each name what would settle them. The
simulation could not be executed, so anything requiring a live run or a packet capture stays unverified.

| Item | Status | What would settle it |
|---|---|---|
| Whether the container's Cyclone was built with type discovery — decides whether type matching (and a hand-forged-RTPS harness carrier) needs a type *hash* or only a type *name* | `[UNVERIFIED]` | Inspecting the built library, or a wire capture showing type information in the endpoint announcements |
| Whether the Autoware nodes owning the command topics are managed lifecycle nodes — decides whether the network-reachable clean `change_state` lever applies | `[code]` — **resolved: none are managed.** The command-topic owners are all plain `rclcpp::Node` components, and no `LifecycleNode` subclass exists anywhere in Autoware Core or Universe; the clean `change_state` lever does not apply to them (§3.2) | Settled from the Autoware node sources (`vehicle_cmd_gate.hpp:100`; base-class sweep of the checkout) |
| Whether the Autoware *application* de-duplicates a repeated command (the DDS layer does not) | `[code]` — **resolved: it does not.** The anchor-topic callbacks act on each value unconditionally, with no stamp/counter/equality guard, so the app accepts a replayed command as fresh (§5.3) | Settled from the subscriber callbacks (`vehicle_cmd_gate.cpp:110-112`; `mrm_handler_core.cpp:163-165`) |
| End-to-end acceptance of a hand-forged discovery + DATA (+ HEARTBEAT) sequence by this Cyclone build (Carrier B feasibility; the verbatim-replay *drop* is a confirmed code-path finding, not `[UNVERIFIED]`) | `[UNVERIFIED]` | A packet capture or bench test against the running container |
| Whether the container's Cyclone was built with DDS Security — decides which branch of the deletion guard runs (both allow deleting an unauthenticated participant) | `[UNVERIFIED]` | Inspecting the built library |
| Whether a production vehicle build enables network channels / DSCP transport-priority marking (compiled out here) | `[UNVERIFIED]` | The production Cyclone build flags and configuration |
| Writer batching is off (one publish is approximately one wire send) | `[INFERRED]` | No batching element in the deployment configuration |
| Command topics leave deadline and lifespan at default (unset), so flooding neither expires samples nor trips a deadline miss | `[code]` — **confirmed from the reader QoS.** The command subscriptions declare only depth/durability (`rclcpp::QoS(1).transient_local()`; polling default `rclcpp::QoS{1}`) and set no deadline or lifespan, with no `qos_overriding_options` hook to re-introduce one (§5.3) | Settled from the subscription QoS (`vehicle_cmd_gate.cpp:110-111`; `polling_subscriber.hpp:206`) |
| ROS command readers keep the DDS default SHARED ownership (the binding never sets ownership) | `[code]` — **confirmed.** The command subscriptions build QoS from `rclcpp::QoS(1).transient_local()` / `rclcpp::QoS{1}` and never set ownership (the `rclcpp` QoS class has no ownership setter); no C-API or direct-DDS path is used for them (§6.3) | Settled from the subscription QoS (`vehicle_cmd_gate.cpp:110-111`; `polling_subscriber.hpp:206`) |
| A port-7400 drop starves discovery while established unicast flows briefly survive; participant-lease expiry (10 seconds) as an indirect kill when discovery keepalives are blocked | `[INFERRED]` | A packet capture of the port model and lease/renewal cadence |
| Discovery-multicast flooding or malformed-packet destabilization | `[UNVERIFIED]` | Fuzzing the built library, or a packet capture |

<!-- SAFETY-REVISION-COMPLETE -->
