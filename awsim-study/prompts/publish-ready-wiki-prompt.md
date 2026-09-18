<role>
You are a technical editor and systems educator. A finished, rigorous synthesis document already
exists: a single-file study of how the AWSIM Digital-Twin demo — a ROS 2 / Autoware
autonomous-driving simulation running over Eclipse Cyclone DDS — can be configured, shut down,
injected into, replayed against, prioritized, and silently disabled at each layer of its
communication stack, in service of designing a **Safety** Enforcement Unit (SEU) — an STL runtime
monitor that derives temporal/freshness constraints from data dependencies and executes a preemptive
safe-stop on a critical violation. (The source `reports/wiki.md` is already safety-framed; do not
re-introduce the old "security / detect-or-block" framing. Preserve its `[LSEU-abstract]` tags.)

That document was written for the study's own authors. Your job is to turn it into a **standalone,
newcomer-accessible wiki page for publication on a research lab's public wiki**. You are NOT
re-investigating anything and you are NOT adding findings. You are re-editing an existing document so
that (a) a reader who knows autonomous vehicles and software in general — but does NOT know this
specific ROS 2 / DDS / Cyclone / RTPS stack — can follow it, and (b) it stands completely on its own,
with no reference to any other file, report, task list, or local checkout.

Everything factual in your output must already be present in the source. You may reorganize, retitle,
merge, expand explanations, add on-ramps for newcomers, and reframe provenance. You may NOT invent new
findings, add file:line citations that are not in the source, soften any verdict, or drop any
load-bearing caveat.
</role>

<input>
Read in full before editing:

- `reports/wiki.md` — the existing single-document synthesis. This is your ONLY content source; every
  fact, citation, verdict, constant, and SEU closing block (STL property / trace event / safe-stop) in
  your output must already appear here.

Overwrite it in place: write the rewritten, publication-ready version back to `reports/wiki.md`.
English throughout, regardless of the language of this prompt.
</input>

<the_two_transformations>
This is the whole job. Apply both to every section.

**1. Make it self-contained (publishable).** The output must read as if it were born on the lab wiki,
with no pointer to anything a public reader cannot see:

- **Delete the "source of record" framing.** Remove the opening sentence(s) that describe this as a
  synthesis of "six files under `reports/`" or that name `foundation.md`, `task-1-report.md`, etc. The
  wiki IS the document now, not a summary of one.
- **Drop the task numbering.** Retitle every section that currently reads "... (Task N)" to a plain
  topic title (e.g. "Configurable Elements and Shutting an Element Down", "Injecting Data from Outside
  the Simulation", "Replay and Over-Publication", "QoS Message Prioritization", "Disabling an Element
  Without a Clean Shutdown"). Remove the "(Task N)" parentheticals from the table of contents,
  headings, and every in-text cross-reference. Cross-references should point to the section by its new
  title/anchor, never by task number.
- **Absorb the `setup-guide §N` citations.** A reader has no setup guide. Wherever the text cites
  `setup-guide §N` for a configuration fact, state the fact directly as the studied deployment's
  configuration, and drop the `§N` pointer. Consolidate the concrete runtime configuration (the Docker
  `--net host` container, native AWSIM, Cyclone domain 0 on loopback, `RMW_IMPLEMENTATION`, the
  Cyclone knobs such as `WhcHigh=500kB` and `MaxMessageSize=65500B`, the two command topics and their
  enum values) into the scope/topology section so later mentions are internal references, not external
  ones.
- **Reframe the file:line citations, don't delete them.** They are the study's rigor and must survive,
  but "this checkout under `src/`" is a local artifact. Strip the leading `src/` and the "in the
  checkout" language; present each path as a reference into the named upstream open-source component
  (Eclipse Cyclone DDS, `rmw_cyclonedds`, `rclcpp`, `rcl`, `rmw`, and the Autoware message packages),
  all of which are public. Add ONE sentence near the top stating that file paths refer to the source
  of these open-source components at the versions studied. Keep every citation at clause end; the
  prose must still pass the strip test (read cleanly if all citations were removed).
- **Redefine the evidence tags in plain, self-contained terms.** Keep the honesty they encode but stop
  assuming the reader knows the scheme. Replace the current `[repo]` / `[spec]` / `[UNVERIFIED]` /
  `[INFERRED]` legend with one written for an outsider: e.g. confirmed in the open-source code /
  stated by the OMG DDS/DDSI-RTPS specification / not verified because the simulation was not executed
  (would need a live run or packet capture) / a reasoned inference from cited code. You may keep short
  tag markers, but define them once, up front, without referring to "this checkout." Never re-tag a
  specification or inference claim as a confirmed-code finding.
- **Purge every remaining dangling reference.** No mention of `reports/`, other `.md` files, "the six
  documents", "the index", task numbers, or the setup guide may remain anywhere, including inside
  Mermaid diagram labels, captions, footnotes, and the glossary.

**2. Make it accessible (for a non-specialist in this stack).** Assume a reader who is technically
literate and understands autonomous vehicles, but has NOT worked with ROS 2, DDS, Cyclone DDS, RTPS,
or DDS QoS:

- **Add a short primer before the deep stack.** Early in the document, briefly explain the layered
  picture in plain language — what ROS 2 is, what DDS is and why ROS 2 uses it, what Cyclone DDS and
  RTPS are, what "publish/subscribe over topics with QoS" means, and what "discovery" is — so the
  layer map that follows lands on prepared ground. Keep it tight; it is an on-ramp, not a textbook.
- **Motivation before mechanism.** Open each major section with one or two plain sentences on what the
  section is really asking and why it matters for the SEU, before the source-level detail. Introduce
  the concrete worked example (the two command topics) before the general rule.
- **Expand every acronym on first use** (ROS 2, DDS, RTPS, DDSI, CDR, QoS, RxO, SPDP, SEDP, WHC, RHC,
  GUID, SEU, ECU, DSCP, ...), and make sure each internal term links to its single glossary definition
  on first use. The glossary stays the one place each term is defined; expand any definitions that are
  too terse for a newcomer, but keep exactly one definition per term.
- **Answer the study's questions clearly and up front.** Each major section must give a plain,
  direct answer to its guiding question in its first lines, then support it. The questions the wiki
  must answer unambiguously are:
  1. Which elements of this stack can be configured or controlled to change their behavior, lifetime,
     or presence, and how can a single element be shut down cleanly? Keep the four shutdown mechanisms
     distinct (whole-context shutdown, single-node destruction, lifecycle transition, process
     signal/kill), each with its blast radius, whether an outside element can trigger it, whether it is
     reversible, and how the resulting freshness loss shows up in the trace the monitor observes.
  2. How can a process outside the simulation publish messages that legitimate nodes accept? Cover both
     carriers (an ordinary ROS 2 / rclcpp node, and a hand-forged RTPS speaker), the load-bearing
     `transient_local` durability-match requirement, and include the case of an injection that is
     dropped and why.
  3. Can captured traffic be replayed so subscribers accept it as fresh? Preserve the conditional
     shape: investigate faithful replay first and give its verdict (blocked by the reader's reorder
     admin / duplicate filtering), then pivot to over-publication and explain what forced the pivot
     and how flow control self-throttles it.
  4. How can Cyclone DDS QoS be used to prioritize messages, and how much of that is reachable through
     ROS 2 / rclcpp versus only through Cyclone's own configuration? State the central finding (that
     transport priority and ownership are not reachable through the ROS middleware profile) plainly.
  5. Beyond a clean shutdown, how can an element be disabled or silenced, at the protocol layer, the
     physical/transport (loopback) layer, and the application layer? Give each method's effect, whether
     an outside element can do it, reversibility, and whether the resulting loss is silent or visible in
     the trace.
- **Prose for reasoning, tables for enumerable facts.** Keep the systems-paper voice. Avoid walls of
  bullets. Diagrams may stay (Mermaid for layer/sequence/state, ASCII for byte layouts) if they clarify
  and their labels are cleaned of external references.
</the_two_transformations>

<preserve_exactly>
- Every verdict, in its original strength: faithful direct-RTPS replay is blocked (`NN_REORDER_TOO_OLD`);
  prioritization is not reachable through rclcpp; the participant-deletion guard degenerates on this
  non-secure stack; injection requires offering durability at least `transient_local`; and so on.
- Every load-bearing constant and identifier: the durability enum order (VOLATILE 0 < TRANSIENT_LOCAL
  1), ports 7400/7401, builtin entity ids (`0x100c2`, `0x3c2`, `0x4c2`), `WhcHigh=500kB`,
  `MaxMessageSize=65500B`, the two topics and their key values (mode 2 = AUTONOMOUS, command 2 = DRIVE),
  and the key sequence-number/QoS-match citations.
- The realism caveat: loopback co-location in one domain is a simulation artifact; the SEU targets a
  real vehicular network (a bus element on automotive Ethernet or CAN emitting off-nominal data, by
  fault or compromise) whose data must still reach discovery and match topic/type/QoS to affect a
  consumer. State it once, prominently, and honor it throughout.
- The SEU payoff: the closing block that, per mechanism, states the STL property it implies, the trace
  event the monitor observes, and the safe-stop decision. Do not thin it out.
- The honest boundaries of what was and was not verified (the items that would need a live run remain
  flagged as not runtime-verified, in the new plain-language phrasing).
</preserve_exactly>

<do_not>
- Do not invent findings, constants, or citations. If it is not in `reports/wiki.md`, it does not go in.
- Do not re-open the underlying source code to arbitrate anything; edit only what the source document
  contains.
- Do not soften or strengthen any verdict, and do not drop a caveat to make the document flow better.
- Do not leave a single reference to reports, tasks, the index, the setup guide, or a local checkout
  path anywhere in the output.
</do_not>

<self_check>
Before finishing, verify and report:
- All five guiding questions are answered clearly and up front in their sections.
- No occurrence of "reports/", "task-N", "(Task N)", "setup-guide", "the six", "this checkout", or a
  leading "src/" path remains anywhere, diagrams and glossary included.
- Every acronym is expanded on first use; a newcomer primer precedes the deep stack; each internal term
  links to exactly one glossary definition.
- The evidence-tag legend is redefined in self-contained, outsider-readable terms, and no spec or
  inference claim is mislabeled as confirmed code.
- Every verdict, constant, identifier, the realism caveat, and the SEU closing block (STL property /
  trace event / safe-stop) survive intact.
- All in-document anchor links resolve, and the prose reads cleanly with every citation removed.
</self_check>
