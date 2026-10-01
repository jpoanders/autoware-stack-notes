# autoware-stack-notes

Research study of the AWSIM + Autoware Core communication stack (Eclipse Cyclone DDS),
feeding the design of a **SEU** (Safety Enforcement Unit): an STL runtime-verification
monitor that safe-stops on temporal/freshness violations. Fault injection is the *test
instrument* that drives off-nominal traces to validate the monitor.

## Start here

- **Brief** — [`docs/NetStudents-Plan-20262-M1-M2.md`](docs/NetStudents-Plan-20262-M1-M2.md) (project plan) and [`docs/tasks/`](docs/tasks/) (task specs).
- **Study** — [`study/wiki_summary.md`](awsim-study/study/wiki_summary.md) (short) → [`study/wiki.md`](awsim-study/study/wiki.md) (full).
  Sources: [`00-index.md`](awsim-study/study/00-index.md) (property catalog + reading order), `foundation.md`, `task-1..5-report.md`.
  `study/prompts/` holds the prompts that drove it; `study/tooling/` the headless runners.
- **Experiments** — [`awsim-study/experiments/README.md`](awsim-study/experiments/README.md): one folder per fault-injection experiment, plus `roadmap.md` and `stage2-run-plan.md`.
- **Setup** — [`awsim-study/setup/`](awsim-study/setup/): `autoware-core-awsim-setup-guide.md`, `lab-machine-setup.md`, `stage2-preflight.sh`.
  Bring-up scripts (AWSIM, Autoware container, drive/goal helpers) live in [`awsim-study/scripts/`](awsim-study/scripts/).
- **`awsim-study/src/`** — read-only upstream evidence (gitignored except `REPOS.md`; re-clone from it). Never modified.

The sim runs only on the lab PC `ml-XPS-8960`.
