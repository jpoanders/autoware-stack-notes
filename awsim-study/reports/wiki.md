# AWSIM / Autoware / Cyclone DDS Fault-Injection Study

A controlled, academic study of how the communication stack of an autonomous-driving simulation can
be configured, shut down, injected into, replayed against, prioritized, and silently disabled — and
what each of those mechanisms means for a device designed to defend the vehicle network.

Abstract. This study examines the AWSIM Digital-Twin demo, an autonomous-driving simulation built
on the Robot Operating System 2 (ROS 2) and the Autoware self-driving software stack, communicating
over Eclipse Cyclone DDS (an implementation of the Data Distribution Service messaging standard). The
analysis is conducted from the open-source code of that stack rather than from a running system. 
Working layer by layer, from the application's C++ publish call down to the raw packets on the wire, 
it catalogues how a coreelement can be reconfigured, shut down, injected into, replayed against, prioritized, or made to
disappear. The end goal it serves is a Security Enforcement Unit (SEU): a device that will sit on
a real vehicle network and detect or block exactly these faults. Every section therefore closes with
the SEU consequence of what it found, the observable signature to detect, or the lever to enforce,
and those are gathered in one place near the end.

---

## Table of contents

1. [Scope, threat model, and how to read this](#1-scope-threat-model-and-how-to-read-this)
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
8. [Security Enforcement Unit implications, gathered](#8-security-enforcement-unit-implications-gathered)
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

A note on file citations. File paths such as `dds_write.c:566` refer to the source of the named
open-source component at the versions studied. All of these projects are public; the paths let a
reader locate the exact code behind a claim. The prose is written so that it reads cleanly even if
every path citation were removed.

---

## 1. Scope, threat model, and how to read this

What the study asks. For this specific stack, and from its source code: how can each element be
configured or controlled; how can one element be shut down; how can a process from outside publish
messages that legitimate nodes accept; can captured traffic be replayed; can message priority be
manipulated; and how can an element be disabled short of a clean shutdown? Each answer is then
translated into a detection signature or an enforcement lever for the Security Enforcement Unit.

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
| Max message size | `MaxMessageSize=65500B` | The fragmentation limit relevant to malformed-packet attacks |
| Write-history-cache limit | `WhcHigh=500kB` | The back-pressure watermark that throttles flooding |

The worked targets. Two real, vehicle-controlling command topics ground every section, chosen
because both are published with `transient_local` durability (a delivery mode explained in
[§2.4](#24-delivery-matching-rules)) and the vehicle actually obeys them:

| Topic | Message type | Key value that commands the vehicle |
|---|---|---|
| `/system/operation_mode/state` | `autoware_adapi_v1_msgs/msg/OperationModeState` | `mode: 2` = AUTONOMOUS |
| `/control/command/gear_cmd` | `autoware_vehicle_msgs/msg/GearCommand` | `command: 2` = DRIVE |

The enum constant `DRIVE = 2` is defined at `autoware_vehicle_msgs/msg/GearCommand.msg:3` `[code]`, and
`AUTONOMOUS = 2` at `autoware_adapi_v1_msgs/operation_mode/msg/OperationModeState.msg:4` `[code]`.

The attacker model. The attacker is a process outside the simulation that joins Cyclone domain
0 on `lo`. Two carriers for that attacker recur throughout: an ordinary ROS 2 (`rclcpp`) process
configured for Cyclone, and a hand-forged RTPS speaker that runs no ROS 2 at all and emits raw wire
packets.

The realism caveat — it binds every section, and is stated once here. Because the container uses
host networking and AWSIM is native, both sides sit on Cyclone domain 0 bound to `lo`, so any
process on the host that joins domain 0 is discovered and matched with no network isolation to
cross. That makes injection and disabling trivial in this simulation — but that ease is a
simulation artifact. The Security Enforcement Unit is designed for a real vehicle network — a
compromised Electronic Control Unit (ECU) on automotive Ethernet or a Controller Area Network (CAN)
bus — where a hostile element must still reach the discovery group and match a topic's name, type, and
Quality-of-Service settings. Throughout, "easy because it is all on loopback in one domain" is kept
distinct from "the attacker's real capability on the deployment network the simulation stands in for,"
wherever a realism or detectability judgment depends on it. Later sections refer back to this caveat
rather than restating it.

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
   `[code]`. A forged-RTPS attacker must reproduce this CDR by hand.
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
endpoints never connect (`q_qosmatch.c:167-169`) `[code]`. This is the gate an injector's writer
must satisfy by offering `transient_local` durability or stronger, and the dropped-injection trace
in the [injection section](#4-injecting-data-from-outside-the-simulation) follows exactly this failure.

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
- SEDP carries exactly the QoS that the matching function later compares — so the durability an
  injector offers is visible on the wire before a single data sample is sent. This is the Security
  Enforcement Unit's earliest detection surface.

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

GUID as a signature. Any process that joins domain 0 carries a locally generated GUID prefix not
belonging to the two legitimate simulation participants (AWSIM and the Autoware container) — the
basis of the "foreign participant GUID" detection signal used throughout.

---

## 3. Configurable elements and shutting an element down

Question answered. Which elements of the stack can be configured or controlled to change their
behaviour, lifetime, or presence — and how can a single element be shut down cleanly? The direct
answer: configuration splits into settings fixed at launch, settings announced but not changeable, and
settings served live over the network; and there are four distinct shutdown mechanisms, of which
only one is reachable from the network, and even that one only if the node is a managed
"lifecycle" node — which, read from source, none of the command-topic owners here are (§3.2), so
no command node has a network-reachable clean shutdown at all.

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
  not apply to the command-topic owners in this deployment. Read from the node sources, the nodes that
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
  unavailable against them. Reversible? `deactivate` yes (via `activate`); `shutdown` no. SEU
  implication: the clean, network-reachable `change_state` disable does not exist for these nodes in
  either direction — the SEU cannot use it to quarantine a compromised command node, and an attacker
  cannot use it to silence a legitimate one; both are driven to the in-process shutdowns (not
  network-reachable) or the forged protocol withdrawal of
  [§7.1](#71-protocol-level--making-the-middleware-believe-the-element-is-gone).
- Process signals / hard kill. The ROS signal handler funnels a termination signal into the
  whole-context shutdown for every context configured to shut down on signal
  (`signal_handler.cpp:254-284`) `[code]`; a hard kill skips all of it. Reachable from domain 0? No
  — signals need host/operating-system access, not a DDS endpoint. Host networking makes killing the
  process trivial, but that ease is a co-location artifact, not a network capability. Signature: a
  graceful signal produces a clean withdrawal like the context shutdown; a hard kill produces no clean
  withdrawal, and peers only reap the participant when its discovery lease expires.

| Mechanism | Blast radius | Reachable from domain 0? | Clean? | Reversible? | Signature |
|---|---|---|---|---|---|
| `rclcpp::shutdown()` | whole process | No | Yes | No | correlated whole-participant withdrawal |
| Node destruction | one node | No | Yes | Re-create only | partial withdrawal, participant stays |
| Lifecycle `change_state` | one managed node | **No for the command nodes — none are managed (§3.2)** | Yes | `deactivate` yes / `shutdown` no | `TransitionEvent` + foreign-GUID service client |
| Signal / hard kill | whole process | No (host only) | graceful yes / hard no | No | graceful clean / hard silence + lease timeout |

---

## 4. Injecting data from outside the simulation

Question answered. What are the viable ways for a process outside the simulation to publish a
message that a legitimate node *accepts* — meaning its callback actually runs with the attacker's value
— and how do those ways compare on realism and detectability? The direct answer: two carriers. An
ordinary ROS 2 node is trivial and works as long as it offers `transient_local` durability; a
hand-forged RTPS speaker is feasible in principle but much harder, with the difficulty concentrated in
faking discovery. "Accept" is load-bearing: the bytes must clear discovery, topic-name matching,
type matching, and QoS compatibility.

The acceptance chain both carriers must clear, assembled as the attacker's checklist:

### 4.1 Carrier A — an external ROS 2 node

The cheapest injector is an ordinary ROS 2 (Humble) C++ program on the host, configured with the same
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and the same Cyclone configuration file. From DDS's point of
view it is just another legitimate participant, discovered within one SPDP period. It reuses the entire
publish path ([§2.3](#23-the-publish-path-to-the-wire)) — nothing is forged; the injector *is* a real
DDS writer with a genuine GUID, sequence numbers starting from 1, and correct CDR. The one thing the
attacker must get right is the QoS:

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
still succeeds — the sample goes into its own write history cache and nowhere else. The attacker
sees success and the vehicle sees nothing. The only network trace is the SEDP announcement of a writer
whose durability does not satisfy the reader — a signature a content-only monitor would miss entirely,
because no sample ever crosses.

### 4.3 Carrier B: hand-forged RTPS without ROS 2

Carrier A matters for the *simulation*; Carrier B matters for the deployment threat model — a
compromised ECU that may not run ROS 2 at all. It is two forgeries: a discovery forgery (make
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
`[UNVERIFIED]` (would need a live capture). The value of the enumeration is that each item is an
invariant the real simulation never violates — so each is a detection surface.

---

## 5. Replay and over-publication

Question answered. Can an outside injector replay traffic — capture legitimate messages on a
command topic and re-publish them so a subscriber accepts them *as fresh* — and if not, can it at least
over-publish (emit many messages without capturing any)? The direct answer, preserving the shape of
the investigation: replay is examined first. A *faithful* replay that re-sends the original packets
verbatim is blocked by the reader's duplicate/ordering filter. That forces a pivot to
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

This satisfies the study's definition of replay (re-publishing previously-seen traffic) but is not
faithful: the original writer's GUID and sequence numbers are gone, replaced by the injector's. A
monitor that models "who said this" sees a new participant. ROS 2 gives the attacker no control over the
writer GUID or sequence number, so a faithful replay is only conceivable on the direct-RTPS path — which
is where it dies.

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
`(writer GUID, next_seq)` state. To succeed, the attacker must abandon faithfulness in one of two ways —
forge a fresh writer GUID (a new proxy writer, `next_seq = 1`, exactly what the ROS 2 path does for
free) or advance the sequence numbers past the reader's window with a matching HEARTBEAT/GAP. Either
way the delivered samples are new samples carrying old content, which is over-publication.

### 5.3 Over-publication and Cyclone's flow control

Every accepted sample is delivered, but a *flood* meets Cyclone's flow control. On a reliable writer,
each unacknowledged sample stays in the write history cache (WHC) until the reader acknowledges it:

1. Each publish retains a sample via `insert_sample_in_whc` (`q_transmit.c:1286,1299`) `[code]`.
2. Before the next sequence number, `write_sample_eot` tests whether unacknowledged bytes exceed the
   high-water mark (`q_transmit.c:1252`) `[code]` — that mark is the `WhcHigh=500kB` from the
   configuration.
3. Over the mark, it calls `throttle_writer`, which forces out a HEARTBEAT and blocks the attacker's
   own `publish()` until the cache drains or a timeout (`q_transmit.c:1257-1105`) `[code]`.
4. The timeout is the reliability max-blocking-time; on expiry the publish aborts with a timeout code
   (`q_transmit.c:1053,1266-1271`) `[code]`. So a reliable flood self-throttles; past the watermark
   the attacker's own publishes stall and can fail.
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

Asymmetry. The watermark is a cost the attacker pays, not a limit on the victim. Flooding
over-writes the command value at high rate but cannot, by volume alone, make a legitimate writer lose —
Cyclone offers no prioritization or ownership arbitration on these SHARED, ROS-created readers (see the
[prioritization section](#6-qos-message-prioritization)). Over-publication is a rate/timing attack, not
a dominance one. The DDS layer imposes no content de-duplication — and, read now from the node sources,
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
a replayed gear or control command is actuated as fresh on the AWSIM side too. SEU
implication: replay and duplicate-command detection cannot be delegated to the application; the SEU
must itself treat a re-presented command value as potentially hostile, since the vehicle path will obey
it.

---

## 6. QoS message prioritization

Question answered. How can Cyclone DDS Quality-of-Service settings be used to prioritize messages,
and how much of that is reachable through ROS 2 versus only through Cyclone's own configuration? The
direct answer, stated plainly: the two policies that would actually prioritize — transport priority
and ownership — are not exposed by the ROS middleware at all, so prioritization is unreachable from
the ROS QoS API. Cyclone implements both internally, but only its C API (and, partly, its XML) can
reach them, and the one XML path that would shape the wire is compiled out of standard builds.

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
DDS vendor — the ceiling is set at the middleware, not the vendor. Consequence: every legitimate
writer and reader, and any ROS injector or enforcement node, carries transport priority 0 and SHARED
ownership.

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
  side keyed on the remote writer's advertised priority — so an attacker setting a high priority gains
  no precedence over other writers.

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
behaviour holds across both client surfaces. An injector that reached the C API
to set exclusive ownership with high strength would gain nothing, and worse would fail to match the
SHARED reader (an RxO ownership-kind mismatch, `q_qosmatch.c:191`) `[code]` and deliver nothing — a
variant of the dropped-injection trace, on ownership kind rather than durability. Making ownership usable
would require changing the Autoware reader's QoS to exclusive and setting the enforcer's strength via the
C API — a coordinated, out-of-band change to both endpoints.

### 6.4 True prioritization vs. latency shaping

The ROS-reachable policies influence timing but do not set priority between writers: deadline is a
contract and alarm, not a scheduler (the [disabling section](#7-disabling-an-element-without-a-clean-shutdown)
uses its *violation* as a silencing signal); latency budget is a hint whose only teeth are the §6.2
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

---

## 7. Disabling an element without a clean shutdown

Question answered. Short of the clean shutdown covered in the
[shutdown section](#3-configurable-elements-and-shutting-an-element-down), how can a core element be
disabled or silenced — at the protocol layer, the physical/transport (loopback) layer, and the
application layer? The direct answer: at the protocol layer, a forged endpoint-withdrawal packet
makes the middleware delete a live endpoint with no authorization check; at the physical layer, one
command on `lo` takes the whole system down; at the application layer, the clean levers already
described apply. This section draws its application layer from the
[shutdown section](#3-configurable-elements-and-shutting-an-element-down), its discovery/forging
mechanics from the [injection section](#4-injecting-data-from-outside-the-simulation) and the
[background](#2-background-the-communication-stack), and its QoS reasoning from the
[prioritization section](#6-qos-message-prioritization). Its one genuinely new mechanism is the forged
endpoint withdrawal.


The protocol layer needs the attacker to forge a small keyed packet but no control of the link; the
physical layer needs control of `lo` but forges nothing; the application layer needs a request the node
obeys.

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
then deletes the proxy writer using the GUID taken from the attacker's payload
(`q_ddsi_discovery.c:1747-1748`); the writer is looked up purely by GUID and removed, and the receive
path is told to stop feeding readers from it (`ddsi_proxy_endpoint.c:419,430,444`) — all `[code]`. No
source-versus-target check exists on this dead path, unlike the alive path, which derives and checks
the owning participant (`q_ddsi_discovery.c:1502-1506`) `[code]`. Net effect: the publishing node still
calls `publish()` successfully, but its `gear_cmd` no longer reaches the AWSIM reader — silenced without
being shut down.

The participant-level kill and the guard that does not guard here. A participant-level withdrawal
writes a dispose on the participant-discovery builtin writer (`q_ddsi_discovery.c:569-576`); on receipt
the handler deletes the proxy participant and all its endpoints — but only if a
deletion-allowed guard passes (`q_ddsi_discovery.c:645-660`) `[code]`. On this non-secure stack the
guard does not stop the attack: without DDS Security compiled in it is a stub that returns `true`
unconditionally (`ddsi_security_omg.h:1183-1186`); with security compiled in but an unauthenticated
participant (this stack configures no security), it still allows deletion of the unauthenticated
participant, its own code comment flagging the missing GUID-prefix check (`ddsi_security_omg.c:2052-2068`)
`[code]`. Which build compiles is `[UNVERIFIED]`, but the outcome is the same for an unauthenticated
participant. This has a strictly larger blast radius than the endpoint withdrawal.

What the forger must first reproduce. A withdrawal is only deliverable if the attacker's builtin
writer is an established, in-order, reliable source — so the attacker must first be discovered (SPDP,
[§4.3](#43-carrier-b-hand-forged-rtps-without-ros-2)) and clear the reorder/HEARTBEAT gating, which is
trivial for a *fresh* writer (sequence numbers from 1, its own HEARTBEAT vouching for them). It must
also know the target's exact GUID, learned passively from the target's own announcements. The chain is:
sniff discovery → learn the GUID → emit one keyed withdrawal.

Liveliness and deadline are weak external levers. They are *matching* policies, not switches an
outsider can flip: liveliness declares a writer not-alive when *the writer* stops asserting, and a
deadline miss fires when samples fail to arrive — an attacker forces either only by blocking traffic
(the physical layer). The one indirect path is blocking the target's discovery keepalives so the
participant lease (default 10 seconds, `defconfig.c:45`) expires (`[INFERRED]`). Discovery-multicast
flooding and malformed-packet destabilization are mention-level: plausible but resting on parser
robustness and operating-system buffering, bounded by the `MaxMessageSize=65500B` limit and the IP
fragmentation limits, and irreducibly `[UNVERIFIED]`.

### 7.2 Physical level — cutting the simulated link (`lo`)

Beneath every DDS gate is one interface: the loopback `lo`. Anyone with host access can disable
communication under the whole application, forging nothing.

| Method | What it disrupts | Reachable from domain 0? | Reversible? |
|---|---|---|---|
| `ip link set lo multicast off` | All container DDS discovery → every node crashes | No — host/link control | Yes: re-enable + relaunch |
| `iptables -A INPUT -i lo -p udp --dport 7400 -j DROP` | Kills SPDP/metatraffic discovery (port 7400) | No — host control | Yes: delete rule |
| `tc qdisc add dev lo ... netem loss/delay` | Degrades *all* `lo` traffic; cannot target one topic | No — host control | Yes: remove qdisc |
| `ip link set lo down` | Kills all loopback traffic | No — host control | Yes: bring up |

The one-command "multicast off" kill is documented behaviour in this deployment, grounded in the
SPDP-multicast gate at `q_ddsi_discovery.c:314` ([§2.5](#25-discovery)). None of these can silence *one*
element selectively — that selectivity is exactly what the protocol withdrawal buys. On the deployment
bus, the equivalent is cutting an automotive Ethernet segment or CAN bus, which needs physical or
switch-level control — a capability the Security Enforcement Unit's threat model gives the *defender*
far more readily than a compromised ECU, so this ease does not transfer to the attacker.

### 7.3 Application level (new points only)

The clean paths already covered, with only what is new for the "disable" framing: lifecycle
deactivate/shutdown over `~/change_state` would be the only network-reachable *clean* disable, but it
requires a managed node and — read from source ([§3.2](#32-four-distinct-shutdown-mechanisms)) — none
of the command-topic owners are managed (all are plain `rclcpp::Node` components), so this path is
simply absent here; a parameter change that gates a behaviour leaves the
endpoint present in discovery, so it is invisible to a discovery-watching detector and shows only as a
parameter-events entry; and publishing a countermanding command is the injection attack from the
[injection section](#4-injecting-data-from-outside-the-simulation), not a disabling of the element,
noted only to keep the boundary clear.

---

## 8. Security Enforcement Unit implications, gathered

Every mechanism above is dual-use: an enforcement action the Security Enforcement Unit can take
against a compromised element, and an attack against a legitimate one. The asymmetry the SEU relies
on is that it is *authorized and can act at a trusted layer, whereas the attacker must forge at an
untrusted one*. The detection surface is dominated by identity, QoS, and sequencing invariants that
Cyclone's own matching and delivery rules force on any attacker — and those invariants transfer to the
deployment bus even though the loopback co-location's trivial ease does not.

Element shutdown.
- The lifecycle `change_state` service is the only network-reachable clean lever in principle, but it
  does not exist for the command-topic owners here: read from source ([§3.2](#32-four-distinct-shutdown-mechanisms)),
  every one of them is a plain `rclcpp::Node` component, not a managed lifecycle node — and there is no
  `LifecycleNode` subclass anywhere in Autoware Core or Universe. So there is no clean
  network-reachable shutdown of these nodes at all, in either direction: the SEU cannot cleanly
  `deactivate` a compromised command node over the network, and — the mirror benefit — an attacker
  cannot cleanly disable a legitimate one either, and is driven to the forged protocol withdrawal in the
  [disabling section](#7-disabling-an-element-without-a-clean-shutdown). (Where a managed node *does*
  exist elsewhere, the `change_state` signature — a `TransitionEvent` plus a service client with a
  foreign participant GUID — is still the thing to watch; it just does not arise on the command
  path.)
- `rclcpp::shutdown()` and node destruction are in-process calls with no DDS endpoint — the SEU sees
  only their *effect* (endpoints withdrawing), useful as a reference for what a clean withdrawal looks
  like, to distinguish it from a forged withdrawal. Signals and hard kills are host-level, not a domain-0
  capability; the SEU should not model process-kill as a network threat, but can watch for the aftermath
  of a hard kill (abrupt silence plus discovery-lease timeout).

Injection.
- Carrier A is maximally effective and maximally detectable: a new participant GUID belonging to
  neither simulation participant appears in discovery, and a new command-topic writer appears in the
  endpoint announcements; the injector had to offer `transient_local`, so even its QoS fingerprint is
  fixed and predictable. On a bounded deployment the legitimate GUID set is knowable, so an
  un-allowlisted command writer is, by itself, the attack.
- The dropped injection is a quieter signature: a foreign writer whose QoS (VOLATILE) does not satisfy
  the reader announces itself yet delivers nothing — a failed or reconnaissance injection visible
  even though no sample crossed, which a content-only monitor would miss.
- Carrier B is the deployment-realistic threat and the harder detection problem: the SEU's surface is
  the set of invariants a forger must reproduce but a real endpoint never thinks about (GUID
  consistency, an exact `transient_local` offer on a writer that never sent any history, monotonic
  sequence numbers, and the exact CDR encapsulation and alignment).

Replay and over-publication.
- ROS-carried replay is content reuse under a foreign GUID with sequence numbers restarting from 1 —
  the join of "known content" and "un-allowlisted GUID" is the detector.
- Faithful replay betrays itself as a sequence-number anomaly: an already-seen (GUID, sequence
  number) pair, or a jump forward under a real GUID without a consistent HEARTBEAT/GAP — the same anomaly
  Cyclone already drops as too-old.
- Over-publication is a per-(topic, writer) rate anomaly, self-limiting at the `WhcHigh=500kB`
  watermark. Deadline is the *wrong* instrument — it fires on starvation, not excess, and the command
  readers leave deadline and lifespan unset anyway ([§5.3](#53-over-publication-and-cyclones-flow-control)).
  No DDS-layer de-duplication exists, and — now read from the node sources — the application does not
  de-duplicate either: the command callbacks act on each value unconditionally, with no stamp,
  counter, or equality guard. The SEU must therefore assume every repeated or replayed accepted command
  changes vehicle behaviour; duplicate- and replay-rejection cannot be delegated to Autoware.

Prioritization.
- The SEU cannot privilege enforcement traffic by QoS through ROS 2 — on SHARED readers, enforcer and
  injector samples are treated identically (last write into keep-last-1 wins), so an SEU that tries to
  out-prioritize is racing, not overriding. Real DDS-ownership privilege would require the Autoware
  readers to request exclusive ownership and the enforcer to hold higher strength — a build-time
  decision on both endpoints, not a runtime network action.
- A priority/ownership attacker is loud: transport priority and ownership ride the endpoint
  announcements, and every legitimate endpoint carries transport priority 0 and SHARED ownership, so any
  non-zero priority or exclusive ownership on a command topic is anomalous at discovery time. A dominance
  attempt mostly defeats itself: an exclusive-ownership writer fails the RxO ownership-kind match against
  the SHARED reader and delivers nothing.

Disabling at three layers.
- The protocol withdrawal is the sharpest attacker tool and the SEU's clearest signature: watch for a
  dispose/unregister whose *source* participant GUID prefix differs from the *endpoint or participant
  GUID being disposed* (the exact check the code's own comment admits it omits — the SEU can enforce it),
  dispose/re-announce flapping, or a dispose from an already-flagged foreign GUID. The decisive
  mitigation is DDS Security (authentication), which flips the deletion guard to reject
  unauthenticated withdrawals — the strongest recommendation for the deployment build.
- The physical link is the SEU's home turf on the real network: an inline SEU can drop or rate-limit
  a compromised ECU's frames at the switch — authoritative, per-source enforcement the attacker cannot
  match without switch control.
- The application levers are clean but conditional on lifecycle/parameter reachability, each carrying
  its own foreign-GUID signature.

On the deployment network the ordering inverts by actor: the *attacker's* easiest layer is the protocol
withdrawal (forgeable from any bus foothold); the *SEU's* strongest layer is the physical link
(authoritative, inline, per-source). The protocol withdrawal is the method the SEU must detect; the
link is the method it should enforce with.

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
| **SEU (Security Enforcement Unit)** | The end-goal defender this study feeds; sits on the vehicle network to detect or block the catalogued faults. |
| **Injection** | Getting an outside process's message *accepted* by a legitimate reader (clearing discovery plus topic/type/QoS matching), so its callback runs with the attacker's value. |
| **Replay** | Re-sending *previously-seen* traffic so a subscriber accepts it as fresh. |
| **Over-publication** | Emitting many (possibly synthetic) samples without capture; the fallback when faithful replay is blocked. |

---

## 10. Open questions and unverified items

These load-bearing `[UNVERIFIED]` and `[INFERRED]` items each name what would settle them. The
simulation could not be executed, so anything requiring a live run or a packet capture stays unverified.

| Item | Status | What would settle it |
|---|---|---|
| Whether the container's Cyclone was built with type discovery — decides whether type matching (and a forged-RTPS attacker) needs a type *hash* or only a type *name* | `[UNVERIFIED]` | Inspecting the built library, or a wire capture showing type information in the endpoint announcements |
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
