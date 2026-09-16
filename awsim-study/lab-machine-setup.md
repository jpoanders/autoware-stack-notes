# AWSIM + Autoware Core on the lab machine (no sudo)

How AWSIM was set up and verified on the shared lab PC (hostname **`ml-XPS-8960`**) on **2026-09-16**,
where the user has **no sudo**. **This is the only machine where the sim can be run.** Everything
below (paths under `~`, installed packages, pulled images) exists only there, not in a clone of this
repo. This is a *delta* on the authoritative runtime record,
`prompts/autoware-core-awsim-setup-guide.md` (cited below as `setup-guide §N`). The guide is left
unchanged because the reports cite it by section number. Read the guide for the full walkthrough
(pose estimate, goal, driving). This file covers what is different when you cannot use root, and
the checks that prove each step worked.

Status: **host side and host↔container DDS bridge verified.** The Autoware Core stack (§6c), RViz,
and the pose/goal/drive steps (§7–8) were **not** run.

---

## 1. Why no sudo is needed here

Every step in the guide that needs root was already done on this machine by its administrators.
The only privilege you need is membership in the `docker` group.

| Guide step | Needs root? | State on the lab machine | How to check (no sudo) |
|---|---|---|---|
| §1 OS / GPU / driver | — | Ubuntu 22.04.5, RTX 3060 12 GB, driver 535.309.01, 24 threads, 30 GB RAM | `cat /etc/os-release; nvidia-smi; nproc; free -h` |
| §2 ROS 2 Humble + `rmw_cyclonedds_cpp` on host | yes (apt) | **Installed** in `/opt/ros/humble`; `librclcpp_action.so` present; `libconsole_bridge.so.1.0` in `/lib/x86_64-linux-gnu` | `ls /opt/ros/humble/lib/librmw_cyclonedds_cpp.so; ldconfig -p \| grep console_bridge` |
| §3 Multicast on `lo` | yes | **On**, and made persistent by `multicast-lo.service` (enabled) | `ip link show lo` must show `MULTICAST`. The service reads `inactive`, which is normal for a oneshot unit that already ran |
| §4 `sysctl net.core.rmem_max` | yes | **Already** `2147483647` | `sysctl net.core.rmem_max` |
| §4 `sysctl net.ipv4.ipfrag_*` | yes | **Not set** (`ipfrag_time=30`, `ipfrag_high_thresh=4194304`) | Not needed on this setup, see note below |
| §6b Docker | no (group) | User is in `docker` group; `autoware:core-humble` image already pulled (also `universe-cuda-humble`) | `id; docker images \| grep autoware` |
| §4 host `~/cyclonedds.xml` | no | Created by user (step 2.1) | — |
| §5 AWSIM + map | no | Downloaded by user (step 2.2) | — |

**Why the missing `ipfrag_*` tuning is harmless here:** those settings govern reassembly of
IP-fragmented datagrams. Both sides talk over `lo` (MTU 65536), and `cyclonedds.xml` caps DDS
datagrams at `MaxMessageSize 65500B`, so a datagram never exceeds the MTU and is never IP-fragmented.
Large samples (point clouds) are split by DDS itself into RTPS fragments, each within the cap.
`[INFERRED]` from the config, not measured.

**If `lo` loses `MULTICAST`** (e.g. the service is disabled after a reboot), you cannot fix it
yourself. Every container node will crash with `Failed to find a free participant index`
(setup-guide §9). Ask an administrator to run `ip link set lo multicast on`.

---

## 2. User-space setup (what was actually done)

### 2.1 Host Cyclone DDS config — copy it from the image, don't retype it

The guide's §4 heredoc matches the image today, but copying straight from the image guarantees
the host and container configs are identical, even if a future image changes:

```bash
docker run --rm --entrypoint cat ghcr.io/autowarefoundation/autoware:core-humble \
  /home/aw/cyclonedds.xml > ~/cyclonedds.xml
```

The image also sets `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and
`CYCLONEDDS_URI=file:///home/aw/cyclonedds.xml`. Check with
`docker run --rm --entrypoint bash ghcr.io/autowarefoundation/autoware:core-humble -c 'env | grep -E "RMW|CYCLONE"'`.

### 2.2 Download AWSIM Lightweight (URP) + Shinjuku map

The RTX 3060 is below the RTX 2080 Ti bar, so use the Lightweight build (setup-guide §1, §5).

```bash
mkdir -p ~/Downloads ~/AWSIM-Demo-Lightweight
cd ~/Downloads
wget -c https://github.com/autowarefoundation/AWSIM/releases/download/v2.0.1/AWSIM-Demo-Lightweight.zip  # 850,709,212 B
wget -c https://github.com/autowarefoundation/AWSIM/releases/download/v2.0.0/Shinjuku-Map.zip           # 129,585,415 B
```

### 2.3 Unzip and flatten (**the guide's paths are one level too shallow**)

Both zips contain their own top-level folder. Unzipping as in setup-guide §5 produces
`~/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight/…` and
`~/AWSIM-Demo-Lightweight/Shinjuku-Map/Shinjuku-Map/map`. That breaks the `cd` in §6a and,
worse, the Docker map mount in §6b, which would mount a folder that doesn't exist. Flatten both
after unzipping:

```bash
cd ~/Downloads
unzip -q AWSIM-Demo-Lightweight.zip -d ~/AWSIM-Demo-Lightweight
unzip -q Shinjuku-Map.zip           -d ~/AWSIM-Demo-Lightweight/Shinjuku-Map

cd ~/AWSIM-Demo-Lightweight
mv AWSIM-Demo-Lightweight/* . && rmdir AWSIM-Demo-Lightweight
mv Shinjuku-Map/Shinjuku-Map/* Shinjuku-Map/ && rmdir Shinjuku-Map/Shinjuku-Map
chmod +x AWSIM-Demo-Lightweight.x86_64
```

Expected result:

```
~/AWSIM-Demo-Lightweight/
├── AWSIM-Demo-Lightweight.x86_64
├── AWSIM-Demo-Lightweight_Data/        (Plugins/ holds the ROS2-for-Unity libs)
├── UnityPlayer.so, libdecor-*.so, sample-config.json, …
└── Shinjuku-Map/map/
    ├── lanelet2_map.osm
    ├── map_projector_info.yaml
    └── pointcloud_map.pcd
```

Disk: ~3.4 GB unpacked, plus ~0.94 GB of zips in `~/Downloads` (safe to delete afterwards).

### 2.4 Pre-flight: check the plugins' shared-library dependencies

This catches the "plugins fail to load silently" problem (setup-guide §2, §9) before you launch:

```bash
source /opt/ros/humble/setup.bash
find ~/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight_Data/Plugins -name '*.so*' -print0 \
  | xargs -0 ldd 2>/dev/null | grep "not found" | sort | uniq -c
```

No output means every dependency resolves. On the lab machine all 1,265 plugin libraries resolved.

---

## 3. Launch

Same as setup-guide §6, now that the paths from §2.3 are correct.

**Terminal 1 — AWSIM (host):**

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
cd ~/AWSIM-Demo-Lightweight && ./AWSIM-Demo-Lightweight.x86_64
```

**Keep sourcing ROS 2, even though AWSIM tells you not to.** AWSIM's log prints
`You should not source ROS2 in 'ros2-for-unity' standalone build` (and the same for
`RobotecGPULidar`). This was tested both ways on the lab machine:

| Launch | `/clock`, `velocity_status` | TF plugins |
|---|---|---|
| ROS 2 sourced | publish | load |
| **Not** sourced (clean `env -i`) | still publish (~99 Hz) | **`Failed to open plugin: …/libtf2_ros.so`** and **`…/libstatic_transform_broadcaster_node.so`** |

So the warning is harmless, and without sourcing the static TF broadcaster is lost. **A healthy
`/clock` does not prove the plugins loaded.** Check the Unity log instead (step 4.1).

**Terminal 2 — Autoware Core (container):** setup-guide §6b–§6c, unchanged. `xhost +local:` needs no
sudo. The container prints `[entrypoint] WARN: failed: ip link set lo multicast on (need --privileged
or --cap-add=NET_ADMIN)`, which is expected and harmless because `lo` already has multicast on the host.

---

## 4. Verify

### 4.1 AWSIM loaded its ROS plugins

The Unity log is at `~/.config/unity3d/TIERIV/AWSIM/Player.log` (overwritten each launch):

```bash
grep -iE "ROS2 version|Failed to open plugin" ~/.config/unity3d/TIERIV/AWSIM/Player.log
```

Healthy: exactly `ROS2 version: humble. Build type: standalone. RMW: rmw_cyclonedds_cpp` and **no**
`Failed to open plugin` lines. If `RMW:` says `rmw_fastrtps_cpp`, the env var didn't reach AWSIM
(setup-guide §9, vendor mismatch).

Also harmless in that log on this machine: `FMOD failed to initialize … no sound` (no audio device)
and `cannot open device : /dev/input/event3` (no permission on an input device).

### 4.2 Host sees AWSIM

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
ros2 topic hz /clock                                        # observed: ~98 Hz
ros2 topic info -v /vehicle/status/velocity_status          # observed: AWSIM PUBLISHER, RELIABLE / KEEP_LAST(1) / VOLATILE
```

### 4.3 Container sees AWSIM (the host↔container bridge)

Test the bridge with AWSIM running before launching the full Autoware stack:

```bash
docker run --rm --net host ghcr.io/autowarefoundation/autoware:core-humble bash -lc \
  'source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash; ros2 topic hz /clock'
# observed: ~98 Hz inside the container
# also observed: ros2 topic info -v /control/command/gear_cmd → AWSIM SUBSCRIPTION, TRANSIENT_LOCAL
```

These QoS observations are recorded as `[runtime]` evidence in
`reports/poc-recon.md` §"Runtime verification (addendum)".

---

## 5. Not yet done on the lab machine

- setup-guide §6c: `ros2 launch autoware_core autoware_core.launch.xml …` with RViz on the host display.
- setup-guide §7–8: GNSS-arrow initial pose, NVTL check, goal pose, engaging autonomous mode.
- The runtime captures that `reports/poc-recon.md` still lists as open (SEDP/RTPS capture on `lo`,
  writer/participant GUIDs). Packet capture on the host is **blocked without root**: `tshark`/`dumpcap`
  are not installed, and `/usr/bin/tcpdump` has no file capabilities (`getcap` is empty), so it
  can't open `lo` as this user. A likely no-sudo route is a capture container, e.g.
  `docker run --rm --net host --cap-add NET_RAW --cap-add NET_ADMIN <image with tshark> …`, since the
  `docker` group grants those capabilities. `[UNVERIFIED]`, not tried.
