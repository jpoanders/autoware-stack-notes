# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not an application to build or test** — it is a *source-code research study*. It analyzes how
the communication stack of an autonomous-driving simulation (**AWSIM + Autoware Core over Eclipse Cyclone
DDS**) establishes the temporal/freshness constraints between components, and how that wire behavior can
be configured, shut down, injected into, replayed against, prioritized, and silently disabled — i.e. how
those constraints are met, degraded, or violated.
The study feeds the design of a **SEU** (**Safety** Enforcement Unit): a lightweight, event-driven
runtime-verification monitor that derives temporal constraints from data dependencies (actuation
frequency + data freshness), formalizes them as Signal Temporal Logic (STL) properties, evaluates system
traces against them, and executes a **preemptive safe-stop** when a critical constraint is violated. The
fault-injection mechanisms the study catalogs are the **test instrument** that drives off-nominal traces
into the system to exercise that monitor and validate its safe-stop path — not "attacks to detect."
(Historical note: earlier drafts framed the SEU as a *Security* Enforcement Unit that detects/blocks
adversarial faults; commit `ba9f735` reframed the report corpus to the safety/STL purpose.
`[LSEU-abstract]` tags any claim taken from the SEU's own unpublished abstract rather than the source
tree — never present its experimental numbers as something this static study measured.)

The primary output is prose: Markdown reports under `reports/`, produced by driving Claude Code itself in
headless mode. The `src/` trees are **read-only evidence**, cloned upstream repos that the study cites —
never modify them.

## Where this repo lives and where the sim runs

- This directory is the `awsim-study/` subfolder of the remote git repo
  **`git@github.com:jpoanders/autoware-stack-notes.git`** (repo root is one level up, alongside
  `docs/` and `scripts/`). It is cloned onto more than one machine, so never assume the current machine
  is the one where the work was done.
- **The sim (AWSIM + the Autoware Core container) can only be run on the lab PC**, hostname
  **`ml-XPS-8960`** (Ubuntu 22.04, RTX 3060, no sudo; AWSIM installed at `~/AWSIM-Demo-Lightweight`).
  Setup and verification steps: `lab-machine-setup.md`. Check with `hostname` before trying anything
  that needs a running sim. On any other machine, treat the sim as not executable.
- What a clone does **not** contain (gitignored): the evidence trees under `src/` (only `src/REPOS.md`
  is tracked. It lists each upstream repo with its pinned branch and commit, so re-clone from it),
  `logs/`, and `teach/`. The AWSIM binary and map are never in the repo.

## Ground rules for any analysis work here (load-bearing)

- **The DDS vendor is Eclipse Cyclone DDS, never Fast DDS.** Target `src/cyclonedds` and
  `src/rmw_cyclonedds`. Do not carry over any Fast DDS / FastRTPS assumptions — this is the single most
  common way to be wrong here.
- **Cyclone core source is in-checkout** at `src/cyclonedds/src/core/` (`ddsc` + `ddsi`). Wire/QoS/
  discovery/reorder claims are therefore verifiable `[code]` findings cited as `path:line`, **not**
  `[UNVERIFIED]` vendor guesses. Only tag `[UNVERIFIED]`: AWSIM's own client surface (`ros2cs`, absent
  from checkout), RTPS byte-layout (`[spec]`), and anything that would require *running* the sim or a
  packet capture that has not actually been observed on the lab PC (the sim is not executable anywhere
  else).
- **Cite every non-obvious claim** as `path:line` against real files under `src/`. Evidence tags used
  throughout: `[code]` / `[spec]` / `[INFERRED]` / `[UNVERIFIED]`, plus `[runtime]` for something
  observed on the live sim on the lab PC. A `[runtime]` finding must state the command run, the date,
  and what was running (e.g. AWSIM only vs the full Autoware stack). See the addendum in
  `reports/poc-recon.md`. Earlier reports predate this tag and do not use it.
- The **authoritative runtime configuration** lives in `prompts/autoware-core-awsim-setup-guide.md`;
  cite it as `setup-guide §N`. Do not renumber its sections (reports cite them). Record lab-PC
  deviations in `lab-machine-setup.md` instead.
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
  DEEP/MEDIUM/MENTION task ranking at its top), `task-{1..5}-report.md`, `00-index.md` (safety /
  temporal-constraint model + STL-property catalog + shared glossary + cross-ref check). Also `wiki.md`
  (~1060-line full narrative — the source of record for
  citations) and `wiki_summary.md` (condensed quick-read version).
- `source-code-study-summary.md` — top-level English summary of the whole study.
- `lab-machine-setup.md` — how AWSIM was set up and verified on the lab PC (`ml-XPS-8960`, no sudo).
  It is a delta on the setup guide: flattened unzip paths, config copied from the image, verification
  checks.
- `src/` — cloned upstream evidence: `cyclonedds`, `rmw_cyclonedds`, `rclcpp`, `rcl`, `rmw`,
  `rmw_dds_common`, the `*_msgs` / `*_interfaces` packages, and `awsim` (assets + `cyclonedds_config.xml`).
  Read-only; branches: rclcpp/rcl/rmw/rmw_cyclonedds @humble, cyclonedds @0.10.x.
- `teach/` — a self-contained `/teach` course (HTML lessons + shared `assets/course.css` & `quiz.js`,
  `reference/glossary.html`) built to help the user learn `reports/wiki.md` in order to design the SEU.
  Open lessons with `xdg-open` — they link `../assets/*` and will not render if moved standalone.
  (Not present in every clone — gitignored. Still carries the old *security* framing and is pending its
  own safety reframe; see the `00-index.md` follow-on list.)
- `logs/` — per-run JSON/stderr output and `incomplete.txt`.

## The layer model (recurring vocabulary)

`rclcpp → rcl → rmw → rmw_cyclonedds_cpp → Cyclone ddsi → RTPS on the wire`. Reports lean on: the publish
path (`publish → dds_write → write_sample_eot (++seq) → nn_xpack_send`), delivery matching (topic-name
mangling `rt<name>`, type name `<ns>::dds_::<Name>_`, and the **RxO/durability** rule where a `transient_local`
reader won't match a default `VOLATILE` writer — `q_qosmatch.c:167`), discovery (SPDP `0x100c2` / SEDP
`0x3c2`,`0x4c2`, ports base 7400/dg 250 on domain 0), the sequence-number reorder buffer, and WHC
flow-control (`WhcHigh` 500 kB back-pressure).
