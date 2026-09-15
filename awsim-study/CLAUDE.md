# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not an application to build or test** — it is a *source-code research study*. It analyzes how
the communication stack of an autonomous-driving simulation (**AWSIM + Autoware Core over Eclipse Cyclone
DDS**) can be configured, shut down, injected into, replayed against, prioritized, and silently disabled.
The study feeds the design of a **SEU** (Security Enforcement Unit) that would sit on a real vehicle
network and detect or block these faults.

The primary output is prose: Markdown reports under `reports/`, produced by driving Claude Code itself in
headless mode. The `src/` trees are **read-only evidence**, cloned upstream repos that the study cites —
never modify them.

## Ground rules for any analysis work here (load-bearing)

- **The DDS vendor is Eclipse Cyclone DDS, never Fast DDS.** Target `src/cyclonedds` and
  `src/rmw_cyclonedds`. Do not carry over any Fast DDS / FastRTPS assumptions — this is the single most
  common way to be wrong here.
- **Cyclone core source is in-checkout** at `src/cyclonedds/src/core/` (`ddsc` + `ddsi`). Wire/QoS/
  discovery/reorder claims are therefore verifiable `[code]` findings cited as `path:line`, **not**
  `[UNVERIFIED]` vendor guesses. Only tag `[UNVERIFIED]`: AWSIM's own client surface (`ros2cs`, absent
  from checkout), RTPS byte-layout (`[spec]`), and anything that would require *running* the sim or a
  packet capture (the sim is not executable in this environment).
- **Cite every non-obvious claim** as `path:line` against real files under `src/`. Evidence tags used
  throughout: `[code]` / `[spec]` / `[INFERRED]` / `[UNVERIFIED]`.
- The **authoritative runtime configuration** (the sim can't be run) lives in
  `prompts/autoware-core-awsim-setup-guide.md`; cite it as `setup-guide §N`.
- Two topics ground every finding: `/system/operation_mode/state` and `/control/command/gear_cmd`, both
  published `transient_local`. Domain 0, loopback (`lo`), multicast discovery.

## Running the study

The whole study is orchestrated by one script that runs a sequence of **headless `claude -p` runs**, one
report per invocation, each with fresh context:

```bash
./run-study.sh                 # normal run; stops once for a human review gate after the foundation
SKIP_REVIEW=1 ./run-study.sh   # unattended (skips the gate)
FORCE=1 ./run-study.sh         # redo reports even if already marked complete
MODEL=sonnet ./run-study.sh    # cheaper/faster (default is opus)
MAX_TURNS=120 MAX_CONT=4 ./run-study.sh   # give deep reports more room
```

Prereqs: `claude` on PATH and authenticated; the repos cloned under `src/`; prompt + guide present under
`prompts/`. Logs (JSON + stderr) land in `logs/`.

### How the runner handles context limits (important when editing reports)

- **Completion marker.** A run is "done" only when its file's final line is exactly
  `<!-- REPORT-COMPLETE -->`. The script uses this both to skip already-complete reports and to detect
  truncation. If you finish a report by hand, preserve/append this marker.
- **Resume marker.** A run that stops early appends `<!-- RESUME: <what remains> -->` instead; the next
  run reads the partial from disk, deletes that line, and **appends** the rest (never rewrites). Re-running
  the script is always safe and resumes; to redo one report, delete its file first.
- Dependency order is `foundation → 1 → 2 → 5 → 3 → 4 → 00-index`. Tasks 1, 2, 5 and the foundation are
  blocking prerequisites; tasks 3, 4 and the index are non-blocking (recorded in `logs/incomplete.txt`).
  Every task report reuses `reports/foundation.md` *by reference* rather than re-deriving the stack.

## Repository map

- `prompts/` — the instructions the study runs against. `awsim-fault-injection-five-tasks-prompt.md` is
  the master spec (the five tasks, evidence rules, quality floors); `autoware-core-awsim-setup-guide.md`
  is the runtime-config record; the others drive the wiki/synthesis passes.
- `reports/` — the deliverables. `foundation.md` (shared stack/publish-path/matching/discovery, plus the
  DEEP/MEDIUM/MENTION task ranking at its top), `task-{1..5}-report.md`, `00-index.md` (threat model +
  shared glossary + cross-ref check). Also `wiki.md` (~1060-line full narrative — the source of record for
  citations) and `wiki_summary.md` (condensed quick-read version).
- `source-code-study-summary.md` — top-level English summary of the whole study.
- `src/` — cloned upstream evidence: `cyclonedds`, `rmw_cyclonedds`, `rclcpp`, `rcl`, `rmw`,
  `rmw_dds_common`, the `*_msgs` / `*_interfaces` packages, and `awsim` (assets + `cyclonedds_config.xml`).
  Read-only; branches: rclcpp/rcl/rmw/rmw_cyclonedds @humble, cyclonedds @0.10.x.
- `teach/` — a self-contained `/teach` course (HTML lessons + shared `assets/course.css` & `quiz.js`,
  `reference/glossary.html`) built to help the user learn `reports/wiki.md` in order to design the SEU.
  Open lessons with `xdg-open` — they link `../assets/*` and will not render if moved standalone.
- `logs/` — per-run JSON/stderr output and `incomplete.txt`.

## The layer model (recurring vocabulary)

`rclcpp → rcl → rmw → rmw_cyclonedds_cpp → Cyclone ddsi → RTPS on the wire`. Reports lean on: the publish
path (`publish → dds_write → write_sample_eot (++seq) → nn_xpack_send`), delivery matching (topic-name
mangling `rt<name>`, type name `<ns>::dds_::<Name>_`, and the **RxO/durability** rule where a `transient_local`
reader won't match a default `VOLATILE` writer — `q_qosmatch.c:167`), discovery (SPDP `0x100c2` / SEDP
`0x3c2`,`0x4c2`, ports base 7400/dg 250 on domain 0), the sequence-number reorder buffer, and WHC
flow-control (`WhcHigh` 500 kB back-pressure).
