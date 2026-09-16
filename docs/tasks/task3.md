After the interface and integration have been approved, execute the previously defined nominal, F1, F2, F3, monitor-resilience, resource-overhead, and latency experiments.


CHAIN TOPOLOGY
Four nodes in a linear DAG:
n0: LiDAR driver      -> publishes /sensing/lidar/pointcloud
n1: Object detector   -> subscribes n0, publishes
/perception/detected_objects
n2: Object tracker    -> subscribes n1, publishes
/perception/tracked_objects
n3: Planner (me)      -> subscribes n2, publishes
/planning/trajectory

DDS QoS CONFIGURATION (applied to each DataWriter/DataReader)
n0 DataWriter /sensing/lidar/pointcloud:
RELIABILITY  = RELIABLE
DEADLINE     = 100 ms      (T_s  = 100 ms)
LIFESPAN     = 100 ms      (A_s  = 100 ms)
USER_DATA    = []          (no WCET; hardware node)
HISTORY      = KEEP_LAST 1
n1 DataWriter /perception/detected_objects:
DEADLINE     = 100 ms
LIFESPAN     = 150 ms
USER_DATA    = [wcet=40]   (W_d1 = 40 ms)
HISTORY      = KEEP_LAST 1
n2 DataWriter /perception/tracked_objects:
DEADLINE     = 100 ms
LIFESPAN     = 150 ms
USER_DATA    = [wcet=20]   (W_d2 = 20 ms)
HISTORY      = KEEP_LAST 1

n3 DataReader /perception/tracked_objects (planner sub):
DEADLINE     = 100 ms      (T_me = 100 ms)
USER_DATA    = [wcet=30]   (W_me = 30 ms)

FAULT INJECTION PROTOCOL
Faults injected via a dedicated fault injector ROS 2 node that intercepts and delays/drops messages on specific topics using a custom DDS middleware plugin.  30 independent runs per fault class; each run lasts 60 s; fault injected at t = 20 s to allow the chain to reach steady state before injection.
F1 — DATA AGE VIOLATION


        
      Mechanism: delay publication of /sensing/lidar/pointcloud by 95 ms beyond its 100 ms period (effective inter-arrival

        
      = 195 ms), causing tau + A_s = tau + 100 ms to exceed EV_threshold = 10 ms at the planner LSEU.

        
      Expected LSEU verdict: FALSE within 1 ms of observing the delayed message (zero-lookahead arithmetic predicate).

        
      Expected B1 (centralized PRV): FALSE only at t_obs + 100 ms (after full planning deadline elapses).

        
      Expected advantage of LSEU: >= 90 ms earlier than B1/B2.

        
      Metric: time-to-verdict (ms) = t_verdict - t_fault_onset. Expect LSEU: <= 10 ms; B1/B2: ~100 ms.

F2 — NODE UNRESPONSIVENESS (detector killed)


        
      Mechanism: send SIGKILL to the object detector node (n1) at t = 20 s, causing permanent silence on /perception/detected_objects.

        
      Expected LSEU verdict: FALSE at t_obs + slack(m) <= 10 ms after the next LiDAR message is observed (phi_wait timer expires without Arr(n1)).

        
      Expected B1: FALSE only after T_me = 100 ms (planner deadline miss detected centrally).

        
      Expected B2: FALSE after next observation round (>= 100 ms).

        
      Expected advantage of LSEU: >= 90 ms earlier than B1/B2.

        
      Additional metric: fraction of /planning/trajectory outputs suppressed before first FALSE verdict (expect 0 for LSEU, >= 1 for B1/B2, representing one unsafe planning cycle).

F3 — PROCESSING OVERRUN (tracker WCET exceeded)


        
      Mechanism: inject artificial sleep of 25 ms into the tracker callback (n2), causing W_d2_actual = 45 ms > W_d2 = 20 ms.

        
      The tracker output arrives at t_arr(n2) = W_d1 + W_d2_actual = 40 + 45 = 85 ms after LiDAR publication, outside the expected window [W_max, T_me - W_me] = [60, 70] ms.

        
      Expected LSEU verdict: FALSE at t_obs + 70 ms (upper bound of phi_wait interval elapses without Arr(n2) in window).

        
      Expected B1: FALSE at t_obs + 100 ms.

        
      Expected B2: FALSE at next round (>= 100 ms).

        
      Expected advantage of LSEU: >= 30 ms earlier than B1/B2.

        
      Metric: also report Out(me) suppression rate --- fraction of planner cycles where trajectory is not published due to overrun; expect LSEU to suppress 100% of overrun cycles, B1/B2 to suppress 0% (they detect too late).

F4 - FALSE INS DATA INJECTION (injection attack)


        
      Inject max(0,speed-10m/s) speed information to create false sense of safety and make vehicle in front brake

        
      Expected result: RSS safe distance is in reality unsafe and crash occurs

        
      Expected LSEU: will fail to identify problem if a safety model (integrating position, for instance) is not in place.

FAULT RESILIENCE SUB-EXPERIMENT


        
      Measure: fraction of monitored properties still evaluable for k = 1 and k = 2 node failures.

        
      Mechanism: kill the centralized PRV monitor node (B1) and one LSEU node (n1 LSEU) simultaneously at t = 20 s.

        
      Expected for LSEU: with k=1 failure, 3 of 4 LSEUs survive and continue issuing verdicts (75% coverage); with k=2, 2 of 4 survive (50% coverage).

        
      Expected for B1 (centralized PRV): k=1 monitor-node failure -> 0% coverage (total loss); k=2 -> 0%.

        
      Expected for B2: partial coverage depending on which decentralized monitor node is killed.

        
      Metric: monitoring_coverage(k) = |evaluable properties| / |total properties| after k failures.

RESOURCE OVERHEAD


        
      Measure per-node CPU utilization (%) and memory (MB) with and without LSEU co-deployed, sampled at 10 Hz.

        
      Expected LSEU overhead: < 1% CPU and < 2 MB memory per node

        
      (on_data_available() is O(1) arithmetic; N_pending = 1).

        
      Confirm that LSEU presence does not increase chain end-to-end

        
      latency (verified by comparing median and 99th-percentile

        
      LiDAR-to-trajectory latency with and without LSEUs).

STATISTICAL REPORTING:


        
      All metrics reported as median +- standard deviation over

        
      30 runs.

        
      Plots: CDF of time-to-verdict per fault class per approach;

        
      box plots of per-node CPU and memory overhead.

Additional Task 3 validity rule:
A trial is invalid when the monitored message, its selected value, its source timestamp, the relevant callback events, and its associated verdict cannot be correlated using the approved Task 1 and Task 2 procedures.
