# awsim-study

Research study of the AWSIM + Autoware Core communication stack (Eclipse Cyclone DDS),
feeding the design of a **SEU** (Safety Enforcement Unit): an STL runtime-verification
monitor that safe-stops on temporal/freshness violations. Fault injection is the *test
instrument* that drives off-nominal traces to validate the monitor.

## Layout

- **`study/`** — the static source-code study (the shared knowledge base): `foundation.md`,
  `task-1..5-report.md`, `wiki.md`/`wiki_summary.md`, `00-index.md`. `study/prompts/` holds the
  prompts that drove it; `study/tooling/` the headless runners (`run-study.sh`, `run-revision.sh`).
- **`setup/`** — runtime/lab config shared by all experiments: `autoware-core-awsim-setup-guide.md`,
  `lab-machine-setup.md`, `stage2-preflight.sh`, and `setup/scripts/` (AWSIM + container bring-up).
- **`experiments/`** — one self-contained folder per fault-injection experiment, plus the
  cross-experiment `roadmap.md` and `stage2-run-plan.md`. See `experiments/README.md`.
- **`src/`** — read-only upstream evidence (gitignored except `REPOS.md`; re-clone from it).

The sim runs only on the lab PC `ml-XPS-8960`. `src/` trees are read-only evidence — never modified.
