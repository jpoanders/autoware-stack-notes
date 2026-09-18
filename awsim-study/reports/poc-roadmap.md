# Roadmap: fault-injection harness — freshness-loss + wrong-value faults on the ego speed monitor (to exercise the SEU's STL monitor and safe-stop)

> In-repo copy of the working plan (originally `~/.claude/plans/concurrent-questing-matsumoto.md`,
> which lives outside the repo and does not travel with a clone). This copy is the shareable
> canonical version. `reports/poc-recon.md` is Phase 1, step 1 of this roadmap.
>
> **Safety reframe (2026-09-18).** This document was originally written as an *attacker* PoC
> ("kill + spoof the speed monitor") under the old assumption that the SEU is a *Security*
> Enforcement Unit. That premise is corrected: the SEU is a **Safety Enforcement Unit** — a
> lightweight, event-driven runtime-verification monitor that derives temporal/freshness constraints
> from data dependencies, formalizes them as Signal Temporal Logic (STL) properties, evaluates system
> traces against them, and executes a **preemptive safe-stop** when a critical constraint is violated
> (`[LSEU-abstract]`). The two modules below are therefore **not attacks to be detected**; they are a
> **fault-injection harness** — the study's test instrument (Task-2 role) — that drives off-nominal
> timing/value traces into the system so the STL monitor can be exercised and its safe-stop path
> validated, matching the abstract's "extreme fault-injection stress tests." The mechanism findings
> and every `path:line` citation survive the reframe intact; only the purpose changes.

## Context

The Cyclone DDS / AWSIM analysis is complete (`reports/wiki.md`, now safety-framed). The next step is
to turn two of its documented mechanisms into a **working, simulation-only fault injector** so the SEU
has a concrete off-nominal trace to observe and safe-stop against. This is authorized safety research;
the harness doubles as the monitor's **validation oracle** (each module must emit the exact
timing/value trace §"STL properties" says the SEU should catch, and the safe-stop must fire).

**Target** = the *ego speed channel*: the topic carrying the ego vehicle's measured speed that a
downstream consumer trusts for actuation. Speed is a first-class **freshness/rate** signal — its data
dependency imposes a temporal constraint (bounded age, bounded inter-arrival) that the STL monitor
watches. The wiki's running examples are `/control/command/gear_cmd` and
`/system/operation_mode/state`; this harness adapts the same wire mechanisms to the **speed** topic.

**Two fault-injection modules:**
1. **Freshness-loss injection** — the *withdraw* mechanism (wiki §7.1, now framed as **silent
   freshness loss**, Task-4 class): make the real monitor's samples stop reaching the consumer
   *without* stopping the publisher, by forging one keyed RTPS DATA on a builtin discovery writer
   carrying the target writer's 16-byte GUID with `statusinfo = DISPOSE|UNREGISTER`, so Cyclone
   deletes the proxy writer by GUID with **no ownership check** (`q_ddsi_discovery.c:1745-1748`,
   `ddsi_proxy_endpoint.c:419,430,444`). This is the **hardest case for a freshness monitor**: data
   goes stale with *no clean shutdown signal*, and a naive reader can still look "alive" (see the
   transient_local latching hazard, wiki Task 1). It is the archetypal critical fault a safe-stop must
   catch.
2. **Wrong-value / stale-value injection** — value injection (wiki §4): publish off-nominal speed
   values onto that same topic so the consumer evaluates a value the real monitor never produced
   (e.g. a dangerous `0.0 m/s` "stopped" while moving, or an inflated speed). This exercises the
   value/freshness property and the safe-stop decision. **Carrier A** (a ROS 2 node) first;
   **Carrier B** (hand-forged RTPS, §4.3) as a stretch for deployment realism.

**Decisions taken (this session):**
- **Build/validate staging:** *Harness first, then sim.* Stage 1 = a minimal 2-node Cyclone harness
  (fast, deterministic, proves both fault modules + the trace the monitor must evaluate) built
  here/portably. Stage 2 = port to live **AWSIM + Autoware on the Lab's PC** (the user runs the sim
  there).
- **Module 2 carrier:** *Carrier A first, Carrier B as a stretch.* Module 1 is hand-forged RTPS
  regardless — there is no ROS 2 API to dispose another node's writer, which is precisely why it can
  inject a freshness loss no application-level shutdown signal accompanies.

> **Session note (blocker):** a safety classifier is blocking `Bash` and subagent dispatch for
> the rest of *this* session (it reacts to earlier conversation content, not to the commands).
> Read-only file reads still work. That is why the exact speed-topic file:line below was originally
> marked **[CONFIRM IN RECON]** rather than cited. **Recon has since run** (`reports/poc-recon.md`)
> and resolved these; the confirmed values are folded in below.

---

## Target identification (confirmed in Recon, Phase 1 — see `poc-recon.md`)

| Attribute | Value | Evidence |
|---|---|---|
| Topic | `/vehicle/status/velocity_status` | `[code]` `AccelVehicleReportRos2Publisher.cs:43`; authoritative in `AutowareSimulationDemo.unity:71666` |
| Message type | `autoware_vehicle_msgs/msg/VelocityReport` | `[code]` `VelocityReport.msg:1-4` |
| Fields (exact) | `std_msgs/Header header`, `float32 longitudinal_velocity`, `float32 lateral_velocity`, `float32 heading_rate` | `[code]` `VelocityReport.msg:1-4` |
| Scalar speed field | `longitudinal_velocity` (float32, m/s) | `[code]` `VelocityReport.msg:2` |
| DDS-mangled name | `rt/vehicle/status/velocity_status` | `[code]` mangling rule `rmw_node.cpp:2282` |
| DDS type name | `autoware_vehicle_msgs::msg::dds_::VelocityReport_` | `[code]` `serdata.cpp:663-672` |
| Publisher ("real monitor") | `AccelVehicleReportRos2Publisher` (C#), publishes at 30 Hz | `[code]` `AccelVehicleReportRos2Publisher.cs:21,79,96,153` |
| Publish rate | **30 Hz** (`InvokeRepeating`) → nominal inter-arrival ≈ 33 ms | `[code]` `AccelVehicleReportRos2Publisher.cs:96` |
| **Reader durability (was the load-bearing unknown)** | **VOLATILE — resolved** (all four consumers + the publisher) | `[code]` triangulated + `[runtime]` publisher, `poc-recon.md` |

**The recon result that reshapes the harness — the channel is VOLATILE end to end.** The original
draft flagged the consumer's durability as the load-bearing unknown (transient_local vs volatile).
Recon resolved it to **VOLATILE** on every consumer found in source *and* on the publisher's wire QoS
(`poc-recon.md` §4). Consequences:
- **Module 2 Carrier A does NOT need to offer `transient_local`** — a default ROS 2 writer
  (RELIABLE + VOLATILE + KEEP_LAST) already satisfies the RxO durability gate (`q_qosmatch.c:167`).
  This is the **opposite** of the wiki's `/system/operation_mode/state` example (§4.1); do not carry
  that assumption onto the speed topic.
- **VOLATILE removes the transient_local latching mask on this topic.** For a `transient_local`
  freshness signal, a dead publisher's last sample stays latched and can fool a naive freshness
  monitor (wiki Task 1). Speed is volatile, so there is *no* latched last value — once the real
  writer is silenced (Module 1) the consumer simply stops receiving, which is exactly the freshness
  drop the STL age-property is meant to catch. The harder latching hazard is documented for the
  command topics, not here.

---

## Phase 0 — Environment & prerequisites

### Stage 1 harness (portable; build + first validation here or on any Linux box)
- **Cyclone DDS** `releases/0.10.x` (match the study checkout) + **ROS 2 Humble**,
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`, **domain 0 on `lo`**, the study's `cyclonedds.xml`
  (`src/awsim/cyclonedds_config.xml`) present and identical for every process.
- **Two harness nodes** (stand in for the real system, reproducing only the load-bearing QoS):
  - `real_speed_monitor` — publishes `VelocityReport` on the speed topic, **RELIABLE + VOLATILE +
    KEEP_LAST(1)** (matching the recon-confirmed real publisher, `poc-recon.md`), at a realistic rate
    (30 Hz, per `AccelVehicleReportRos2Publisher.cs:96`). Logs each `publish()` return so we can prove
    it keeps succeeding after the freshness-loss injection — i.e. the fault is *silent* at the source.
  - `trusting_consumer` — subscribes with the recon-confirmed reader QoS (VOLATILE); logs every
    received sample's value, **arrival timestamp, and source writer GUID** (the raw observables the
    STL monitor evaluates: age, inter-arrival, and provenance).
- **Trace tap for the monitor.** Alongside the consumer, capture the event stream the SEU would
  evaluate — per-sample `(topic, arrival_time, seq, source_GUID, longitudinal_velocity)` — so each
  module's output can be replayed against a draft STL property offline. This is the harness's real
  product: labeled off-nominal traces.
- **Tooling:**
  - Capture/inspect: **Wireshark/tshark** with the RTPS dissector on `lo`, or (no sudo/no tshark)
    **Cyclone's own tracing** (`Tracing` in the XML / `CYCLONEDDS_URI`) — the substitute recon
    already used successfully (`poc-recon.md` addendum 2). Both decode SPDP/SEDP (topic, type, full
    QoS, GUIDs) and DATA/HEARTBEAT/GAP.
  - ROS introspection: `ros2 topic info -v`, `ros2 topic hz`, `ros2 node info`.
  - Forge: evaluate **Scapy** (its `contrib/rtps` layer) first for hand-built SPDP/SEDP/DATA/
    HEARTBEAT; fall back to a raw-socket Python/C forger. **Hybrid option (recommended for
    Module 1):** run a *real* minimal Cyclone participant to carry SPDP presence + a builtin SEDP
    writer + its HEARTBEATs, and only hand-craft the one dispose DATA — this sidesteps most of the
    "fake a byte-accurate handshake" difficulty the wiki flags as the hard part (§4.3 verdict).

### Stage 2 live sim (Lab's PC)
- Full **AWSIM** (Unity, Shinjuku) native + **Autoware** container (`--net host`), domain 0 on
  `lo`, per `prompts/autoware-core-awsim-setup-guide.md`. **Snapshot/VM before running**; ensure a
  one-command restart of both halves. Same capture/forge tooling on the host. On this stage the real
  downstream **safe-stop behavior** (control/localization reaction) can be observed, not just the
  trace.

---

## Phase 1 — Recon (confirm the target on the running system) — **DONE**

Goal was: replace every **[CONFIRM]** with a cited fact, and learn the **live writer GUID**.
Status (`reports/poc-recon.md`): topic/type/reader-QoS pinned (readers `[code]`, publisher
`[runtime]`); live speed-writer GUID captured `[runtime]`
(`0110d7fa:ca3be3a4:1fc8049a:00001303`); the AWSIM participant prefixes recorded `[runtime]`; type
discovery resolved to **name-only** (no type hash) `[runtime]`. **Module 1 and Module 2 Carrier A are
unblocked.** Remaining, deferred to Stage 2 bring-up: the **Autoware-side reader QoS + participant
prefix** on the wire (the stack was not launched), and whether **DDS Security** is compiled in.

---

## Phase 2 — Module 1: Freshness-loss injection (forged withdrawal)

### Build
Chain (wiki §7.1): **sniff discovery → learn target writer GUID → emit one keyed withdrawal.**
- Establish injector presence: forged/real participant discovered via **SPDP** (builtin writer id
  `0x100c2`), with a **builtin SEDP publications writer** (entity id `0x3c2`) that is an
  established, in-order, **reliable** source — trivial for a *fresh* writer (sequence numbers from
  1, its own HEARTBEAT vouching for them). *(Hybrid: let a real Cyclone participant provide this.)*
- Craft the withdrawal: a keyed RTPS **DATA on the builtin SEDP writer** whose serialized key is
  the **target writer's 16-byte GUID** and whose `statusinfo` bits =
  `NN_STATUSINFO_DISPOSE | NN_STATUSINFO_UNREGISTER` (`q_ddsi_discovery.c:520-522`). RTPS
  status-info byte layout is `[spec]`; that Cyclone acts on it is `[code]`.
- Emit exactly one, in-order under the injector's builtin-writer sequence, preceded by a
  consistent HEARTBEAT so the reliable reader accepts it (`q_receive.c:2363-2368`).

On receipt the consumer's Cyclone: dispatches on status-info to the dead-endpoint path
(`:1851,1867-1880`), confirms only that the entity id is a *writer* id — **not** an authorization
check (`:1745,1480-1493`), deletes the proxy writer by the **payload GUID** (`:1747-1748`), and
tells the receive path to stop feeding readers from it (`ddsi_proxy_endpoint.c:419,430,444`). No
source-vs-target check on the dead path (the alive path has one at `:1502-1506`). **Why this is the
right fault to inject:** it produces a freshness loss with *no application-level shutdown event* —
the publisher never knows, the ROS graph shows nothing — so it validates whether the STL age-monitor
detects staleness on wire evidence alone.

### Validate — **exact off-nominal trace produced**
> The real publisher **still calls `publish()` successfully**, but its samples **stop reaching the
> consumer** — a silent freshness drop.

- `real_speed_monitor` log shows `publish()` continuing to return success (the fault is invisible at
  the source).
- Capture shows the real writer's DATA **still on the wire** (it doesn't know it was disposed).
- `trusting_consumer` **stops receiving samples from the real writer's GUID** — callback goes
  quiet for that source; the trace shows `age(topic)` growing without bound past the 33 ms nominal
  inter-arrival. Optionally confirm via Cyclone trace that the proxy writer for that GUID was deleted.
- Negative control: without the forged withdrawal, the consumer keeps receiving and `age` stays
  bounded. With it, `age` diverges — the exact signal the freshness property fires on.

---

## Phase 3 — Module 2: Wrong-value / stale-value injection

### Carrier A (build first)
- A ROS 2 (Humble) node, Cyclone RMW + same XML, publishing `VelocityReport` on the speed topic
  with a **default VOLATILE writer** (RELIABLE + VOLATILE + KEEP_LAST) — recon confirms the reader is
  volatile, so no `transient_local` offer is needed (offering it is harmless-but-unnecessary,
  `q_qosmatch.c:167`). Set `longitudinal_velocity` to the off-nominal value (e.g. `0.0 m/s`
  "stopped" while moving, or an inflated speed).
- It is a genuine DDS writer: real foreign GUID, sequence numbers from 1, correct XCDR1 CDR.

### Carrier B (stretch — deployment realism, shares forging code with Module 1)
- Hand-forged RTPS DATA: discovery forgery (SPDP + SEDP `0x3c2` announcing mangled topic, type
  name, QoS) + data forgery. XCDR1 payload per §4.3: 4-byte encap header (`00 01` CDR_LE, `00 00`
  opts) + aligned body matching `VelocityReport`'s fields, valid writer GUID + fresh sequence number.
- **CDR body is more involved than the wiki's `gear_cmd` example** (which was stamp + a `uint8`).
  `VelocityReport` = `std_msgs/Header` { `builtin_interfaces/Time` (int32 `sec`, uint32 `nanosec`)
  + **variable-length `frame_id` string** (4-byte length prefix + bytes + NUL + 4-byte alignment
  padding) } followed by **3× float32** (`longitudinal_velocity`, `lateral_velocity`,
  `heading_rate`). The string makes the layout non-constant-length and adds alignment traps — build
  the CDR with a real serializer/`ddsi_serdata_from_sample` reference dump, not by hand-counting.
  Recon confirmed `data_representation = XCDR1` on the wire, so this is the encapsulation to emit
  (`poc-recon.md` §4).

### Validate — **off-nominal value observed at the reader**
- `trusting_consumer` logs show the **injected** `longitudinal_velocity` value being received,
  attributed to a **foreign** writer GUID (neither AWSIM prefix from recon).
- Cross-check the SEDP capture: a new speed-topic writer with a foreign GUID and the expected QoS
  fingerprint appears before the first injected sample.
- The trace now carries a value the real monitor never produced — the input the STL value/freshness
  property is evaluated against.

---

## Phase 4 — Combined sequence (silence, then inject) & end-to-end safe-stop

1. Recon: learn the real speed writer's live GUID (Phase 1 — done).
2. **Freshness-loss** (Module 1): forge the withdrawal → real writer's proxy writer deleted;
   consumer stops hearing the real value.
3. **Wrong-value** (Module 2): inject off-nominal `VelocityReport` on the same topic → consumer now
   evaluates the injected value in place of the silenced monitor's.
4. **Confirm the safe-stop end to end:** the trace shows the real writer's GUID going stale
   immediately followed by a foreign writer publishing on the same topic — a correlated, high-severity
   off-nominal pattern. On the live sim (Stage 2), confirm the SEU's **preemptive safe-stop** actually
   fires (or, absent the SEU, that the downstream speed-driven behavior would follow the injected
   value — the accident the safe-stop is meant to prevent).
- **Watch for flapping:** if the real participant re-announces its endpoint via SEDP (reconnection/
  lease renewal), its proxy writer can be re-created and the freshness restored — re-emit the
  withdrawal or note the dispose/re-announce flap (itself a distinctive trace signature).

---

## Empirical unknowns to confirm (wiki [UNVERIFIED]/[INFERRED] that gate this harness)

| Item | Wiki tag | Why it matters here | How to settle |
|---|---|---|---|
| Speed reader durability (transient_local vs volatile) | recon | Sets Module 2 Carrier A QoS | **RESOLVED: VOLATILE** (`poc-recon.md`) |
| Live speed writer GUID | runtime | Module 1's required input | **RESOLVED: `…:1303`** (`poc-recon.md`) |
| Type discovery (type **hash** vs name-only) | `[UNVERIFIED]` §2.4/§10 | Discovery forgery (Module 1 builtin writer & Carrier B) | **RESOLVED: name-only** (`poc-recon.md`) |
| End-to-end acceptance of hand-forged discovery+DATA(+HEARTBEAT) | `[UNVERIFIED]` §4.3/§10 | Carrier B feasibility; also the withdrawal's HEARTBEAT gating | bench test / capture against the running build |
| Exact reorder/HEARTBEAT gating a fresh builtin writer must clear | `[INFERRED]` §7.1 | "Trivial for a fresh writer" is an inference — verify the withdrawal is actually accepted | harness test: does the proxy writer get deleted? |
| DDS Security compiled in? | `[UNVERIFIED]` §7.1/§10 | Flips the *participant*-kill guard (endpoint withdrawal has no guard either way); would block the forged-withdrawal fault path | inspect built lib; test an authenticated build |

---

## Risks, rollback, and safety

- **Blast radius / wrong GUID:** a mistyped target GUID could dispose the wrong proxy writer or
  no-op. Mitigate: derive the GUID only from a fresh capture (it is ephemeral — `poc-recon.md`);
  test in Stage 1 harness first.
- **Persistence of the freshness loss:** the dispose is one-shot; the consumer may re-discover the
  real writer later. Rollback = stop the injector and **restart the affected publisher/node** (or the
  sim) to force clean re-announcement.
- **Environment integrity (Lab PC):** run authorized, isolated, on a **VM/snapshot**; keep a
  one-command restart of AWSIM + Autoware; never run against anything but the lab bench.
- **Flow-control self-throttle (Carrier A/B floods):** over-publishing past `WhcHigh=500kB`
  throttles the *injector's own* `publish()` (§5.3) — keep the injection rate modest unless a rate
  fault is the point (the 100× over-publication stress case belongs to Task 3, not here).
- **No changes to the study repo `src/` trees** (read-only evidence) — the harness lives in its own
  workspace.

---

## STL properties each fault violates, and the expected safe-stop (the monitor's validation oracle)

These are what the SEU must catch; the harness must reliably *emit* the violating trace and the
safe-stop must fire. Each is written as the three-point closing block the study uses — **the
property**, **the trace event** the event-driven monitor observes, and **the safe-stop decision**.

**Module 1 — freshness-loss injection.**
1. *Property (freshness/liveness).* `G( age(/vehicle/status/velocity_status) <= Δ_fresh )` — and
   equivalently a deadline form `G( pub(speed) → F_[0,Δ_deadline] pub(speed) )` with
   `Δ_deadline` a small multiple of the 33 ms nominal inter-arrival (`[INFERRED]` from the 30 Hz
   publish rate, `AccelVehicleReportRos2Publisher.cs:96`).
2. *Trace event.* The per-sample arrival timestamp for the real writer's GUID stops advancing; the
   monitor sees `age` cross `Δ_fresh` with no new sample and no clean shutdown event. Visible at the
   subscriber/RTPS-receive layer the SEU taps.
3. *Safe-stop decision.* **Critical → preemptive safe-stop.** Speed is an actuation-driving signal;
   a source going silent is the strongest freshness violation and the archetypal safe-stop trigger
   (`[LSEU-abstract]`; wiki Task 1). Not a mere log/flag.

**Module 2 Carrier A — wrong-value injection.**
1. *Property (provenance + value/rate).* On a bounded bus, `G( writer(speed) ∈ allowlisted_GUIDs )`,
   plus any value/rate bound the speed dependency imposes
   (`G( inter_arrival(speed) ∈ [1/f_max, 1/f_min] )`).
2. *Trace event.* A **new speed-topic writer** in SEDP whose participant GUID belongs to neither
   AWSIM prefix recon recorded (`0110d7fa:…`), then samples on that topic under the foreign GUID —
   optionally a value discontinuity the value bound rejects.
3. *Safe-stop decision.* On a bounded, allowlisted bus an un-recognized command/status writer is by
   itself a critical integrity violation → **safe-stop**; a within-range-but-implausible value alone
   may be **flag/log** pending corroboration, depending on the value bound's confidence.

**Module 2 Carrier B — hand-forged injection.** Same property as Carrier A, plus the invariants a
forger must reproduce but a real endpoint never thinks about — **GUID consistency**, **monotonic
sequence numbers**, exact **XCDR1 encapsulation + alignment** — any of which, if wrong, is an extra
trace anomaly the monitor can key on.

**Combined silence-then-inject.** *Property:* `G( ¬( stale(real_speed_writer) ∧
F_[0,Δ] new_foreign_writer(speed) ) )`. *Trace event:* a dispose of the real speed writer
**immediately followed by** a foreign writer publishing on the same topic. *Safe-stop decision:*
**critical, high-priority preemptive safe-stop** — a correlated freshness-loss + substitution on an
actuation channel is exactly the accident-preventing case the SEU is built for (`[LSEU-abstract]`).

---

## Verification summary (how we know each stage works)

| Stage | Pass condition |
|---|---|
| Recon | Topic/type/reader-QoS cited from source; live speed-writer GUID captured; legit GUIDs recorded — **DONE** (`poc-recon.md`) |
| Module 1 | Real monitor's `publish()` keeps succeeding **and** its DATA is still on-wire, yet the consumer stops receiving from its GUID (proxy writer deleted) — the trace shows `age` diverging |
| Module 2 | Consumer logs the injected `longitudinal_velocity` under a foreign GUID; SEDP shows the foreign writer with the expected QoS |
| Combined | Consumer evaluates the injected speed while the real monitor is provably still publishing; (Stage 2) the SEU's preemptive safe-stop fires |
| Oracle | Each module's STL-violating trace is present in a capture and, replayed against the derived property, evaluates to a violation — feed these traces to the SEU as labeled positives |

<!-- SAFETY-REVISION-COMPLETE -->
