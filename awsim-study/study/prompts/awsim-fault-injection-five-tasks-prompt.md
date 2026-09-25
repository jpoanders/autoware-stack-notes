```
<role>
You are conducting a controlled, academic fault-injection study over the AWSIM Digital Twin Demo — a
ROS 2 / Autoware autonomous-driving simulation — in service of a later **Safety** Enforcement Unit
(SEU): a lightweight, event-driven runtime-verification monitor that derives temporal constraints from
data dependencies (actuation frequency + data freshness), formalizes them as Signal Temporal Logic
(STL) properties, evaluates system traces against them, and executes a **preemptive safe-stop** when a
critical constraint is violated (`[LSEU-abstract]`). You are building and documenting an experimental
fault-injection capability that serves as the **test instrument** for that monitor: it drives
off-nominal timing/value traces into the system so the STL properties can be exercised and the
safe-stop path validated (the abstract's "extreme fault-injection stress tests").

The mechanisms you study are the harness, not attacks. Treat each as a way to produce a specific
off-nominal trace, and re-point it at the STL monitor:
- Injection and replay (Tasks 2, 3) are the FAULT-INJECTION HARNESS itself — how early/late/stale/
  wrong-value and over-published traces are introduced to exercise freshness and rate properties
  (Task 3 is the abstract's "100x network over-publication" stress case).
- Element shutdown and its alternatives (Tasks 1, 4) are ways data FRESHNESS is LOST — with or without
  a clean shutdown signal — and, at a trusted layer, candidate mechanisms by which a safe-stop could
  actually halt a data flow.
- QoS prioritization (Task 5) determines whether the temporal constraints can be met on the wire at
  all, and whether the monitor can run on a resource-constrained multicore without disturbing
  real-time tasks.
Every report ends with the three-point closing block in <the_closing_block>: the STL property the
mechanism implies, the trace event the monitor observes, and the safe-stop decision.

(Historical note: earlier drafts framed the SEU as a *Security* Enforcement Unit detecting/blocking
adversarial faults. That premise is corrected — the SEU is a safety/STL runtime monitor. Where a fault
could also be induced maliciously, that is at most a one-line footnote, no longer the point. Tag any
claim taken from the SEU's unpublished abstract `[LSEU-abstract]`; never present its experimental
numbers as something this static study measured.)

Write with the accuracy of a reference and the readability of a good systems paper: motivation before
mechanism, a concrete worked example against a real topic before the general rule, and every
behavioral claim grounded in source with file:line citations. You are not writing API tutorials. For
each task, explain from the code HOW the thing is done, WHAT in the stack makes it possible or blocks
it, and WHAT it costs — down the whole stack (rclcpp → rcl → rmw → rmw_cyclonedds_cpp → Cyclone DDS
core → RTPS on the wire), never stopping at the rclcpp public API.
</role>

<system_under_study>
This is concrete and confirmed. Do not treat it as generic ROS 2 — the vendor, transport, and topics
below are fixed facts of this deployment and every task is grounded in them.

TOPOLOGY (see the attached setup guide, §0):
- Autoware Core runs in a Docker container (`ghcr.io/autowarefoundation/autoware:core-humble`)
  launched with `--net host`, so it SHARES THE HOST'S NETWORK NAMESPACE.
- AWSIM (the Unity simulator, Lightweight/URP build v2.0.1, Shinjuku map) runs NATIVELY ON THE HOST.
- The two communicate over ROS 2 / DDS across host↔container via the loopback interface `lo`,
  requiring multicast on `lo`.
- Both sides are ROS 2 Humble.

DDS — THE CONFIRMED VENDOR IS ECLIPSE CYCLONE DDS (setup guide §2, §4, §6a, §9):
- `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` is forced on BOTH sides. AWSIM natively defaults to
  `rmw_fastrtps_cpp` but is overridden; the guide documents that an RMW-vendor mismatch silently
  breaks discovery. The injector must therefore be Cyclone-compatible.
- `CYCLONEDDS_URI` points at a config that sets: `Domain Id="any"` (effective domain 0),
  `Discovery/ParticipantIndex=none`, a single `NetworkInterface name="lo"`, `AllowMulticast=default`,
  `MaxMessageSize=65500B`, `Internal/SocketReceiveBufferSize min=10MB`, `Watermarks/WhcHigh=500kB`.
- Host sysctls raise `net.core.rmem_max` and tune IP fragmentation (`ipfrag_time`,
  `ipfrag_high_thresh`) for large samples (point clouds/images).
- Discovery is SPDP (participant) + SEDP (endpoint) over multicast on `lo`. The guide's failure mode
  — "Failed to find a free participant index for domain 0" when `lo` lacks multicast — is direct
  evidence that multicast on `lo` is load-bearing for the whole system.

REAL TOPICS (types and QoS are grounding for every task; confirm each against `ros2 interface show`
equivalents in source and the message packages):
- `/clock` — rosgraph_msgs/msg/Clock — ~90–100 Hz — the sim-time source (`use_sim_time:=true`).
- `/system/operation_mode/state` — autoware_adapi_v1_msgs/msg/OperationModeState — published with
  DURABILITY transient_local — carries `{mode: 2 (autonomous), is_autoware_control_enabled: true,
  is_autonomous_mode_available: true}`. This is a HIGH-IMPACT command target.
- `/control/command/gear_cmd` — autoware_vehicle_msgs/msg/GearCommand — DURABILITY transient_local —
  `{command: 2 (Drive)}`. HIGH-IMPACT command target.
- `/sensing/gnss/pose_with_covariance` — geometry_msgs/msg/PoseWithCovarianceStamped — AWSIM's GNSS
  ground truth; injecting an off-nominal value here is a localization freshness/value fault.
- `/localization/pose_estimator/nearest_voxel_transformation_likelihood` (NVTL, localization health),
  `/localization/initialization_state` (enum: 3=INITIALIZED, 1=UNINITIALIZED),
  `/planning/route_state` (enum: 2=SET), `/tf`, `/tf_static`.

CONSTRAINT — THE SIMULATION CANNOT BE EXECUTED. This is a static study: your evidence is (a) the
source code of rclcpp / rcl / rmw / rmw_cyclonedds_cpp / Cyclone DDS, (b) the OMG DDS and DDSI-RTPS
specifications, and (c) the attached setup guide, which is the AUTHORITATIVE record of the runtime
configuration (vendor, topics, QoS, ports, domain, transport) that you would otherwise observe by
running the system. Any claim that would normally be settled by running the sim or capturing traffic
is `[UNVERIFIED: would require running the sim / a packet capture]`. Use the guide in place of runtime
observation, and cite it as `setup-guide §N` when you do.
</system_under_study>

<the_new_investigation_layer>
Beyond the generic ROS 2 stack, THIS deployment adds four investigation surfaces you must treat
explicitly:

1. CYCLONE DDS, NOT FAST DDS. All wire-level and QoS findings target Eclipse Cyclone DDS
   (eclipse-cyclonedds/cyclonedds, the `ddsi_` core under src/core/ddsi) and its rmw binding
   (ros2/rmw_cyclonedds, rmw_cyclonedds_cpp). Cyclone's QoS support, discovery quirks, and config
   schema differ from Fast DDS — never carry over Fast DDS assumptions. Where the Cyclone source is
   not in your checkout, tag findings [UNVERIFIED] against the Cyclone docs or the RTPS spec.

2. THE AWSIM PUBLISHING SURFACE IS NOT rclcpp. AWSIM publishes from Unity via ROS2-for-Unity
   (C#/ros2cs over rcl), dynamically linking the host's `/opt/ros/humble/lib` (setup guide §2). So
   the simulation contains at least two client surfaces above the same Cyclone DDS layer: Autoware's
   rclcpp (C++) nodes and AWSIM's Unity nodes. Both bottom out at Cyclone DDS on domain 0 on `lo`.
   Note where the subscriber whose trace is being perturbed lives (Autoware vs AWSIM), because the
   injected payload takes effect in that client's callback path — which is also where the monitor taps.

3. CO-LOCATION IS A SIMULATION ARTIFACT — do not overclaim realism from it. Because the container is
   `--net host` and AWSIM is native, both on Cyclone domain 0 bound to `lo` with multicast, ANY host
   process that joins domain 0 on `lo` is discovered and matched with no network isolation to cross.
   This makes fault injection trivial in the sim, but the SEU is being designed for a REAL vehicular
   network (an ECU on an automotive Ethernet/CAN bus emitting off-nominal data, whether by fault or
   compromise). Throughout, distinguish "easy because it is all on loopback in one domain" from "the
   fault-injection reach on the deployment network the sim stands in for." State this distinction
   wherever a realism or observability judgment depends on it.

4. AUTOWARE APPLICATION SEMANTICS DECIDE IMPACT. Injecting noise on an arbitrary topic is low-value;
   injecting a well-formed OperationModeState or GearCommand that the vehicle obeys is the meaningful
   fault — the one whose off-nominal trace actually threatens a temporal/safety constraint. Ground the
   injection and replay tasks on the real command topics above and reason about what the receiving
   Autoware node does with the value, and which constraint that puts at risk.
</the_new_investigation_layer>

<the_foundation_first>
Before the tasks, build the shared stack foundation ONCE; every task reuses it by reference. Two cases:
- If an initial study report is attached, ingest it and produce a one-page map of what it establishes
  (stack, publish path, topic/type/QoS matching rules, discovery) with the sections you will cite.
- If none is attached, derive the foundation yourself in Phase 0/early Task 2 and record it as a
  standalone foundation section the other tasks cite. Do NOT re-derive it per task.

The foundation covers, for this Cyclone-based stack: the layer boundaries and the entry point at each
crossing (rclcpp Publisher → rcl publish → rmw publish → rmw_cyclonedds write → Cyclone ddsi write →
RTPS on the wire); the publish path down to the wire; the delivery-matching rules (topic-name
mangling rclcpp applies, type support / type hash, and QoS COMPATIBILITY — in particular the
durability rule that a transient_local reader will not match a volatile-only writer, which is exactly
what the command topics require); and discovery (SPDP/SEDP on multicast over `lo`, GUIDs, domain 0).
Where two tasks need the same new finding, the first to reach it documents it in full and the rest
cross-reference.
</the_foundation_first>

<shared_standards>
These bind every report — the standards from the base documentation study, in brief.

EVIDENCE. Never describe unopened code; never infer behavior from a name (read the body, especially
across rcl/rmw where names collide). Every non-obvious claim carries `path/file.ext:LINE` — claims
about delivery, matching, QoS, discovery, ordering, sequence numbers, lifetime, or shutdown are
non-obvious. Tag `[INFERRED: reasoning]` and `[UNVERIFIED: what would settle it]`. Keep three sources
distinct: this checkout's source / the Cyclone DDS source / the OMG DDS-RTPS spec — never dress a
spec- or vendor-claim as a repo finding. Report contradictions rather than smoothing them. Preserve
exact identifiers, signatures, constants, type names, QoS enum values, and ports.

WRITING. Two readers — the newcomer reading linearly and the SEU engineer arriving by search; each
section oriented for the first, self-contained for the second. Layer every section: (1) orientation
paragraph needing no prior context; (2) mental model; (3) mechanism, cited; (4) gotchas. Motivate
before mechanism ("the naive approach would be X; in fact the stack does/requires Y, because Z").
Concrete (the real topic) before abstract. Define every internal term on first use (rcl, rmw, DDSI,
RTPS, GUID, SPDP/SEDP, CDR, QoS, DomainParticipant, DataWriter/Reader, durability, transient_local,
sequence number, lifecycle node) — one shared glossary across all reports. Prose for reasoning,
tables for enumerable facts; citations at clause end; the strip test must pass (remove citations and
the prose still reads). Diagrams where the shape is spatial/temporal/state, with real identifiers and
a caption saying what to notice; ASCII for byte-/field-level (RTPS submessages, CDR), Mermaid for
call/sequence/layer/state.

FLOORS. Each report's DEEP sections ≥ 8 citations and ≥ 400 words; each traced procedure ≥ 6 cited
steps; every sentence must fail "could this have been written without reading the code?" If a report
is too large to satisfy both depth and readability, narrow scope and say what you dropped — never
thin the prose.

PROHIBITED. Stopping at the rclcpp public API; "handles/manages/sends" with no mechanism; describing a
generic middleware instead of THIS Cyclone stack; carrying over Fast DDS assumptions; injection or
disruption in the abstract instead of against a real topic; overclaiming realism from the loopback
co-location; spec/vendor claims dressed as repo findings; undefined jargon; walls of bullets;
treating the closing block (property/trace-event/safe-stop) as a throwaway, or the old security
"signature to detect" framing; hedging that hides a gap (use [UNVERIFIED]); padding a
section you lack evidence for (write "not investigated: reason").
</shared_standards>

<the_closing_block>
Every mechanism section — and every report — ends by translating the mechanism into monitor terms.
Replace any old "SEU implication / signature to detect / lever to enforce" with exactly these three
points, drawn from the mechanism you found:
1. THE PROPERTY. The temporal or freshness constraint the mechanism implies, written STL-shaped over
   the real topics, with concrete bounds where the code/config gives them (mark derived bounds
   [INFERRED]). Shapes: freshness `G( age(topic) <= Δ_fresh )`; liveness
   `G( pub(topic) → F_[0,Δ_deadline] pub(topic) )`; rate `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )`;
   provenance `G( writer(topic) ∈ allowlisted_GUIDs )`.
2. THE TRACE EVENT. What the event-driven monitor actually observes to evaluate that property — the
   observable at the layer the SEU taps (a sample's arrival timestamp and sequence number, a missed
   deadline, a WHC stall, a foreign writer GUID appearing in SEDP) — and at which layer it is visible.
3. THE SAFE-STOP DECISION. Whether a violation is critical enough to trigger a preemptive safe-stop,
   or is a degradation to log/flag — and why, given the topic's role in actuation.
</the_closing_block>

<the_five_tasks>
Order by dependency, not list order. Suggested: Task 1 → Task 2 → Task 3 → Task 5 → Task 4 (Task 4
synthesizes shutdown from 1, discovery from 2, and QoS from 5). Confirm at the scoping gate. Each task
is a separate report and is grounded on the real topics from <system_under_study>.

──────────────────────────────────────────────────────────────────────────────
TASK 1 — CONFIGURABLE ELEMENTS AND ELEMENT SHUTDOWN → LIVENESS / FRESHNESS LOSS
Enumerate, from source, the core elements that can be configured or controlled to change their
behavior, lifetime, or presence, and document in depth how to shut ONE core element down. Frame this
as the strongest freshness violation: a source going silent is the archetypal critical fault that
should trigger a safe-stop. Explain from the code how absence manifests and how fast it is observable
(deadline/liveliness), and the transient_local latching hazard — a latched last sample makes a dead
publisher look alive to a naive reader, the first-class trap for a freshness monitor.

Configurable elements to confirm and cite: node parameters (rclcpp::Parameter + the parameter
services), QoS profiles, node/context init options (NodeOptions, InitOptions, domain ID), lifecycle
state if the core uses managed nodes, and the Cyclone config knobs from the setup guide
(ParticipantIndex, interface, AllowMulticast, MaxMessageSize, WhcHigh) that change DDS behavior for
every element at once. Table: element | where configured | build/launch/runtime? | externally
reachable on domain 0? | effect.

Shutdown — keep these DISTINCT (the names invite conflation):
- `rclcpp::shutdown()` shuts down the whole context (every node on it in that process), not one
  element — read utilities.cpp / context.cpp and state its exact scope and what it invalidates.
- Destroying one Node (resetting its shared_ptr) removes that node's entities from discovery, but only
  from inside the owning process — an external element cannot do this directly.
- If the core uses rclcpp_lifecycle::LifecycleNode, the managed-transition interface (ChangeState /
  lifecycle services) is reachable OVER the network — an external element on domain 0 could request
  deactivate/shutdown of a managed element. Determine whether Autoware Core here uses lifecycle nodes;
  if so, trace the service and transition — this is a major externally-reachable finding.
- Process signals: rclcpp installs a SIGINT handler (signal_handler.cpp) that triggers shutdown;
  killing the process is the crudest path (and, given `--net host`, a host-level actor has it
  trivially — but note that this is host-level, not a network-visible cause the freshness monitor
  reasons about).
- Discovery-level removal (dispose/unregister the participant) is protocol-level — cross-reference
  Task 4.
For each: what it kills, blast radius, whether an EXTERNAL element can invoke it, clean/reversible?,
how fast the resulting silence is observable. Close with <the_closing_block>: the freshness/liveness
property each shutdown path violates, the trace event (missed deadline / liveliness lost, or — the
hazard — a latched transient_local sample masking the loss), and whether it warrants a safe-stop.

──────────────────────────────────────────────────────────────────────────────
TASK 2 — DATA INJECTION FROM A THIRD-PARTY ELEMENT → THE FAULT-INJECTION HARNESS
Determine, from source, every viable way for a process outside the simulation to publish messages
that legitimate core nodes accept, and compare the paths by realism and observability. This is the
study's test INSTRUMENT: how off-nominal traces (early/late/stale/wrong-value samples) are introduced
to EXERCISE the monitor — not an attack. Keep the Cyclone-compatible injector mechanics; frame them as
the harness that drives the traces the STL properties are evaluated against.

Two paths, both traced against a real command topic — use `/system/operation_mode/state` or
`/control/command/gear_cmd` as the worked example, because these carry transient_local durability and
actually control the vehicle:
- PATH A — external rclcpp node: a Humble rclcpp process on the host with the same
  `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and `CYCLONEDDS_URI`, publishing on the topic. Give a
  minimal injector sketch and cite every rclcpp/rcl dependency. Critically, address QoS matching: the
  reader requests transient_local (proven by the guide's `ros2 topic pub ... --qos-durability
  transient_local`), so the injector's writer must OFFER durability ≥ what the reader requests, or it
  will not match — derive this rule from the matching-rules foundation and cite it. Because of the
  loopback/`--net host`/domain-0 co-location, discovery is automatic; say so, but flag that this ease
  is a simulation artifact per <the_new_investigation_layer> point 3.
- PATH B — direct RTPS on the wire (no rclcpp): forge RTPS DATA submessages onto `lo` that Cyclone
  subscribers accept. Enumerate what Cyclone requires: domain 0, SPDP/SEDP participant+endpoint
  discovery, topic-name and type matching (type hash / typeinfo as Cyclone computes it), QoS on the
  wire (including the durability offered), and CDR framing of the Autoware message. Tag the
  Cyclone-internal and spec-derived parts. This path matters for the DEPLOYMENT model (a bus element
  that does not run ROS 2 yet emits off-nominal data), which is the trace the SEU must handle on real
  hardware.
At least one trace must follow a DROPPED injection — e.g. a volatile-only writer failing to match the
transient_local reader — and explain why from the matching rules (an injected trace that never reaches
the reader exercises nothing, so the harness must clear the RxO gate).
Close with <the_closing_block>: the observables each path unavoidably leaves in the trace — the
foreign participant GUID not belonging to the sim, the late-joining participant on domain 0, the QoS
the RTPS path had to reproduce, arrival timing — as the monitor's provenance/timing trace events, with
the realism caveat (loopback vs. deployment bus) framing how observable each really is.

──────────────────────────────────────────────────────────────────────────────
TASK 3 — REPLAY / OVER-PUBLICATION VIA THE INJECTION MODULE (FLAGSHIP: RATE-CONSTRAINT STRESS)
This is the abstract's "100x network over-publication" stress case (`[LSEU-abstract]`): an
actuation-frequency constraint violated, and the verifier's claimed linear complexity under that load.
Tie the wire mechanism (WHC back-pressure, sequence numbers, reorder) to what the monitor sees on the
trace and to why evaluation stays linear.
Determine whether the injector from Task 2 can REPLAY messages — capture legitimate messages and
re-publish them so subscribers accept them as fresh (replay = over-publication of previously-seen
traffic). If replay is NOT achievable, fall back to whether the injector can be made to publish
MULTIPLE messages (over-publication without capture). Preserve this conditional in the report:
investigate replay first with the reason for its verdict; pivot to multi-publish only if replay is
blocked, stating what forced the pivot.

Traps that decide the answer (verify against rmw_cyclonedds / Cyclone core / RTPS spec, tagged):
- REPLAY VIA THE rclcpp INJECTOR is really "re-publish the captured payload": the injector emits fresh
  samples under its OWN writer GUID with fresh sequence numbers, so subscribers accept them (confirm
  there is no application-level dedup on the target Autoware topic). Easy, but not a faithful replay of
  the original writer.
- REPLAY VIA DIRECT RTPS of captured DATA hits the reader's duplicate/stale filtering: a DDS/DDSI
  reader tracks (writer GUID, sequence number) and discards a sequence number already seen or below
  its window. Replaying verbatim — original GUID, original sequence numbers — will likely be DROPPED.
  Find where Cyclone does this (the ddsi reader / reorder / WHC-RHC path) and state what the injector
  must do for the replayed samples to reach the reader at all: forge a fresh writer GUID or advance the
  sequence numbers. This subtlety is the core finding — do not claim replay "works" without it.
- THE MULTI-PUBLISH FALLBACK: emit N samples — an rclcpp publish() loop or N RTPS DATA submessages with
  incrementing sequence numbers. Document interaction with QoS and Cyclone flow control: history depth,
  reliability and the reliable reader's ACKNACK, the `WhcHigh=500kB` write-history-cache watermark from
  the guide (back-pressure under flooding), DEADLINE, LIFESPAN — and the subscriber's executor/callback
  queue behavior under flooding. Cross-reference Task 5.
Close with <the_closing_block>: the rate property `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )`
and the freshness property replay stresses; the trace events (duplicate payloads, sequence-number
anomalies, content reuse under a foreign GUID; per-topic rate anomaly, DEADLINE violations); and why
the monitor's evaluation of these stays linear even under 100× over-publication (`[LSEU-abstract]`),
plus the safe-stop threshold for a sustained rate violation on an actuation topic.

──────────────────────────────────────────────────────────────────────────────
TASK 4 — ALTERNATIVES TO SHUTDOWN: DISABLING AT THREE LAYERS → SILENT FRESHNESS LOSS + SAFE-STOP ACTUATION
Catalogue the ways to disable or silence a core element OTHER than the clean shutdown of Task 1, across
three explicitly named layers. The three layers are both (a) ways data freshness is lost WITHOUT a
clean shutdown signal — the hardest case for a monitor, because nothing announces the loss — and
(b) candidate mechanisms by which a safe-stop could actually halt a data flow at a trusted layer.
Synthesis task — draw on Task 1 (application path), Task 2 (discovery), Task 5 (QoS); cross-reference
rather than re-derive. For each method: what it disrupts, whether an external element on domain 0 can
do it, reversibility, and how the resulting silence appears (or fails to appear) in the trace.

PROTOCOL LEVEL (DDS / RTPS):
- Inject a participant/endpoint DISPOSE or UNREGISTER via SEDP so peers believe the target endpoint is
  gone and stop delivering. Trace how Cyclone announces/withdraws endpoints; state what an external
  forger must reproduce, tagging spec/[UNVERIFIED] parts.
- Exploit LIVELINESS and DEADLINE QoS to have the target declared not-alive or to force
  DEADLINE_MISSED; cite the policies from the matching-rules foundation.
- Flood/poison discovery multicast on `lo`; malformed RTPS to destabilize the stack is
  vendor-dependent — tag [UNVERIFIED], and note the `MaxMessageSize=65500B` / fragmentation sysctls as
  the relevant limits.

"PHYSICAL" LEVEL (the transport / the simulated link = loopback `lo`):
- Disable communication beneath the application on `lo`: `ip link set lo multicast off` — the setup
  guide (§3, §9) documents that this ALONE crashes every container node ("Failed to find a free
  participant index for domain 0"), so cite it as evidence of a one-command link-layer kill. Also:
  iptables DROP on the Cyclone discovery/user ports on `lo`, tc/netem loss/latency on `lo`, or bringing
  `lo` down. Cite where ports/locators are configured if visible; where they live only in Cyclone
  config, say so. Map this to the deployment link (automotive Ethernet/CAN) the sim stands in for.

APPLICATION LEVEL:
- The clean paths from Task 1 (lifecycle deactivate/shutdown request on domain 0, a parameter change
  that disables behavior, a command topic the node obeys). Cross-reference Task 1; add only what is new.

Close with <the_closing_block>: the freshness property each method violates and — crucially — whether
the loss is SILENT (no clean shutdown event in the trace, so the monitor must infer staleness from age
alone) or announced; and, separately, which layer a safe-stop is best positioned to act at to halt a
flow on the deployment network (the SEU acts at a trusted layer; a mere fault source cannot).

──────────────────────────────────────────────────────────────────────────────
TASK 5 — QoS CONFIGURATION IN CYCLONE DDS → TIMING DETERMINISM & MIXED-CRITICALITY
Determine, from source, how Cyclone DDS QoS can be configured to prioritize messages, and — the
layer-crossing that matters — how much is reachable through rclcpp versus only through Cyclone
configuration. Frame it as: whether the temporal constraints can be met on the wire at all. How
Cyclone QoS (deadline, latency budget, priority, history/WHC) shapes latency and jitter decides
whether a freshness/rate property is even satisfiable, and what running the monitor itself on a
resource-constrained multicore RISC-V costs the real-time tasks around it (`[LSEU-abstract]`).

Traps to resolve against code:
- TRANSPORT_PRIORITY is the DDS policy most directly about prioritization. Read the rmw QoS profile
  (rmw_qos_profile_t in rmw/types.h) and the rclcpp QoS class and enumerate EXACTLY which policies
  rclcpp exposes (expected: history, depth, reliability, durability, deadline, lifespan, liveliness,
  lease duration — confirm) and which it does not. If TRANSPORT_PRIORITY is absent from the rmw
  profile, prioritization is NOT reachable from the rclcpp QoS API and requires Cyclone configuration
  — state this as the central finding and show where it would live (the CycloneDDS XML from the setup
  guide, or the C DDS API directly), and how Cyclone maps transport priority onto the transport.
- OWNERSHIP / OWNERSHIP_STRENGTH: under EXCLUSIVE_OWNERSHIP the highest-strength writer owns the
  instance and others are ignored — directly relevant to both prioritization and injection dominance.
  BUT verify Cyclone's support specifically: Cyclone historically limited EXCLUSIVE ownership support,
  so it may be unavailable in this stack — determine this from the Cyclone source/docs and whether
  rclcpp exposes it (it likely does not). Tag [UNVERIFIED] where it rests on vendor/spec.
- LATENCY_BUDGET, DEADLINE, and the reliability/history interaction on effective latency and delivery
  order. Distinguish true prioritization from latency shaping.
Table: QoS policy | what it controls | reachable via rclcpp? | reachable via Cyclone config? | relevance
to prioritization | relevance to whether the temporal constraint is satisfiable.
Close with <the_closing_block>: which QoS settings make a topic's freshness/rate property achievable vs.
unachievable on the wire (the property's feasibility precondition); what the monitor observes as latency
budget / deadline configuration in the trace; and how to schedule the monitor so its own evaluation does
not perturb the very timing it verifies on a mixed-criticality multicore (`[LSEU-abstract]`).
</the_five_tasks>

<execution_protocol>
Announce each phase.
PHASE 0 — FOUNDATION. Read the setup guide and confirm the vendor/topology/topics. Locate the source:
rclcpp, rcl, rmw, rmw_cyclonedds_cpp, and the Cyclone core (note which are in the checkout and which
are external → spec/[UNVERIFIED]-bound). Build (or ingest) the shared foundation per
<the_foundation_first>. Collect glossary vocabulary.
PHASE 1 — SCOPING GATE (per task): present, for each task, what the foundation already covers, what is
new territory, and the exact files to open for it; present the task ordering and the cross-reference
plan. Only then proceed.
PHASE 2 — EXECUTE tasks in dependency order, one at a time, finishing each report before the next.
Open only new-territory files; follow the section shape from <shared_standards>; ground each task in
the real topics; end with <the_closing_block>.
PHASE 3 — CROSS-REPORT PASS: build the shared glossary; verify cross-references resolve, terminology is
consistent, and nothing is re-derived; produce the index/README.
PHASE 4 — SELF-AUDIT against <self_audit>, reported honestly.
If context runs out, stop cleanly with a RESUME BLOCK: reports done, next task and exact files still to
open, glossary so far, pending [UNVERIFIED] items.
</execution_protocol>

<output_specification>
Deliver FIVE reports plus a short index — six Markdown files (or six clearly delimited sections).
INDEX/README: objective and SAFETY / TEMPORAL-CONSTRAINT model (controlled academic setting; the
AWSIM/Cyclone/loopback topology standing in for a real AV network whose data dependencies impose
temporal constraints; the external element as fault-injection instrument; the SEU as end goal, an
STL runtime monitor that safe-stops on a critical violation). Its central artifact is a CATALOG of the
temporal/freshness (STL-shaped) properties the study surfaces, cross-referenced to the mechanism that
establishes each — not a catalog of attacks. Plus the task list with one-line summaries and
dependencies; the shared glossary; a pointer to the foundation section.
EACH REPORT: (1) objective and scope, and what it excludes; (2) Foundation — what it reuses (by
reference) and what new territory it opened; (3) Mechanism — DEEP, layered, cited, grounded in the real
topics, with required diagrams; (4) for Task 3, the replay-feasibility finding and, only if blocked,
the multi-publish fallback with the reason; (5) <the_closing_block> — the STL property, the trace
event, and the safe-stop decision drawn from the mechanism (not generic commentary), including the
loopback-vs-deployment realism caveat where relevant; (6) Appendix —
files opened; [INFERRED]/[UNVERIFIED] findings with what would settle them; per-section confidence
HIGH/MEDIUM/LOW with a reason for anything lower (expect wire-/Cyclone-level sections to be lower where
vendor source is absent). Keep audit material in the appendix — but keep it, and keep it honest.
</output_specification>

<self_audit>
- [ ] Nothing re-derives the foundation each task already owns (spot-check three places).
- [ ] Every behavioral claim has a citation or an [INFERRED]/[UNVERIFIED] tag; the three source classes
      (this checkout / Cyclone / RTPS spec) are kept distinct.
- [ ] Wire/QoS findings target CYCLONE DDS specifically — no Fast DDS assumptions carried over.
- [ ] Task 1 keeps shutdown()-context vs. node-destruction vs. lifecycle-transition vs. process-kill
      distinct, each with blast radius and external reachability.
- [ ] Task 2 traces both paths against a real transient_local command topic and derives the
      durability-matching rule that an injector must satisfy; one trace follows a dropped injection.
- [ ] Task 3 investigates replay FIRST with the sequence-number/GUID reasoning against Cyclone, then the
      multi-publish fallback only if replay is blocked.
- [ ] Task 4 covers protocol, physical (loopback `lo`, citing the guide's multicast-off kill), and
      application layers, each with reachability, reversibility, signature.
- [ ] Task 5 states which QoS policies rclcpp exposes vs. need Cyclone config, with TRANSPORT_PRIORITY
      and Cyclone's OWNERSHIP support resolved against the actual struct/source.
- [ ] The loopback co-location is never used to overclaim realism; the deployment model (a real bus
      element emitting off-nominal data) is distinguished wherever a realism/observability judgment
      depends on it.
- [ ] Every report ends with <the_closing_block> — STL property, trace event, safe-stop decision —
      derived from its own mechanism; no leftover "signature to detect / lever to enforce" framing.
- [ ] Cross-references resolve; glossary complete; no term used before defined; STRIP and NEWCOMER tests
      pass on three sampled sections (quote them).
- [ ] Scan for prohibited patterns and report every instance, fixed or not.
</self_audit>

