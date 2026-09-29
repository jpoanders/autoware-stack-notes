# FI3 — Publication Delay, option 2: sensor-source delay

> **Task.** "Modify the source code of the sensor to delay publication (FI3 option 2); if not
> possible, explain why. If option 2 is not possible, adapt FI4 to run FI3 option 1; if that is not
> possible, explain why." This folder answers that. **Read the [FI3 options report](../options.md)
> and the [FI1 report](../../fi1-data-age/report.md) for the property/SEU context.** Evidence tags:
> `[code]`/`[spec]`/`[runtime]`/`[INFERRED]`/`[UNVERIFIED — needs Stage 2]`.

> **Update 2026-09-29:** the route being implemented is **not** this Unity rebuild. It is an
> `LD_PRELOAD` shim on Cyclone's `dds_write` in the AWSIM process: no Unity, and it keeps the
> acquisition-time stamp. See **[`../shim/PLAN.md`](../shim/PLAN.md)**. Known issues in this folder
> (§7 there): emission-time stamping makes a constant delay invisible; the camera topic has no
> consumer in Autoware Core; the fault can only be armed from the Inspector.

## Verdict

**Option 2 is feasible and is implemented here — but it cannot take effect on the lab PC's *current*
deployment without standing up the AWSIM Unity project + Editor.** It is not a code problem; it is a
deployment problem.

| Question | Answer | Evidence |
|---|---|---|
| Is the sensor/publisher source available? | **Yes.** The velocity report is published by `AccelVehicleReportRos2Publisher.Publish()`, driven at 30 Hz by `InvokeRepeating` | `[code]` `AccelVehicleReportRos2Publisher.cs:96,122-154` |
| Is there a clean injection point for a delay? | **Yes.** The six status reports are built, stamped, then published in one method; the velocity publish is one call that can be deferred in isolation | `[code]` `:147-153` |
| Can the edit take effect on what the lab PC runs today? | **No — not as-is.** AWSIM runs as a **prebuilt binary** (`AWSIM-Demo-Lightweight.x86_64`, downloaded from releases), and a C# edit is compiled into the Unity player; the binary cannot pick up source changes | `[code]` `setup/autoware-core-awsim-setup-guide.md §5` (`wget …/AWSIM-Demo-Lightweight.zip`, run `./…​.x86_64`) |
| What unblocks it? | Open the AWSIM **Unity project** (v2.0.1, upstream `awsim@9e55528`) in the matching Unity Editor and press Play, **or** rebuild the standalone player. Neither is installed or documented in the current setup | `[code]` `src/REPOS.md` (awsim v2.0.1); setup guide documents only the binary download |

So: **option 2 is the correct path** (the fault is precise, isolated to one topic, toggle-reversible),
**conditional on** a Unity toolchain on the lab PC. Building/running it is a lab-PC Unity step and is
therefore `[UNVERIFIED — needs Stage 2]`.

## Which sensor — perception-sensor feasibility (the important split)

The target chosen is a **perception sensor** (the truest "sensor" in FI3, whose delay stresses a
*dependent transformer's* execution time → the "processing overrun" the SEU must catch). Feasibility of
a source-delay edit is **not uniform across sensors** — it depends entirely on *where each publishes*:

| Sensor / publisher | Publishes from… | Source-delay feasible? | Evidence |
|---|---|---|---|
| **Camera** `CameraRos2Publisher.cs` | C# `_imagePublisher.Publish(...)` | **Yes — clean C# edit** | `[code]` `:232-233` |
| **IMU** `ImuRos2Publisher.cs` | C# `_imuPublisher.Publish(...)`, event-driven | **Yes — clean C# edit** | `[code]` `:88,103` |
| **GNSS** `GnssRos2Publisher.cs` | C# `_navSatFix/_posePublisher.Publish(...)` | **Yes — clean C# edit** | `[code]` `:102,115,132-133` |
| **LiDAR / radar** `RglLidarPublisher.cs` | **native RGL plugin graph** (`AddNodePointsRos2Publish`), *not* C# | **No — not via a publisher-script edit** | `[code]` `:96-102` |

**The LiDAR caveat is the load-bearing finding.** `RglLidarPublisher` only *builds an RGL node graph*;
the actual ROS 2 point-cloud publish executes inside the native Robotec GPU Lidar plugin (`librgl`,
likely a prebuilt `.so` not in the AWSIM C# repo) when a scan completes. There is **no C# `Publish()`
call to wrap**, so the coroutine-delay technique used here does not reach it. Delaying the LiDAR cloud
would require modifying the native RGL plugin or interposing a delay in the LiDAR scan-trigger path — a
separate, larger effort, **out of scope for "modify the sensor publisher source."** If the LiDAR→NDT
localization chain is the intended FI3 target, that is the one case this approach cannot cover cleanly.

**Implemented in this folder** (both drop-in replacements, fault OFF by default):
- `CameraRos2Publisher.fi3.cs` — **recommended perception target.** Delays `/sensing/camera/traffic_light/image_raw`
  (+ `camera_info`) → stresses the traffic-light-recognition transformer.
- `AccelVehicleReportRos2Publisher.fi3.cs` — the ego-velocity-status variant (SEU / FI1 target channel,
  continuity with Modules 1-3). Kept as an alternative / lighter-weight demo target.

The IMU and GNSS variants are the *same* two-method edit applied to their `Publish(...)` callbacks — ask
and I will generate them; they are trivial given the pattern above.

## What the modification does

`AccelVehicleReportRos2Publisher.fi3.cs` is a drop-in replacement for the upstream file. It adds four
Inspector fields (fault **OFF** by default) and defers **only** the velocity publish:

| Field | Effect |
|---|---|
| `_fi3Enabled` | master switch; `false` ⇒ byte-for-byte upstream behaviour |
| `_fi3DelayMeanMs` | mean delay before each velocity publish; `> 1000/PublishHz` (≈33 ms) stretches the period |
| `_fi3DelayJitterMs` | uniform ± jitter on the delay (`0` = fixed delay) |
| `_fi3UseRealtime` | wall-clock delay (`WaitForSecondsRealtime`), independent of `Time.timeScale` |

The other five status reports (`control_mode`, `gear_status`, …) stay on the nominal 30 Hz tick, so the
fault is **isolated to `rt/vehicle/status/velocity_status`** — the SEU / FI1 target channel
(`experiments/recon/report.md`). The delayed sample is stamped at *emission* time, so it carries a
**fresh `header.stamp` but arrives late**: the SEU sees increased inter-arrival / arrival-age, not a
back-dated stamp (this matches the options report's mapping — FI3 trips **P_rate's upper edge** and the
arrival watchdog, `[options.md §2]`). A back-dated variant is a one-line change, noted in the source.

Three delay shapes, per the options report's variants (a)/(b)/(c):
- **one-shot / sustained gap** — set `_fi3DelayMeanMs` (e.g. 250 ms > Δ_fresh 165 ms) ⇒ `STALE` on the
  arrival watchdog `[INFERRED from fi1-data-age/report.md]`.
- **period stretch** — a delay comparable to the 33 ms period ⇒ `dt > 40 ms`, **P_rate** upper edge.
- **jitter** — nonzero `_fi3DelayJitterMs` ⇒ variable `dt`, **P_rate** on outliers.

## Build / run procedure (lab PC `ml-XPS-8960`, Stage 2)

> `[UNVERIFIED — needs Stage 2]` — this is the intended procedure; it has not been executed (no Unity
> toolchain in the documented setup, and the sim runs only on the lab PC).

1. **Get the AWSIM Unity project** (not the binary): clone `autowarefoundation/AWSIM` at the pinned
   `v2.0.1` / `9e55528` (`src/REPOS.md`) into a *working copy* — **never build from the read-only
   `src/` evidence tree.**
2. **Install the matching Unity Editor** (the version in the project's `ProjectSettings/ProjectVersion.txt`)
   and the AWSIM ROS2-for-Unity dependencies per upstream AWSIM docs.
3. **Apply the edit** (perception target = camera): replace
   `Assets/Awsim/Scripts/Entity/Sensor/Camera/Ros2/CameraRos2Publisher.cs`
   with `CameraRos2Publisher.fi3.cs` from this folder (rename to the original name; keep the class name
   `CameraRos2Publisher`). For the velocity variant instead, replace
   `Assets/Awsim/Scripts/Entity/Vehicle/AccelVehicle/Ros2/AccelVehicleReportRos2Publisher.cs` with
   `AccelVehicleReportRos2Publisher.fi3.cs`. In either case confirm it **compiles** in the Editor console
   — the FI3 edit only reuses upstream field/method names verbatim, so a compile error means a binding
   name drifted between AWSIM versions.
4. **Configure QoS/DDS as the setup guide requires** (force `rmw_cyclonedds_cpp`, mirror `cyclonedds.xml`)
   so the Editor-run AWSIM matches the container — otherwise no discovery (`setup guide §4,§6a`).
5. **Arm the fault** in the Inspector on the AccelVehicle's report-publisher component: check
   `_fi3Enabled`, set `_fi3DelayMeanMs` / `_fi3DelayJitterMs`. A `[FI3] … ARMED` warning prints on start.
6. **Run** AWSIM from the Editor (Play) with Autoware in its container, and capture the velocity channel
   with the FI1 tap (`experiments/_common/consumer/trusting_consumer.c` + `fi1_seu_check.py`), which
   already logs `dt_ms` and the arrival watchdog — **no tap change needed** for the rate/freshness facet
   (`[options.md §2]`).
7. **Disable** by unchecking `_fi3Enabled` (no rebuild) or restoring the upstream file.

**Negative control:** `_fi3Enabled = false` (or `_fi3DelayMeanMs = 0`) must reproduce nominal —
zero `STALE`, mean `dt ≈ 33 ms`, P_rate pass — isolating the delay as the sole cause of any alarm.

## Fallback branch: "adapt FI4 to run FI3 option 1"

Two independent findings, either of which blocks this fallback:

1. **There is no `FI4` in this study.** A repo-wide search (`experiments/`, `study/`, `docs/`, the
   sibling `~/awsim-study`, and `~/.claude/plans`) finds **no FI4 artifact, roadmap entry, or
   reference** `[runtime]` (grep, 2026-09-28). The catalog here is Module 1 (freshness-loss), Module 2
   (wrong-value), Module 3 = **FI1** (data-age). **I cannot adapt an FI4 that does not exist — please
   point me to it if it lives outside these trees** (see question below).

2. **Even with a flooding harness, option 1 cannot induce a publication delay on this stack** — a
   physics/topology fact, independent of which harness runs it (`[options.md §3]`, HIGH confidence):
   - **No network to overload.** AWSIM (native) ↔ Autoware (`--net host`) is **UDP over loopback,
     domain 0** — no NIC, no switch, no shared-memory path `[code]` (`study/foundation.md:276`, setup
     guide §0). "Overload the network switch near the publication instant" has no switch to overload.
   - **Sub-`WhcHigh` target.** The velocity payload (~30 B at 30 Hz ≈ 0.9 kB/s) is two-plus orders below
     `WhcHigh = 500 kB`; FI1's 10× run measured **1793/1793 `write_rc=OK`, zero WHC stalls**
     `[runtime]` (`fi1-data-age/report.md §3.3`). A flood never fills the target's queue.
   - **Flooding delays the flooder, not the victim.** Over-publishing past `WhcHigh` throttles the
     **flooder's own** `publish()` and is delivered on the **flooder's own** writer/sequence space —
     it cannot delay someone else's publisher `[code]` (`study/task-3-report.md §4,§6`; roadmap
     flow-control note).

   The only loopback analogue of "heavy traffic → service unavailability" is **CPU/scheduler
   contention** on Cyclone's shared transmit/recv threads (cgroup limits / `stress-ng` on the Autoware
   container), whose magnitude is `[UNVERIFIED — needs Stage 2]`. That is a *scheduler* fault, not the
   *network flood* of option 1.

**Conclusion for the fallback:** option 1 as written (network overload) is **not possible** on this
loopback deployment regardless of the harness, so adapting FI4 (or any flooder) to run it would not
produce FI3's publication delay. The viable route to FI3 is **option 2 (this folder)**; the viable
loopback *analogue* of option 1 is **CPU/scheduler starvation**, which the options report ranks as the
Stage-2 realism complement (option 3 there), not a network flood.

## Open question for the user

- **What is `FI4`?** It is not in these trees. If it is an external harness (another repo, a plan file,
  or a flooding tool you have in mind), point me to it and I will assess adapting it — but note the
  fallback is blocked by the loopback transport above, not by the harness. If you meant **FI1** (the
  existing data-age harness), say so and I will spell out the CPU-starvation adaptation instead.
