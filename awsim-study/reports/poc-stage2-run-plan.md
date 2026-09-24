# Stage 2 run plan: driving the fault-injection harness against live AWSIM + Autoware

> Status of Stage 2 before this plan: **referenced, not planned.** The roadmap names it (Phase 0
> "Stage 2 bring-up", Phase 3/4 "on the live sim") and `poc-phase2-report.md §8` lists it under
> "Next", but no date, runbook, or go/no-go gates existed. This document is that plan. It does **not**
> run anything; it is the runbook a human executes on the lab PC (`ml-XPS-8960`), the only machine
> where the sim runs (`CLAUDE.md`; `lab-machine-setup.md`).

Evidence tags follow the study convention (`[code]`/`[spec]`/`[INFERRED]`/`[UNVERIFIED]`/`[runtime]`/
`[LSEU-abstract]`). A `[runtime]` line records the command, the date, and what was running
(`poc-recon.md` addendum). Everything below that has not happened yet is a *planned* observation, not
a `[runtime]` claim.

## 1. Why Stage 2 exists (what only the live sim can settle)

Every fault-path verdict the study holds on the speed channel is either static (`[code]`/`[spec]`/
`[INFERRED]`) or, since Phase 2, `[runtime]` **on a Stage-1 loopback harness of three co-located
Cyclone participants** — not on AWSIM/Autoware (`poc-phase2-report.md`). Stage-1 co-location on `lo`
is a simulation artifact: it validates the *mechanism* and the *monitor-observable trace*, but not the
live vehicle reaction. Only Stage 2 can show three things the harness cannot:

1. that the forged withdrawal deletes the **real AWSIM speed writer's** proxy inside a **real Autoware
   consumer** (localization/control), not a stand-in `trusting_consumer`;
2. the **downstream safe-stop reaction** — what the driving stack actually does when the speed signal
   goes stale or carries an injected value (the accident the SEU's preemptive safe-stop is meant to
   prevent, `[LSEU-abstract]`);
3. the still-`[UNVERIFIED]` deployment facts: the **Autoware-side reader QoS + participant prefix on
   the wire** and whether **DDS-Security** is compiled into the `autoware:core-humble` image
   (`poc-phase2-report.md §7`; wiki §10).

## 2. Blockers to clear before any live injection (go/no-go)

| # | Blocker | Current state | Clearance |
|---|---|---|---|
| B1 | Full Autoware stack never launched here | AWSIM host + host↔container bridge only (`lab-machine-setup.md §5`) | Run setup-guide §6c–§8: launch `autoware_core`, set pose, set goal, engage autonomous |
| B2 | No wire capture without root | `tshark`/`dumpcap` absent; `tcpdump` no caps (`lab-machine-setup.md §5`) | Observe via a **co-resident Cyclone monitor participant + Cyclone tracing** (as Phase 2 did), and ROS 2 topic tools; OR a `--net host --cap-add=NET_ADMIN` capture container if an admin allows it |
| B3 | Snapshot / one-command restart | Not established | Snapshot the box (or scripted restart of AWSIM + container) **before** the first injection; verify clean re-announce restores freshness |
| B4 | Module 2 not built | Only Module 1 validated (Stage 1) | Build Phase 3 Carrier A before milestone S2-2; Module 1 (S2-1) does **not** need it |
| B5 | Live speed-writer GUID is ephemeral | One capture exists (`…:1303`, `poc-recon.md`) | Re-capture the live writer GUID at the start of **every** run session; never reuse a stale GUID (blast-radius risk, roadmap "Risks") |

## 3. Milestones (each with its own go/no-go gate)

### S2-0 — Full-stack bring-up + observability + snapshot (prerequisite)
**Objective:** get an engaged, driving ego and a working way to see the wire, safely reversible.
**Steps (grounded in `lab-machine-setup.md §3` and `setup-guide §6c–§8`):**
1. `hostname` → must be `ml-XPS-8960`. Confirm `lo` shows `MULTICAST` (`ip link show lo`).
2. Terminal 1: launch AWSIM (`lab-machine-setup.md §3`), ROS 2 sourced.
3. Terminal 2: launch the Autoware Core container and `autoware_core.launch.xml` (setup-guide §6c).
4. RViz: set the GNSS/initial pose, check NVTL, set a goal, **engage autonomous mode** (setup-guide §7–8).
5. Stand up the observability route (B2): a small Cyclone monitor participant on domain 0 with tracing,
   plus `ros2 topic hz /vehicle/status/velocity_status` and `ros2 topic info -v` for QoS.
6. Snapshot / confirm one-command restart (B3).
**Success:** ego drives autonomously; velocity topic ticks at its nominal rate; the monitor sees the
AWSIM speed writer's GUID and its DATA on the wire; restart restores a clean run.
**Records to capture (`[runtime]`, dated):** Autoware-side reader QoS + participant prefix on the
velocity topic (settles a wiki §10 row); presence/absence of DDS-Security handshake traffic (B / §10).

### S2-1 — Module 1 live: silent freshness-loss on the real speed channel (**first true live-sim run**)
**Objective:** reproduce the Phase-2 mechanism against the real AWSIM writer and a real Autoware
consumer, and watch the downstream reaction. This is the near-term target; it is unblocked once S2-0
passes (does not need Module 2).
**Steps:** re-capture the live speed-writer GUID (B5); run the Phase-2 forge (`poc-harness/`,
`inject/forge_withdraw.py`) with the hybrid carrier — a real participant for discovery/reliability +
one hand-forged keyed SEDP `DISPOSE|UNREGISTER` naming that GUID; emit one, HEARTBEAT-preceded.
**Success / observables:**
- the AWSIM writer keeps publishing (its DATA still on the wire, source oblivious) — the silent case;
- the Autoware consumer's proxy for that GUID is deleted and it stops receiving — `age(topic)` diverges
  past the nominal inter-arrival, the archetypal freshness-monitor trigger;
- **the driving stack's reaction is recorded** (does control degrade / does anything safe-stop today,
  absent the SEU?). This is the Stage-2-only observation.
**Watch:** SEDP re-announce (lease renewal) can re-create the proxy and restore freshness — re-emit or
note the dispose/re-announce flap (roadmap Phase 4 note).

### S2-2 — Module 2 live: wrong-value / stale-value injection (needs B4)
Carrier A (a real VOLATILE ROS/Cyclone writer publishing off-nominal `longitudinal_velocity`), then
Carrier B (fully hand-forged `VelocityReport` XCDR1 body). Observe whether the consumer evaluates the
injected value. **Precondition:** Phase 3 Carrier A built and validated on the Stage-1 harness first.

### S2-3 — Phase 4 live: combined silence-then-inject + end-to-end safe-stop
Silence the real writer (S2-1) then inject an off-nominal value on the same topic (S2-2): the trace
shows the real GUID going stale immediately followed by a foreign writer on the topic — the correlated,
high-severity pattern. **Confirm the SEU's preemptive safe-stop actually fires** (or, absent the SEU,
that the speed-driven behavior would follow the injected value — the accident to prevent). This closes
the STL closing block empirically end-to-end (wiki §8).

### S2-4 — Module 3 (FI1) live: data-age / stuck-sensor injection
Reuses Module 2 Carrier A (a real VOLATILE writer) but injects **old data with new timestamps** — a
stuck value at 1×/2×/10× (`poc-harness/fi1_stuck_sensor`, `run_fi1.sh --live`). **Bench (Step 0)
already validated** on `ml-XPS-8960` (2026-09-24): the fresh-stamp stuck sensor is invisible to the
arrival watchdog and to `header.stamp` freshness, caught only by the value-age property P_stuck;
back-dated stamps trip P_age; 2×/10× trip P_rate (consumer-side deadline, not writer WHC stall on this
small-payload topic). See [`fi1-data-age-report.md`](fi1-data-age-report.md). Live steps: coexist, then
silence-then-inject (chain S2-1's dispose), rate sweep, back-dated variant; record the stack reaction.
**Precondition:** same as S2-2 (Carrier A built — done) plus S2-0.

## 4. Proposed sequencing and "when"

The calendar date is a **human/logistics decision** — it needs a booked block on `ml-XPS-8960` with
no other lab users, because engaging autonomous mode and injecting faults is disruptive and the box is
shared and snapshot-gated. Recommended ordering, each gated on the prior passing:

1. **Session A — S2-0** (bring-up + observability + snapshot). ~half a day; the real unknown is how
   cleanly §6c–§8 come up first time. This is the single most valuable next step and unblocks everything.
2. **Session B — S2-1** (Module 1 live). Short once S2-0 holds; the mechanism is already validated.
   This is the milestone the user's question is really asking about — the first fault driven into the
   real sim.
3. **Build Phase 3 Carrier A** off-sim (portable), then **Session C — S2-2**.
4. **Session D — S2-3** (combined + safe-stop), the capstone.

Do **not** collapse these into one sitting: S2-0's bring-up risk and S2-1's blast radius each deserve
their own clean snapshot and go/no-go.

## 5. What Stage 2 will settle (mapping to open items)

- Autoware-side reader QoS + participant prefix on the wire — **wiki §10 / `poc-recon.md` deferred row**
  → settled in S2-0.
- DDS-Security compiled into the image — **wiki §10 / `poc-phase2-report.md §7` "Untouched"** → settled
  in S2-0 (handshake traffic present or not) and confirmed under injection in S2-1.
- Live downstream safe-stop reaction — the Stage-2-only item flagged throughout Phase 2 → S2-1 (partial,
  freshness) and S2-3 (full, combined).
- Full from-scratch SPDP forge without a real carrier — **still deferred**; Carrier B in S2-2 approaches
  it, but the plan keeps the hybrid carrier for S2-1 exactly as Phase 2 did.

## 6. Safety and rollback (non-negotiable, from roadmap "Risks")

Run authorized and isolated on the lab bench only; **snapshot before injecting**; keep a one-command
restart of AWSIM + the container; derive the target GUID only from a fresh capture (a mistyped GUID
disposes the wrong proxy or no-ops); the dispose is one-shot, so rollback = stop the injector and
restart the affected publisher/node (or the sim) to force clean re-announcement.
