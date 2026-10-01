# FI3 — Publication Delay via an `LD_PRELOAD` shim (`libfi3_delay.so`) — runbook

> **Where this runs:** everything below runs on the **lab PC `ml-XPS-8960`**. It is the only machine
> with ROS 2 Humble on the host and the AWSIM binary; the dev machine has neither. Work on branch
> **`fi3-shim`** (`git fetch && git switch fi3-shim`). Tick the checkboxes and commit as stages
> complete, so progress travels through git.
>
> **Written to be picked up cold** by a person or a fresh Claude Code session. All paths are
> repo-relative (`$REPO = git rev-parse --show-toplevel`) or `~/…` on the lab PC. Evidence tags follow
> the study's convention: `[code]`/`[spec]`/`[runtime]`/`[INFERRED]`/`[UNVERIFIED]`.
>
> **Status (2026-10-01):** Stages A–C and D0 **pass** (evidence in `evidence/`). Next: D1/D2 with
> Autoware running and a human watching the vehicle. See "As built" below for deviations from this plan.

### As built (deviations from §2–§4)
- **Symbol resolution:** `real()` tries `dlsym(RTLD_NEXT)` then `dlopen("libddsc.so.0", RTLD_NOLOAD)`,
  because rmw/libddsc are `dlopen`ed `RTLD_LOCAL`. All ddsc calls go through these pointers (the shim is
  not linked to ddsc). Bare-Cyclone `dds_create_topic` also routes through the hooked
  `dds_create_topic_sertype`, so plain C writers are covered too `[runtime]`.
- **Dropped samples** (`stall latest`, `stretch`, queue full) are freed with the header-inline
  `ddsi_serdata_unref` (Humble's ddsc asserts `refc == 0` in free).
- **Modes cut:** no `FI3_REORDER`, no `FI3_DIST=gauss` (uniform jitter, FIFO only).
- **No new bench publisher / checker / live runner.** Bench writer = Module 1's `real_speed_monitor`
  (built here; stamps on `CLOCK_MONOTONIC` like the tap — the rclpy node stamps wall clock, which makes
  `stamp_age` meaningless against the tap). Checker = `../../fi1-data-age/analysis/fi1_seu_check.py`,
  now also counting mid-stream `STALE` episodes. Live runner = `../../fi1-data-age/live/run_case.sh NAME DUR --baseline`
  with AWSIM launched as `FI3_… LD_PRELOAD=$SHIM/build/libfi3_delay.so scripts/launch-awsim.sh`.
- **No shim↔tap cross-check script**; the shim's own log shows delays within 0.5 ms of target
  (`evidence/stage_c_bench.txt`).
- **No `dds_writecdr` hook needed:** the D0 probe shows the LiDAR plugin also publishes via `dds_write`
  (`evidence/d0_probe_lidar.txt`); target topic `rt/sensing/lidar/top/pointcloud_raw_ex`.

## 1. Why a shim (context)

The task: *"Modify the source code of the sensor to delay publication (FI3 option 2); if not possible,
explain why. If option 2 is not possible, adapt FI4 to run FI3 option 1."*

The literal source edit exists in `../option2-source-delay/` (C#), but:
- **It needs Unity.** The lab PC runs the **prebuilt** `AWSIM-Demo-Lightweight.x86_64`. A C# edit takes
  effect only after a rebuild in Unity Editor 6000.0.34f1 plus `Shinjuku.unitypackage`, and neither is installed.
- **Its timing is wrong.** Those files stamp and sample at *emission*. A constant delay then only
  shifts the phase of the stream: inter-arrival stays at 33 ms and every stamp is fresh, so the SEU
  sees nothing.
- **The camera target does nothing.** Autoware Core runs no traffic-light recognition; Core perception is
  LiDAR-only (`autoware_core_perception.launch.xml`). Nothing subscribes to `/sensing/camera/traffic_light/image_raw`.

**The shim route** `[code]`: inside the AWSIM process, every ROS 2 publish ends in Cyclone's
`dds_write()`:
- C# sensors: `ros2cs → librcl → rmw_cyclonedds → dds_write` (`rmw_node.cpp:1834`);
- the LiDAR plugin `libRobotecGPULidar.so`: `rclcpp → rcl → rmw_cyclonedds → dds_write`.

A small library loaded with `LD_PRELOAD` provides its own `dds_write`. For **one target topic** it:
1. serializes the sample immediately, so the stamp and value stay as measured;
2. queues it;
3. sends it later from a background thread.

Every other topic passes straight through. AWSIM, Unity and Autoware are not modified. To turn it
off, launch without `LD_PRELOAD`. The effect is the real publication-delay semantics: **measured
on time, delivered late.**

**Primary target:** `rt/vehicle/status/velocity_status` (ROS `/vehicle/status/velocity_status`). Its
consumers are `vehicle_velocity_converter` → EKF, and the SEU channel (`../../recon/report.md`).
**Optional:** the LiDAR point cloud (Stage E).

## 2. Design

**Hooks** (resolve the real symbols lazily with `dlsym(RTLD_NEXT, …)` on first use; libddsc is
`dlopen`ed after the shim loads):

| Hooked symbol | What the shim does |
|---|---|
| `dds_create_topic_sertype(pp, name, struct ddsi_sertype **st, qos, listener, sedp_plist)` | Call the real function, then record `topic → (name, *st)`. It must read `*st` **after** the call, because it may be swapped for an already-registered sertype. rmw_cyclonedds creates every topic this way (`rmw_node.cpp:1769`). Cyclone 0.10 has **no public getter** for a writer's sertype, which is why this hook exists. |
| `dds_write(wr, data)` | `tp = dds_get_topic(wr)`. If it isn't the target, or the fault is inactive, return `real_dds_write`. Otherwise `d = ddsi_serdata_from_sample(st, SDK_DATA, data)` (inline, `ddsi_serdata.h:270`; the same thing `dds_write` does internally), enqueue `(wr, d, t_release)`, and return `DDS_RETCODE_OK`. |

**Sender thread:** uses `CLOCK_MONOTONIC`. At `t_release` it calls the real
`dds_writecdr(wr, d)` (`dds.h:2608`, which consumes the reference). If rc < 0 (e.g. the writer is
gone at shutdown) it calls `ddsi_serdata_unref(d)`. No `atexit` flush. The queue is capped
(`FI3_QUEUE_MAX`, default 1024) and overflow drops are logged.

**Config** — environment variables (read once, on first call):

| Var | Default | Meaning |
|---|---|---|
| `FI3_TOPIC` | `rt/vehicle/status/velocity_status` | DDS topic name to delay (exact match) |
| `FI3_MODE` | `off` | `off` \| `probe` (log topics only, no delay) \| `fixed` \| `jitter` \| `stall` \| `stretch` |
| `FI3_DELAY_MS` | `0` | base delay (`fixed`, `jitter`) |
| `FI3_JITTER_MS`, `FI3_DIST` | `0`, `uniform` | ± jitter; `uniform` \| `gauss` (σ = jitter) |
| `FI3_REORDER` | `0` | `0` = FIFO (release = max(prev_release, t+d)); `1` = allow reordering |
| `FI3_STALL_MS`, `FI3_STALL_POLICY` | `0`, `flush` | `stall`: hold everything for STALL_MS, then `flush` (burst) or `latest` (send newest only, drop the rest) |
| `FI3_RATE_HZ` | `0` | `stretch`: forward at most one sample per 1/RATE_HZ, keeping the newest |
| `FI3_START_S`, `FI3_DURATION_S` | `0`, `0` (=forever) | fault window, relative to the first matching write |
| `FI3_LOG` | `/tmp/fi3_shim.log` | ground truth: `topic seq t_in_ns t_out_ns delay_ms action` per intercepted sample |

It prints `[FI3] ARMED topic=… mode=… …` on stderr at arm time, so a faulted run can't be
mistaken for a nominal one.

**Mode → expected SEU signal** (thresholds from FI1: Δ_fresh = Δ_expiry = 165 ms, P_rate dt ∈ [25,40] ms):

| Mode | Wire effect | Expected on the tap |
|---|---|---|
| `fixed d` | every sample late by d; cadence unchanged | stamp age ≈ d → **P_age** iff d > 165 |
| `jitter d±j` | variable inter-arrival | **P_rate** outliers |
| `stall S` | arrival gap of S, then a burst (`flush`) or one sample (`latest`) | **STALE** (watchdog) + **P_rate**; burst samples also trip **P_age** |
| `stretch R` | sustained period 1/R | **P_rate** upper edge (R < 25 Hz) |

**ABI:** AWSIM bundles `libddsc.so.0.10.3`. Build against **`/opt/ros/humble/include`** (ros-humble-cyclonedds,
0.10.x). `ddsi_serdata.h`/`ddsi_sertype.h` are identical from 0.10.3 to 0.10.5 `[code]` (`git diff 0.10.3 HEAD`
in the upstream clone).

## 3. Files to create (under `awsim-study/experiments/fi3-publication-delay/shim/`)

| File | Purpose | Based on |
|---|---|---|
| `src/fi3_delay_shim.c` | the shim | — |
| `CMakeLists.txt` | `libfi3_delay.so` (`-fPIC -shared`, `dl`, `pthread`, Cyclone include dirs only; **do not link ddsc**) + `include(../../_common/common.cmake)` for `trusting_consumer` | `../../fi1-data-age/bench/CMakeLists.txt` |
| `bench/fi3_nominal_pub.py` | 30 Hz rclpy `VelocityReport` publisher (fresh stamp, ramping value) | overlay in `../../fi1-data-age/fi1_ros2_ws` |
| `run_bench.sh` | Stage C matrix | `../../fi1-data-age/bench/run_bench.sh` |
| `analysis/fi3_seu_check.py` | P_age/P_rate/STALE + jitter stats + gap detector + cross-check against `FI3_LOG` | `../../fi1-data-age/analysis/fi1_seu_check.py` |
| `live/run_case_fi3.sh` | Stage D per-case runner (bag + tap + checks) | `../../fi1-data-age/live/run_case.sh`, **but with no hard-coded `/home/joao.anders/…` paths** |
| `evidence/` | curated log excerpts (raw `logs/` is gitignored) | repo convention |

## 4. Stages (checklists)

Common environment for every stage:
```bash
REPO=$(git rev-parse --show-toplevel)
SHIM=$REPO/awsim-study/experiments/fi3-publication-delay/shim
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
```

### Stage A — prerequisites + implement (lab PC)
- [x] `grep -h 'DDS_VERSION ' /opt/ros/humble/include/dds/version.h` → 0.10.x. **Stop** if the
      `dds/ddsi/ddsi_serdata.h` header is missing (then clone `eclipse-cyclonedds/cyclonedds@0.10.3`
      and configure it only to generate the headers).
- [x] `find ~/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight_Data/Plugins -name "libddsc.so*" -o -name "librmw_cyclonedds_cpp.so"` shows `libddsc.so*` and `librmw_cyclonedds_cpp.so`.
- [x] Informational: `ls …_Data/Managed/Assembly-CSharp.dll` exists and there is **no** `GameAssembly.so`
      (a Mono build; this matters only for the non-shim fallback).
- [x] Implement the §3 files. `cmake -S $SHIM -B $SHIM/build && cmake --build $SHIM/build` → `libfi3_delay.so`.
- [x] `nm -D $SHIM/build/libfi3_delay.so | grep -E ' T (dds_write|dds_create_topic_sertype)$'` shows both.
- [x] The fi1 overlay is built: `(cd $REPO/awsim-study/experiments/fi1-data-age/fi1_ros2_ws && colcon build)`.

### Stage B — reachability smoke (lab PC, no AWSIM)
- [x] `FI3_MODE=probe LD_PRELOAD=$SHIM/build/libfi3_delay.so python3 $SHIM/bench/fi3_nominal_pub.py`
      (overlay sourced). **Pass:** `FI3_LOG` lists `rt/vehicle/status/velocity_status`. This proves the
      preload survives rmw being `dlopen`ed, which rehearses Unity's plugin loading.
- [x] Same run, but the tap `$SHIM/build/trusting_consumer` receives samples with `FI3_MODE=off`, and the stack keeps working.

### Stage C — bench matrix (lab PC, no AWSIM; stamp_age is valid because everything shares one wall clock)
- [x] `$SHIM/run_bench.sh`: each case = tap + preloaded `fi3_nominal_pub.py` for `DUR` s, then `fi3_seu_check.py`:

| Case | Env | Expect |
|---|---|---|
| `control` | `FI3_MODE=off` | NONE; mean dt ≈ 33 ms |
| `fixed80` | `fixed`, `DELAY_MS=80` | NONE (latency ≈ 80 ms recorded, < 165) |
| `fixed250` | `fixed`, `DELAY_MS=250` | P_age |
| `jitter` | `jitter`, `DELAY_MS=30 JITTER_MS=25` | P_rate |
| `stall_flush` | `stall`, `STALL_MS=400 START_S=2` | STALE + P_rate + P_age |
| `stall_latest` | `stall`, `STALL_MS=400 START_S=2 STALL_POLICY=latest` | STALE + P_rate |
| `stretch10` | `stretch`, `RATE_HZ=10` | P_rate |

- [x] **Gate → Stage D:** every case produces exactly its expected verdict set, **and** the cross-check
      (shim `t_out` vs tap arrival) agrees within ±2 ms. Commit the curated excerpts to `evidence/`. **Do
      not go live with a flaky oracle.**

### Stage D — live AWSIM (lab PC; a human watches the vehicle)
Safety steps, same as FI1 (`../../fi1-data-age/report.md §4`, `../../stage2-run-plan.md`):
S2-0 bring-up (pose → NVTL → goal → engage, `../../fi1-data-age/live/*.sh`), a snapshot plus a
one-command restart, and one fault run per AWSIM launch (**restart AWSIM between cases**; the env is
read once).

- [x] **D0 — preload reaches AWSIM:** launch AWSIM exactly as in `setup/autoware-core-awsim-setup-guide.md §6a`,
      but with `FI3_MODE=probe LD_PRELOAD=$SHIM/build/libfi3_delay.so ./AWSIM-Demo-Lightweight.x86_64`.
      **Pass:** `FI3_LOG` lists the target topic (and LiDAR topics). **If it's empty**, Unity's
      loading bypasses the preload: stop and fall back (§6).
- [ ] **D1 — baseline:** `FI3_MODE=off`. The vehicle drives the route normally; record the baseline with `../../fi1-data-age/live/run_case.sh fi3_baseline 60 --baseline`.
- [ ] **D2 — matrix:** the §C cases, one per AWSIM launch, via `../../fi1-data-age/live/run_case.sh fi3_<case> <dur> --baseline` (AWSIM relaunched with that case's `FI3_*` env). Judge
      on **arrival-side dt + shim ground truth**, not stamp_age (AWSIM stamps with the sim `/clock`
      and the tap compares against wall clock). Record the stack's reaction: the EKF
      (`/localization/kinematic_state`), `/sensing/vehicle_velocity_converter/twist_with_covariance`, the
      operation mode, and whether anything degrades or stops (absent the SEU).
- [ ] Commit evidence + a `report.md` (verdicts, the stack's reaction, confidence table).

### Stage E — optional: LiDAR target
- [x] From the D0 probe log, take the exact point-cloud topic name (expected around
      `rt/sensing/lidar/top/pointcloud_raw_ex` `[UNVERIFIED]`).
- [ ] Re-run D2 `fixed`/`stall` with `FI3_TOPIC=<that>`. Watch the copy cost at 10 Hz. This is the delay
      on Core perception's real input (ground filter + euclidean clustering, and NDT via the LiDAR chain).

## 5. Rollback / blast radius
- Launch AWSIM without `LD_PRELOAD` and the fault is gone; nothing is installed or modified.
- Only the AWSIM process is affected; the Autoware container is untouched.
- Only `FI3_TOPIC` writers are delayed; every other topic takes the real path.

## 6. Fallbacks, if D0 shows the preload doesn't reach AWSIM
1. **Patch the managed DLL** (Mono build): IL-edit `AccelVehicleReportRos2Publisher.Publish` in
   `Assembly-CSharp.dll` with Mono.Cecil, or runtime-patch it with BepInEx + Harmony. No Unity needed.
2. **Unity rebuild** with the (corrected) `../option2-source-delay/*.fi3.cs`: needs Unity 6000.0.34f1 +
   `Shinjuku.unitypackage`, scene `AutowareSimulationURPDemo.unity`.

## 7. Known issues in `../option2-source-delay/` to fix in the docs
- The emission-time stamp makes a constant delay invisible, so the README's "250 ms ⇒ STALE" and
  "delay > 33 ms stretches the period" claims are wrong.
- The camera target has no consumer in Autoware Core.
- Its config is Inspector-only, so it can't be set in a built player.
