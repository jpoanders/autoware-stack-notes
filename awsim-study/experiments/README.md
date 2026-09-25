# Experiments

Each folder is a self-contained fault-injection experiment: its own code, build, scripts,
evidence, and `report.md`. Shared pieces live in `_common/`.

- **`_common/`** — the shared tap `consumer/trusting_consumer.c` (the SEU trace source), the shared
  type `idl/VelocityReport.idl`, `cyclonedds_trace.xml`, and `common.cmake` (generates `vr_lib` +
  builds `trusting_consumer`; `include()`-d by each experiment's `CMakeLists.txt`).
- **`recon/`** — Phase 1 recon (SPDP/SEDP sniff + decode). `report.md` = the recon findings.
- **`module1-freshness-loss/`** — silent freshness-loss via forged SEDP withdrawal. Build with
  `cmake -S . -B build && cmake --build build`; run `./run_module1.sh`. Owns `real_speed_monitor.c`
  (the nominal writer other experiments reference).
- **`fi1-data-age/`** — FI1 data-age / stuck-sensor injection. `bench/` = bare-Cyclone Step-0 smoke
  (no msgs); `fi1_ros2_ws/` = the **Path A** colcon workspace (rclpy node + a minimal
  `autoware_vehicle_msgs` overlay); `analysis/fi1_seu_check.py` = the SEU/STL evaluator. Driver:
  `./run_fi1.sh bench|ros|live`.

Cross-experiment plans: `roadmap.md`, `stage2-run-plan.md`.

## Conventions
- Builds go under `<exp>/build/` (or the ws's `build/install/log`) — all gitignored.
- Raw run logs under `<exp>/logs/` are gitignored; commit only curated `evidence/*.txt` excerpts.
- Evidence tags in reports: `[code]`/`[spec]`/`[INFERRED]`/`[UNVERIFIED]`/`[runtime]`.
