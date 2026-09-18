# PoC Phase 2 report — Module 1: silent freshness-loss injection (forged SEDP withdrawal)

> Executes **Phase 2** of `reports/poc-roadmap.md` (Module 1) to completion, on the
> lab PC. This is the *fault-injection harness* deliverable — the SEU's validation
> instrument, not an attack. The harness drives the exact off-nominal trace the STL
> freshness monitor must catch, and the run below proves the fault is **silent at the
> source**: the real speed writer keeps publishing successfully while its samples
> stop reaching the consumer. Phase 1 (recon) is `reports/poc-recon.md`.

## Status: DONE — Module 1 built and validated end-to-end `[runtime]`

- **Where/when:** lab PC `ml-XPS-8960`, 2026-09-18. Cyclone DDS **0.10.5**
  (`/opt/ros/humble/lib/x86_64-linux-gnu/libddsc.so.0.10.5`), ROS 2 Humble, domain 0
  on loopback (`lo`), the study socket-buffer config plus tracing. No AWSIM/Autoware
  running — this is the portable **Stage 1** harness (three Cyclone participants).
- **Result:** a hand-forged, single keyed RTPS **SEDP-publications DISPOSE|UNREGISTER**
  naming the live speed writer's GUID causes the victim consumer's Cyclone to delete
  that writer's **proxy** — with no authorization check — so the consumer stops
  receiving while the real writer keeps publishing and never notices. The freshness
  (`age`) property fires exactly as the roadmap's Module-1 STL block predicts.
- **Settles** three roadmap unknowns (see §6): end-to-end acceptance of a
  forged discovery+DATA+HEARTBEAT sequence, the reorder/HEARTBEAT gating a fresh
  builtin writer must clear, and (as mechanism) the no-source-check dead path.

Workspace: `poc-harness/` (tracked; `build/`, `*.trace`, `cap/*.bin` gitignored).

---

## 1. The Stage-1 harness (Phase 0 build)

Three Cyclone-C participants stand in for the real system, reproducing only the
**load-bearing QoS** recon pinned. Built directly against Cyclone (`idlc` + `libddsc`,
`poc-harness/CMakeLists.txt`) — no ROS overlay needed, and the same DDS layer Module 1
operates at.

| Node | Role | Key QoS / behaviour | Source |
|---|---|---|---|
| `real_speed_monitor` | stand-in for AWSIM `AccelVehicleReportRos2Publisher` | publishes `VelocityReport` on `rt/vehicle/status/velocity_status`, **RELIABLE + VOLATILE + KEEP_LAST(1)**, 30 Hz; logs every `dds_write()` return | `poc-harness/src/real_speed_monitor.c` |
| `trusting_consumer` | downstream node trusting ego speed | VOLATILE reader; logs per-sample `(arrival_time, source_GUID, longitudinal_velocity, inter-arrival)`; built-in freshness watchdog emits `age(topic)` and fires at `DELTA_FRESH = 165 ms` (≈5×33 ms) | `poc-harness/src/trusting_consumer.c` |
| `injector_presence` | the roadmap "hybrid" carrier | a **real, bare** participant, no user endpoints — exists only to be discovered so its builtin SEDP writer `0x3c2` is matched at the victim | `poc-harness/src/injector_presence.c` |

The IDL (`poc-harness/idl/VelocityReport.idl`) yields the exact ROS-mangled top-level
type name `autoware_vehicle_msgs::msg::dds_::VelocityReport_`; since recon resolved
discovery to **name-only** (no type hash), this is wire-faithful for topic/type
matching. `[INFERRED]` nested member modules differ cosmetically from the real
`std_msgs`/`builtin_interfaces` types — immaterial because both harness ends share the
one IDL, and Module 1 touches discovery/liveness, not payload contents.

**Baseline `[runtime]`** (`./run_module1.sh` with the injection step removed →
negative control below): consumer receives 30 Hz samples at ~33.3 ms spacing tagged
with the writer's GUID; `age` stays bounded; zero `STALE`.

---

## 2. Module 1 forge — design

**Goal (wiki §7.1 mechanism):** delete the real writer's *proxy* at the consumer by
forging one keyed SEDP dispose, so the data goes stale with **no clean shutdown
event**. There is no DDS API to dispose another participant's endpoint — which is
precisely why this injects a freshness loss no application-level shutdown accompanies.

**Hybrid carrier (roadmap-recommended).** A real Cyclone participant
(`injector_presence`) provides SPDP presence, ports, and a reliable, already-matched
builtin SEDP publications writer `0x3c2`. The Python forger
(`poc-harness/inject/forge_withdraw.py`) then injects **only the one dispose DATA** on
that already-matched `0x3c2`, sidestepping a from-scratch SPDP/port/reliability
reimplementation (the wiki flags the full handshake as the hard part, §4.3). RTPS
rides on UDP, so the forge is an ordinary UDP `sendto` to the domain-0 metatraffic
multicast locator `239.255.0.1:7400` — no raw sockets, no scapy.

**Wire contract, read from source (all `[code]` against `src/cyclonedds`):**

| Element | Value | Evidence |
|---|---|---|
| Dead-endpoint handler deletes purely by payload GUID | `ddsi_delete_proxy_writer(gv, &datap->endpoint_guid, …)` | `q_ddsi_discovery.c:1748` |
| **No** source/authorization check on the dead path | `handle_sedp_dead_endpoint` runs no `handle_sedp_checks` (alive-path only, `:1575`) | `q_ddsi_discovery.c:1739-1752` |
| Dispose routed by StatusInfo bits | `switch (statusinfo & (DISPOSE\|UNREGISTER))` → dead case | `q_ddsi_discovery.c:1851,1867-1879` |
| Key PID carrying the target GUID | `PID_ENDPOINT_GUID = 0x5a` | `q_protocol.h:426` |
| StatusInfo PID; **read big-endian** regardless of encapsulation | `PID_STATUSINFO = 0x71`; `ddsrt_fromBE4u(...) & STANDARDIZED` | `q_protocol.h:421`, `ddsi_plist.c:394` |
| DISPOSE / UNREGISTER bit values | `0x1` / `0x2` | `q_protocol.h:61-62` |
| Payload path taken when DATA flag set | `ddsi_serdata_from_ser(sedp_writer_type, SDK_DATA, …)` | `q_ddsi_discovery.c:2049` |

**Forged datagram (132 B):** RTPS header (src = injector prefix) · `INFO_DST`
(consumer prefix) · `DATA` (flags E|Q|D; reader `0x3c7`, writer `0x3c2`, SN 1; inline
QoS `PID_STATUSINFO = 00 00 00 03` big-endian; payload `PL_CDR_LE` parameter list
`{PID_ENDPOINT_GUID(0x5a)=<target 16-byte GUID>, SENTINEL}`) · `HEARTBEAT`
(F, first=last=1). Exact bytes: `poc-harness/evidence/module1_trace_excerpt.txt`.

---

## 3. Validation — the exact off-nominal trace `[runtime]`

`./poc-harness/run_module1.sh`, 2026-09-18, three participants on domain 0/`lo`.
Target writer GUID (ephemeral, per recon) captured live this run:
`0110bb04:46898719:fd2844b7:00000203`; injector participant `0110b75a:…`; victim
consumer `011015ee:…`. Consumer Cyclone trace, verbatim:

```
recv: DATA(110b75a:…:3c2 -> 11015ee:…:3c7 #1)                                 ← forged SEDP DATA
recv: HEARTBEAT(F#1:1..1 110b75a:…:3c2 -> 11015ee:…:3c7)                      ← forged HEARTBEAT
dq.builtin: … 110b75a:…:3c2 #1: ST3 DCPSPublication:{endpoint_guid={110bb04:…:203}}
dq.builtin: SEDP ST3 110bb04:…:203 ddsi_delete_proxy_writer(110bb04:…:203) - deleting
dq.builtin:   delete
```

The dispose came from injector participant `110b75a` yet deleted a writer owned by a
**different** participant `110bb04` — the no-authorization dead path, confirmed live.

Immediately after, the real writer keeps sending, but its samples are unmatched
(trailing `?` = no proxy writer; delivered to no reader):

```
recvUC: DATA(110bb04:…:203 -> 0:0:0:0 #63 110bb04:…:203? -> 0:0:0:0)
recvUC: DATA(110bb04:…:203 -> 0:0:0:0 #64 110bb04:…:203? -> 0:0:0:0)   … #65, #66, …
```

**Pass conditions (roadmap Phase 2 "Validate" + verification table):**

| Condition | Observed |
|---|---|
| Real monitor's `publish()` keeps succeeding | **142/142 `write_rc=OK`**, incl. all samples after the dispose |
| Real writer's DATA still on the wire | **yes** — #63…#68+ observed post-dispose (unmatched) |
| Consumer stops receiving from the writer's GUID | **yes** — last delivered `rx=60`; proxy writer deleted |
| Trace shows `age` diverging | **yes** — `STALE age=173.3 ms` (> `DELTA_FRESH` 165) then unbounded growth |
| Fault silent at source | **yes** — monitor never errors, ROS graph shows nothing |

**Negative control** (same three nodes, same ~4.5 s window, **forge not fired**):
consumer received **134 samples, 0 `STALE`**; no mid-run proxy delete. The staleness
is caused by the injection and nothing else.

---

## 4. New `[runtime]` findings (command · date · what was running)

All: `poc-harness/run_module1.sh`, 2026-09-18, lab PC `ml-XPS-8960`, three Cyclone
0.10.5 participants on domain 0/`lo`, **no AWSIM/Autoware**.

1. A forged SEDP `DISPOSE|UNREGISTER` on a *foreign* participant's builtin `0x3c2`,
   keyed with a target writer's GUID, **is accepted and deletes that writer's proxy**
   at an unrelated consumer — no ownership/source check. (Confirms the mechanism the
   study derived from `q_ddsi_discovery.c` as a live behaviour.)
2. A **freshly-matched** builtin proxy writer's first sample (SN 1) + `HEARTBEAT(1,1)`
   is accepted with no reorder stall — the roadmap's "trivial for a fresh writer"
   inference, now verified.
3. After the proxy delete, the real writer's continued DATA is received on the socket
   but **unmatched** (`…:203?`) and delivered to no reader — the silent freshness loss
   is stable until re-announcement (the persistence caveat, roadmap §Risks).

---

## 5. STL closing block (the monitor's validation oracle) — now empirically grounded

**Property (freshness/liveness).** `G( age(/vehicle/status/velocity_status) <= Δ_fresh )`,
equivalently `G( pub(speed) → F_[0,Δ_deadline] pub(speed) )`, with `Δ_deadline` a small
multiple of the 33 ms nominal inter-arrival (`[code]` 30 Hz,
`AccelVehicleReportRos2Publisher.cs:96`; harness `DELTA_FRESH = 165 ms`).

**Trace event (what the event-driven monitor observes).** The per-sample arrival
timestamp for the real writer's GUID stops advancing (`STALE age=173 ms →` unbounded)
with **no clean shutdown event** on the ROS graph — observed live at the
subscriber/RTPS-receive layer the SEU taps. Distinctively, the *cause* (a foreign
`0x3c2` dispose naming the writer's GUID) is itself visible in the SEDP trace: a
second, corroborating signal available to a wire-tapping monitor.

**Safe-stop decision.** **Critical → preemptive safe-stop.** Speed drives actuation; a
source going silent with no shutdown signal is the strongest freshness violation and
the archetypal safe-stop trigger (`[LSEU-abstract]`). Not a mere log/flag.

---

## 6. Roadmap unknowns settled / carried

| Roadmap item | Prior tag | Now |
|---|---|---|
| End-to-end acceptance of hand-forged discovery+DATA(+HEARTBEAT) | `[UNVERIFIED]` §4.3/§10 | **CONFIRMED** via hybrid carrier `[runtime]` (§3) |
| Reorder/HEARTBEAT gating a fresh builtin writer must clear | `[INFERRED]` §7.1 | **CONFIRMED** — SN 1 + HB(1,1) accepted `[runtime]` |
| No source-vs-target check on the SEDP dead path | `[code]` | **CONFIRMED live** — foreign `0x3c2` deleted `110bb04:…:203` `[runtime]` |
| DDS Security compiled in? | `[UNVERIFIED]` | **Untouched** — this build is non-secure (forge landed); a secured build would gate the *participant* dispose but not the endpoint dead path either way. Confirm on the Autoware build in Stage 2. |
| Full from-scratch SPDP forge (no real carrier) | — | **Not attempted** — the hybrid meets Module 1's intent; full SPDP forge remains for Carrier B / deployment realism (Phase 3). |

---

## 7. Reproduce

```bash
cd poc-harness
cmake -S . -B build -DCMAKE_PREFIX_PATH=/opt/ros/humble && cmake --build build -j4
./run_module1.sh            # positive: prints the dispose trace + STALE transition
# negative control: comment out the python forge_withdraw.py line and re-run
```
Requires `source /opt/ros/humble/setup.bash` (the script does this) and Cyclone 0.10.x.
Trace files land in `poc-harness/logs/*.trace` (gitignored); curated evidence is in
`poc-harness/evidence/`.

---

## 8. Next (Phase 3+ — not in this report)

- **Phase 3 / Module 2** — wrong-value injection: Carrier A (a real VOLATILE ROS/Cyclone
  writer publishing off-nominal `longitudinal_velocity`) then Carrier B (fully
  hand-forged, including the `VelocityReport` XCDR1 body with its variable-length
  `frame_id` string). The forging code here is reused for Carrier B.
- **Phase 4** — combined silence-then-inject on one topic; correlated STL property.
- **Stage 2** — port to live AWSIM + Autoware on this PC (snapshot first) to observe the
  real downstream **safe-stop** reaction, and to confirm DDS-Security build flag +
  Autoware-side reader QoS on the wire.

<!-- REPORT-COMPLETE -->
