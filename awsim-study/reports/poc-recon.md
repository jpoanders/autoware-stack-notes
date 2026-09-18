# PoC Recon (static half) — the ego SPEED monitor

**Phase 1, step 1 of the SEU attacker-PoC roadmap** (`~/.claude/plans/concurrent-questing-matsumoto.md`).
Static source recon only — no sim, ROS 2, or DDS process was run. Every row is cited `path:line`
against files under `src/`. Evidence tags per the study convention (`[code]` / `[spec]` /
`[INFERRED]` / `[UNVERIFIED]`). A later live check against the running sim is appended as
§"Runtime verification (addendum)"; its findings carry the tag `[runtime]`.

## Headline (the load-bearing unknown, resolved)

**The ego speed topic is consumed VOLATILE, on every consumer found in source.** The roadmap's
decisive question — *does the speed consumer request `transient_local` or `volatile`?* — resolves to
**volatile**. Consequences for the PoC:

- **Module 2 Carrier A does NOT need to offer `transient_local`.** A default ROS 2 writer
  (RELIABLE + VOLATILE + KEEP_LAST) already satisfies the RxO durability gate for these readers
  (`rd.durability(0) > wr.durability(0)` is false → match, `q_qosmatch.c:167`). Offering
  `transient_local` also matches (`0 > 1` false), so it is harmless but unnecessary. This is the
  **opposite** of the wiki's `/system/operation_mode/state` example (§4.1), where the reader is
  `transient_local` and offering it is the load-bearing line. **Do not carry that assumption onto
  the speed topic.**
- This is triangulated three independent ways (converter reader, AEB reader, explicit monitor
  config) **and** cross-checked by the publisher side: the AWSIM velocity publisher itself offers
  **VOLATILE** (below), and the sim demonstrably works — a `transient_local` reader would *not*
  have matched a volatile writer (`q_qosmatch.c:167`), so no real consumer can be requesting
  `transient_local`. `[INFERRED]` cross-check, consistent with the three `[code]` readings.

## Target facts table

| Attribute | Value | Evidence |
|---|---|---|
| **ROS topic string** | `/vehicle/status/velocity_status` | `[code]` `AccelVehicleReportRos2Publisher.cs:43` (default); authoritative in the run scene `AutowareSimulationDemo.unity:71666` (URP scene identical, `AutowareSimulationURPDemo.unity`) |
| **DDS-mangled name** | `rt/vehicle/status/velocity_status` | `[code]` `rt` prefix + `make_fqtopic`, `rmw_node.cpp:2282`; prefix constant `namespace_prefix.hpp:18-20` |
| **DDS type name** | `autoware_vehicle_msgs::msg::dds_::VelocityReport_` | `[code]` `create_type_name`, `serdata.cpp:663-672` (`<ns>::dds_::<Name>_`) |
| **Message type / speed scalar** | `autoware_vehicle_msgs/msg/VelocityReport`; scalar = `longitudinal_velocity` (float32, m/s) | `[code]` `VelocityReport.msg:1-4`; set from Unity local velocity at `AccelVehicleReportRos2Publisher.cs:133` |
| **Publisher class** | `AccelVehicleReportRos2Publisher` (C#, `MonoBehaviour`); creates the pub at line 79, publishes at 30 Hz (`InvokeRepeating`, :96) | `[code]` `AccelVehicleReportRos2Publisher.cs:21,79,96,153` |
| **Publisher QoS** | **RELIABLE + VOLATILE + KEEP_LAST(1)** | `[code]` scene block `AutowareSimulationDemo.unity:71670-71673` (`reliability 1`, `durability 2`, `history 1`, `depth 1`); prefab identical `Lexus RX450h 2015.prefab` (Hdrp) `:2590-2593` |
| **Consumer 1 — velocity converter** (autoware_core, sensing → localization) | subscribes `velocity_status` (remapped to the full topic) with **`rclcpp::QoS{10}` = RELIABLE + VOLATILE + KEEP_LAST(10)** | `[code]` `vehicle_velocity_converter_node.cpp:26-27`; remap `vehicle_velocity_converter.launch.xml:8`; wired to `/vehicle/status/velocity_status` at `autoware_core_sensing.launch.xml:5` |
| **Consumer 2 — AEB** (autoware_universe, control/safety) | `InterProcessPollingSubscriber<VelocityReport>` on `~/input/velocity`, **default `rclcpp::QoS{1}` = RELIABLE + VOLATILE + KEEP_LAST(1)** | `[code]` `node.hpp:336-337` (no QoS arg → default); default `polling_subscriber.hpp:206`; remap `control.launch.xml:252` (`~/input/velocity` → `/vehicle/status/velocity_status`) |
| **Consumer 3 — component_state_monitor** (autoware_universe, system) | explicit config: `best_effort: false` (RELIABLE), **`transient_local: false` (VOLATILE)** | `[code]` `autoware_component_state_monitor/config/topics.yaml:135-140` |
| **Consumer 4 — accel_brake_map_calibrator** (universe, *optional calibration tool*) | `InterProcessPollingSubscriber<VelocityReport>` on `~/input/velocity`, default `rclcpp::QoS{1}` = RELIABLE + VOLATILE + KEEP_LAST(1) | `[code]` `accel_brake_map_calibrator_node.hpp:116-117`; remap `accel_brake_map_calibrator.launch.xml:16` |

`rclcpp::QoS{N}` default durability = VOLATILE (and reliability = RELIABLE): `[code]`
`rclcpp/qos.hpp:117-118` (default-profile doc); `transient_local()` opt-in setter at `qos.hpp:198-200`.

## How the durability decode is pinned (no reliance on the absent ros2cs)

The AWSIM QoS is stored as Unity-serialized **integers** in the scene/prefab; the enum lives in
`ros2cs`, which is not in the checkout (`[UNVERIFIED]` client surface). The decode is nonetheless
checkout-verifiable:

1. AWSIM's command **input** reader is constructed *in code* with the enum by name —
   `DurabilityPolicy.QOS_POLICY_DURABILITY_TRANSIENT_LOCAL` (`AccelVehicleRos2Input.cs:44`) — and
   that same component serializes to `_durabilityPolicy: 1` in the prefab
   (`Lexus RX450h 2015.prefab` Hdrp, input-reader block `:421`). So **`TRANSIENT_LOCAL` ≡ 1**.
2. The velocity **publisher** serializes to `_durabilityPolicy: 2` — a *different, higher* value.
3. The rmw enum (in-checkout, canonical, mirrored by the ros2cs `QOS_POLICY_*` names) orders
   `SYSTEM_DEFAULT=0, TRANSIENT_LOCAL=1, VOLATILE=2, UNKNOWN=3` (`rmw/types.h:408-417`; reliability
   `:376-385`, history `:392-401`). Hence **`2` = VOLATILE**, `reliability 1` = RELIABLE,
   `history 1` = KEEP_LAST.

So the publisher is RELIABLE + VOLATILE + KEEP_LAST(1) — decoded without needing the ros2cs source.

## Notable asymmetry (worth flagging, not a contradiction)

The roadmap's "already confirmed" fact — AWSIM's *command input* readers are RELIABLE +
TRANSIENT_LOCAL + KEEP_LAST(1) (`AccelVehicleRos2Input.cs:43-46`) — still holds and is unrelated to
the speed path. But note the asymmetry it implies: AWSIM's **command inputs are `transient_local`**
while its **status outputs (velocity) are `volatile`**. The speed channel is the volatile one. The
roadmap target table listed reader durability as "transient_local *or* volatile — MUST confirm";
this recon settles it as **volatile**, and additionally establishes that the *publisher* is volatile
too (the target table did not state the publisher's durability).

## Consumers seen but excluded from the runtime table

- `autoware_simple_planning_simulator` — an *alternative* vehicle simulator that **publishes**
  `/vehicle/status/velocity_status` (`simple_planning_simulator.launch.py:56`); it stands in for
  AWSIM, so it is not a consumer of AWSIM's speed. Not relevant when AWSIM is the ego source.
- rviz plugins (`autoware_overlay_rviz_plugin/speed_display.*`, `tier4_vehicle_rviz_plugin`) —
  visualization only, not a trusted control/localization consumer.
- `autoware_autonomous_emergency_braking/test/test.cpp:110` — a unit-test publisher, not runtime.

## Open items (settle only on a running system — Phase 1 steps 2–3)

- **Live speed-writer GUID** (Module 1's required input): 12-byte participant prefix + 4-byte entity
  id of the AWSIM velocity writer — passive SEDP sniff. `[UNVERIFIED]` (runtime-only).
- **The two legitimate participant GUID prefixes** (AWSIM, Autoware) that define "foreign" for the
  SEU oracle — runtime capture.
- **Type discovery: hash vs name-only** — whether SEDP matching needs a type *hash* or only the
  type-name string depends on how this build was compiled (`q_qosmatch.c:216-267`); `[UNVERIFIED]`,
  wiki §2.4/§10. Affects Module 1's discovery forgery and Carrier B.
- **On-wire confirmation of the decoded QoS fingerprint** — *partially settled, see addendum.*
  `ros2 topic info -v` confirms the **AWSIM publisher** as RELIABLE + VOLATILE + KEEP_LAST(1)
  `[runtime]`. Still open: the Autoware-side **reader** endpoints (the stack was not launched) and
  the tshark RTPS/SEDP capture on `lo`. `[UNVERIFIED]` for those parts.
- **DDS Security compiled in?** — flips the participant-kill guard (not the endpoint withdrawal);
  wiki §7.1/§10. `[UNVERIFIED]`, inspect the built lib.

## Runtime verification (addendum, 2026-09-16)

`[runtime]` = observed on the live system, not read from source. Environment: lab machine, Ubuntu
22.04.5, RTX 3060 / driver 535, AWSIM **Demo-Lightweight v2.0.1** (URP) on the host, Autoware
`ghcr.io/autowarefoundation/autoware:core-humble` in Docker `--net host`; both sides
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, identical `cyclonedds.xml` (host copy taken verbatim from the
image's `/home/aw/cyclonedds.xml`), domain 0 on `lo` — i.e. the setup-guide §4/§6 configuration.
**Only AWSIM was running**; the Autoware Core stack (§6c) was not launched.

| Check | Observed | Confirms |
|---|---|---|
| `ros2 topic info -v /vehicle/status/velocity_status` (host) | one endpoint: `Node name: AWSIM`, `PUBLISHER`, **Reliability RELIABLE, History KEEP_LAST (1), Durability VOLATILE** | Publisher QoS row above — the integer decode (`_durabilityPolicy: 2` = VOLATILE, `rmw/types.h:408-417`) is correct. `[code]` → `[runtime]` |
| `ros2 topic info -v /control/command/gear_cmd` (inside the container) | AWSIM endpoint `SUBSCRIPTION`, **Durability TRANSIENT_LOCAL** | The asymmetry section: AWSIM command inputs are `transient_local` (`AccelVehicleRos2Input.cs:43-46`; `_durabilityPolicy: 1` = TRANSIENT_LOCAL). `[runtime]` |
| `ros2 topic hz /clock`, host and container | ~98 Hz on both sides | Host↔container Cyclone discovery over `lo` works with this config (setup-guide §6d) — a precondition for the Phase 1 steps 2–3 captures |

**What this does *not* settle:**

- **Reader-side QoS of the speed consumers (Consumers 1–4)** — they are Autoware nodes and were
  not running, so the VOLATILE headline is still backed by `[code]` for the readers. The publisher
  being VOLATILE at runtime keeps the `[INFERRED]` cross-check in the headline valid: a
  `transient_local` reader would not match it (`q_qosmatch.c:167`).
- **The wire view.** `ros2 topic info` reports QoS as rmw sees it, not RTPS bytes. The tshark
  SEDP capture on `lo` is still open.
- **The writer GUID, participant GUID prefixes, type-hash-vs-name, and DDS Security** — all still
  open (see Open items).

## Runtime verification (addendum 2, 2026-09-17 — SEDP wire capture)

`[runtime]` = observed on the live system. Environment: lab machine `ml-XPS-8960`, same as
addendum 1 — AWSIM **Demo-Lightweight v2.0.1** (URP, pid 280356) running on the host; the Autoware
container was up but **the Autoware Core stack was not launched** (`ros2 node list` → only `/AWSIM`,
`/RobotecGPULidar`). `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, domain 0 on `lo`.

**Method (no tshark / no sudo).** tshark is not installed on this host and installing/capturing
needs root, so the SEDP wire view was taken with **Cyclone DDS's own tracing** instead (the roadmap's
named substitute): a throwaway config identical to `~/cyclonedds.xml` plus
`<Tracing><Category>discovery,plist</Category></Tracing>`, then a short-lived subscriber
(`ros2 topic echo --no-daemon /vehicle/status/velocity_status …`, ~8 s) whose participant provoked
SPDP/SEDP from the live peers. The trace decodes each announcement's raw PIDs, GUIDs, full QoS and
type info — everything the tshark step was for. Command run: `2026-09-17`.

### 1. Live speed-writer GUID (Module 1's required input) — captured

- **GUID = `0110d7fa:ca3be3a4:1fc8049a:00001303`** (12-byte participant prefix
  `01 10 d7 fa ca 3b e3 a4 1f c8 04 9a` + 4-byte entity id `00 00 13 03`). `[runtime]`
- Confirmed two independent ways: `ros2 topic info -v` GID
  `01.10.d7.fa.ca.3b.e3.a4.1f.c8.04.9a.00.00.13.03.…`, **and** the SEDP publication's
  `PID_ENDPOINT_GUID` (0x5a) byte-for-byte identical.
- Entity-id low byte `0x03` = `ENTITYID_KIND_WRITER_WITH_KEY` — a **keyed** user writer, consistent
  with the keyed dispose Module 1 forges. `[spec]`/`[runtime]`
- **Ephemeral.** `ParticipantIndex` is `none` (`~/cyclonedds.xml`), so the prefix is random per
  process start — re-learn it from a fresh capture each run (roadmap Phase 1.3). The *entity id*
  `0x1303` is assigned in creation order and is stable-ish but must not be assumed.

### 2. Legitimate participant GUID prefixes ("foreign" discriminator for the SEU)

From SPDP, the AWSIM process (pid 280356) runs **two** participants:

| Prefix | Owner (from SPDP `property_list`) | Notes |
|---|---|---|
| `0110d7fa:22dce303:5427c7d5` | `AWSIM-Demo-Lightweight.x86_64`, pid 280356 | AWSIM |
| `0110d7fa:ca3be3a4:1fc8049a` | `AWSIM-Demo-Lightweight.x86_64`, pid 280356 | **owns the speed writer `:1303`** |

`[runtime]`. **SEU note:** both AWSIM participants share the leading 32-bit word `0110d7fa`
(Cyclone derives the prefix stem per-process), while the throwaway subscriber used here got a
distinct stem — one lever for a prefix-based allowlist, though the value is ephemeral. The
**Autoware** participant prefix is still uncaptured because that stack was not launched; capture it
the same way during Stage 2 bring-up (it is likewise ephemeral).

### 3. Type discovery: **name-only, no type hash** — resolved

The speed writer's SEDP publication carries exactly:
`PID_TOPIC_NAME`(0x05)=`"rt/vehicle/status/velocity_status"`,
`PID_TYPE_NAME`(0x07)=`"autoware_vehicle_msgs::msg::dds_::VelocityReport_"`,
`PID_ENDPOINT_GUID`(0x5a), reliability/history/protocol/vendor PIDs, two Cyclone vendor PIDs
(0x800c, 0x8003), then `PID_SENTINEL`. **No `PID_TYPE_INFORMATION` (0x1071), no type object, no
type hash.** `[runtime]`

→ Matching is by **type-name string**, not an XTypes type hash. **A forger (Module 1 discovery
forgery; Carrier B) needs only the two strings above** — it does *not* have to reproduce a type
hash. (TypeLookup service endpoints `DCPSTypeLookupRequest`/`Reply` do exist on the bus, but the
publication itself matches without them.) This resolves the wiki §2.4/§10 `[UNVERIFIED]` item for
this build/topic.

### 4. On-wire QoS fingerprint of the speed writer — confirmed

SEDP QOS blob: `durability=0` (**VOLATILE**), `reliability=1:…` (**RELIABLE**), `history=0:1`
(**KEEP_LAST depth 1**), `ownership=0` (SHARED), `partition={}`, `data_representation=1(0)`
(**XCDR1**). `[runtime]`

- Confirms the recon **VOLATILE headline on the wire**, upgrading the publisher QoS from `[code]`/
  `ros2 topic info` to a byte-level `[runtime]` reading. **Module 2 Carrier A** may publish with a
  default VOLATILE writer; offering `transient_local` remains harmless-but-unnecessary.
- `data_representation` = XCDR1 is the encapsulation **Carrier B** must emit (§4.3).

### Still open after this capture

- **Autoware-side reader QoS + participant prefix on the wire** — requires launching the Autoware
  Core stack (`scripts/launch-autoware.sh`). The VOLATILE conclusion for readers stays `[code]`-
  backed (source triangulation) + the publisher `[runtime]` cross-check until then. Fold this into
  Stage 2 bring-up.
- **DDS Security compiled in?** — not settled here (flips the participant-kill guard, not the
  endpoint withdrawal); inspect the built lib. `[UNVERIFIED]`, wiki §7.1/§10.

**Phase 1 exit criteria status:** topic/type/reader-QoS pinned (readers `[code]`, publisher
`[runtime]`); live speed-writer GUID captured `[runtime]`; AWSIM participant prefixes recorded
`[runtime]`; type-hash-vs-name resolved (**name-only**) `[runtime]`. Remaining: Autoware-side
prefix + reader wire QoS (deferred to Stage 2). **Module 1 and Module 2 Carrier A are unblocked.**

*(No PoC/attack code in this document — recon only.)*

<!-- REPORT-COMPLETE -->
