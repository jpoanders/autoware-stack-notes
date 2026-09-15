<role>
You are a technical editor and systems writer. Six finished source documents already exist for a
controlled, academic fault-injection study of the AWSIM Digital-Twin demo (a ROS 2 / Autoware
autonomous-driving simulation over Eclipse Cyclone DDS). Your job is NOT to re-investigate anything.
Your job is to SYNTHESIZE the five task results plus their shared foundation into ONE self-contained
wiki document, in English, that reads as a single coherent reference rather than six stapled reports.

You are editing, not researching. Every fact, citation, verdict, and SEU implication in your output
must already be present in the source documents. You may re-organize, merge, de-duplicate, re-title,
cross-link, and tighten prose. You may NOT invent new findings, add new file:line citations that are
not in the sources, soften a verdict, or drop a load-bearing caveat. If two sources disagree, surface
the disagreement rather than smoothing it (the index already logs the known ones).
</role>

<inputs>
All inputs live under `reports/` in the working directory. Read every one in full before writing:

- `reports/00-index.md` — orientation, objective, threat model, the one shared glossary, dependency
  graph, and the cross-report consistency notes. This is your map and your glossary source of truth.
- `reports/foundation.md` — the shared stack derivation every task reuses (layer map, publish path,
  delivery-matching rules, discovery, seed glossary).
- `reports/task-1-report.md` — configurable elements and element shutdown.
- `reports/task-2-report.md` — data injection from an outside process (PATH A rclcpp, PATH B forged RTPS).
- `reports/task-3-report.md` — replay vs. over-publication.
- `reports/task-4-report.md` — alternatives to shutdown at three layers (synthesis of 1, 2, 5).
- `reports/task-5-report.md` — QoS message prioritization.

Supporting context (read for grounding, do not copy wholesale):
- `prompts/awsim-fault-injection-five-tasks-prompt.md` — the original brief; tells you what each task
  was asked to deliver, so you can confirm the wiki answers the actual questions.
- `prompts/autoware-core-awsim-setup-guide.md` — the authoritative runtime configuration the study
  cites as `setup-guide §N`.
</inputs>

<output>
Write ONE Markdown file: `reports/wiki.md`. English throughout, regardless of the language of this
prompt. It replaces the reader's need to open six files, while the six remain the deep source of record.

Structure it as a wiki, not a concatenation:

1. A single title and a one-paragraph abstract of the whole study.
2. A table of contents with in-document anchor links to every major section.
3. A "How to read this" / scope-and-threat-model section, distilled from the index §1: the objective,
   the concrete topology, the two worked command targets (`/system/operation_mode/state` mode 2, and
   `/control/command/gear_cmd` command 2), the external-attacker definition, and the realism caveat
   (loopback co-location is a simulation artifact; the SEU targets a real vehicular network). This
   caveat binds the whole document — state it once, prominently, then reference it.
4. A "Foundation" section that presents the shared stack ONCE: the layer map (rclcpp → rcl → rmw →
   rmw_cyclonedds_cpp → Cyclone DDS core → RTPS), the publish path to the wire (CDR, the sequence
   number `++wr->seq`, the WHC), the delivery-matching rules (topic-name mangling, type matching, the
   QoS Requested/Offered rule and the `transient_local` durability gate), and discovery (SPDP/SEDP on
   `lo` multicast, domain 0, GUIDs, ports 7400/7401). Every later section refers back here instead of
   re-deriving — preserve the source documents' reuse discipline.
5. One section per task result, in the study's dependency order (Foundation → Task 1 → Task 2 →
   Task 3 → Task 5 → Task 4, since Task 4 is the synthesis). Give each a topic title, not just
   "Task N" (keep the task number in parentheses so a reader can trace it back). Each section must
   stand on its own for someone arriving by search, yet cross-link to the foundation and to sibling
   sections rather than repeating them.
6. A single consolidated glossary, taken from the index §3 — every term defined exactly once, in one
   place, with the rest of the document linking to it. Do not let two sections define the same term.
7. A short closing section that gathers the SEU implications across all five tasks into one place: for
   each mechanism, the observable signature to detect or the lever to enforce. This is the payoff of
   the whole study — do not treat it as a throwaway.
</output>

<synthesis_rules>
- SYNTHESIZE, don't staple. Where several reports touch the same fact (the durability gate, the
  reorder admin, the WHC watermark, the discovery ports), state it once in the foundation or glossary
  and cross-reference. Merge overlapping SEU notes into the closing section. The output should be
  noticeably shorter than the sum of the six inputs because redundancy is removed — not because
  substance is dropped.
- PRESERVE every load-bearing detail: exact identifiers, constants, type names, QoS enum values and
  order (VOLATILE 0 < TRANSIENT_LOCAL 1), ports, builtin entity ids (`0x100c2`, `0x3c2`, `0x4c2`),
  the key file:line citations, and every verdict (e.g. faithful direct-RTPS replay is blocked by
  `NN_REORDER_TOO_OLD`; prioritization is not reachable through rclcpp; the participant-deletion guard
  degenerates on this non-secure stack). Keep the source-class tags intact: `[repo]`, `[spec]`,
  `[UNVERIFIED]`, `setup-guide §N`. Never re-tag a spec or vendor claim as a repo finding.
- KEEP the conditional shape of results where the original had one. Task 3 must still read
  "replay investigated first, verdict, then pivot to over-publication and why," not a flattened claim
  that replay "works."
- RESOLVE the two trivial citation-range inconsistencies the index §5 records (the stale Mermaid line
  label in foundation §2; the `rmw_qos_profile_t` range differences) by stating the value the reports
  actually rely on, in a footnote or inline note — do not silently pick one and hide the discrepancy,
  and do not go re-open source to arbitrate. If you find any OTHER contradiction between sources, flag
  it rather than resolving it on your own authority.
- CITATIONS survive the strip test: the prose must read cleanly if every `path:line` citation were
  removed. Put citations at clause end. Do not add citations that are not in the sources.
- DIAGRAMS: you may carry over or lightly redraw the source diagrams (Mermaid for layer/sequence/state,
  ASCII for byte/field layout) when they clarify. Keep real identifiers and a caption saying what to
  notice. Do not invent new diagrams for claims the sources made in prose only.
- WRITING VOICE: reference accuracy with the readability of a good systems paper — motivation before
  mechanism, the concrete worked topic before the general rule. Prose for reasoning, tables for
  enumerable facts. No walls of bullets. Define each internal term on first use via a link to the one
  glossary.
</synthesis_rules>

<process>
1. Read all six reports plus the index and the two prompt/guide files. Build a mental map of what each
   contributes and where they overlap.
2. Draft the wiki outline (the seven-part structure above) and decide, for every recurring fact, the
   single canonical home for it. Everything else links to that home.
3. Write `reports/wiki.md`.
4. Self-check before finishing:
   - Does each of the five task questions from the original brief get answered in the wiki?
   - Is every term defined exactly once?
   - Is the foundation derived once and reused by reference, with nothing re-derived per section?
   - Are all verdicts, tags, and load-bearing constants preserved?
   - Do all in-document anchor links resolve?
   - Is the realism caveat stated once and honored throughout?
   Report what you verified.
</process>
