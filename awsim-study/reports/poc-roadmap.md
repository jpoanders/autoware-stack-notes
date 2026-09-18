# Roadmap: SEU attacker PoC — kill + spoof the ego speed monitor

> In-repo copy of the working plan (originally `~/.claude/plans/concurrent-questing-matsumoto.md`,
> which lives outside the repo and does not travel with a clone). This copy is the shareable
> canonical version. `reports/poc-recon.md` is Phase 1, step 1 of this roadmap.

## Context

The Cyclone DDS / AWSIM fault-injection analysis is complete (`reports/wiki.md`). The next step
is to turn two of its documented mechanisms into a **working, simulation-only proof-of-concept**
so the Security Enforcement Unit (SEU) has a concrete attacker to detect and defend against. This
is authorized defensive research; the PoC doubles as the SEU's **test oracle** (each module must
emit the exact wire signature §8 says the SEU should catch).

**Target** = the *real speed monitor*: the node/topic carrying the ego vehicle's measured speed
that a downstream consumer trusts. The wiki's running examples are `/control/command/gear_cmd`
and `/system/operation_mode/state`; this PoC adapts the same mechanisms to the **speed** topic.

**Two modules:**
1. **Kill** — the *withdraw* strategy (wiki §7.1): silence the real monitor without shutting it
   down, by forging one keyed RTPS DATA on a builtin discovery writer carrying the target
   writer's 16-byte GUID with `statusinfo = DISPOSE|UNREGISTER`, so Cyclone deletes the proxy
   writer by GUID with **no ownership check** (`q_ddsi_discovery.c:1745-1748`,
   `ddsi_proxy_endpoint.c:419,430,444`).
2. **Publish** — injection (wiki §4): publish spoofed speed values onto that same topic so the
   consumer reads the attacker's value in place of the silenced monitor's. **Carrier A** (a ROS 2
   node) first; **Carrier B** (hand-forged RTPS, §4.3) as a stretch.

**Decisions taken (this session):**
- **Build/validate staging:** *Harness first, then sim.* Stage 1 = a minimal 2-node Cyclone
  harness (fast, deterministic, proves both modules + the SEU oracle) built here/portably.
  Stage 2 = port to live **AWSIM + Autoware on the Lab's PC** (the user runs the sim there).
- **Module 2 carrier:** *Carrier A first, Carrier B as a stretch.* Module 1 is hand-forged RTPS
  regardless — there is no ROS 2 API to dispose another node's writer.

> **Session note (blocker):** a safety classifier is blocking `Bash` and subagent dispatch for
> the rest of *this* session (it reacts to earlier conversation content, not to the commands).
> Read-only file reads still work. That is why the exact speed-topic file:line below is marked
> **[CONFIRM IN RECON]** rather than cited — it needs a `grep`/`ros2` step that must run in a
> fresh session or outside auto mode. It does not affect executing this roadmap later.

---

## Target identification (best-effort static; confirm in Recon, Phase 1)

| Attribute | Value | Evidence |
|---|---|---|
| Topic | `/vehicle/status/velocity_status` | **[CONFIRM IN RECON]** — standard Autoware/AWSIM ego-speed topic; not yet grep-confirmed this session |
| Message type | `autoware_vehicle_msgs/msg/VelocityReport` | **[confirmed]** `VelocityReport.msg` — but confirm this is the type on the ego-speed topic in recon |
| Fields (exact) | `std_msgs/Header header`, `float32 longitudinal_velocity`, `float32 lateral_velocity`, `float32 heading_rate` | **[confirmed]** `autoware_vehicle_msgs/msg/VelocityReport.msg:1-4` |
| Scalar speed field | `longitudinal_velocity` (float32, m/s) | **[confirmed]** `VelocityReport.msg:2` |
| DDS-mangled name | `rt/vehicle/status/velocity_status` | `[code]` mangling rule `rmw_node.cpp:2282` |
| DDS type name | `autoware_vehicle_msgs::msg::dds_::VelocityReport_` | `[code]` `serdata.cpp:663-672` |
| Publisher ("real monitor") | AWSIM vehicle-status output component (sibling of `AccelVehicleRos2Input`) | **[CONFIRM]** — search `src/awsim/.../Entity/Vehicle/` for the `VelocityReport` publisher |
| **Reader QoS (the load-bearing unknown)** | **transient_local *or* volatile — MUST confirm** | see below |

**The single most important recon fact — the consumer's durability.** Autoware shows *two*
reader patterns and the speed consumer could be either:
- explicit `rclcpp::QoS(1).transient_local()` (e.g. VehicleCmdGate op-mode reader,
  `vehicle_cmd_gate.cpp:110-111`) → injector **must** offer `transient_local` or it is dropped at
  the RxO durability gate (`q_qosmatch.c:167`, the wiki's §4.2 dropped-injection trace); **or**
- the polling-subscriber default `rclcpp::QoS{1}` (`polling_subscriber.hpp:206`) which is
  RELIABLE + **VOLATILE** → a default volatile writer already matches; `transient_local` is not
  required (but still matches).

AWSIM's *own* readers use RELIABLE + TRANSIENT_LOCAL + KEEP_LAST(1) via its `QosSettings` wrapper
(**confirmed this session**, `AccelVehicleRos2Input.cs:43-46`). If the trusting consumer of speed
is on the AWSIM side, assume `transient_local`; if on the Autoware side, confirm which pattern.
**Module 2 Carrier A's QoS is set by this fact.**

---

## Phase 0 — Environment & prerequisites

### Stage 1 harness (portable; build + first validation here or on any Linux box)
- **Cyclone DDS** `releases/0.10.x` (match the study checkout) + **ROS 2 Humble**,
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, **domain 0 on `lo`**, the study's `cyclonedds.xml`
  (`src/awsim/cyclonedds_config.xml`) present and identical for every process.
- **Two harness nodes** (stand in for the real system, reproducing only the load-bearing QoS):
  - `real_speed_monitor` — publishes `VelocityReport` on the speed topic, RELIABLE +
    TRANSIENT_LOCAL + KEEP_LAST(1), at a realistic rate (e.g. 30–50 Hz). Logs each `publish()`
    return so we can prove it keeps succeeding after the kill.
  - `trusting_consumer` — subscribes with the **recon-confirmed** reader QoS; logs every received
    sample's value **and source writer GUID** (the oracle for "whose value am I obeying").
- **Tooling:**
  - Capture/inspect: **Wireshark/tshark** with the RTPS dissector on `lo` (reads SPDP/SEDP —
    topic, type, full QoS, and all GUIDs — and DATA/HEARTBEAT/GAP). Cyclone's own tracing
    (`Tracing` in the XML / `CYCLONEDDS_URI`) as a cross-check.
  - ROS introspection: `ros2 topic info -v`, `ros2 node info`.
  - Forge: evaluate **Scapy** (its `contrib/rtps` layer) first for hand-built SPDP/SEDP/DATA/
    HEARTBEAT; fall back to a raw-socket Python/C forger. **Hybrid option (recommended for
    Module 1):** run a *real* minimal Cyclone participant to carry SPDP presence + a builtin SEDP
    writer + its HEARTBEATs, and only hand-craft the one dispose DATA — this sidesteps most of the
    "fake a byte-accurate handshake" difficulty the wiki flags as the hard part (§4.3 verdict).

### Stage 2 live sim (Lab's PC)
- Full **AWSIM** (Unity, Shinjuku) native + **Autoware** container (`--net host`), domain 0 on
  `lo`, per `prompts/autoware-core-awsim-setup-guide.md`. **Snapshot/VM before running**; ensure a
  one-command restart of both halves. Same capture/forge tooling on the host.

---

## Phase 1 — Recon (confirm the target, on the running system)

Goal: replace every **[CONFIRM]** above with a cited fact, and learn the **live writer GUID**.

1. **Static confirm (fresh session / outside auto mode):** grep `src/awsim` and `src/autoware`
   for the `VelocityReport` publisher and every subscriber; read the `.msg`; record topic string,
   type, publisher class + QoS, each consumer + QoS with file:line. Resolve the durability
   question above.
2. **Live confirm:** with the sim (or harness) running, `ros2 topic info -v <speed topic>` to list
   endpoints and QoS; cross-check against a **tshark RTPS capture** on `lo` — the SEDP publication
   announcement shows the mangled topic, type name, full QoS, and the **writer's 16-byte GUID**.
3. **Learn the live GUID passively** (this is Module 1's input): from the SEDP capture, record the
   real speed writer's GUID (12-byte participant prefix + 4-byte entity id). Note it is
   re-announced periodically, so it can be re-learned if the participant restarts.

**Exit criteria:** topic/type/reader-QoS pinned with citations; live speed-writer GUID captured;
the two legitimate participant GUID prefixes (AWSIM, Autoware) recorded (they define "foreign").

---

## Phase 2 — Module 1: Kill (forged withdrawal)

### Build
Chain (wiki §7.1): **sniff discovery → learn target writer GUID → emit one keyed withdrawal.**
- Establish attacker presence: forged/real participant discovered via **SPDP** (builtin writer id
  `0x100c2`), with a **builtin SEDP publications writer** (entity id `0x3c2`) that is an
  established, in-order, **reliable** source — trivial for a *fresh* writer (sequence numbers from
  1, its own HEARTBEAT vouching for them). *(Hybrid: let a real Cyclone participant provide this.)*
- Craft the withdrawal: a keyed RTPS **DATA on the builtin SEDP writer** whose serialized key is
  the **target writer's 16-byte GUID** and whose `statusinfo` bits =
  `NN_STATUSINFO_DISPOSE | NN_STATUSINFO_UNREGISTER` (`q_ddsi_discovery.c:520-522`). RTPS
  status-info byte layout is `[spec]`; that Cyclone acts on it is `[code]`.
- Emit exactly one, in-order under the attacker's builtin-writer sequence, preceded by a
  consistent HEARTBEAT so the reliable reader accepts it (`q_receive.c:2363-2368`).

On receipt the victim's Cyclone: dispatches on status-info to the dead-endpoint path
(`:1851,1867-1880`), confirms only that the entity id is a *writer* id — **not** an authorization
check (`:1745,1480-1493`), deletes the proxy writer by the **payload GUID** (`:1747-1748`), and
tells the receive path to stop feeding readers from it (`ddsi_proxy_endpoint.c:419,430,444`). No
source-vs-target check on the dead path (the alive path has one at `:1502-1506`).

### Validate — **exact success signal**
> The real publisher **still calls `publish()` successfully**, but its samples **stop reaching the
> consumer.**

- `real_speed_monitor` log shows `publish()` continuing to return success (no error on its side).
- tshark shows the real writer's DATA **still on the wire** (it doesn't know it was disposed).
- `trusting_consumer` **stops receiving samples from the real writer's GUID** — callback goes
  quiet for that source; optionally confirm via Cyclone trace that the proxy writer for that GUID
  was deleted.
- Negative control: without the forged withdrawal, the consumer keeps receiving. With it, it stops.

---

## Phase 3 — Module 2: Publish spoofed speed

### Carrier A (build first)
- A ROS 2 (Humble) node, Cyclone RMW + same XML, publishing `VelocityReport` on the speed topic
  with **QoS matched to the recon-confirmed reader** (offer `transient_local` if the reader
  requests it — the §4.1 load-bearing line — else default is fine). Set `longitudinal_velocity`
  to the spoof value (e.g. a dangerous 0.0 m/s "stopped" or an inflated speed).
- It is a genuine DDS writer: real foreign GUID, sequence numbers from 1, correct XCDR1 CDR.

### Carrier B (stretch — deployment realism, shares forging code with Module 1)
- Hand-forged RTPS DATA: discovery forgery (SPDP + SEDP `0x3c2` announcing mangled topic, type
  name, QoS **offering `transient_local`**) + data forgery. XCDR1 payload per §4.3: 4-byte encap
  header (`00 01` CDR_LE, `00 00` opts) + aligned body matching `VelocityReport`'s fields, valid
  writer GUID + fresh sequence number.
- **CDR body is more involved than the wiki's `gear_cmd` example** (which was stamp + a `uint8`).
  `VelocityReport` = `std_msgs/Header` { `builtin_interfaces/Time` (int32 `sec`, uint32 `nanosec`)
  + **variable-length `frame_id` string** (4-byte length prefix + bytes + NUL + 4-byte alignment
  padding) } followed by **3× float32** (`longitudinal_velocity`, `lateral_velocity`,
  `heading_rate`). The string makes the layout non-constant-length and adds alignment traps — build
  the CDR with a real serializer/`ddsi_serdata_from_sample` reference dump, not by hand-counting.

### Validate — **spoofed value observed at the reader**
- `trusting_consumer` logs show the **attacker's** `longitudinal_velocity` value being received,
  attributed to the **foreign** writer GUID.
- Cross-check the SEDP capture: a new speed-topic writer with a foreign GUID and the expected QoS
  fingerprint appears before the first spoof sample.

---

## Phase 4 — Combined sequence (kill, then publish) & end-to-end effect

1. Recon: learn the real speed writer's live GUID (Phase 1).
2. **Kill** (Module 1): forge the withdrawal → real writer's proxy writer deleted; consumer stops
   hearing the real value.
3. **Publish** (Module 2): spoof `VelocityReport` on the same topic → consumer now consumes the
   attacker's value in place of the silenced monitor's.
4. **Confirm end-to-end on the consumer:** the trusting consumer's acted-on speed is the attacker's
   value; the real monitor is still calling `publish()` (proven from its log + on-wire DATA) yet
   contributes nothing. On the live sim (Stage 2), confirm the downstream behavior driven by speed
   (e.g. control/localization reaction) follows the spoofed value.
- **Watch for flapping:** if the real participant re-announces its endpoint via SEDP (reconnection/
  lease renewal), its proxy writer can be re-created and the kill undone — re-emit the withdrawal or
  note the dispose/re-announce flap (itself an SEU signature).

---

## Empirical unknowns to confirm (wiki [UNVERIFIED]/[INFERRED] that gate this PoC)

| Item | Wiki tag | Why it matters here | How to settle |
|---|---|---|---|
| Speed reader durability (transient_local vs volatile) | recon | Sets Module 2 Carrier A QoS; wrong choice = dropped injection (§4.2) | `ros2 topic info -v` + SEDP capture |
| Live speed writer GUID | runtime | Module 1's required input | passive SEDP sniff |
| Type discovery enabled? (type **hash** vs name-only) | `[UNVERIFIED]` §2.4/§10 | Discovery forgery (Module 1 builtin writer & Carrier B) may need a type hash | inspect built lib / wire capture of endpoint announcements |
| End-to-end acceptance of hand-forged discovery+DATA(+HEARTBEAT) | `[UNVERIFIED]` §4.3/§10 | Carrier B feasibility; also the withdrawal's HEARTBEAT gating | bench test / capture against the running build |
| Exact reorder/HEARTBEAT gating a fresh builtin writer must clear | `[INFERRED]` §7.1 | "Trivial for a fresh writer" is an inference — verify the withdrawal is actually accepted | harness test: does the proxy writer get deleted? |
| DDS Security compiled in? | `[UNVERIFIED]` §7.1/§10 | Flips the *participant*-kill guard (endpoint withdrawal has no guard either way); the SEU's decisive mitigation | inspect built lib; test an authenticated build |

---

## Risks, rollback, and safety

- **Blast radius / wrong GUID:** a mistyped target GUID could dispose the wrong proxy writer or
  no-op. Mitigate: derive the GUID only from a fresh capture; test in Stage 1 harness first.
- **Persistence of the kill:** the dispose is one-shot; the victim may re-discover the real writer
  later. Rollback = stop the attacker and **restart the affected publisher/node** (or the sim) to
  force clean re-announcement.
- **Environment integrity (Lab PC):** run authorized, isolated, on a **VM/snapshot**; keep a
  one-command restart of AWSIM + Autoware; never run against anything but the lab bench.
- **Flow-control self-DoS (Carrier A/B floods):** over-publishing past `WhcHigh=500kB` throttles
  the *attacker's own* `publish()` (§5.3) — keep the spoof rate modest; this is a spoof, not a flood.
- **No changes to the study repo `src/` trees** (read-only evidence) — the PoC lives in its own
  workspace.

---

## SEU detection signatures each module produces (the defender's test oracle)

These are what the SEU must catch; the PoC must reliably *emit* them (wiki §8).

- **Module 1 (forged withdrawal):** a dispose/unregister whose **source participant GUID prefix ≠
  the endpoint GUID prefix being disposed** — the exact check the code's own comment admits it omits
  (`ddsi_security_omg.c:2052-2068`), and the one the SEU can enforce. Also: dispose→re-announce
  **flapping**, and any dispose originating from an un-allowlisted/foreign GUID. Decisive
  mitigation to note: **DDS Security** flips the deletion guard to reject unauthenticated
  withdrawals.
- **Module 2 Carrier A:** a **new participant GUID** belonging to neither AWSIM nor Autoware, plus
  a **new speed-topic writer** in SEDP whose QoS fingerprint is fixed and predictable
  (`transient_local` offer). On a bounded bus, an un-allowlisted command/status writer is *by
  itself* the attack.
- **Module 2 Carrier B:** the invariants a forger must reproduce but a real endpoint never thinks
  about — **GUID consistency**, a `transient_local` offer on a writer that **never sent any
  history**, **monotonic sequence numbers**, and exact **XCDR1 encapsulation + alignment**.
- **Combined kill-then-spoof:** a dispose of the real speed writer **immediately followed by** a
  foreign writer publishing on the same topic — a high-severity correlated signature the SEU
  should treat as a takeover of the speed channel.

---

## Verification summary (how we know each stage works)

| Stage | Pass condition |
|---|---|
| Recon | Topic/type/reader-QoS cited from source; live speed-writer GUID captured; legit GUIDs recorded |
| Module 1 | Real monitor's `publish()` keeps succeeding **and** its DATA is still on-wire, yet the consumer stops receiving from its GUID (proxy writer deleted) |
| Module 2 | Consumer logs the attacker's `longitudinal_velocity` under a foreign GUID; SEDP shows the foreign writer with expected QoS |
| Combined | Consumer acts on the spoofed speed while the real monitor is provably still publishing; (Stage 2) downstream speed-driven behavior follows the spoof |
| Oracle | Each module's §8 signature is present in a tshark RTPS capture — feed these captures to the SEU as labeled positives |
