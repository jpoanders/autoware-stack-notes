```
<role>
You are conducting a FULL REVISION SWEEP over an existing source-code research study. The study was
written under a wrong premise: it assumed the "SEU" it feeds is a *Security* Enforcement Unit — a
network guard that detects and blocks adversarial faults. That premise is now corrected. The SEU is a
SAFETY ENFORCEMENT UNIT: a lightweight, event-driven runtime-verification monitor that derives
temporal constraints from data dependencies, formalizes them as Signal Temporal Logic (STL)
properties, evaluates system traces against them, and executes preemptive safe-stops when a critical
temporal or freshness constraint is violated.

Your job is NOT to re-derive the Cyclone DDS stack from scratch. The low-level mechanism findings in
this study (the publish path, WHC back-pressure, the reorder buffer, transient_local durability
matching, discovery latency, QoS compatibility) are still correct and still load-bearing — they are
exactly the wire behavior that determines whether a temporal/freshness constraint can be met or
violated. Your job is to REFRAME the study around the safety/STL purpose: keep the verified
mechanism, replace the security narrative, and re-point every conclusion at what the mechanism means
for a runtime STL monitor and its safe-stop decision.

Revise files IN PLACE, in dependency order, honoring the runner's completion/resume markers exactly
(see <sweep_contract>). Preserve every `path:line` citation that is still accurate; rewrite the
framing, the motivation, and the closing implications.
</role>

<the_corrected_north_star>
The SEU the whole study feeds is defined by this abstract (unpublished; cite as `[LSEU-abstract]`
when you invoke its claims, and NEVER present its experimental numbers as something this static study
measured):

  "Modern Cyber-Physical Systems (CPS), such as Autonomous Vehicles (AVs), rely on the timely
  processing and exchange of data among components to drive decision-making and actuation. These data
  relationships establish critical temporal constraints that are primarily determined by actuation
  frequency and data freshness. This paper adopts a data-centric abstraction of publish-subscribe CPS
  to automatically derive temporal constraints from data dependencies and formalize them as Signal
  Temporal Logic properties for runtime verification. To support this verification process, we
  introduce the Safety Enforcement Unit (SEU), a lightweight, event-driven monitoring unit that
  captures and evaluates system traces. Because the formal properties are automatically derived, this
  mechanism can be deployed without requiring manually crafting logical expressions or prior training
  in formal methods. We evaluate the proposed approach through a Hardware-in-the-Loop AV case study
  and rigorous baseline on a resource-constrained multicore RISC-V architecture executing
  mixed-criticality workloads. Experimental results demonstrate that the SEU actively prevents
  accidents by executing preemptive safe-stops during critical faults, all while consuming less than
  2% of the processing capacity of the cores and inducing negligible interference on real-time tasks.
  Furthermore, under extreme fault-injection stress tests, including 100x network over-publication
  scenarios demonstrated the linear complexity of the verification algorithms in realistic settings."

The pipeline the study now serves, end to end:

  data-centric pub/sub abstraction
    → temporal constraints derived from data dependencies (actuation frequency + data freshness)
    → STL properties for runtime verification
    → event-driven capture and evaluation of system traces
    → preemptive safe-stop on a critical violation

Everything the study documents about Cyclone DDS is now in service of ONE question: where do these
temporal/freshness properties come from in the real stack, and how can the wire behavior satisfy,
degrade, or violate them — so a trace monitor can observe the violation and decide whether to
safe-stop. The deployment target is a resource-constrained multicore RISC-V running mixed-criticality
workloads; timing determinism and interference therefore matter (this is where the Task 5 / QoS
material now lands).
</the_corrected_north_star>

<what_is_preserved>
Do NOT weaken or discard any of this; it survives the reframe intact:

- Every `[code]` finding cited as `path:line` against the in-checkout sources
  (`src/cyclonedds`, `src/rmw_cyclonedds`, `rclcpp`, `rcl`, `rmw`, the `*_msgs`). If a citation is
  still accurate, keep it verbatim.
- THE VENDOR IS ECLIPSE CYCLONE DDS, NEVER FAST DDS. This does not change. Do not let the reframe
  reintroduce any FastRTPS assumption.
- The layer model: `rclcpp → rcl → rmw → rmw_cyclonedds_cpp → Cyclone ddsi → RTPS on the wire`.
- The publish path (`publish → dds_write → write_sample_eot (++seq) → nn_xpack_send`), delivery
  matching (topic-name mangling `rt<name>`, type name `<ns>::dds_::<Name>_`, the RxO/durability rule
  where a transient_local reader won't match a default VOLATILE writer — `q_qosmatch.c:167`),
  discovery (SPDP `0x100c2` / SEDP `0x3c2`,`0x4c2`, ports base 7400/dg 250 on domain 0), the reorder
  buffer, and WHC flow-control (`WhcHigh` 500 kB back-pressure).
- The two grounding topics, both `transient_local`: `/system/operation_mode/state` and
  `/control/command/gear_cmd`. Also `/clock` (~90–100 Hz) — which becomes newly important, because
  actuation frequency and freshness are measured against sim time.
- The authoritative runtime configuration lives in `prompts/autoware-core-awsim-setup-guide.md`; cite
  it as `setup-guide §N`. THE SIMULATION STILL CANNOT BE RUN — this remains a static source study.
- The evidence tags `[code]` / `[spec]` / `[INFERRED]` / `[UNVERIFIED]`, with the same discipline:
  wire/QoS/discovery claims verifiable in-checkout are `[code]`, not `[UNVERIFIED]`; RTPS byte-layout
  is `[spec]`; anything needing a running sim or packet capture is `[UNVERIFIED]`.
- Add one tag for this revision: `[LSEU-abstract]` for any claim, number, or definition that comes
  from the abstract above rather than from the source tree.
</what_is_preserved>

<what_changes>
Replace, throughout every file, the security spine with the safety/STL spine:

- REMOVE the "attacks vs. enforcement actions" dual-use frame as the organizing idea. Injection and
  replay are no longer "attacks the SEU must detect"; they are FAULT-INJECTION MECHANISMS used to
  drive off-nominal timing/value traces INTO the system so the STL monitor can be exercised and its
  safe-stop path validated (this matches the abstract's "extreme fault-injection stress tests").
- REPLACE every closing "what it means for the SEU" block (the old "observable signature to detect /
  lever to enforce") with the new closing block defined in <the_new_closing_block>.
- RECAST the 00-index "threat model" as a SAFETY / TEMPORAL-CONSTRAINT model: the topology stands in
  for a real AV network whose data dependencies impose temporal constraints; the index's central
  artifact becomes a **catalog of the temporal/freshness (STL-shaped) properties** the study surfaces,
  cross-referenced to the mechanism that establishes each one, not a catalog of attacks.
- DEMOTE, do not delete, genuinely adversarial observations: if a timing/freshness fault can also be
  induced maliciously, that is at most a one-line footnote; it is no longer the point.
- Do NOT fabricate Hardware-in-the-Loop measurements. The abstract's `<2% CPU`, `negligible
  interference`, `linear complexity`, `100x over-publication` are motivation and target behavior,
  cited `[LSEU-abstract]` — this static study does not reproduce them. STL properties you derive from
  the code's timing behavior are `[INFERRED]` from mechanism, never "measured."
</what_changes>

<the_task_reframe_map>
Keep the five-task skeleton and the foundation; recast each around a timing/freshness fault class and
its STL angle. For each file, preserve valid mechanism prose and citations; rewrite the motivation
(motivation-before-mechanism) and the closing block.

- FOUNDATION — add, above the existing stack material, the data-centric layer of the new north star:
  data dependency → temporal constraint (actuation frequency + freshness) → STL property → trace
  event → safe-stop. Re-point the existing DEEP/MEDIUM/MENTION ranking at "how much each task informs
  the STL monitor." Everything downstream still reuses the foundation BY REFERENCE.

- TASK 1 (element shutdown) → LIVENESS / FRESHNESS LOSS. A source going silent is the strongest
  freshness violation and the archetypal critical fault that should trigger a safe-stop. Explain from
  the code how absence manifests and how fast it is observable (deadline/liveliness, transient_local
  last-sample latching that can MASK staleness — a latched transient_local sample makes a dead
  publisher look alive to a naive reader; this is a first-class hazard for a freshness monitor).

- TASK 2 (third-party injection) → THE FAULT-INJECTION HARNESS. This is how off-nominal traces
  (early/late/stale/wrong-value samples) are introduced to EXERCISE the monitor, not an attack. Keep
  the Cyclone-compatible injector mechanics; frame them as the study's test instrument.

- TASK 3 (replay / over-publication) → FLAGSHIP. This is the abstract's "100x network
  over-publication" stress case: an actuation-frequency constraint violated, and the verifier's
  claimed linear complexity under that load. Tie the wire mechanism (WHC back-pressure, sequence
  numbers, reorder) to what the monitor sees and to why evaluation stays linear `[LSEU-abstract]`.

- TASK 4 (disable at three layers) → SILENT FRESHNESS LOSS + SAFE-STOP ACTUATION. The three layers
  are both (a) ways data freshness is lost without a clean shutdown signal — the hardest case for a
  monitor — and (b) candidate mechanisms by which a safe-stop could actually halt a data flow.

- TASK 5 (QoS prioritization) → TIMING DETERMINISM & MIXED-CRITICALITY. Whether the temporal
  constraints can be met on the wire at all: how Cyclone QoS (deadline, latency budget, priority,
  history/WHC) shapes latency and jitter, and what that implies for running the monitor on a
  resource-constrained multicore RISC-V without disturbing real-time tasks `[LSEU-abstract]`.
</the_task_reframe_map>

<the_new_closing_block>
Every mechanism section — and every report — ends by translating the mechanism into monitor terms.
Replace the old "SEU implication" with exactly these three points, drawn from the mechanism you found:

1. THE PROPERTY. The temporal or freshness constraint the mechanism implies, written STL-shaped over
   the real topics. Use concrete bounds where the code/config gives them and mark derived bounds
   `[INFERRED]`. Examples of the shape (illustrative, not prescriptive):
     - freshness:   `G( age(/control/command/gear_cmd) <= Δ_fresh )`
     - liveness:    `G( pub(/system/operation_mode/state) → F_[0,Δ_deadline] pub(...) )`
     - rate bound:  `G( inter_arrival(topic) ∈ [1/f_max, 1/f_min] )`
2. THE TRACE EVENT. What the event-driven monitor actually observes to evaluate that property — the
   observable at the layer the SEU taps (e.g. a sample's arrival timestamp and sequence number, a
   missed deadline, a WHC stall) — and at which layer it is visible.
3. THE SAFE-STOP DECISION. Whether a violation of this property is critical enough to trigger a
   preemptive safe-stop, or is a degradation to log/flag — and why, given the topic's role in
   actuation.
</the_new_closing_block>

<sweep_contract>
Revise the corpus IN PLACE, in this dependency order (same order the runner uses):

  foundation → task-1 → task-2 → task-5 → task-3 → task-4 → 00-index → wiki → wiki_summary → summary

Files, all under the repo root:
  reports/foundation.md
  reports/task-1-report.md, task-2-report.md, task-5-report.md, task-3-report.md, task-4-report.md
  reports/00-index.md
  reports/wiki.md               (the ~1060-line source-of-record narrative; reframe, keep citations)
  reports/wiki_summary.md       (condensed quick-read; keep it consistent with the revised wiki)
  source-code-study-summary.md  (top-level English summary; rewrite its premise to the safety SEU)

Marker discipline — DO NOT BREAK THE RUNNER:
- The original files ended with `<!-- REPORT-COMPLETE -->` (meaning "generation finished," NOT
  "revision finished"); the runner strips that marker before you start, so the file you receive has NO
  trailing completion marker. Leave the tail clean until you are truly done — do NOT stamp a
  completion marker as an early or first step.
- A file is "done" for THIS sweep only when its final line is exactly
  `<!-- SAFETY-REVISION-COMPLETE -->`, AND the file genuinely carries the safety/STL framing (a marker
  over unchanged security-framed text is a no-op and will be rejected). Append that line ONLY as your
  very last action, once the whole file has been reframed.
- If you must stop early (context/budget), do NOT write the completion marker; instead append a single
  final line `<!-- RESUME: <what remains — name the section/heading through which the reframe reached,
  and what is still in the OLD security framing below it> -->`.
- On a continuation run, a file may already hold a PARTIAL revision (top reframed, lower sections still
  in the old framing). Read it to find how far the reframe reached; if the last line is a
  `<!-- RESUME: ... -->` comment, follow it and delete that one line, then continue reframing the
  still-original sections below. Never re-reframe a section already done, and never restart a file.
- If a file already ends with `<!-- SAFETY-REVISION-COMPLETE -->`, it is done — do not touch it.
- Because you are editing existing prose (not generating fresh), prefer targeted edits: keep intact
  paragraphs and their citations, and rewrite only the framing sentences, the motivation, and the
  closing blocks. Do not gratuitously reflow text that is already correct.

OUT OF SCOPE for this sweep (list them at the end of the 00-index revision as explicit follow-on work,
do not touch them here): the `teach/` course, the `awsim-seu-poc-roadmap` memory and `poc-recon.md`
(the attacker-PoC line needs its own safety reframe), CLAUDE.md, the master five-tasks prompt, and
`run-study.sh`.
</sweep_contract>

<quality_floor>
- Motivation before mechanism; a concrete worked example against a real topic before the general rule.
- Every non-obvious behavioral claim still grounded `path:line`. A reframe that drops a citation is a
  regression.
- Do not re-derive the stack in each file; reuse the foundation by reference.
- No fabricated measurements. The abstract is context (`[LSEU-abstract]`); the sim is not run.
- When you finish a file cleanly, its last line is `<!-- SAFETY-REVISION-COMPLETE -->` (having first
  removed the old `<!-- REPORT-COMPLETE -->` line).
</quality_floor>
```
