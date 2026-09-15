# Shared Foundation — AWSIM / Autoware Core / Cyclone DDS Fault-Injection Study

> This is the **shared stack foundation** the five task reports reuse by reference. It is built
> once here; no task re-derives it. It covers the layer map, the publish path to the wire, the
> delivery-matching rules (topic-name mangling, type matching, QoS compatibility including the
> `transient_local` durability rule), discovery (SPDP/SEDP on multicast over `lo`, domain 0,
> GUIDs), and a seed glossary. It contains **none of the five task reports**.
>
> **Source classes are kept distinct throughout.** `[repo]` = a file in this checkout under
> `src/` (cited `path:line`). `[cyclone]` = Eclipse Cyclone DDS source, which **is present in this
> checkout** at `src/cyclonedds/` and is therefore cited as `[repo]` `path:line`, not as a vendor
> claim. `[spec]` = the OMG DDS / DDSI-RTPS specification (an external claim, not a repo finding).
> `[UNVERIFIED]` = would require running the sim or a packet capture. `setup-guide §N` = the
> authoritative runtime-configuration record.

---

## SCOPING GATE (Phase 1) — task ranking, reading order, cross-reference plan

This block exists so a human can review the scope before the task reports are written. It is the
output of Phase 1 and reflects Phase 0 reconnaissance (below).

### DEEP / MEDIUM / MENTION ranking of the five tasks

The rank reflects how much *new, source-traced* depth each report needs beyond this foundation, and
how much novel Cyclone/RTPS territory it must open. It is not the reading order (that is dependency
order, next section).

| Task | Rank | Why this rank |
|---|---|---|
| **Task 2 — Data injection from an outside element** | **DEEP** | Two full paths (external rclcpp node vs. hand-forged RTPS) traced against a real `transient_local` command topic, plus one *dropped* injection trace. It anchors the injector that Tasks 3 and 4 reuse. Highest reuse, highest novelty. |
| **Task 3 — Replay / over-publication** | **DEEP** | The replay verdict hinges on a subtle Cyclone-internal mechanism — per-writer `(GUID, sequence number)` tracking in the reader's reorder/RHC path and the WHC watermark — not on the public API. This is the hardest thing in the study to get right. |
| **Task 1 — Configurable elements & element shutdown** | **DEEP** | Must keep four conflation-prone shutdown mechanisms distinct (`rclcpp::shutdown()` vs. node destruction vs. lifecycle transition vs. process kill), each with blast radius and external reachability, and resolve whether Autoware Core uses lifecycle nodes. Large enumeration + one potentially major externally-reachable finding. Feeds Task 4's application layer. |
| **Task 5 — QoS for message prioritization** | **MEDIUM** | The central finding is crisp and already half-proven here: `TRANSPORT_PRIORITY` and `OWNERSHIP` are **absent** from both `rmw_qos_profile_t` and Cyclone's rmw QoS mapping (see §4.3), so prioritization is not reachable through rclcpp. The report is a bounded enumeration plus the "where would it live" answer (Cyclone XML / C API). Feeds Task 4's protocol layer. |
| **Task 4 — Alternatives to shutdown (three layers)** | **MEDIUM** | A synthesis: protocol layer (SEDP dispose/unregister, liveliness/deadline), physical layer (`lo` multicast-off kill, iptables/tc on the discovery ports from §5), application layer (cross-ref Task 1). Much is cross-reference; the genuinely new tracing is the endpoint-withdrawal path. Some sub-parts (malformed-RTPS destabilization) are irreducibly `[UNVERIFIED]`. |

No task is a pure **MENTION** — all five are required full reports — but Task 4's malformed-RTPS
sub-point and Task 5's `OWNERSHIP` sub-point are MENTION-level within their reports (documented,
not deeply traced, because they rest on vendor/spec rather than a traceable code path here).

### Proposed reading (and writing) order — by dependency

```
Foundation (this file)
   └─> Task 1  (shutdown & configurable elements; establishes the application-layer levers)
        └─> Task 2  (injection; builds the external injector + derives the durability-match rule in use)
             └─> Task 3  (replay/over-publication; reuses the Task 2 injector, adds seq/GUID dedup)
                  └─> Task 5  (QoS prioritization; needed as a lever before Task 4 can cite it)
                       └─> Task 4  (alternatives to shutdown; SYNTHESIS of 1 + 2 + 5)
```

This matches the prompt's suggested order (1 → 2 → 3 → 5 → 4) and is confirmed. Rationale: Task 4 is
explicitly a synthesis — it draws its application layer from Task 1, its discovery/protocol
mechanics from Task 2, and its QoS levers from Task 5 — so it must come last. Task 3 depends on the
injector that Task 2 constructs. Task 5 is pulled ahead of Task 4 (against pure list order) only so
Task 4 can cite the QoS findings rather than re-derive them.

### Cross-reference plan (what each task cites vs. what it opens)

| Task | Reuses from foundation (by reference) | New territory it opens |
|---|---|---|
| **Task 1** | Layer map §2; the `[repo]` locations of `context.cpp`/`utilities.cpp`; QoS-as-config from §4 | `rclcpp::shutdown()` scope; Node destruction; lifecycle service reachability; `signal_handler.cpp`; the Cyclone config knobs as global config |
| **Task 2** | Publish path §3; topic mangling §4.1; type matching §4.2; **durability RxO rule §4.3**; discovery + GUIDs + ports §5 | Minimal injector sketch; forged-RTPS DATA requirements; the dropped-injection trace (volatile writer vs. `transient_local` reader — mechanism in §4.3) |
| **Task 3** | The Task 2 injector; writer `seq` assignment §3 (step 6); WHC watermark §3/§5 | Cyclone reader-side dedup (reorder/RHC), `(writer GUID, seq)` tracking, ACKNACK, flow control under flooding |
| **Task 5** | rmw QoS mapping §4.3; the RxO comparison table §4.3 | `rmw_qos_profile_t` full enumeration; absence of `TRANSPORT_PRIORITY`/`OWNERSHIP`; Cyclone XML/C-API path; `transport_priority` handling in Cyclone |
| **Task 4** | Discovery/dispose §5; ports §5; liveliness/deadline in the RxO table §4.3; Task 1 app layer; Task 5 QoS | SEDP endpoint-withdrawal (dispose/unregister) forging; `lo` link-layer kills mapped to a deployment bus |

---

## Phase 0 — Reconnaissance: what is in the checkout, and what is confirmed

**Vendor / topology / topics confirmed** against the setup guide: the DDS vendor is Eclipse Cyclone
DDS, forced on both sides via `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (setup-guide §6a, §9); AWSIM
runs native on the host and Autoware Core in a `--net host` container, communicating over loopback
`lo` on domain 0 with multicast (setup-guide §0, §3); the command topics
`/system/operation_mode/state` (`autoware_adapi_v1_msgs/msg/OperationModeState`) and
`/control/command/gear_cmd` (`autoware_vehicle_msgs/msg/GearCommand`) are published with
`transient_local` durability (setup-guide §8). Both message definitions are present in this checkout
and carry the exact enum constants the guide uses: `GearCommand` `DRIVE = 2`
(`src/autoware_msgs/autoware_vehicle_msgs/msg/GearCommand.msg:3`) and `OperationModeState`
`AUTONOMOUS = 2` (`src/autoware_adapi_msgs/autoware_adapi_v1_msgs/operation_mode/msg/OperationModeState.msg:4`).

**What is in the checkout** (so most wire-level claims are `[repo]`, not `[UNVERIFIED]`):

| Layer | In checkout? | Path |
|---|---|---|
| rclcpp (C++ client library) | yes | `src/rclcpp/` |
| rcl (C client library) | yes | `src/rcl/` |
| rmw (middleware abstraction) | yes | `src/rmw/` |
| rmw_cyclonedds_cpp (Cyclone binding) | yes | `src/rmw_cyclonedds/` |
| **Cyclone DDS core (ddsc + ddsi)** | **yes** | `src/cyclonedds/src/core/` |
| rmw_dds_common | yes | `src/rmw_dds_common/` |
| Message packages (autoware, rcl_interfaces) | yes | `src/autoware_msgs/`, `src/autoware_adapi_msgs/`, `src/rcl_interfaces/` |
| AWSIM / ROS2-for-Unity (`ros2cs`) | **no** | not in checkout — claims about AWSIM's client surface are `[UNVERIFIED]` |
| DDSI-RTPS wire format (the OMG standard itself) | n/a | `[spec]` — the *behaviour* is in `src/cyclonedds`, but the normative wire contract is spec |

**Consequence for evidence:** because Cyclone's core is present, findings about serialization,
sequence numbering, the write history cache, QoS matching, and discovery are `[repo]` findings with
`path:line`, not vendor guesses. Only three things stay tagged: AWSIM's own publishing behaviour
(no source here), the on-the-wire byte layout as an interoperability *contract* (`[spec]`), and
anything settled only by running the sim (`[UNVERIFIED]`).

**Realism caveat (applies study-wide).** Everything below describes a stack where container and
simulator share one host network namespace and one Cyclone domain on `lo`. That co-location makes
discovery and matching automatic for any host process — but it is a **simulation artifact**. The SEU
this study feeds defends a *real vehicular network* (a compromised ECU on automotive Ethernet/CAN).
Where a "how easy is this" or "how detectable is this" judgment depends on the loopback co-location,
the task reports say so explicitly rather than transferring the ease to the deployment threat model.

---

## §1. Terms you need before reading (mini-orientation)

Full definitions are in the **glossary (§6)**; this paragraph is the minimum to read §2–§5 linearly.
A ROS 2 program talks to the network through four stacked libraries: **rclcpp** (the C++ API you
write against), **rcl** (a thin C core beneath it), **rmw** (a vendor-neutral interface), and a
vendor **rmw binding** — here **rmw_cyclonedds_cpp** — that calls the actual DDS implementation,
**Cyclone DDS**. Cyclone's own internals split into **ddsc** (its public C API, e.g. `dds_write`)
and **ddsi** (the protocol engine that speaks **RTPS**, the DDS wire protocol). A **DataWriter**
sends samples on a **Topic**; a **DataReader** receives them; they only exchange data if discovery
matched them and their **QoS** is compatible. Each entity has a 16-byte **GUID** identifying it on
the wire.

---

## §2. The layer map — boundaries and the entry point at each crossing

**Orientation.** A single `publisher->publish(msg)` in an Autoware node descends through five library
boundaries before a byte reaches `lo`. Naming collides across these layers (there is a `publish` at
three of them), so the value of this map is the *exact function* at each crossing, read from the
body, not inferred from the name.

```mermaid
flowchart TD
  A["rclcpp::Publisher<T>::publish(msg)\nsrc/rclcpp/.../publisher.hpp:257"] -->|"do_inter_process_publish"| B
  B["rclcpp Publisher::do_inter_process_publish\npublisher.hpp:453 → calls rcl_publish"] -->|"rcl_publish"| C
  C["rcl_publish\nsrc/rcl/rcl/src/rcl/publisher.c:236 → calls rmw_publish"] -->|"rmw_publish"| D
  D["rmw_publish (Cyclone binding)\nsrc/rmw_cyclonedds/.../rmw_node.cpp:1817 → calls dds_write"] -->|"dds_write"| E
  E["dds_write (Cyclone ddsc)\nsrc/cyclonedds/.../dds_write.c:45"] --> F
  F["ddsi write path: serialize + assign seq + WHC\ndds_write.c → q_transmit.c:1207/1286"] -->|"nn_xpack_send"| G
  G["RTPS DATA submessage on lo\n(domain 0, multicast/unicast) — [spec] wire contract"]
```
*What to notice:* every crossing is a real function whose body was read (cited below), and the
vendor-specific part begins precisely at `rmw_publish → dds_write`. Above that line the code is
vendor-neutral; below it, it is Cyclone.

| Boundary crossed | Entry-point function | Cited at |
|---|---|---|
| rclcpp public API → rclcpp internal | `Publisher::publish` → `do_inter_process_publish` | `src/rclcpp/rclcpp/include/rclcpp/publisher.hpp:257,453` `[repo]` |
| rclcpp → rcl | `do_inter_process_publish` → `rcl_publish` | `publisher.hpp:456` `[repo]` |
| rcl → rmw | `rcl_publish` → `rmw_publish` | `src/rcl/rcl/src/rcl/publisher.c:249` `[repo]` |
| rmw → vendor binding → Cyclone ddsc | `rmw_publish` → `dds_write` | `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp:1834` `[repo]` |
| ddsc → ddsi (protocol engine) | `dds_write` → `dds_write_impl` → … → `write_sample_gc` | `src/cyclonedds/src/core/ddsc/src/dds_write.c:55,599`; `q_transmit.c:1392` `[repo]` |
| ddsi → wire | `write_sample_gc` → `write_sample_eot` → `nn_xpack_send` | `src/cyclonedds/src/core/ddsc/src/dds_write.c:259` `[repo]`; RTPS framing `[spec]` |

---

## §3. The publish path to the wire (DEEP — traced procedure)

**Orientation.** This section follows one message — say a `GearCommand{command: 2}` on
`/control/command/gear_cmd` — from the rclcpp call all the way to an RTPS DATA submessage leaving
`lo`. The point every task reuses: **where the message is serialized to CDR, where it gets a
sequence number, and where it enters the write history cache (WHC)**, because those three facts
decide injection (Task 2), replay (Task 3), and flow control under flooding (Task 3/5).

**Mental model.** rclcpp/rcl/rmw are pass-through plumbing: they validate arguments and forward the
still-C-struct message down. No serialization happens until Cyclone. Cyclone serializes the message
to **CDR** (the DDS binary encoding), stamps it with the **next per-writer sequence number**, stores
it in the **WHC** (so reliable readers can be retransmitted to, and late `transient_local` joiners
can be resent history), and hands it to the packing layer that emits the RTPS DATA submessage.

**The traced steps** (each cited; ≥6 steps):

1. **rclcpp entry.** `Publisher<T>::publish(const ROSMessageType & msg)` calls
   `this->do_inter_process_publish(*msg)` for the inter-process case
   (`src/rclcpp/rclcpp/include/rclcpp/publisher.hpp:257`) `[repo]`. Intra-process delivery is a
   separate branch and is not the wire path.
2. **rclcpp → rcl.** `do_inter_process_publish` calls `rcl_publish(publisher_handle_.get(), &msg,
   nullptr)` and throws on any non-`RCL_RET_OK` status, except it silently returns if the failure is
   only because the context was already shut down
   (`src/rclcpp/rclcpp/include/rclcpp/publisher.hpp:456,462-465`) `[repo]`. That shutdown-tolerance
   is relevant to Task 1.
3. **rcl → rmw.** `rcl_publish` validates the publisher, emits a tracepoint, then forwards to
   `rmw_publish(publisher->impl->rmw_handle, ros_message, allocation)`; a non-`RMW_RET_OK` return is
   turned into `RCL_RET_ERROR` (`src/rcl/rcl/src/rcl/publisher.c:236,248-252`) `[repo]`. Note: rcl
   does **not** serialize — it passes the raw C message pointer through.
4. **rmw → Cyclone ddsc.** The Cyclone binding's `rmw_publish` checks the implementation identifier
   matches `eclipse_cyclonedds_identifier`, recovers the `CddsPublisher`, and calls
   `dds_write(pub->enth, ros_message)`, returning OK iff `dds_write(...) >= 0`
   (`src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp:1825-1834`) `[repo]`. The identifier
   check is why an RMW-vendor mismatch fails (setup-guide §9): a Fast DDS handle would not carry
   `eclipse_cyclonedds_identifier`.
5. **ddsc dispatch.** `dds_write` looks up the writer and calls `dds_write_impl(wr, data, dds_time(),
   0)` (`src/cyclonedds/src/core/ddsc/src/dds_write.c:45,55`) `[repo]`. `dds_write_impl` runs the
   topic filter, then (no shared-memory in this config) calls `dds_write_impl_plain`
   (`dds_write.c:589,599`) `[repo]`.
6. **Serialization to CDR.** `dds_write_impl_plain` converts the C message to a serialized sample via
   `ddsi_serdata_from_sample(ddsi_wr->type, ... , data)`
   (`src/cyclonedds/src/core/ddsc/src/dds_write.c:566`) `[repo]`. This is the **first and only**
   point the message becomes CDR bytes; the DDS type used is the sertype built by the Cyclone binding
   (§4.2). It then calls `dds_writecdr_impl_common`
   (`dds_write.c:571`) `[repo]`.
7. **Sequence number + WHC.** `dds_writecdr_impl_common` → `deliver_data_any` → `deliver_data_network`
   → `write_sample_gc` (`dds_write.c:321,272,254`) → `write_sample_eot`, where the writer's
   sequence number is advanced with `seq = ++wr->seq;` and the sample is placed in the write history
   cache via `insert_sample_in_whc(wr, seq, plist, serdata, tk)`
   (`src/cyclonedds/src/core/ddsi/src/q_transmit.c:1286,1299`) `[repo]`. **Sequence numbers are
   per-writer and monotonic** — the fact Task 3's replay analysis turns on.
8. **Onto the wire.** After `write_sample_gc` succeeds, `deliver_data_network` flushes the packed
   message unless the writer batches: `if (flush && xp != NULL) nn_xpack_send(xp, false)`
   (`src/cyclonedds/src/core/ddsc/src/dds_write.c:258-259`) `[repo]`. `deliver_data_any` then also
   delivers to local matched readers in-process via `deliver_locally`
   (`dds_write.c:286`) `[repo]`. The bytes that leave here are an RTPS DATA submessage; the exact
   submessage/field layout is the `[spec]` wire contract, realized by Cyclone's `q_xmsg`/`nn_xpack`.

**Gotchas.**
- **No serialization above Cyclone.** Anyone reasoning about "what rmw sends" must remember the CDR
  bytes exist only from step 6 onward; Task 2's forged-RTPS path must reproduce that CDR itself.
- **`transient_local` uses the WHC as its history store.** The same WHC that serves reliable
  retransmission also holds the samples resent to late-joining `transient_local` readers; the
  binding wires this via `dds_qset_durability_service` (§4.3). This is why a late injector can still
  match and why the WHC `WhcHigh=500kB` watermark (setup-guide §4) is the back-pressure knob Task 3
  cites.
- **Batching.** `flush` is `!wr->whc_batch` (`dds_write.c:571`) `[repo]`; with batching off (the
  default here, `[INFERRED: no WriterBatching set in the setup-guide XML]`), each `publish` flushes
  immediately, so one publish ≈ one wire send.

---

## §4. Delivery-matching rules — what makes a reader accept a writer

A writer and reader exchange data only if **three independent gates** all pass: the **topic name**
matches (§4.1), the **type** matches (§4.2), and the **QoS is compatible** under the
Requested-offered rule (§4.3). Discovery (§5) is what lets the two sides learn each other's name,
type, and QoS in the first place. All three gates are enforced by Cyclone's `qos_match_mask_p`,
which checks topic name and type name in the *same* function as the QoS policies
(`src/cyclonedds/src/core/ddsi/src/q_qosmatch.c:160,267`) `[repo]`.

### §4.1 Topic-name mangling — `/control/command/gear_cmd` → `rt/control/command/gear_cmd`

**Motivation.** The naive assumption is that the DDS topic name equals the ROS topic name. It does
not: rmw_cyclonedds prepends a namespace prefix, so an injector that creates a DDS topic literally
named `/control/command/gear_cmd` will **not** match the Autoware reader.

The binding builds the fully-qualified DDS topic name with `make_fqtopic(ROS_TOPIC_PREFIX,
topic_name, "", qos_policies)` (`src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp:2282`)
`[repo]`. `make_fqtopic` returns `prefix + topic_name + suffix` unless
`avoid_ros_namespace_conventions` is set, in which case the prefix is dropped
(`rmw_node.cpp:1969-1977`) `[repo]`. The prefix constants are `ROS_TOPIC_PREFIX = "rt"` (topics),
`"rq"`/`"rr"` (service request/reply) (`rmw_cyclonedds_cpp/src/namespace_prefix.hpp:18-20`) `[repo]`.

So for the command topic, the DDS topic name on the wire is **`rt/control/command/gear_cmd`** (prefix
`rt` concatenated with the leading-slash ROS name). An injector must create its topic under exactly
this mangled name (or set `avoid_ros_namespace_conventions` and supply the mangled name itself). The
name equality is enforced byte-for-byte at `strcmp(rd_qos->topic_name, wr_qos->topic_name) != 0`
(`src/cyclonedds/src/core/ddsi/src/q_qosmatch.c:160`) `[repo]`.

### §4.2 Type matching — the DDS type name and the type hash

**Motivation.** Two endpoints on the same topic must agree on the message type. rmw_cyclonedds
encodes the ROS type into a DDS type name and (when type discovery is enabled) a type identifier the
reader can compare.

The DDS type name is built by `create_type_name`: it takes the message namespace, replaces the C
separator `__` with `::`, and emits `<namespace>::dds_::<MessageName>_`
(`src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/serdata.cpp:663-672`) `[repo]`. For the worked example
the wire type name is **`autoware_vehicle_msgs::msg::dds_::GearCommand_`** (and
`autoware_adapi_v1_msgs::msg::dds_::OperationModeState_` for the operation-mode topic). This name is
attached to the Cyclone `sertype` created in `create_sertype`
(`serdata.cpp:688-696`) `[repo]`.

Type agreement is then enforced in `qos_match_mask_p`. With `DDS_HAS_TYPE_DISCOVERY` compiled in,
Cyclone compares type *ids* (a hash-based identifier) and only falls back to comparing the type
*name* string when a type id is absent on either side; if force-validation is off and ids exist, it
runs assignability checks
(`src/cyclonedds/src/core/ddsi/src/q_qosmatch.c:216-265`) `[repo]`. Without type discovery it is a
plain type-name `strcmp` (`q_qosmatch.c:267`) `[repo]`. **Whether this build defines
`DDS_HAS_TYPE_DISCOVERY`** determines whether an injector needs a matching type *hash* or only a
matching type *name* — `[UNVERIFIED: depends on the container's Cyclone build flags; would be settled
by inspecting the built library or a capture]`. Task 2 resolves what the forged-RTPS path must
reproduce here.

### §4.3 QoS compatibility — the Requested/Offered rule and the `transient_local` gate (DEEP)

**Motivation.** This is the gate that silently drops the "obvious" injector. The setup guide proves
the command readers request `transient_local` durability (`ros2 topic pub ... --qos-durability
transient_local`, setup-guide §8). A newcomer's first injector uses the rclcpp default (volatile)
writer QoS and then wonders why the vehicle never obeys the command. The reason is a single
comparison in Cyclone.

**Mental model — Requested ≥ Offered, per policy (RxO).** DDS QoS compatibility is asymmetric: for
each "request-offer" policy, the **reader's requested** value must be *satisfiable by* the
**writer's offered** value, or the pair does not match and **no data flows at all** (it is not a
downgrade — it is a non-match). Cyclone implements exactly this in `qos_match_mask_p`. The relevant
comparisons, read from the body:

| Policy | Cyclone check (reader `rd` vs writer `wr`) | Fails (no match) when | Cited |
|---|---|---|---|
| Reliability | `rd.reliability.kind > wr.reliability.kind` | reader RELIABLE(1) > writer BEST_EFFORT(0) | `q_qosmatch.c:163` `[repo]` |
| **Durability** | `rd.durability.kind > wr.durability.kind` | **reader TRANSIENT_LOCAL(1) > writer VOLATILE(0)** | `q_qosmatch.c:167` `[repo]` |
| Deadline | `rd.deadline.deadline < wr.deadline.deadline` | reader wants a tighter (smaller) period than writer offers | `q_qosmatch.c:183` `[repo]` |
| Latency budget | `rd.latency_budget.duration < wr.latency_budget.duration` | reader budget tighter than writer's | `q_qosmatch.c:187` `[repo]` |
| Ownership | `rd.ownership.kind != wr.ownership.kind` | kinds differ | `q_qosmatch.c:191` `[repo]` |
| Liveliness | `rd.liveliness.kind > wr.liveliness.kind` **or** `rd.lease_duration < wr.lease_duration` | reader stricter than writer | `q_qosmatch.c:195,199` `[repo]` |

**The durability enum ordering is what makes the rule bite.** In Cyclone,
`DDS_DURABILITY_VOLATILE` is declared first (value 0), then `DDS_DURABILITY_TRANSIENT_LOCAL` (1),
`DDS_DURABILITY_TRANSIENT` (2), `DDS_DURABILITY_PERSISTENT` (3)
(`src/cyclonedds/src/core/ddsc/include/dds/ddsc/dds_public_qosdefs.h:77-80`) `[repo]`. So a
`transient_local` reader has `durability.kind == 1` and a volatile writer has `durability.kind ==
0`; the check `rd(1) > wr(0)` is true, the function sets `*reason =
DDS_DURABILITY_QOS_POLICY_ID` and returns `false` (`q_qosmatch.c:167-169`) `[repo]`. **The reader
never accepts the writer; the sample is not dropped after arrival — the two endpoints simply never
match.** This is the dropped-injection trace Task 2 must follow, and the rule Task 2's injector must
satisfy: **the injector's writer must OFFER durability ≥ the reader's request**, i.e. it must offer
`transient_local` (or stronger) to reach a `transient_local` reader.

**How rclcpp/rmw map onto these Cyclone values.** The rmw QoS profile carries exactly these fields
and no others: `history`, `depth`, `reliability`, `durability`, `deadline`, `lifespan`,
`liveliness`, `liveliness_lease_duration`, and `avoid_ros_namespace_conventions`
(`src/rmw/rmw/include/rmw/types.h:471-512`) `[repo]`. The rmw durability enum orders
`TRANSIENT_LOCAL` *before* `VOLATILE` (`rmw/types.h:411,414`) `[repo]` — the reverse of Cyclone's —
so the binding maps by *case*, not by numeric value: `create_readwrite_qos` translates
`RMW_QOS_POLICY_DURABILITY_TRANSIENT_LOCAL` to `dds_qset_durability(qos,
DDS_DURABILITY_TRANSIENT_LOCAL)` and additionally sets a durability *service* QoS so the WHC retains
history for late joiners (`src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp:2057-2068`)
`[repo]`. It maps reliability, history/depth, lifespan, deadline, and liveliness likewise
(`rmw_node.cpp:2017-2100`) `[repo]`.

**Two consequences the tasks reuse.** First, **there is no `transport_priority` and no `ownership`
setter** anywhere in `create_readwrite_qos` (`rmw_node.cpp:2010-2104`) `[repo]` and no such field in
`rmw_qos_profile_t` (`rmw/types.h:471-512`) `[repo]` — this is the seed of Task 5's central finding
that prioritization is unreachable through rclcpp. Second, the binding disables writer autodispose
(`dds_qset_writer_data_lifecycle(qos, false)`, `rmw_node.cpp:2016`) `[repo]`, which Task 1/Task 4
cite when reasoning about what a writer's disappearance does (or does not) signal.

**Gotcha.** The comparison uses `mask &= rd_qos->present & wr_qos->present`
(`q_qosmatch.c:158`) `[repo]`: a policy is only compared if *both* sides declared it present. This is
why defaults matter — an injector that leaves durability unset offers volatile-by-construction
through the binding, not "unspecified", because `create_readwrite_qos` always calls a
`dds_qset_durability` (`rmw_node.cpp:2052-2074`) `[repo]`.

---

## §5. Discovery — SPDP/SEDP on multicast over `lo`, domain 0, GUIDs (DEEP)

**Orientation.** Before any of §4's gates can be checked, the two sides must *find* each other. DDS
does this with a two-stage discovery protocol carried as ordinary RTPS messages over `lo`:
**SPDP** announces participants; **SEDP** announces each participant's endpoints (writers/readers)
with their topic, type, and QoS. The setup guide's failure mode — "Failed to find a free participant
index for domain 0" when `lo` lacks multicast (setup-guide §3, §9) — is direct evidence that
multicast-based discovery on `lo` is load-bearing for the whole system.

**Mental model.** Each process hosts a **DomainParticipant** with a random 12-byte **GUID prefix**;
every writer/reader under it has a **GUID** = that prefix + a 4-byte **entity id** (the GUID struct
is literally `{ guid_prefix (12B), entityid (4B) }`,
`src/cyclonedds/src/core/ddsi/include/dds/ddsi/ddsi_guid.h:21-31`) `[repo]`. Discovery uses
**well-known builtin entity ids** so peers know which endpoint carries which discovery data:
`NN_ENTITYID_SPDP_BUILTIN_PARTICIPANT_WRITER = 0x100c2`,
`NN_ENTITYID_SEDP_BUILTIN_PUBLICATIONS_WRITER = 0x3c2`,
`NN_ENTITYID_SEDP_BUILTIN_SUBSCRIPTIONS_WRITER = 0x4c2`
(`src/cyclonedds/src/core/ddsi/include/dds/ddsi/q_rtps.h:41,43,45`) `[repo]`. These values are the
RTPS-spec well-known ids `[spec]`, realized here in Cyclone.

**SPDP — participant announcement.** Cyclone announces the local participant by writing a parameter
list on the builtin SPDP writer: `spdp_write` fetches
`ddsi_get_builtin_writer(pp, NN_ENTITYID_SPDP_BUILTIN_PARTICIPANT_WRITER)` and calls
`write_and_fini_plist(wr, &ps, true)` (`src/cyclonedds/src/core/ddsi/src/q_ddsi_discovery.c:527,540,547`)
`[repo]`. The announcement carries the participant's metatraffic and default locators and its QoS,
built into the plist just above (`q_ddsi_discovery.c:445-505`) `[repo]`. SPDP is periodic; the
default resend interval is 30 s (`spdp_interval = 30000000000` ns,
`src/cyclonedds/src/core/ddsi/defconfig.c:36`) `[repo]`. **A late-joining participant is therefore
discovered within one SPDP period**, which Task 2 cites for the "late-joining participant on domain
0" signature.

**SEDP — endpoint announcement.** Once two participants know each other, each publishes its
writers/readers (topic name, type name/id, and full QoS) over the SEDP publications/subscriptions
builtin writers, using the `SEDP_KIND_{READER,WRITER,TOPIC}` classification
(`q_ddsi_discovery.c:58-62`) `[repo]`. The QoS carried in SEDP is exactly what `qos_match_mask_p`
(§4.3) later compares — so **the durability an injector offers is visible on the wire in its SEDP
announcement before a single data sample is sent.** That is the SEU's earliest detection surface and
Task 2/Task 4 both rely on it.

**Domain 0 and the ports.** The effective domain is 0 (setup-guide §2: `Domain Id="any"` →
effective 0). Cyclone computes RTPS ports from `port = dg*domain_id + base + pg*participant_index +
offset`, with defaults `base = 7400`, `dg = 250`, `pg = 2`, `d1 = 10`, `d2 = 1`, `d3 = 11`
(`src/cyclonedds/src/core/ddsi/defconfig.c:37-42`) `[repo]`, `d0 = 0` (unset). Multicast ports do
**not** depend on participant index (`get_port_int` uses offset `d0` for metatraffic-multicast and
`d2` for data-multicast and skips the per-participant term for them,
`src/cyclonedds/src/core/ddsi/src/ddsi_portmapping.c:29-56,60-61`) `[repo]`. So for **domain 0**:

| Traffic | Offset | Port (domain 0) |
|---|---|---|
| SPDP / metatraffic multicast (discovery) | d0 = 0 | **7400** |
| User-data multicast | d2 = 1 | **7401** |
| Unicast (metatraffic / user) | d1 / d3, per participant index | **ephemeral** — chosen by transport |

The unicast ports are ephemeral because the setup guide sets `ParticipantIndex=none` (setup-guide
§2, §4), and Cyclone treats "none" as "let the transport choose the unicast port"
(`ddsi_portmapping.c:39-52`) `[repo]`. **This is exactly why the guide needs an identical
`cyclonedds.xml` on host and container** (setup-guide §4): the fixed multicast discovery port (7400)
is what both sides rendezvous on; a mismatch in participant-index policy would put them on different
unicast ports and break discovery even on the same interface. These ports are Task 4's targets for a
port-level iptables/tc kill on `lo`.

**Why `lo` multicast is load-bearing.** With `NetworkInterface name="lo"` and
`AllowMulticast=default` (setup-guide §4), SPDP relies on ASM multicast on `lo`; the SPDP-multicast
path is guarded by `gv->config.allowMulticast & DDSI_AMC_SPDP`
(`src/cyclonedds/src/core/ddsi/src/q_ddsi_discovery.c:314`) `[repo]`. If `lo` is not
multicast-capable, Cyclone disables multicast and cannot complete participant discovery, producing
the guide's "Failed to find a free participant index for domain 0" crash (setup-guide §3, §9). Task
4 cites `ip link set lo multicast off` as a one-command link-layer kill on this basis.

**GUID as a signature.** The participant GUID prefix is generated locally per process; any process
that joins domain 0 — including an injector — carries a GUID prefix **not belonging to the two
legitimate sim participants** (AWSIM and the Autoware container). `[INFERRED: the prefix is
process-local and random/host-derived, so a third participant is distinguishable by prefix; the
exact generation routine is in Cyclone init and not quoted here]`. Establishing the exact prefix
derivation is deferred to Task 2, where the "foreign participant GUID" signature is developed.

**Realism caveat.** On this loopback setup, any host process that joins domain 0 is discovered and
matched with no network boundary to cross (setup-guide §0; the-new-investigation-layer point 3). On
the deployment network the SEU defends, a compromised ECU would still have to reach the discovery
multicast group on the vehicle bus — the *discovery mechanics* transfer, but the *trivial ease* does
not. Task 2 and Task 4 carry this distinction wherever a detectability judgment depends on it.

---

## §6. Seed glossary (shared across all reports)

Terms are defined here once; task reports link back rather than redefining. Ordered roughly
bottom-of-stack to top, then protocol terms.

| Term | Definition (as used in this study) |
|---|---|
| **rclcpp** | The ROS 2 C++ client library — the API Autoware nodes write against (`src/rclcpp/`). Publisher/Subscription/Node live here. |
| **rcl** | The ROS 2 C client library beneath rclcpp; thin, language-agnostic core (`src/rcl/`). Validates and forwards to rmw; does not serialize. |
| **rmw** | ROS MiddleWare interface — the vendor-neutral C API (`src/rmw/`) every DDS binding implements (`rmw_publish`, `rmw_qos_profile_t`). |
| **rmw_cyclonedds_cpp** | The rmw binding for Cyclone DDS (`src/rmw_cyclonedds/`). Translates ROS calls/QoS into Cyclone `dds_*` calls; owns topic-name mangling and type-name construction. |
| **Cyclone DDS** | Eclipse Cyclone DDS, the DDS implementation (`src/cyclonedds/`). **ddsc** = its public C API (`dds_write`); **ddsi** = its RTPS protocol engine. |
| **DDS** | Data Distribution Service — the OMG pub/sub standard with typed topics and QoS. |
| **DDSI / RTPS** | DDSI = the DDS Interoperability wire protocol; **RTPS** (Real-Time Publish-Subscribe) is its concrete packet format (DATA, HEARTBEAT, ACKNACK, etc.). `[spec]` for the byte layout. |
| **CDR** | Common Data Representation — the binary encoding DDS uses for message payloads on the wire. Produced in Cyclone by `ddsi_serdata_from_sample` (§3 step 6). |
| **DomainParticipant** | A process's membership in a DDS domain; owns writers/readers and the builtin discovery endpoints. |
| **DataWriter / DataReader** | The endpoints that send / receive samples on a topic. A publish is a write on a DataWriter. |
| **Topic** | A named, typed channel. The DDS topic name is the *mangled* ROS name (§4.1), e.g. `rt/control/command/gear_cmd`. |
| **Domain (domain id)** | An isolation scope for DDS traffic; only same-domain participants discover each other. Here effectively **0** (setup-guide §2). |
| **QoS** | Quality-of-Service policies (reliability, durability, history, deadline, liveliness, …) that govern delivery and matching. |
| **Durability** | The QoS deciding whether samples are kept for late-joining readers. **VOLATILE** = not kept; **TRANSIENT_LOCAL** = the writer keeps recent samples and resends them to late joiners. Enum order VOLATILE(0) < TRANSIENT_LOCAL(1) in Cyclone (§4.3). |
| **transient_local** | The durability the command topics require (setup-guide §8). A transient_local reader will **not match** a volatile-only writer (§4.3). |
| **RxO (Requested/Offered)** | The rule that a reader's requested QoS must be satisfiable by the writer's offered QoS, per policy, or the two do not match (§4.3). |
| **Reliability** | RELIABLE (retransmit until acknowledged, via HEARTBEAT/ACKNACK) vs BEST_EFFORT (fire-and-forget). |
| **Sequence number** | A per-writer, monotonically increasing sample counter (`++wr->seq`, §3 step 7). Readers track `(writer GUID, sequence number)` to order and de-duplicate — central to Task 3. |
| **WHC** | Write History Cache — Cyclone's per-writer store of published samples, used for reliable retransmission and for resending history to late transient_local joiners. Bounded by `WhcHigh=500kB` here (setup-guide §4). |
| **GUID** | Globally Unique Identifier of a DDS entity: 12-byte participant prefix + 4-byte entity id = 16 bytes (`ddsi_guid.h:21-31`). |
| **Discovery** | The process by which participants and endpoints learn of each other; two stages, SPDP then SEDP. |
| **SPDP** | Simple Participant Discovery Protocol — periodic multicast announcement of a participant (builtin writer `0x100c2`), default interval 30 s (§5). |
| **SEDP** | Simple Endpoint Discovery Protocol — announcement of each writer/reader with its topic, type, and QoS (builtin writers `0x3c2`/`0x4c2`) (§5). |
| **Multicast** | One-to-many delivery; discovery here uses ASM multicast on `lo` (port 7400, domain 0). Disabling it on `lo` breaks the system (setup-guide §3). |
| **Lifecycle node** | A ROS 2 managed node with an explicit state machine (configure/activate/deactivate/shutdown) exposed as network services. Whether Autoware Core uses these is a Task 1 question. |
| **NodeOptions / InitOptions / Context** | rclcpp/rcl configuration objects for a node, an init, and the shared process-wide context that `rclcpp::shutdown()` tears down (Task 1). |
| **SEU** | Security Enforcement Unit — the end-goal defender this study feeds; sits on the vehicular network to detect/block the catalogued faults. |

---

## §7. Appendix — files opened, tags, confidence

**Files opened for this foundation** (all `[repo]`):
- `src/rclcpp/rclcpp/include/rclcpp/publisher.hpp`
- `src/rcl/rcl/src/rcl/publisher.c`
- `src/rmw/rmw/include/rmw/types.h`
- `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp`
- `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/namespace_prefix.hpp`
- `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/serdata.cpp`
- `src/cyclonedds/src/core/ddsc/src/dds_write.c`
- `src/cyclonedds/src/core/ddsc/include/dds/ddsc/dds_public_qosdefs.h`
- `src/cyclonedds/src/core/ddsi/src/q_qosmatch.c`
- `src/cyclonedds/src/core/ddsi/src/q_transmit.c`
- `src/cyclonedds/src/core/ddsi/src/q_ddsi_discovery.c`
- `src/cyclonedds/src/core/ddsi/src/ddsi_portmapping.c`
- `src/cyclonedds/src/core/ddsi/defconfig.c`
- `src/cyclonedds/src/core/ddsi/include/dds/ddsi/ddsi_guid.h`
- `src/cyclonedds/src/core/ddsi/include/dds/ddsi/q_rtps.h`
- `src/autoware_msgs/autoware_vehicle_msgs/msg/GearCommand.msg`
- `src/autoware_adapi_msgs/autoware_adapi_v1_msgs/operation_mode/msg/OperationModeState.msg`

**Open `[INFERRED]` / `[UNVERIFIED]` items carried forward:**
- `[UNVERIFIED]` Whether the container's Cyclone build defines `DDS_HAS_TYPE_DISCOVERY` — decides
  whether type matching needs a type *hash* or only a type *name* (§4.2). Settled by inspecting the
  built library or a wire capture.
- `[INFERRED]` Writer batching is off (one publish ≈ one wire send), based on no `WriterBatching`
  element in the setup-guide XML (§3 gotcha).
- `[INFERRED]` A third participant is distinguishable by GUID prefix; exact prefix-generation routine
  not yet quoted (§5) — developed in Task 2.
- `[UNVERIFIED]` Anything requiring the running sim or a packet capture (actual port bindings, actual
  SEDP contents on the wire, timing).

**Per-section confidence:**

| Section | Confidence | Reason |
|---|---|---|
| §2 Layer map | HIGH | Every crossing read from the function body in-checkout. |
| §3 Publish path | HIGH | Full chain `publish → dds_write → write_sample_eot → nn_xpack_send` cited in-checkout; only the RTPS byte layout is `[spec]`. |
| §4.1 Topic mangling | HIGH | Prefix constant and `make_fqtopic` read directly. |
| §4.2 Type matching | MEDIUM | Type-name construction is HIGH; the name-vs-hash question depends on an `[UNVERIFIED]` build flag. |
| §4.3 QoS / durability rule | HIGH | The comparison and enum ordering are both in-checkout Cyclone source. |
| §5 Discovery | MEDIUM-HIGH | Builtin ids, ports, SPDP/SEDP writers, interval all in-checkout; the *contents on the wire* and GUID-prefix derivation are `[UNVERIFIED]`/deferred. |

<!-- REPORT-COMPLETE -->
