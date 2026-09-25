#!/usr/bin/env bash
# stage2-preflight.sh — S2-0 go/no-go for the live AWSIM+Autoware run.
# Runs only READ-ONLY checks (safe to run anytime on ml-XPS-8960), then prints the
# interactive launch/verify sequence a human drives. See experiments/stage2-run-plan.md.
set -u
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "== S2-0 read-only preflight gate =="
[ "$(hostname)" = "ml-XPS-8960" ] && ok "hostname ml-XPS-8960 (sim host)" || no "not the lab PC — sim runs only on ml-XPS-8960"
ip link show lo 2>/dev/null | grep -q MULTICAST && ok "lo has MULTICAST" || no "lo lost MULTICAST -> ask admin: ip link set lo multicast on"
[ "$(sysctl -n net.core.rmem_max 2>/dev/null)" -ge 2147483647 ] 2>/dev/null && ok "net.core.rmem_max sized" || no "net.core.rmem_max too small"
docker images 2>/dev/null | grep -q 'autoware:core-humble' && ok "autoware:core-humble image present" || no "core-humble image missing"
[ -f "$HOME/cyclonedds.xml" ] && ok "~/cyclonedds.xml present" || no "~/cyclonedds.xml missing (copy from image, lab-machine-setup §2.1)"
[ -x "$HOME/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight.x86_64" ] && ok "AWSIM binary present+exec" || no "AWSIM binary missing"
[ -f "$HOME/AWSIM-Demo-Lightweight/Shinjuku-Map/map/pointcloud_map.pcd" ] && ok "Shinjuku map present" || no "Shinjuku map missing"
[ -f /opt/ros/humble/lib/librmw_cyclonedds_cpp.so ] && ok "Cyclone RMW installed" || no "Cyclone RMW missing"
source /opt/ros/humble/setup.bash 2>/dev/null
nf=$(find "$HOME/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight_Data/Plugins" -name '*.so*' -print0 2>/dev/null | xargs -0 ldd 2>/dev/null | grep -c "not found")
[ "${nf:-1}" -eq 0 ] && ok "AWSIM plugin deps all resolve" || no "$nf AWSIM plugin deps unresolved"

echo; echo "== gate result: $pass pass / $fail fail =="
[ "$fail" -ne 0 ] && { echo "STOP: clear the FAILs before launching."; exit 1; }

cat <<'STEPS'

== Interactive launch (human drives these — GUI/RViz, not scriptable) ==
Terminal 1 (AWSIM, keep ROS 2 sourced — lab-machine-setup §3):
  source /opt/ros/humble/setup.bash
  export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
  cd ~/AWSIM-Demo-Lightweight && ./AWSIM-Demo-Lightweight.x86_64
  Verify: grep -iE "ROS2 version|Failed to open plugin" ~/.config/unity3d/TIERIV/AWSIM/Player.log
          -> want "RMW: rmw_cyclonedds_cpp" and NO "Failed to open plugin"

Terminal 2 (Autoware Core container + stack — setup-guide §6b-6c):
  xhost +local:
  # launch container --net host, then inside: ros2 launch autoware_core autoware_core.launch.xml ...

RViz (setup-guide §7-8):  set initial pose -> check NVTL -> set goal -> ENGAGE autonomous.

== Observability + records to capture as [runtime] (dated) ==
  ros2 topic info -v /vehicle/status/velocity_status   # Autoware reader QoS + participant prefix (settles a wiki §10 row)
  ros2 topic hz  /vehicle/status/velocity_status        # nominal inter-arrival on the live channel
  # DDS-Security: note presence/absence of auth handshake traffic on the Cyclone monitor participant

== SAFETY GATE before any injection (S2-1) — plan §6 ==
  Snapshot / confirm one-command restart of BOTH halves. Re-capture the LIVE speed-writer GUID
  (it is ephemeral). Only then run the Phase-2 forge (experiments/module1-freshness-loss/). Do NOT inject without a human
  watching the vehicle reaction.
STEPS
