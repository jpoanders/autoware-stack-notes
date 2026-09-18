# Phase 2 in the study: the first `[runtime]` confirmation of a wire mechanism feeding the SEU

Abstract. For the length of this study, every claim about how the AWSIM / Autoware / Eclipse
Cyclone DDS stack carries — or loses — a temporal constraint has been a *reading of source code*:
`[code]`, `[spec]`, or a reasoned `[INFERRED]` step, with the behaviours that would need a live run
left honestly `[UNVERIFIED]`. Phase 2 of the fault-injection roadmap crosses that line for the first
time. On the lab PC, a purpose-built Stage-1 harness drove the study's hardest freshness-loss
mechanism — the **silent endpoint withdrawal** derived statically in [wiki §7.1] — as a live
`[runtime]` result: a single hand-forged discovery packet naming a live writer's identifier causes an
unrelated consumer's middleware to delete that writer's local shadow *with no authorization check*, so
the consumer stops receiving while the real publisher keeps publishing successfully and never notices.
This is exactly the off-nominal trace the Safety Enforcement Unit (SEU) — the lightweight,
event-driven runtime-verification monitor this study feeds — must catch and safe-stop against
`[LSEU-abstract]`. The harness is the SEU's **test instrument**, not an attack to be blocked. What
follows situates that result in the whole study: what was built, where the mechanism sits in the wiki,
what it now lets the study conclude, and — stated plainly and up front — what it does *not* yet show,
because it ran on three co-located processes over loopback and not on the live vehicle.

This report integrates `reports/poc-phase2-report.md` (the raw result and its evidence) into the
study's standing narrative in `reports/wiki.md`. It does not re-run the proof-of-concept, re-derive
the stack, or restate the primary report; it is the connective tissue between the two. Provenance
pointers to sibling reports and to the harness workspace (`poc-harness/`) are kept in-text on purpose:
this is a study report, not the publish-ready wiki, so naming where the evidence lives is a feature.

---

## Table of contents

1. [Evidence-tag legend](#1-evidence-tag-legend)
2. [What was built](#2-what-was-built)
3. [Where it fits in the study](#3-where-it-fits-in-the-study)
4. [Analysis: what the run actually proves](#4-analysis-what-the-run-actually-proves)
5. [The STL closing block, now empirically grounded](#5-the-stl-closing-block-now-empirically-grounded)
6. [What the study can now conclude](#6-what-the-study-can-now-conclude)
7. [Pendencies and unverified aspects](#7-pendencies-and-unverified-aspects)
8. [Glossary by reference](#8-glossary-by-reference)

---

## 1. Evidence-tag legend

This report reuses the wiki's evidence discipline unchanged, and adds one tag for the new class of
finding Phase 2 introduces.

| Tag | Meaning |
|---|---|
| `[code]` | Confirmed by reading the open-source code of the named component, cited as `file:line`. |
| `[spec]` | Defined by the OMG DDS / DDSI-RTPS specification — an external standard, not this stack's own code. |
| `[INFERRED]` | A reasoned conclusion drawn from cited code, flagged as an inference rather than a direct reading. |
| `[UNVERIFIED]` | Settleable only by running the simulation or capturing live packets. |
| `[LSEU-abstract]` | Drawn from the SEU's own unpublished abstract — its motivation and target behaviour, *not* a number this static study measured. |
| `[runtime]` | **Observed on the live lab PC (`ml-XPS-8960`), not read from source.** Per the `poc-recon.md` convention, every `[runtime]` claim states the command run, the date, and what was running when it was observed. |

Throughout, a `[runtime]` finding from Phase 2 carries the same context: command `./poc-harness/run_module1.sh`,
date **2026-09-18**, with **three Cyclone DDS 0.10.5 participants on domain 0 / loopback (`lo`) and no
AWSIM or Autoware running**. Source-class tags are preserved at their original strength: a `[code]`,
`[spec]`, `[INFERRED]`, or `[LSEU-abstract]` claim is never re-tagged `[runtime]` just because a live
run is now consistent with it — the live run confirms that the derived code path *fires*, which is a
separate, additional fact.

---

## 2. What was built

Why this matters first. To exercise the SEU you need a controllable way to produce the exact
off-nominal trace its monitor must evaluate. Phase 2's deliverable is that instrument for the
freshness-loss fault: a small, portable harness plus a one-packet forge that, together, manufacture a
*silent* loss of data freshness on demand and record the trace a monitor would tap. Everything below is
built to be faithful to the one thing that governs whether the fault lands — the load-bearing
Quality-of-Service (QoS) the recon phase pinned — and deliberately unfaithful to everything that does
not matter for this mechanism.

### 2.1 The Stage-1 harness — three participants standing in for the system

The harness (`poc-harness/`) is three Cyclone-C participants, built directly against Cyclone
(`idlc` + `libddsc`) with no ROS 2 overlay. Two reproduce the real data path and one carries the
injection; each reproduces only the QoS that recon proved load-bearing on the ego speed channel.

| Node | Study role | Load-bearing behaviour it reproduces |
|---|---|---|
| `real_speed_monitor` | stand-in for AWSIM's velocity publisher | publishes `VelocityReport` on `rt/vehicle/status/velocity_status`, **RELIABLE + VOLATILE + KEEP_LAST(1)** at 30 Hz, and logs every `dds_write()` return so the fault's silence at the source is measurable |
| `trusting_consumer` | a downstream node that trusts ego speed | a VOLATILE reader that logs per-sample `(arrival time, source GUID, longitudinal_velocity, inter-arrival)` — the raw observables the monitor evaluates — with a freshness watchdog that fires at `Δ_fresh = 165 ms` (≈ 5 × the 33 ms nominal inter-arrival) |
| `injector_presence` | the roadmap's "hybrid" carrier | a real but bare participant with no user endpoints — it exists only so its builtin SEDP-publications writer (`0x3c2`) is discovered and matched at the consumer, giving the forge an established, reliable channel to ride |

Three design choices are worth one line each. A **Cyclone-C harness rather than a full ROS 2 build**
because Module 1 operates at the DDS discovery/liveness layer, below the language binding — the wiki's
publish path shows `rclcpp`/`rcl`/`rmw` are pass-through plumbing above `dds_write` [wiki §2.3], so
nothing above Cyclone is needed to reproduce the mechanism. **Reproducing only the QoS that matters**
because recon settled the ego speed channel as VOLATILE + RELIABLE + KEEP_LAST(1) end to end
[poc-recon §4], and the withdrawal mechanism turns on discovery and liveness, not on payload contents.
And the harness IDL (`poc-harness/idl/VelocityReport.idl`) yields the exact ROS-mangled top-level type
name `autoware_vehicle_msgs::msg::dds_::VelocityReport_`; because recon resolved discovery to
**name-only, with no type hash** `[runtime]` [poc-recon §3], that single string is wire-faithful for
topic/type matching even though the nested member modules differ cosmetically from the real
`std_msgs`/`builtin_interfaces` types — immaterial, since both harness ends share the one IDL.

### 2.2 The Module-1 forge — a hybrid carrier and one hand-forged packet

The forge (`poc-harness/inject/forge_withdraw.py`) is the study's realisation of the endpoint
withdrawal. Its goal, in monitor terms, is to delete the real writer's *proxy writer* at the consumer
— the consumer's local shadow of that remote writer — so the speed samples go stale with **no clean
shutdown event** on the ROS graph. There is deliberately no DDS API for this: no application can
dispose another participant's endpoint, which is precisely why the resulting freshness loss carries no
application-level shutdown signal.

The carrier is **hybrid**, as the roadmap recommended. Rather than fake a byte-accurate
SPDP-and-reliability handshake from scratch — the part the wiki flags as the genuinely hard forgery
[wiki §4.3] — a *real* Cyclone participant (`injector_presence`) supplies participant presence, ports,
and an already-matched, reliable builtin SEDP writer `0x3c2`; the forge then injects **only the one
dispose DATA** onto that already-established channel. Because RTPS rides on UDP, emitting it is an
ordinary UDP `sendto` to the domain-0 metatraffic multicast locator `239.255.0.1:7400` — no raw
sockets and no packet-crafting library are needed. The forged datagram is 132 bytes: an RTPS header
(source = the injector's prefix), an `INFO_DST` naming the victim consumer's prefix, a `DATA` submessage
on reader `0x3c7` / writer `0x3c2` at sequence number 1 whose inline QoS sets
`PID_STATUSINFO = 0x71` to `DISPOSE|UNREGISTER` (bits `0x1|0x2`, read big-endian regardless of
encapsulation) and whose payload is a parameter list carrying `PID_ENDPOINT_GUID = 0x5a` set to the
target writer's 16-byte GUID, followed by a `HEARTBEAT` vouching for that one sequence number. The exact
bytes are in `poc-harness/evidence/module1_trace_excerpt.txt`.

Every element of that wire contract was read from Cyclone source before it was emitted, and those
readings stay `[code]`: the dead-endpoint handler deletes purely by the payload GUID
(`q_ddsi_discovery.c:1748`); it runs **no** source/authorization check on that dead path, unlike the
alive path (`q_ddsi_discovery.c:1739-1752` vs `:1575`); it dispatches to the dead case on the
StatusInfo bits (`:1851,1867-1879`); the key and status PIDs are `PID_ENDPOINT_GUID = 0x5a`
(`q_protocol.h:426`) and `PID_STATUSINFO = 0x71` read big-endian (`q_protocol.h:421`, `ddsi_plist.c:394`),
with the dispose/unregister bit values `0x1`/`0x2` (`q_protocol.h:61-62`). The forge's contribution is
to make those code paths *run on live processes*.

---

## 3. Where it fits in the study

The single most important thing to say about Phase 2 is where it sits on the study's evidence ladder.
Until now the wiki's conclusions about silent freshness loss were a chain of `[code]` and `[spec]`
readings joined by `[INFERRED]` steps, with the crucial end-to-end question — *does this specific build
actually accept a hand-forged withdrawal and act on it?* — left `[UNVERIFIED]` [wiki §10]. Phase 2 is
**the first crossing from that static evidence into `[runtime]`**, and it makes the crossing on the
mechanism the wiki itself named as its one genuinely new and hardest case.

Connecting it to the wiki explicitly:

- **§7.1 (protocol-level endpoint withdrawal)** is the exact mechanism Phase 2 validated. The wiki
  derives it on the `/control/command/gear_cmd` writer: a forged keyed DATA with the dispose status
  flag makes the middleware delete a live endpoint's proxy "keyed on the payload GUID, with no
  ownership check," so "the publishing node still calls `publish()` successfully, but its `gear_cmd` no
  longer reaches the AWSIM reader — freshness is lost with no announced transition" [wiki §7.1]. That
  was a reading of `q_ddsi_discovery.c`; Phase 2 is the same sentence observed happening.
- **§4 / §4.3 (the injection framing and Carrier B, hand-forged RTPS)** supply the acceptance chain the
  forged packet had to clear and the difficulty budget it had to manage. The wiki's verdict is that the
  hard part of a hand-forged carrier is the *discovery* forgery (its §4.3 items 1–3), not the data
  forgery. The hybrid carrier is precisely the roadmap's answer to that verdict: let a real participant
  own discovery and reliability, and hand-forge only the payload — which is why Phase 2 could validate
  the withdrawal without first solving the full from-scratch SPDP forge.
- **§8 (the gathered SEU implications)** is where the result lands as monitor value: it moves property
  **P2 (liveness)** and **P1 (freshness)** on the anchor of the catalog from "mechanism that *would*
  violate them, per the code" to "mechanism *observed* violating them," and it does so for the silent,
  no-announced-transition case the wiki calls the hardest for a monitor.
- **§10 (open questions)** is moved in two specific rows and left untouched in several others; §7 below
  is the precise accounting.

Two framing details keep the placement honest. First, Phase 2 runs on the **ego speed channel**
(`/vehicle/status/velocity_status`), not the wiki's `gear_cmd` worked example — the roadmap's chosen
target, a first-class freshness/rate signal for actuation [poc-roadmap "Target"]. That the same §7.1
mechanism lands on a *different* topic than the one it was derived on is itself corroboration that the
mechanism is generic to the discovery layer, not specific to one endpoint. Second, the speed channel is
**VOLATILE end to end** [poc-recon §4], which the roadmap notes removes the `transient_local` latching
hazard the wiki documents for the command topics [wiki §2.3 closing block]: there is no latched last
value to mask the loss, so once the proxy writer is deleted the consumer simply and cleanly goes quiet
— the archetypal freshness drop, uncomplicated by a stale latched sample.

---

## 4. Analysis: what the run actually proves

### 4.1 The no-source-check dead path, confirmed live

Motivation. The wiki's §7.1 verdict rests on one structural fact about Cyclone: on the endpoint
*dead* path there is no check that the sender of a withdrawal owns the endpoint being withdrawn
(`q_ddsi_discovery.c:1745,1480-1493`; the alive path's owner check at `:1502-1506` is skipped)
`[code]`. Everything the monitor must worry about — that a freshness loss can be induced with no clean
shutdown and no announced transition — follows from that one missing check. Phase 2 shows it is not
merely present in the source but *taken* at runtime.

The trace is unambiguous `[runtime]` (command `./poc-harness/run_module1.sh`, 2026-09-18, three Cyclone
0.10.5 participants on domain 0/`lo`, no AWSIM/Autoware). The dispose was emitted by the injector
participant `110b75a`, yet it deleted a proxy writer owned by a **different** participant, `110bb04`
(the run's ephemeral speed-writer GUID `0110bb04:46898719:fd2844b7:00000203`), captured live this run.
The consumer's Cyclone trace shows the forged SEDP DATA and HEARTBEAT accepted on the already-matched
`0x3c2` channel, then `ddsi_delete_proxy_writer` invoked on the *foreign* writer's GUID:

```
recv: DATA(110b75a:…:3c2 -> 11015ee:…:3c7 #1)                              ← forged SEDP DATA
dq.builtin: … 110b75a:…:3c2 #1: ST3 DCPSPublication:{endpoint_guid={110bb04:…:203}}
dq.builtin: SEDP ST3 110bb04:…:203 ddsi_delete_proxy_writer(110bb04:…:203) - deleting
```

A foreign participant's builtin writer deleting an unrelated participant's proxy, with no ownership
objection, is the code-derived dead path behaving exactly as read. The `[code]` claim keeps its tag;
the new fact is the `[runtime]` observation that the path fires.

### 4.2 What "silent freshness loss" means, and why it is the hardest monitor case

Motivation. "Silent" is load-bearing, and the run measures each half of it. A freshness monitor's
worst case is a loss that presents *no positive signal anywhere* — the source looks healthy, the ROS
graph is unchanged, and the only evidence is data that stops arriving. Phase 2 produces exactly that
shape.

- **Source healthy and oblivious.** The real speed writer's `publish()` kept returning success —
  **142 of 142 `write_rc=OK`**, including every sample after the dispose `[runtime]`. Its DATA stayed
  on the wire the whole time (`#63, #64, …` observed post-dispose). The publisher never learns anything
  is wrong; there is no error to log, no exception to catch.
- **Data on the wire but unmatched.** After the proxy delete, the real writer's continued DATA is
  received on the socket but delivered to no reader — the trace marks it unmatched with a trailing `?`
  (`110bb04:…:203? -> 0:0:0:0`) `[runtime]`. The bytes arrive; nothing consumes them.
- **Consumer starved.** The consumer's last delivered sample was number 60; thereafter its freshness
  watchdog crossed the bound (`STALE age = 173.3 ms`, past the 165 ms `Δ_fresh`) and grew without
  bound `[runtime]`.

The **negative control** ties the causation down: the identical three nodes over the same ~4.5 s
window, with the forge simply not fired, delivered **134 samples and zero `STALE`** `[runtime]`. The
staleness is caused by the injection and by nothing else in the harness.

This is the hardest case for a freshness monitor precisely because none of the cheaper signals exist. A
monitor keyed on delivered *content* sees only absence, indistinguishable from a slow producer. A
monitor trusting DDS liveliness would wait out the participant lease (on the order of seconds) before
the writer is declared not-alive [wiki §7.1]. The only reliable discriminator is what the harness
records: the per-(topic, GUID) arrival timestamp stops advancing while sim time keeps moving. Speed
drives actuation, and a source going silent with no shutdown signal is the strongest freshness
violation — the archetypal safe-stop trigger the SEU exists to catch `[LSEU-abstract]`.

### 4.3 The observability argument — the monitor can see both effect and cause

Motivation. A safe-stop is only as good as the trace the monitor taps. Phase 2's most useful result
for the SEU design is that **both** the effect and the cause of this fault are present in observable
wire evidence — so the monitor is not forced to infer the loss from silence alone.

- **The effect** is the age divergence: the arrival-timestamp gap for the real writer's GUID, visible
  at the subscriber/RTPS-receive layer the SEU taps, is what fires the freshness property (P1/P2).
- **The cause** is independently visible: a foreign `0x3c2` SEDP dispose naming the writer's GUID
  appears in the discovery trace *before* the samples stop. A wire-tapping monitor therefore has a
  second, corroborating signal — an unexpected withdrawal of a still-live writer — that both confirms
  the loss and localizes it to a specific endpoint, without waiting for the age bound to blow.

For the SEU this means the freshness property is the primary, always-available detector (it needs only
sample arrivals), and the SEDP dispose is a corroborating early signal available to a monitor that also
watches discovery traffic.

### 4.4 Strength and limits of the evidence — the realism caveat

Stated once, prominently, and binding on everything above: **this is Stage-1, on loopback.** The three
participants are co-located Cyclone processes exchanging RTPS over `lo` in one domain, with no AWSIM and
no Autoware in the loop. That co-location is a *simulation artifact* — the same "everything on one
domain over loopback" ease the wiki flags as convenient for a harness but not representative of the
deployment [wiki §1 topology caveat]. What Phase 2 validates is therefore precise and bounded:

- **Validated:** the *mechanism* (the forged withdrawal is accepted and deletes a foreign proxy with
  no authorization check on this non-secure Cyclone build) and the *monitor-observable trace* (silent
  age divergence at the source plus a corroborating SEDP dispose).
- **Not validated:** the *live vehicle reaction*. On a real vehicular network the injected withdrawal
  must still reach discovery and match topic/type/QoS to affect a real consumer, and the downstream
  effect — whether the SEU's preemptive safe-stop actually fires, and how Autoware's own speed readers
  behave on the wire — is Stage 2, against live AWSIM + Autoware on the lab PC. Phase 2 makes no claim
  there.

The harness proves the trace is real and the monitor-observable; it does not, and cannot, prove the
end-to-end safe-stop on the deployment target.

---

## 5. The STL closing block, now empirically grounded

The study closes each mechanism in a three-point block — the **property**, the **trace event** an
event-driven monitor observes, and the **safe-stop decision**. The Module-1 block was written in the
roadmap as a projection of what the harness *should* emit [poc-roadmap "STL properties", Module 1]. It
is restated here in the same form, now tied to an observed `[runtime]` trace rather than to an
expectation.

1. **The property (freshness / liveness).**
   `G( age(/vehicle/status/velocity_status) ≤ Δ_fresh )`, equivalently the deadline form
   `G( pub(speed) → F_[0,Δ_deadline] pub(speed) )`, with `Δ_deadline` a small multiple of the 33 ms
   nominal inter-arrival that the 30 Hz publish rate implies (`AccelVehicleReportRos2Publisher.cs:96`
   `[code]`; the harness used `Δ_fresh = 165 ms`). This is the wiki catalog's **P1/P2** on the speed
   channel [wiki §8].
2. **The trace event.** The per-sample arrival timestamp for the real writer's GUID stops advancing —
   observed live as `STALE age = 173 ms →` unbounded, with **no clean shutdown event** on the ROS graph
   `[runtime]`. Distinctively, the *cause* is itself in the trace: a foreign `0x3c2` dispose naming the
   writer's GUID, a second corroborating signal available to a wire-tapping monitor (§4.3).
3. **The safe-stop decision. Critical → preemptive safe-stop.** Speed drives actuation; a source going
   silent with no shutdown signal is the strongest freshness violation and the archetypal safe-stop
   trigger `[LSEU-abstract]` — not a mere log or flag.

What changed between the roadmap's block and this one is only the middle point: the trace event is no
longer projected from the code path but drawn from a capture in which the property demonstrably fired
(and, in the negative control, demonstrably did not). Against the gathered catalog in [wiki §8], this
supplies the first *observed* instance of a P1/P2 violation via the silent-freshness-loss mechanism —
the row the wiki could previously only populate from `[code]` + `[INFERRED]`.

---

## 6. What the study can now conclude

Folding this first empirical result back into the study's standing conclusions:

- **A load-bearing static finding is now confirmed live.** The wiki's central §7.1 claim — that a
  freshness loss can be induced on this stack *with no clean shutdown and no authorization check* — was
  its strongest and most consequential silent-fault result, and it was `[UNVERIFIED]` end to end.
  Phase 2 confirms it fires on a live Cyclone build (`[runtime]`), on a topic other than the one it was
  derived on. Among the study's conclusions this is now the most load-bearing *and* confirmed: the
  monitor's hardest case is real, not hypothetical.
- **The STL-property catalog gains its first observed positive.** P1/P2 on an actuation-feeding topic
  now has a captured, reproducible off-nominal trace — with a matched negative control — that evaluates
  to a violation. That is exactly the "labeled off-nominal trace" the roadmap set out to produce for
  the SEU to be exercised against [poc-roadmap "Context"], and the first entry in what the harness is
  meant to deliver as a corpus.
- **The observability thesis is supported.** The study has argued throughout that freshness/liveness
  properties must be owned by the monitor and keyed on arrival timestamps, because neither DDS nor the
  Autoware application freshness-gates the data path [wiki §8]. Phase 2 supports the corollary that the
  monitor *can* carry that burden here: both the effect and the cause of the worst-case loss are in the
  trace it taps.
- **The confirmation is bounded to the mechanism.** Consistent with §4.4, the study still concludes
  nothing about the live vehicle's reaction; the standing conclusions about the deployment target
  remain as the wiki left them, awaiting Stage 2.

The unverified numbers from the SEU abstract — its CPU budget, interference bound, and linear
verification cost `[LSEU-abstract]` — remain context, not something this study measured; Phase 2 does
not change that.

---

## 7. Pendencies and unverified aspects

Phase 2 settles some wiki §10 / roadmap open items and leaves others explicitly open. The distinction
that matters everywhere below is **confirmed on the Stage-1 harness** (three Cyclone processes on
loopback) versus **still pending on live AWSIM/Autoware** (Stage 2).

| Item (wiki §10 / roadmap) | Prior status | After Phase 2 |
|---|---|---|
| End-to-end acceptance of a hand-forged discovery + DATA (+ HEARTBEAT) sequence by this build | `[UNVERIFIED]` [wiki §10; §4.3] | **Settled for the hybrid carrier** — accepted and acted upon on the Stage-1 harness `[runtime]`. The *full from-scratch SPDP forge with no real carrier* is a different question and remains open (see below). |
| Reorder / HEARTBEAT gating a freshly-matched builtin writer must clear | `[INFERRED]` [wiki §7.1] | **Settled** — sequence number 1 + `HEARTBEAT(1,1)` accepted with no reorder stall on the Stage-1 harness `[runtime]`; the "trivial for a fresh writer" inference is confirmed. |
| No source-vs-target check on the SEDP dead path | `[code]` [wiki §7.1] | **Confirmed live** as a behaviour — a foreign `0x3c2` deleted `110bb04:…:203` `[runtime]`. The `[code]` claim keeps its tag; the run adds a `[runtime]` observation that it fires. |
| Type discovery: hash vs name-only | resolved in **Phase 1** (recon), not Phase 2 | Already `[runtime]` **name-only** [poc-recon §3]; Phase 2 relies on it (harness IDL supplies only the type-name string). Listed for completeness, not moved by Phase 2. |
| DDS Security compiled into the target build | `[UNVERIFIED]` [wiki §10; §7.1] | **Still open for the Autoware container.** Phase 2 shows the endpoint dead path landed on the harness's **non-secure** Cyclone build (the forge was accepted); it does *not* inspect the Autoware container's build. A secured build would gate a *participant* dispose but, per the wiki, not the endpoint dead path either way [wiki §7.1]. Confirm on the Autoware build in Stage 2. |
| Full from-scratch SPDP forge (no real carrier) — Carrier B discovery forgery | `[UNVERIFIED]` [wiki §4.3] | **Not attempted.** The hybrid carrier meets Module 1's intent by sidestepping it; the full SPDP/port/reliability forgery remains for Carrier B / deployment realism (Phase 3). |
| Module 2 / Carrier B wrong-value injection | roadmap Phase 3 | **Not started.** Off-nominal *value* injection (a real off-nominal writer, then a fully hand-forged `VelocityReport` XCDR1 body) is Phase 3; the forge here is reused for Carrier B. |
| Live downstream safe-stop; Autoware-side reader QoS on the wire | roadmap Stage 2 | **Pending.** Whether the SEU's preemptive safe-stop actually fires end to end, and the Autoware speed readers' wire QoS, need live AWSIM + Autoware — Stage 2, not this report. |

Do not read any Stage-1 result above as a live-sim result: Phase 2 confirms the *mechanism and the
monitor-observable trace* on the harness, and nothing about the vehicle's reaction on live
AWSIM/Autoware.

---

## 8. Glossary by reference

The stack vocabulary this report uses — proxy writer, SPDP/SEDP, the builtin entity ids, dispose/
unregister, StatusInfo, RxO/durability, VOLATILE vs `transient_local`, WHC, GUID, freshness/age,
STL, safe-stop — is defined once in the [wiki glossary, §9], and this report uses those terms in that
sense rather than redefining them. Only three roles are genuinely new here, all specific to the
harness:

| Term | Definition |
|---|---|
| **`real_speed_monitor`** | Harness node standing in for AWSIM's velocity publisher: a RELIABLE + VOLATILE + KEEP_LAST(1) writer of `VelocityReport` on the mangled speed topic at 30 Hz, logging each `dds_write()` return so the fault's silence at the source is measurable. |
| **`trusting_consumer`** | Harness node standing in for a downstream speed consumer: a VOLATILE reader logging per-sample `(arrival time, source GUID, value, inter-arrival)` with a freshness watchdog at `Δ_fresh = 165 ms` — the trace tap the monitor evaluates. |
| **`injector_presence`** | The hybrid carrier: a real but endpoint-less Cyclone participant whose only purpose is to be discovered, so its already-matched builtin SEDP writer `0x3c2` carries the single hand-forged dispose DATA — sidestepping a from-scratch discovery forgery. |

---

*Provenance.* Primary result and evidence: `reports/poc-phase2-report.md`. Plan and staging:
`reports/poc-roadmap.md`. Target facts (topic/type/QoS/GUID, name-only discovery): `reports/poc-recon.md`.
Static derivation and style model: `reports/wiki.md` (§4/§4.3, §7.1, §8, §10). Harness workspace:
`poc-harness/` (`src/*.c`, `idl/VelocityReport.idl`, `inject/forge_withdraw.py`, `run_module1.sh`,
`evidence/`).

<!-- REPORT-COMPLETE -->
