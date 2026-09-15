# PoC Recon (static half) — the ego SPEED monitor

**Phase 1, step 1 of the SEU attacker-PoC roadmap** (`~/.claude/plans/concurrent-questing-matsumoto.md`).
Static source recon only — no sim, ROS 2, or DDS process was run. Every row is cited `path:line`
against files under `src/`. Evidence tags per the study convention (`[code]` / `[spec]` /
`[INFERRED]` / `[UNVERIFIED]`).

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
- **On-wire confirmation of the decoded QoS fingerprint** — `ros2 topic info -v
  /vehicle/status/velocity_status` + a tshark RTPS/SEDP capture on `lo` should show every endpoint
  as RELIABLE + VOLATILE, corroborating the static decode above. `[UNVERIFIED]` (runtime-only).
- **DDS Security compiled in?** — flips the participant-kill guard (not the endpoint withdrawal);
  wiki §7.1/§10. `[UNVERIFIED]`, inspect the built lib.

*(No PoC/attack code in this document — recon only.)*

<!-- REPORT-COMPLETE -->
