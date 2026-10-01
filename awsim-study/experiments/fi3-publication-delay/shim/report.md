# FI3 — publication delay via `LD_PRELOAD` shim: results

Lab PC `ml-XPS-8960`, 2026-10-01. Runbook: `PLAN.md`. Evidence: `evidence/stage_c_bench.txt` (bench),
`evidence/d0_probe_*.txt` (preload reaches AWSIM), `evidence/stage_d_live.txt` (live).

## Setup
- Shim `build/libfi3_delay.so` preloaded into the AWSIM process; target `rt/vehicle/status/velocity_status`.
  Samples are serialized at `dds_write` time (stamp + value as measured) and released later via `dds_writecdr`. [runtime]
- Live driver `run_live.sh NAME DUR FI3_*=…`: relaunch AWSIM with the case env → `../../fi1-data-age/live/reset_aw.sh 60`
  (relaunch Autoware Core, localize, 60 m route) → `run_case.sh` (bag + tap + checker) → engage at launch+150 s.
  Stall cases use `FI3_START_S=165` ⇒ the stall lands mid-drive (confirmed: lv ≈ 2.0 / 1.2 m/s at the gap).
- Oracle: tap arrival-side dt + STALE + the shim log (ground-truth delay). Live `stamp_age` is invalid (AWSIM stamps
  with sim `/clock`, the tap compares against monotonic), so **P_age fires in every live case including baseline**;
  P_stuck fires on the standstill before/after the drive. Both are ignored live.

## Results — live (D1/D2)

| Case | Shim (ground truth) | Tap dt p5/p50/p95/max (ms) | STALE | SEU-visible? | Stack reaction |
|---|---|---|---|---|---|
| baseline (`off`) | — | 17.6 / 32.8 / 49.0 / 94 | 0 | — | 59.3 m, NVTL min 3.05 |
| fixed80 | 80.1 ms mean (max 84) | 30.5 / 33.3 / 36.4 / 99 | 0 | **no** (only P_age with a valid clock) | 59.3 m, NVTL min 2.98 |
| fixed250 | 250.1 ms mean (max 252) | 28.7 / 33.3 / 37.6 / 80 | 0 | **no** (only P_age with a valid clock) | 59.3 m, NVTL min 2.99 |
| jitter 30±25 | 30.5 ms mean (max 55) | **0.1** / 33.1 / **66.5** / 82 | 0 | yes — dt spread | 59.2 m, NVTL min 3.02 |
| stall_flush 400 | one 380 ms hold, then 11-sample burst | 30.6 / 33.3 / 36.1 / **414** | **1** | yes — STALE (180→414 ms) | 59.2 m, NVTL min 2.91 |
| stall_latest 400 | 11 dropped, newest released | 19.3 / 33.3 / 47.2 / **410** | **1** | yes — STALE | 59.3 m, NVTL min 3.03 |
| stretch10 | 1911 sent / 3822 dropped | **99.9 / 100.0 / 100.1** / 102 | 0 | yes — rate 10 Hz | 59.2 m, NVTL min 2.86 |

Bench (Stage C, valid shared clock): all 7 cases hit their expected verdict sets, incl. P_age for fixed250
(`evidence/stage_c_bench.txt`).

## Findings
1. **The shim works live.** Delays observed by the tap match the shim's log; AWSIM is unaffected otherwise. [runtime]
2. **Autoware Core does not react to any FI3 case.** Every run completes the 60 m route (59.2–59.3 m), localization
   stays INITIALIZED, NVTL ≥ 2.86, control commands identical in range; no degradation, MRM or stop. The converter
   and EKF consume 250 ms-old or 10 Hz velocity without complaint. [runtime] ⇒ FI3 is silent to the stack: only an
   external monitor (the SEU) can flag it.
3. **A constant delay is invisible on the arrival side.** fixed80/fixed250 keep dt at 33 ms; only P_age on
   `header.stamp` against the *same clock as the stamp* detects it. A live SEU therefore needs a sim-time (or
   wall-clock-stamped) reference — the current tap cannot judge P_age against AWSIM. [runtime]
4. **The DDS source timestamp is no help:** `dds_writecdr` rewrites it at release (`dds_write.c:76`), so a monitor
   keyed on it would see fixed delays as zero latency. [code]
5. **AWSIM's native dt is noisy** (p5 17.6 / p95 49 ms at baseline): P_rate's [25,40] ms band is violated with no
   fault, so live P_rate needs a widened band or a percentile test. Queued modes (fixed*, stall_flush) *smooth* dt
   because the shim's sender thread re-times releases off Unity's frame loop. [runtime]
6. **STALE (Δ_fresh 165 ms) cleanly catches both stall policies** mid-drive with no false episodes in any other case.

## Confidence
| Claim | Level |
|---|---|
| Shim delays as configured (bench + live) | high — shim log and tap agree |
| Autoware Core tolerates FI3 at these magnitudes | medium — one 60 m route, 1 run per case, ≤ 4.2 m/s |
| Fixed delay undetectable without a valid stamp clock | high |
| Larger stalls/delays also tolerated | untested — next: stall 2000 ms, fixed 1000 ms |
