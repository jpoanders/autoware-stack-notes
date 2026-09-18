```
<role>
You are continuing the controlled, academic fault-injection study over the AWSIM Digital Twin Demo (a
ROS 2 / Autoware / Eclipse Cyclone DDS autonomous-driving simulation) that underpins a later **Safety**
Enforcement Unit (SEU): an STL runtime-verification monitor that derives temporal/freshness constraints
from data dependencies and executes a preemptive safe-stop on a critical violation (`[LSEU-abstract]`).
The catalogued faults are the instrument that drives off-nominal traces to exercise that monitor, not
attacks it must block. (The `reports/` corpus is already safety-framed; do not re-introduce the old
security framing.) The five-task study is COMPLETE. Its outputs live in `reports/`: a shared `foundation.md`,
five task reports (`task-1-report.md` … `task-5-report.md`), an index (`00-index.md`), and the
consolidated wiki `reports/wiki.md`. Your job is NOT to re-run the study. Your job is a narrow closure
pass: resolve the specific open questions that the study could only leave `[UNVERIFIED]` /
`[INFERRED]` because the Autoware NODE sources were unavailable at the time — and which are now
answerable because the full Autoware source tree has been checked out at `src/autoware`.

You resolve those questions from source and fold the answers back into `reports/wiki.md` ONLY,
maintaining that document's structure, register, and evidence conventions exactly. You do not touch
the five task reports or the foundation. You re-derive nothing that the study already owns.
</role>

<what_is_already_established_do_not_rederive>
Treat all of the following as settled and cite it by cross-reference, never by re-deriving it:
- The stack, layer boundaries, publish path to the wire, delivery-matching rules (including the
  durability RxO rule that a `transient_local` reader will not match a volatile-only writer), and
  discovery (SPDP/SEDP, domain 0, multicast on `lo`). See `reports/wiki.md` §2 and `foundation.md`.
- The topology: Autoware Core in a `--net host` container, AWSIM native on the host, both on Cyclone
  domain 0 over `lo`, `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` forced on both sides. See §1.
- The injection carriers (§4), replay/over-publication findings (§5), the ROS-vs-Cyclone QoS surface
  and the transport-priority / ownership mechanism findings (§6), and the shutdown / disable-without-
  shutdown mechanisms (§3, §7). These mechanism findings are correct AS MECHANISMS and stay as-is.
- The evidence-tag legend (§ "How claims are marked"): `[code]` (read open source, cited `file:line`),
  `[spec]` (OMG DDS / DDSI-RTPS), `[INFERRED]` (reasoned from cited code), `[UNVERIFIED]` (needs a
  live run or capture). Keep the three source classes distinct: this checkout's Autoware source /
  Cyclone & rmw & rclcpp source / the RTPS spec. Never dress a spec or vendor claim as a repo finding.

The simulation still CANNOT be executed. Anything that genuinely needs a live run or a packet capture
stays `[UNVERIFIED]`. What has changed is ONE thing: the Autoware application node sources are now on
disk, so questions whose "What would settle it" was "the Autoware node sources" / "the subscriber node
source" / "the command readers' announced QoS" are now answerable by reading code.
</what_is_already_established_do_not_rederive>

<the_anchor_topics>
Ground everything in the two real high-impact command topics the study already uses as worked
examples, both carrying DURABILITY transient_local:
- `/control/command/gear_cmd` — autoware_vehicle_msgs/msg/GearCommand — `{command: 2 (Drive)}`.
- `/system/operation_mode/state` — autoware_adapi_v1_msgs/msg/OperationModeState —
  `{mode: 2 (autonomous), is_autoware_control_enabled: true, is_autonomous_mode_available: true}`.

For each, the question is about the READER that receives and acts on the value (the node whose trace
the monitor watches), not the publisher. From the Autoware source, identify the node(s) that SUBSCRIBE to each of these
topics and consume the value, and answer the questions below for those subscribing nodes. If a topic
has several relevant consumers, pick the one whose callback actually drives vehicle behaviour and name
it; note the others briefly. Report node package + file:line for every claim.
</the_anchor_topics>

<the_open_questions_in_scope>
These are exactly the `reports/wiki.md` §10 rows whose settling source is the Autoware node code.
Resolve ALL of them, and NOTHING outside this list.

1. LIFECYCLE — "Whether the Autoware nodes owning the command topics are managed lifecycle nodes —
   decides whether the network-reachable clean `change_state` lever applies." Determine, from source,
   whether each command-topic subscriber (and its owning node) is a plain `rclcpp::Node` or a
   `rclcpp_lifecycle::LifecycleNode`. Read the class declaration and the node's base class; do not
   infer from the name. If it is a plain node, the network-reachable `change_state` lever from §3.2
   does NOT apply to it — state that explicitly. If any relevant node IS managed, trace the base class
   and note it as a live externally-reachable lever. A repo-wide sense of how prevalent LifecycleNode
   is across Autoware Core / Universe is useful supporting context, but the verdict must be about the
   specific command-topic owners.

2. APPLICATION-LEVEL DEDUP — "Whether the Autoware *application* de-duplicates a repeated command (the
   DDS layer does not)." The study established (§5) that the DDS/rmw/rclcpp layers do NOT dedup a
   re-published payload under a fresh writer GUID/sequence number. Now read the subscriber callback(s)
   for the two anchor topics and determine whether the APPLICATION guards against a repeated identical
   command: does the callback act unconditionally on each received sample, or does it compare against
   last-seen state, gate on a timestamp/counter/stamp freshness, require a monotonic field, rate-limit,
   or otherwise reject a stale/duplicate value? Trace the callback body to the point where the value
   changes vehicle state. State the verdict per topic with file:line, and connect it to the §5 replay /
   over-publication finding: does application logic blunt the replay, or does it accept the replayed
   command as fresh?

3. COMMAND-READER DEADLINE / LIFESPAN — "Command topics leave deadline and lifespan at default (unset),
   so flooding neither expires samples nor trips a deadline miss." Read the QoS actually declared on the
   subscriptions to the two anchor topics in the Autoware node source. Confirm or correct whether
   DEADLINE and LIFESPAN are left default (unset) on the reader. Note any `qos_overrides` parameter
   hooks that could change this at runtime, and whether a fixed QoS profile is used.

4. COMMAND-READER OWNERSHIP — "ROS command readers keep the DDS default SHARED ownership (the binding
   never sets ownership)." The study showed (§6.3) that the rclcpp/rmw QoS surface does not expose
   OWNERSHIP, so readers keep DDS-default SHARED. Confirm from the Autoware subscription QoS that these
   specific command readers do not (and cannot, via the ROS QoS API) request EXCLUSIVE ownership, and
   that no Cyclone-config or direct-DDS path is used for them in this deployment.

While you are reading the subscription QoS for questions 3 and 4, you may ALSO confirm the reader's
DURABILITY (expected: transient_local — this is what the whole injection matching argument rests on),
RELIABILITY, and HISTORY/DEPTH, and report them, since they come from the same declaration. This
confirms — does not re-derive — the foundation's matching claim; flag it as a confirmation.

EXPLICITLY OUT OF SCOPE (leave these §10 rows exactly as they are; they need the built Cyclone library,
production build flags, or a packet capture — none of which the Autoware source provides):
- type-discovery build flag; DDS Security build flag; production network-channels / DSCP build;
- end-to-end acceptance of a hand-forged discovery+DATA+HEARTBEAT sequence (Carrier B bench test);
- writer-batching-off (a deployment-config inference, already settled from config);
- port-7400 drop / participant-lease-expiry timing; discovery-multicast flooding / malformed-packet
  destabilization.
Do not weaken, strengthen, or restyle these rows.
</the_open_questions_in_scope>

<method>
Announce your phases.
PHASE 0 — ORIENT. Read `reports/wiki.md` end to end so every edit you make is consistent with the
surrounding prose and cross-references. Note every place the four in-scope questions are referenced (at
minimum: §3.2 lifecycle bullet ~L386-398; the §7 disable diagram and application-level text; §5 replay/
over-publication dedup mentions; §6.3 ownership; §5.3 deadline/flooding; the glossary "Lifecycle node"
entry; and the §10 table). You will need to update ALL of them, not only §10, so the document has no
lingering "cannot be confirmed / node sources not available" language for a question you have now
settled.
PHASE 1 — LOCATE. In `src/autoware`, find the subscriber node(s) for each anchor topic. The source is
split under `src/core` (autoware_core, msgs) and `src/universe/autoware_universe` (control, vehicle,
system, planning, …). Command consumers are most likely under `control/` and `vehicle/` and `system/`.
Identify the owning node class and file for each.
PHASE 2 — RESOLVE, per question, per node, from code. Read the class base (lifecycle vs plain), the
subscription creation and its QoS argument, and the callback body. Every verdict carries a `file:line`
`[code]` citation against the Autoware source. Where a runtime `qos_overrides` parameter could change a
declared QoS, say so and tag the residual uncertainty precisely (`[INFERRED]` that the default profile
is used, or `[UNVERIFIED]` only if it truly cannot be read).
PHASE 3 — WRITE BACK into `reports/wiki.md` only (see <output>).
PHASE 4 — SELF-AUDIT (see <self_audit>).
If context runs out, stop cleanly with a RESUME BLOCK: which questions are resolved, which nodes/files
are still to open, and any residual tags.
</method>

<output>
Edit `reports/wiki.md` in place, preserving its voice, section shape, tables, and evidence tags. Do
NOT edit any other file. Concretely:

- §10 table: for each of the four in-scope rows, either move the finding to `[code]` and rewrite the
  row to state the resolved answer (with the settling Autoware `file:line` folded into the body text
  where the topic is discussed), or — if a residual uncertainty remains after reading source — keep a
  tightened tag that names the exact remaining gap. Do not silently delete a row; a resolved row should
  now read as settled, pointing to where in the body the mechanism is documented.
- In-text: update every passage that previously said the answer "cannot be confirmed" / "node sources
  are not available" for these four questions, replacing the hedge with the sourced finding and its
  citation. Keep the mechanism explanations that are already correct; you are removing the specific
  "unavailable" caveat and adding the now-known Autoware-side fact.
- Glossary: update the "Lifecycle node" entry's "Whether Autoware uses these is `[UNVERIFIED]`" clause
  to reflect the verdict for the command-topic owners.
- End each materially changed passage the way the document does: with the SEU closing block (the STL
  property, the trace event the monitor observes, and the safe-stop decision) drawn from the
  newly-settled fact (e.g. "these nodes read the command VOLATILE, so a freshness property must be
  evaluated on arrival age, not on a latched last sample"; or "the application accepts a replayed
  command as fresh, so the monotonic-sequence check must live in the monitor, not the app"). Preserve
  the loopback-vs-deployment realism caveat wherever an observability judgment depends on it. Do not
  add generic commentary.
- Keep the strip test passing: the prose must read cleanly if every `file:line` citation were removed.
- Match the existing citation style precisely (`path/file.ext:LINE` with an evidence tag at clause end).
</output>

<self_audit>
- [ ] Exactly the four in-scope §10 questions are resolved; the out-of-scope rows are byte-for-byte
      unchanged.
- [ ] Every new verdict cites Autoware source as `file:line` `[code]`, kept distinct from Cyclone/rmw/
      rclcpp citations and from `[spec]` claims.
- [ ] Lifecycle verdict is read from the node's base class, not inferred from its name.
- [ ] Dedup verdict is read from the actual subscriber callback body and tied to the §5 replay finding.
- [ ] Deadline/lifespan/ownership verdicts are read from the subscription QoS declaration; any
      `qos_overrides` runtime hook is noted; residual uncertainty is tagged precisely, not hand-waved.
- [ ] No foundation or mechanism from §2–§9 was re-derived; confirmations of existing claims are
      labelled as confirmations, not new derivations.
- [ ] Every in-text reference to the four questions is updated — no orphaned "sources not available"
      hedge remains anywhere in the document.
- [ ] Each changed passage ends with the SEU closing block (STL property / trace event / safe-stop)
      drawn from the newly-settled mechanism.
- [ ] Only `reports/wiki.md` was modified.
- [ ] Report, at the end, a short changelog: which rows/sections changed, the key file:line evidence
      for each verdict, and any question that could only be partially settled and why.
</self_audit>
```
