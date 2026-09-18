<role>
You are a technical editor and systems writer continuing a controlled, academic study of the AWSIM
Digital-Twin demo (a ROS 2 / Autoware autonomous-driving simulation over Eclipse Cyclone DDS). The
static source study is complete and consolidated in `reports/wiki.md`. Since then, the study crossed
from paper analysis into a running bench test: **Phase 2 of the fault-injection roadmap built a
working harness and validated Module 1 (silent freshness-loss injection) live on the lab PC**, recorded
in `reports/poc-phase2-report.md`.

Your job is to write ONE new report that **integrates the Phase 2 result into the context of the whole
study**, in the same register, structure, and evidence discipline as `reports/wiki.md`. You are NOT
re-running the PoC, NOT re-deriving the stack, and NOT rewriting or overwriting `reports/wiki.md`. You
are producing a standalone, coherent narrative that says what was built, where it sits in the study,
what it means, what the study can now conclude, and what remains open.

Framing you must keep (the study is already safety-framed — do not regress it): the **SEU is a Safety
Enforcement Unit** — a lightweight, event-driven runtime-verification monitor that derives
temporal/freshness constraints from data dependencies, formalizes them as Signal Temporal Logic (STL)
properties, evaluates traces, and executes a **preemptive safe-stop** on a critical violation
(`[LSEU-abstract]`). The fault-injection harness Phase 2 built is the study's **test instrument** that
drives off-nominal traces so the monitor can be exercised and its safe-stop validated — **not an attack
to be detected or blocked**. Do not reintroduce any "security / detect-or-block / attacker" framing.
</role>

<audience>
Write for the **SEU design team and the technical stakeholders/reviewers following this study** — the
same audience `reports/wiki.md` serves. Assume a reader who is technically literate and understands
autonomous vehicles and software in general, and who may know the broad study, but who does NOT
necessarily live inside the ROS 2 / DDS / Cyclone / RTPS / QoS details. Therefore:
- Lead every section with motivation in plain language (what this proves and why it matters for the
  SEU) before the wire-level detail.
- Expand an acronym on first use; for stack terms already defined in the wiki glossary, use them and
  point to that one glossary rather than redefining them here.
- The report must read coherently on its own — a reader should follow the argument without opening
  another file — while remaining honest that it is a study report: it MAY name the sibling reports and
  the harness workspace as provenance (this is not the public wiki, so the "no local paths" rule of the
  publish-ready pass does NOT apply here). Keep the systems-paper voice: prose for reasoning, tables for
  enumerable facts, no walls of bullets.
</audience>

<inputs>
Read all of these in full before writing:
- `reports/poc-phase2-report.md` — PRIMARY. What was built and the validated Module-1 result, with the
  `[runtime]` evidence, the negative control, and the settled unknowns. Your report is the study-context
  narrative around this; do not merely restate it — integrate it.
- `reports/poc-roadmap.md` — the fault-injection plan: the two modules, the staging (Stage-1 harness vs
  Stage-2 live sim), the target (ego speed channel), and the phase structure. Use it to place Phase 2 in
  the arc (Phase 1 recon done, Phase 2 done, Phase 3/4 pending).
- `reports/poc-recon.md` — Phase 1: the topic/type/QoS/GUID facts the harness rests on (VOLATILE end to
  end; name-only type discovery; the live speed-writer GUID). The `[runtime]` tag convention (command +
  date + what was running) is defined in its addendum — obey it for every runtime claim you make.
- `reports/wiki.md` — the consolidated static study and your STYLE MODEL. It is the source of record for
  citations; do not add `file:line` citations that are not already in the corpus. Connect Phase 2
  explicitly to at least: §4 (injecting data from outside) and §4.3 (Carrier B hand-forged RTPS); §7.1
  (protocol-level withdrawal — the exact mechanism Phase 2 validated, derived there statically on the
  `gear_cmd` writer and `[UNVERIFIED]` end-to-end); §8 (the gathered SEU/STL implications); and §10 (the
  open-questions table — state precisely which rows Phase 2 moves and which it leaves untouched).
- `poc-harness/` — the workspace: the three Cyclone-C nodes (`src/*.c`), the IDL, the forger
  (`inject/forge_withdraw.py`), `run_module1.sh`, and `evidence/`. Read enough to describe what was built
  accurately; you may cite these as provenance.

Supporting context (for grounding, do not copy wholesale): `prompts/awsim-fault-injection-five-tasks-prompt.md`
(the master brief and the closing-block definition), `prompts/autoware-core-awsim-setup-guide.md`
(`setup-guide §N`), and `CLAUDE.md` (repo ground rules, evidence tags, the SEU definition).
</inputs>

<output>
Write ONE Markdown file: `reports/poc-phase2-integration.md`. English throughout, regardless of the
language of this prompt. Do not touch any other file. Structure it as a wiki-style report, not a log:

1. **Title + one-paragraph abstract** of what Phase 2 achieved and why it matters to the study as a whole
   (the first time a statically-derived mechanism became a `[runtime]`-confirmed result feeding the SEU).
2. **Table of contents** with in-document anchor links.
3. **Evidence-tag legend** — reuse the wiki's (`[code]` / `[spec]` / `[INFERRED]` / `[UNVERIFIED]` /
   `[LSEU-abstract]`), and ADD `[runtime]` defined exactly as `poc-recon.md` does (a live observation on
   the lab PC, stated with the command, the date, and what was running).
4. **What was built** — the Stage-1 harness (the three participants and the load-bearing QoS they
   reproduce, faithful to recon), and the Module-1 forge (the hybrid carrier: a real participant for
   discovery/reliability + one hand-forged keyed SEDP DISPOSE|UNREGISTER). Explain the design choices
   (why hybrid; why UDP is enough; why a Cyclone-C harness rather than a full ROS build) in one or two
   sentences each, not as a changelog.
5. **Where it fits in the study** — connect the mechanism to wiki §7.1 (protocol-level endpoint
   withdrawal) and the injection framing of §4/§4.3, and to the roadmap's target (the ego speed channel)
   and staging. Make explicit that Phase 2 is the first crossing from `[code]`/`[spec]`/`[INFERRED]` into
   `[runtime]`, on the speed channel rather than the wiki's `gear_cmd` worked example.
6. **Analysis** — the substance. At minimum: (a) that the forged withdrawal was accepted and deleted a
   proxy writer owned by a *different* participant, confirming live the no-source-check dead path the
   wiki derived statically; (b) the meaning of "silent freshness loss" — source healthy and oblivious
   (`write_rc=OK`), data still on the wire but unmatched, consumer starved — and why this is the hardest
   case for a freshness monitor and the archetypal safe-stop trigger; (c) what the harness proves about
   the SEU's **observability** — that both the effect (age divergence) and the cause (a foreign SEDP
   dispose naming the writer's GUID) are visible in the trace the monitor taps; (d) the strength and the
   limits of the evidence, including the loopback-vs-deployment realism caveat (this is Stage-1 on `lo`;
   the SEU targets a real vehicular network where the same data must reach discovery and match
   topic/type/QoS to affect a consumer).
7. **The STL closing block, now empirically grounded** — restate the Module-1 property / trace event /
   safe-stop decision in the study's closing-block form, and show it is no longer a projection but tied
   to an observed `[runtime]` trace. Relate it to the gathered catalog in wiki §8.
8. **What the study can now conclude** — a short synthesis that folds this first empirical result back
   into the study's standing conclusions (the static findings plus this confirmation; progress on the
   STL-property catalog; which claims are now the most load-bearing and confirmed).
9. **Pendencies and unverified aspects** — a precise table: which wiki §10 rows Phase 2 settled
   (end-to-end acceptance of a hand-forged discovery+DATA+HEARTBEAT — resolved via the hybrid carrier;
   the fresh-writer HEARTBEAT/reorder gating — resolved) and which it did NOT (DDS-Security build flag —
   still open, though Phase 2 shows the endpoint dead path landed on a non-secure build; the full
   from-scratch SPDP forge without a real carrier — not attempted; Module 2 / Carrier B wrong-value
   injection — Phase 3; the live downstream safe-stop and Autoware-side reader QoS on the wire — Stage 2).
   Do not overstate: distinguish "confirmed on the Stage-1 harness" from "confirmed on live AWSIM/Autoware."
10. **Glossary by reference** — do not re-define the stack terms; point to the wiki glossary and define
    only any term genuinely new to this report (e.g. the harness node roles) if needed.
</output>

<rules>
- INTEGRATE, don't restate. The Phase-2 report already has the raw result; your value is the study-level
  narrative, the connective tissue to the wiki sections, and the honest boundary of what is now known.
- Preserve every verdict and load-bearing detail at its original strength: the no-authorization dead
  path; VOLATILE end-to-end on the speed channel; name-only type discovery; 30 Hz ≈ 33 ms nominal
  inter-arrival; the builtin entity ids (`0x3c2`/`0x3c7`, `0x100c2`); `PID_ENDPOINT_GUID = 0x5a`;
  `PID_STATUSINFO = 0x71` read big-endian; the DISPOSE|UNREGISTER bits. Keep source-class tags intact and
  never re-tag a `[spec]`, `[INFERRED]`, or `[LSEU-abstract]` claim as `[code]` or `[runtime]`.
- Every runtime claim carries `[runtime]` WITH its command, date (2026-09-18), and what was running (the
  three Cyclone participants on domain 0 / loopback; no AWSIM/Autoware). Every static claim keeps its
  existing tag and `path:line`. Do not invent citations or numbers not in the corpus.
- Honour the realism caveat once, prominently, and throughout: Stage-1 loopback co-location is a
  simulation artifact; it validates the mechanism and the monitor-observable trace, NOT the live vehicle
  reaction, which is Stage 2.
- CITATIONS survive the strip test: the prose must read cleanly if every `path:line` / provenance pointer
  were removed. Put citations at clause end.
- Do NOT modify `reports/wiki.md`, the five task reports, the roadmap, or any `src/` evidence tree. Your
  only new artifact is `reports/poc-phase2-integration.md`.
- End the file with the completion marker `<!-- REPORT-COMPLETE -->` on its own final line (the runner
  convention; see `CLAUDE.md`).
</rules>

<process>
1. Read the five inputs and skim the harness workspace. Build a map of exactly which wiki sections and
   §10 rows Phase 2 touches, and how.
2. Draft the ten-part outline; decide the single place each fact lives (lean on the wiki glossary by
   reference for stack terms).
3. Write `reports/poc-phase2-integration.md`.
4. Self-audit (below) and report what you verified.
</process>

<self_audit>
- [ ] The report reads as a coherent wiki-style narrative for the stated audience, motivation before
      mechanism, and stands on its own.
- [ ] Phase 2 is explicitly connected to wiki §4/§4.3, §7.1, §8, and §10 by their topics (not just
      "the wiki says").
- [ ] Every runtime claim is tagged `[runtime]` with command + date (2026-09-18) + what was running;
      every static claim keeps its original tag and citation; no tag was upgraded.
- [ ] The no-source-check dead path, the silent-freshness-loss meaning, and the observability argument
      are all present and correct.
- [ ] The STL closing block is restated in the study's form and tied to an observed trace, not projected.
- [ ] The pendencies table distinguishes Stage-1-harness-confirmed from live-sim-pending, and names the
      still-open §10 rows precisely (DDS Security; full SPDP forge; Module 2/Carrier B; Stage-2 safe-stop).
- [ ] The realism caveat is stated once and honoured throughout; safety framing is intact (no
      security/attacker/detect-or-block regressions); `[LSEU-abstract]` numbers are not presented as
      measured by this study.
- [ ] Only `reports/poc-phase2-integration.md` was created/modified, and it ends with
      `<!-- REPORT-COMPLETE -->`.
- [ ] Report a short changelog: the sections written, the key wiki cross-references made, and any point
      you could only partially integrate and why.
</self_audit>
