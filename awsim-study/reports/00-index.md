# Index — AWSIM / Autoware Core / Cyclone DDS Fault-Injection Study

This is the entry point to a six-document study. Read this index for orientation, then the
**[shared foundation](foundation.md)**, then the five task reports in dependency order. Every report
is self-contained for a reader arriving by search, but each *reuses the foundation by reference* and
does not re-derive it. This index adds nothing new about the mechanisms; it fixes the objective and
threat model, lists the reports and their dependencies, and holds the **one shared glossary** every
report links back to.

**Source-class tags** (identical across all reports): `[repo]` = a file in this checkout under
`src/`, cited `path:line`; the Eclipse Cyclone DDS core **is in the checkout** at `src/cyclonedds/`,
so its findings are `[repo]`, not vendor guesses. `[spec]` = the OMG DDS / DDSI-RTPS specification (an
external claim). `[UNVERIFIED]` = would require running the sim or a packet capture. `setup-guide §N`
= the authoritative record of the runtime configuration, which stands in for runtime observation
because the simulation cannot be executed.

---

## 1. Objective and threat model

**Objective.** This is a controlled, academic fault-injection study of the AWSIM Digital-Twin demo —
a ROS 2 / Autoware autonomous-driving simulation — conducted entirely from source. It catalogues, at
each layer of the stack (rclcpp → rcl → rmw → rmw_cyclonedds_cpp → Cyclone DDS core → RTPS on the
wire), how a core element can be configured, shut down, injected into, replayed against, prioritized,
or silently disabled. The end goal it feeds is a **Security Enforcement Unit (SEU)**: a device that
will sit on the vehicular network and detect or block exactly these faults. Every report therefore
ends by stating, from the mechanism it found, the SEU consequence — the observable signature to
detect, or the lever to enforce.

**The system under study (topology).** The deployment is concrete and fixed (setup-guide §0):

- **Autoware Core** runs in a Docker container (`ghcr.io/autowarefoundation/autoware:core-humble`)
  launched with `--net host`, so it **shares the host's network namespace**.
- **AWSIM** (the Unity simulator, Lightweight/URP build, Shinjuku map) runs **natively on the host**.
- The two communicate over ROS 2 / DDS across host↔container via the **loopback interface `lo`**, on
  **Cyclone DDS domain 0**, with **multicast on `lo`** load-bearing for discovery (setup-guide §3, §9;
  foundation §5).
- The DDS vendor is **Eclipse Cyclone DDS**, forced on both sides via
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (setup-guide §6a, §9). No Fast DDS assumptions are carried
  over anywhere in this study.
- Two client surfaces sit above the same Cyclone layer: Autoware's rclcpp (C++) nodes and AWSIM's
  Unity nodes (ROS2-for-Unity / `ros2cs`, **not** in the checkout, so claims about AWSIM's own
  publishing are `[UNVERIFIED]`).

**The worked targets.** Two real, vehicle-controlling command topics ground every task, because both
are published with `transient_local` durability and the vehicle obeys them (setup-guide §8):

| Topic | Type | Key value |
|---|---|---|
| `/system/operation_mode/state` | `autoware_adapi_v1_msgs/msg/OperationModeState` | `mode: 2` = AUTONOMOUS |
| `/control/command/gear_cmd` | `autoware_vehicle_msgs/msg/GearCommand` | `command: 2` = DRIVE |

**The external element.** The attacker is a process **outside the simulation** that joins Cyclone
domain 0 on `lo`. Two carriers recur throughout: an ordinary rclcpp node (Cyclone-configured), and a
hand-forged RTPS speaker with no ROS 2 at all.

**The realism caveat (binds every report).** Because the container is `--net host` and AWSIM is
native, both on Cyclone domain 0 bound to `lo`, any host process that joins domain 0 is discovered and
matched with **no network isolation to cross**. That makes injection and disabling trivial in the sim,
but it is a **simulation artifact**. The SEU is designed for a **real vehicular network** — a
compromised ECU on automotive Ethernet or CAN — where a hostile element must still reach the discovery
group and match topic/type/QoS. Throughout, the reports distinguish "easy because it is all on
loopback in one domain" from "the attacker capability on the deployment network the sim stands in
for," wherever a realism or detectability judgment depends on it.

---

## 2. The reports, their summaries, and dependencies

Reading and writing order is by dependency, not list order: **Foundation → Task 1 → Task 2 → Task 3 →
Task 5 → Task 4**. Task 4 is a synthesis and comes last.

```
foundation.md
   └─> task-1  (shutdown & configurable elements — application-layer levers)
        └─> task-2  (injection; builds the external injector + the durability-match rule)
             └─> task-3  (replay/over-publication; reuses the Task 2 injector, adds seq/GUID dedup)
                  └─> task-5  (QoS prioritization; a lever Task 4 cites)
                       └─> task-4  (alternatives to shutdown; SYNTHESIS of 1 + 2 + 5)
```

| Document | One-line summary | Depends on |
|---|---|---|
| **[foundation.md](foundation.md)** | The shared stack: layer map and entry point at each crossing, the publish path to the wire (where CDR, the sequence number, and the WHC happen), the delivery-matching rules (topic-name mangling, type matching, the QoS Requested/Offered rule and the `transient_local` durability gate), discovery (SPDP/SEDP on `lo` multicast, domain 0, GUIDs, ports), and the seed glossary. | setup-guide |
| **[task-1-report.md](task-1-report.md)** | Enumerates the configurable elements (parameters, QoS, NodeOptions/InitOptions, domain id, lifecycle state, Cyclone XML knobs) and keeps four shutdown mechanisms distinct — `rclcpp::shutdown()` (whole context), Node destruction (one node, in-process), lifecycle `change_state` (the one network-reachable clean lever, if managed), and signal/kill (host-level) — each with blast radius, external reachability, reversibility, and signature. | foundation |
| **[task-2-report.md](task-2-report.md)** | Two ways an outside process gets an *accepted* publish onto a command topic: PATH A, an external rclcpp node whose one load-bearing requirement is offering `transient_local`; PATH B, hand-forged RTPS reproducing discovery + CDR by hand. Includes the required dropped-injection trace (a volatile writer that never matches the `transient_local` reader). | foundation, task-1 |
| **[task-3-report.md](task-3-report.md)** | Replay splits by carrier: via the rclcpp injector it is **achievable** but not faithful (fresh GUID, fresh sequence numbers, so the reader accepts it as new); faithful direct-RTPS replay is **blocked** by the reader's reorder admin (`NN_REORDER_TOO_OLD`), forcing a pivot to over-publication, whose flooding self-throttles at the `WhcHigh=500kB` watermark. | foundation, task-2, task-5 |
| **[task-5-report.md](task-5-report.md)** | Prioritization is **not reachable through rclcpp**: neither `TRANSPORT_PRIORITY` nor `OWNERSHIP` is in `rmw_qos_profile_t` or set by the binding. Cyclone implements both (including working exclusive-ownership arbitration), but only via its C API / XML, and the network-channels/DSCP path is compiled out; the one live lever is synchronous-delivery gating. | foundation |
| **[task-4-report.md](task-4-report.md)** | Disabling an element without a clean shutdown, at three layers: **protocol** (forge an SEDP/SPDP dispose — deletion is keyed on the payload GUID with no ownership check, and the participant-deletion guard degenerates on this non-secure stack); **physical** (kill `lo` — `multicast off`, iptables, tc/netem, link down); **application** (lifecycle/parameter, cross-ref Task 1). | foundation, task-1, task-2, task-3, task-5 |

---

## 3. Shared glossary

Every internal term is defined here **once**. Reports link back to this table rather than redefining a
term. The "canonical treatment" column points to where the term is developed in depth (the foundation
seed glossary is `foundation §6`). Ordered roughly bottom-of-stack to top, then protocol, cache, QoS,
rclcpp, and study terms.

### Stack layers and serialization

| Term | Definition (as used in this study) | Canonical treatment |
|---|---|---|
| **rclcpp** | The ROS 2 C++ client library — the API Autoware nodes write against. Publisher/Subscription/Node live here. | foundation §1, §6 |
| **rcl** | The ROS 2 C client library beneath rclcpp; thin, language-agnostic. Validates and forwards to rmw; does **not** serialize. | foundation §6 |
| **rmw** | ROS MiddleWare — the vendor-neutral C interface every DDS binding implements (`rmw_publish`, `rmw_qos_profile_t`). A policy absent from rmw is invisible to every ROS 2 middleware. | foundation §6; task-5 §4 |
| **rmw_cyclonedds_cpp** | The rmw binding for Cyclone DDS. Translates ROS calls/QoS into Cyclone `dds_*` calls; owns topic-name mangling and type-name construction. | foundation §4, §6 |
| **Cyclone DDS** | Eclipse Cyclone DDS, the DDS implementation, in-checkout at `src/cyclonedds/`. **ddsc** = its public C API (`dds_write`); **ddsi** = its RTPS protocol engine. | foundation §6 |
| **DDS** | Data Distribution Service — the OMG pub/sub standard with typed topics and QoS. | foundation §6 |
| **DDSI / RTPS** | DDSI = the DDS Interoperability wire protocol; **RTPS** (Real-Time Publish-Subscribe) is its concrete packet format (DATA, HEARTBEAT, ACKNACK, GAP). The byte layout is `[spec]`. | foundation §6 |
| **CDR** | Common Data Representation — the binary encoding DDS uses on the wire. Produced in Cyclone by `ddsi_serdata_from_sample`. | foundation §3, §6 |
| **XCDR1** | The specific CDR representation rmw_cyclonedds emits for ROS messages (4-byte encapsulation header `CDR_LE` + aligned body, no key handling for ROS types). What a forged-RTPS payload must reproduce. | task-2 §5.2 |

### Entities and identity

| Term | Definition | Canonical treatment |
|---|---|---|
| **DomainParticipant** | A process's membership in a DDS domain; owns writers/readers and the builtin discovery endpoints. | foundation §5, §6 |
| **DataWriter / DataReader** | The endpoints that send / receive samples on a topic. A publish is a write on a DataWriter. | foundation §6 |
| **Topic** | A named, typed channel. The DDS topic name is the *mangled* ROS name, e.g. `rt/control/command/gear_cmd`. | foundation §4.1, §6 |
| **Domain (domain id)** | An isolation scope; only same-domain participants discover each other. Here effectively **0** (`Domain Id="any"`, setup-guide §2). | foundation §5, §6 |
| **GUID** | Globally Unique Identifier of a DDS entity: 12-byte participant prefix + 4-byte entity id = 16 bytes. A joining process gets a fresh, locally generated prefix — the basis of the "foreign GUID" signature. | foundation §5, §6 |
| **Proxy writer / proxy participant** | Cyclone's local shadow of a *remote* writer/participant, keyed by GUID. Each proxy writer owns one reorder admin; a forged dispose deletes a proxy endpoint by payload GUID. | task-3 §3; task-4 §4.2 |

### Discovery and protocol

| Term | Definition | Canonical treatment |
|---|---|---|
| **Discovery** | How participants and endpoints learn of each other; two stages, SPDP then SEDP. | foundation §5, §6 |
| **SPDP** | Simple Participant Discovery Protocol — periodic multicast announcement of a participant (builtin writer id `0x100c2`), default interval 30 s. | foundation §5, §6 |
| **SEDP** | Simple Endpoint Discovery Protocol — announcement of each writer/reader with its topic, type, and full QoS (builtin writer ids `0x3c2` publications / `0x4c2` subscriptions). The QoS an injector offers is visible here before any data sample. | foundation §5, §6 |
| **Multicast** | One-to-many delivery; discovery here uses ASM multicast on `lo` (SPDP/metatraffic port 7400, user-data 7401, domain 0). Disabling it on `lo` breaks the whole system. | foundation §5, §6 |
| **Sequence number** | A per-writer, monotonically increasing sample counter (`seq = ++wr->seq`). Readers track `(writer GUID, sequence number)` to order and de-duplicate — central to the replay verdict. | foundation §3, §6; task-3 §4–§5 |
| **HEARTBEAT / ACKNACK / GAP** | RTPS control submessages of reliable delivery: a writer announces its available sequence range (HEARTBEAT); a reader acknowledges received and negatively-acknowledges missing sequence numbers (ACKNACK); a writer marks sequence numbers as irrelevant (GAP). A reliable reader must have seen a HEARTBEAT before it accepts data. | task-3 §5, §6 |
| **Reorder admin** | Cyclone's per-proxy-writer buffer that delivers each sequence number once, in order, tracking the next expected `next_seq`. A sequence number below `next_seq` is discarded as `NN_REORDER_TOO_OLD` (`-1`) — the block on faithful replay. | task-3 §3, §5 |
| **Dispose / unregister** | The "this endpoint/instance is gone" announcement: a keyed RTPS DATA on a builtin SEDP/SPDP writer whose `statusinfo` bits are DISPOSE\|UNREGISTER. On receipt Cyclone deletes the proxy endpoint keyed on the payload GUID — with no ownership check on the dead path. | task-4 §4.1–§4.3 |
| **statusinfo** | The RTPS parameter carrying DISPOSE/UNREGISTER status bits on a sample; distinguishes a withdrawal from a live announcement. Byte layout `[spec]`; that Cyclone sets the bits is `[repo]`. | task-4 §4.1 |

### Caches and flow control

| Term | Definition | Canonical treatment |
|---|---|---|
| **WHC** | Write History Cache — Cyclone's per-writer store of published samples, used for reliable retransmission and for resending history to late `transient_local` joiners. Bounded here by `WhcHigh=500kB` (setup-guide §4). | foundation §3, §6; task-3 §6 |
| **RHC** | Reader History Cache — the reader-side store; on `KeepLast(1)` it keeps only the newest sample per instance, so a burst collapses to "the latest one." Also where Cyclone's exclusive-ownership arbitration lives. | task-3 §6; task-5 §6 |
| **Throttle / back-pressure** | When unacked bytes exceed `WhcHigh`, Cyclone blocks the *writer's own* `publish()` (`throttle_writer`) until the WHC drains or `max_blocking_time` expires — so a reliable flood self-limits. | task-3 §6 |

### QoS policies

| Term | Definition | Canonical treatment |
|---|---|---|
| **QoS** | Quality-of-Service policies (reliability, durability, history, deadline, liveliness, …) that govern delivery and matching. | foundation §4, §6 |
| **RxO (Requested/Offered)** | The asymmetric rule that a reader's requested QoS must be satisfiable by the writer's offered QoS, per policy, or the two **do not match** and no data flows (it is a non-match, not a late drop). | foundation §4.3, §6 |
| **Durability** | Whether samples are kept for late-joining readers. **VOLATILE** = not kept; **TRANSIENT_LOCAL** = the writer keeps recent samples and resends them. Enum order VOLATILE(0) < TRANSIENT_LOCAL(1) in Cyclone. | foundation §4.3, §6 |
| **transient_local** | The durability the command topics require. A `transient_local` reader will **not match** a volatile-only writer — the rule an injector must satisfy. | foundation §4.3, §6; task-2 §4 |
| **Reliability** | RELIABLE (retransmit until acknowledged, via HEARTBEAT/ACKNACK) vs BEST_EFFORT (fire-and-forget). RELIABLE readers use NORMAL reorder mode. | foundation §6; task-3 §4 |
| **History / KeepLast / depth** | Whether the cache keeps the last N samples (KeepLast, depth) or all (KeepAll). Command topics are KeepLast(1). | foundation §4.3; task-3 §6 |
| **Deadline** | A *contract and alarm*: max expected inter-sample period; raises `DEADLINE_MISSED` on starvation. Not a scheduler and not triggered by over-publication. | foundation §4.3; task-5 §7; task-3 §6 |
| **Latency budget** | A *hint* about acceptable delay. In this build its only teeth are the synchronous-delivery gate, ANDed with transport priority. | task-5 §5.2, §7 |
| **Liveliness (+ lease duration)** | Declares a writer not-alive when it stops asserting (AUTOMATIC = asserted by participant SPDP presence). Default participant `lease_duration` 10 s. A weak external disable lever. | foundation §4.3; task-4 §4.4 |
| **Lifespan** | Expires samples older than a bound (`drop_expired_samples`); left at default (effectively infinite) on the command topics. | task-3 §6 |
| **Ownership / ownership strength** | Arbitration, not latency: under EXCLUSIVE ownership the highest-strength writer owns an instance and lower-strength writers are dropped. Cyclone implements it in the RHC, but ROS readers stay SHARED, so it never arms; an EXCLUSIVE writer also fails the RxO ownership-kind match. | task-5 §6 |
| **Transport priority** | A per-writer integer intended for higher-priority transport paths. Absent from rmw/rclcpp; in this build it only feeds synchronous-delivery gating (the network-channels/DSCP path is compiled out). | task-5 §3, §5 |
| **Network channels / DSCP / DiffServ** | Cyclone's XML feature routing writers to dedicated threads and marking the IP DiffServ Code Point (DSCP) by transport priority. Guarded by `DDS_HAS_NETWORK_CHANNELS`, which is **compiled out** of standard builds — so no DSCP marking here. | task-5 §5.1 |
| **Synchronous delivery** | Delivering a matched proxy writer's samples straight off the receive thread (lower latency) when its transport priority meets a configured threshold. The one live transport-priority lever, inert at the default threshold 0. | task-5 §5.2 |

### rclcpp control surfaces

| Term | Definition | Canonical treatment |
|---|---|---|
| **Node / Context** | A Node is one participant-ish unit owning publishers/subscriptions; the Context is the shared, process-wide object `rclcpp::shutdown()` tears down. | foundation §6; task-1 §4.1 |
| **NodeOptions / InitOptions** | Process-launch configuration objects (intra-process comms, parameter overrides, `shutdown_on_signal`, domain id); read once at startup, never served on the network. | task-1 §3 |
| **`rclcpp::shutdown()`** | Shuts down the whole **context** — every node on it in that process — from *inside* the process. No DDS endpoint; not network-invokable. | task-1 §4.1 |
| **Lifecycle node** | A ROS 2 managed node with a configure/activate/deactivate/shutdown state machine exposed as network **services**. Whether Autoware Core uses these is `[UNVERIFIED]` (node sources absent). | foundation §6; task-1 §4.3 |
| **change_state** | The lifecycle transition service (`~/change_state`), default QoS RELIABLE + VOLATILE, so an external client matches with **no durability barrier**. The only network-reachable *clean* disable — if the node is managed. | task-1 §4.3; task-4 §6 |
| **TransitionEvent** | The event a lifecycle node publishes when it transitions — a self-announced signal the SEU can watch. | task-1 §4.3 |
| **Parameter services** | Per-node services (`set_parameters`, etc.) that are matchable on domain 0; a parameter can disable a behaviour without restart, bounded by what the node declared and validates. | task-1 §3 |

### Study terms

| Term | Definition | Canonical treatment |
|---|---|---|
| **SEU** | Security Enforcement Unit — the end-goal defender this study feeds; sits on the vehicular network to detect or block the catalogued faults. | this index §1; every report's SEU section |
| **Injection** | Getting an outside process's message *accepted* by a legitimate reader (clears discovery + topic/type/QoS matching), so its callback runs with the attacker's value. | task-2 |
| **Replay** | Over-publication of *previously-seen* traffic — re-sending captured messages so a subscriber accepts them as fresh. | task-3 |
| **Over-publication** | Emitting multiple (possibly synthetic) samples without capture; the fallback when faithful replay is blocked. | task-3 §6 |

---

## 4. Pointer to the foundation

The **[shared foundation](foundation.md)** is the single derivation of the stack that all five tasks
reuse by reference. Its sections, and the tasks that lean on each:

| Foundation section | Content | Most used by |
|---|---|---|
| §2 Layer map | The entry-point function at each crossing (`publish → rcl_publish → rmw_publish → dds_write → … → nn_xpack_send`). | all tasks |
| §3 Publish path | Where CDR is produced, where the sequence number is assigned (`++wr->seq`), where the WHC is filled. | task-2, task-3 |
| §4.1 Topic-name mangling | The `rt` prefix: `/control/command/gear_cmd` → `rt/control/command/gear_cmd`. | task-2, task-4 |
| §4.2 Type matching | DDS type name `autoware_vehicle_msgs::msg::dds_::GearCommand_`; name-vs-hash `[UNVERIFIED]`. | task-2 |
| §4.3 QoS RxO rule | The Requested/Offered comparison and the `transient_local` durability gate; the rmw QoS mapping. | task-1, task-2, task-3, task-5 |
| §5 Discovery | SPDP/SEDP on `lo` multicast, domain 0, GUIDs, ports 7400/7401, why `lo` multicast is load-bearing. | task-2, task-3, task-4 |
| §6 Seed glossary | Superseded by the shared glossary in §3 above, which extends it with every task's new terms. | — |

---

## 5. Cross-report consistency notes

**Cross-references verified.** Every inter-report pointer resolves to a real section: Task 1's
references to Task 4's protocol/physical layers; Task 2's to Tasks 3/4/5; Task 3's to Task 2's injector
and Task 5 §6–§7; Task 4's to Task 1 §3/§4, Task 2 §5/§6, Task 3's reorder path, and Task 5 §5/§6; Task
5's to Tasks 2/3/4. No broken cross-reference was found, so none was edited.

**Terminology is consistent** across reports on every load-bearing identifier: the builtin entity ids
(`0x100c2`, `0x3c2`, `0x4c2`), the ports (7400 SPDP/metatraffic multicast, 7401 user-data multicast),
the durability enum order (VOLATILE 0 < TRANSIENT_LOCAL 1), the QoS-match citation
(`q_qosmatch.c:167`), the sequence-number assignment (`q_transmit.c:1286`), the WHC watermark
(`WhcHigh=500kB`), and the reorder discard (`NN_REORDER_TOO_OLD = -1`). No term is used before it is
defined once the glossary above is in hand.

**Nothing is re-derived.** Spot-checks confirm the reuse discipline: Task 2 §4 cites the publish path
and durability rule from the foundation rather than re-tracing them; Task 3 §6 cross-references Task 5
for the KeepLast/DEADLINE/flow-control facts instead of re-deriving them; Task 4 §6 defers the clean
shutdown levers to Task 1 and adds only the new "disable" framing.

**Minor inconsistencies recorded (not fixed, to avoid rewriting the reports):**

- In `foundation.md` §2, the Mermaid diagram labels the `rmw_publish → dds_write` crossing
  `rmw_node.cpp:1817`, while the same section's table and §3 step 4 cite `rmw_node.cpp:1825-1834`. The
  table/prose value is the one the other reports rely on; the diagram label is a stale line number.
- The `rmw_qos_profile_t` struct is cited as `rmw/types.h:471-512` in `foundation.md` §4.3 and as
  `:471-513` / `:468-513` in `task-5-report.md`. These are the same struct; the one-line range
  differences do not affect the finding that `transport_priority` and `ownership` are absent.

Both are trivial citation-range discrepancies within single reports, not broken cross-references, and
neither changes any behavioral claim.

<!-- REPORT-COMPLETE -->
