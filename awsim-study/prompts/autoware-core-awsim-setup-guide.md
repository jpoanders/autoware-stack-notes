# Autoware Core + AWSIM Digital Twin Demo — Setup Guide

Tested on: Ubuntu 22.04, RTX 3060 (12GB), NVIDIA driver 535, 24-thread CPU, 30GB RAM.

This guide reflects the *actual* working setup after troubleshooting several real issues:
missing loopback multicast, missing host ROS 2 install, and a DDS vendor mismatch between
AWSIM and the Autoware Docker container. Follow it in order — skipping steps will very
likely reproduce the same failures.

---

## 0. Architecture — what runs where

- **Autoware Core** runs inside a Docker container (`ghcr.io/autowarefoundation/autoware:core-humble`),
  launched with `--net host` so it shares the host's network stack.
- **AWSIM** is a native Unity binary that runs directly on the **host** — not in Docker — because
  it needs direct GPU/Vulkan access for rendering.
- The two communicate over ROS 2 / DDS across host↔container using loopback (`lo`), which requires
  multicast enabled and matching DDS configuration on both sides.

---

## 1. Hardware / OS prerequisites

| Item | Requirement |
|---|---|
| OS | Ubuntu 22.04 |
| CPU | 6 cores / 12 threads+ |
| GPU | NVIDIA RTX 2080 Ti or better recommended (raytracing) — a weaker GPU (e.g. RTX 3060) works with the **Lightweight (URP)** build instead |
| RAM | 32 GB+ |
| NVIDIA driver | 570+ recommended (535 also works, driver limitations may cause rendering issues) |

Quick checks:
```bash
cat /etc/os-release | grep -E "PRETTY_NAME|VERSION_ID"
nproc
free -h
nvidia-smi
dpkg -l | grep libvulkan1
docker --version && docker ps
```

---

## 2. Install ROS 2 Humble on the **host**

This is required even though Autoware itself runs in Docker. AWSIM's bundled Unity ROS2
plugins (ROS2-for-Unity) are compiled against ROS 2 Humble but do **not** bundle the full
client library set — they expect `librclcpp_action.so`, `libconsole_bridge.so.1.0`, etc. to
already exist on the host at `/opt/ros/humble/lib`. Without this, AWSIM's plugins
(`libtf2_ros.so`, `libtf2.so`, `libstatic_transform_broadcaster_node.so`, etc.) fail to load
silently — the app still opens and renders, but nothing gets published to ROS.

```bash
sudo apt update && sudo apt install -y curl gnupg lsb-release

sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /usr/share/keyrings/ros-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | \
  sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

sudo apt update
sudo apt install -y ros-humble-ros-base ros-humble-rmw-cyclonedds-cpp
```

---

## 3. Enable multicast on the loopback interface

Autoware's Docker image needs multicast on `lo` to establish DDS domain participants. Without
it, **every single ROS 2 node in the container crashes on launch** with:
```
selected interface "lo" is not multicast-capable: disabling multicast
Failed to find a free participant index for domain 0
```

Enable it now:
```bash
sudo ip link set lo multicast on
ip link show lo   # confirm MULTICAST appears in the flags
```

Make it permanent (this reverts on every reboot otherwise):
```bash
sudo tee /etc/systemd/system/multicast-lo.service > /dev/null <<'EOF'
[Unit]
Description=Enable Multicast on Loopback

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set lo multicast on

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable multicast-lo.service
sudo systemctl start multicast-lo.service
```

---

## 4. Create a matching CycloneDDS config on the host

The Autoware Docker image ships its own CycloneDDS config at `/home/aw/cyclonedds.xml`
inside the container, which sets `ParticipantIndex=none` (fixes the crash above) and binds
to `lo`. For host↔container discovery to actually work, **the host needs an identical config**
— without it, the two sides can end up on different discovery ports even on the same interface.

```bash
cat > ~/cyclonedds.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="https://cdds.io/config https://raw.githubusercontent.com/eclipse-cyclonedds/cyclonedds/master/etc/cyclonedds.xsd">
  <Domain Id="any">
    <Discovery>
      <ParticipantIndex>none</ParticipantIndex>
    </Discovery>
    <General>
      <Interfaces>
        <NetworkInterface name="lo" priority="default" multicast="default"/>
      </Interfaces>
      <AllowMulticast>default</AllowMulticast>
      <MaxMessageSize>65500B</MaxMessageSize>
    </General>
    <Internal>
      <SocketReceiveBufferSize min="10MB"/>
      <Watermarks>
        <WhcHigh>500kB</WhcHigh>
      </Watermarks>
    </Internal>
  </Domain>
</CycloneDDS>
EOF
```

Also apply recommended DDS throughput tuning (needed for point clouds/images):
```bash
sudo sysctl -w net.core.rmem_max=2147483647
sudo sysctl -w net.ipv4.ipfrag_time=3
sudo sysctl -w net.ipv4.ipfrag_high_thresh=134217728
```

---

## 5. Download AWSIM + map

Given a GPU below RTX 2080 Ti, use the **Lightweight (URP)** build:

```bash
mkdir -p ~/AWSIM-Demo-Lightweight
cd ~/Downloads
wget https://github.com/autowarefoundation/AWSIM/releases/download/v2.0.1/AWSIM-Demo-Lightweight.zip
wget https://github.com/autowarefoundation/AWSIM/releases/download/v2.0.0/Shinjuku-Map.zip

unzip AWSIM-Demo-Lightweight.zip -d ~/AWSIM-Demo-Lightweight
unzip Shinjuku-Map.zip -d ~/AWSIM-Demo-Lightweight/Shinjuku-Map

chmod +x ~/AWSIM-Demo-Lightweight/AWSIM-Demo-Lightweight.x86_64
```

Confirm the map's point cloud/vector files landed in a `map/` subfolder:
```bash
ls ~/AWSIM-Demo-Lightweight/Shinjuku-Map/map
```

---

## 6. Launch — every time, in this order

Always fully close both apps before relaunching (crashes/collisions can leave stale state).

### 6a. Launch AWSIM first (host)

```bash
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
cd ~/AWSIM-Demo-Lightweight
./AWSIM-Demo-Lightweight.x86_64
```

> **Why CycloneDDS here?** AWSIM defaults to `rmw_fastrtps_cpp`, but Autoware's container
> uses `rmw_cyclonedds_cpp` (the officially recommended DDS vendor for Autoware). Mismatched
> RMW vendors between the two sides silently prevents discovery even with everything else
> correct — force both to CycloneDDS.

### 6b. Launch Autoware Core (host — new terminal)

```bash
xhost +local:
docker run --rm -it --net host --name autoware_core \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v $HOME/AWSIM-Demo-Lightweight/Shinjuku-Map/map:/home/aw/autoware_data/maps \
  ghcr.io/autowarefoundation/autoware:core-humble
```
(If you see `WARN: failed: ip link set lo multicast on (need --privileged...)` — harmless as
long as you already ran step 3 on the host. `ip link show lo` should still show `MULTICAST`.)

### 6c. Inside the container, launch the Autoware stack

```bash
ros2 launch autoware_core autoware_core.launch.xml use_sim_time:=true \
  map_path:=/home/aw/autoware_data/maps \
  vehicle_model:=autoware_sample_vehicle \
  sensor_model:=autoware_awsim_sensor_kit
```
RViz should open on your host desktop showing the Shinjuku map.

### 6d. Verify the bridge is alive (new terminal)

```bash
docker exec -it -u aw autoware_core bash
source /opt/ros/humble/setup.bash
source /opt/autoware/setup.bash
ros2 topic hz /clock
```
You should see a steady tick rate (~90-100 Hz). If this hangs with no output, stop here —
do not proceed to pose estimation, go to the Troubleshooting section below.

---

## 7. Set the initial pose accurately (critical step)

Guessing the pose by eyeballing AWSIM's window is unreliable and leads to NDT divergence,
loss of localization, and the vehicle driving into obstacles. Instead, use AWSIM's own GNSS
output as a visual reference:

1. In RViz, **Displays** panel → **Add** → **By topic** → find
   `/sensing/gnss/pose_with_covariance` → select **PoseWithCovarianceStamped** → OK.
   This draws a persistent arrow at the vehicle's true position/heading.
2. Click **2D Pose Estimate** in the RViz toolbar.
3. Click exactly on the GNSS arrow's base, then drag in the exact direction it's pointing,
   and release.

**Immediately verify convergence** — do not proceed until this passes:
```bash
ros2 topic echo /localization/pose_estimator/nearest_voxel_transformation_likelihood --once
```
Value should be comfortably **above ~2.3** (ideally 3+). Also confirm:
```bash
ros2 topic echo /localization/initialization_state --once
```
Should read `state: 3` (`INITIALIZED`). If NVTL is low or state reverts to `1`
(`UNINITIALIZED`), redo the pose estimate more carefully — a close position with a wrong
heading is the most common cause of slow-motion localization divergence.

---

## 8. Set the goal and start autonomous driving

1. Click **2D Goal Pose** in RViz, then click-drag a destination clearly on a road within the map.
2. Confirm the route registered:
```bash
ros2 topic echo /planning/route_state --once
```
   `state: 2` = `SET` (route accepted).

3. Enable autonomous mode and set gear to Drive:
```bash
ros2 topic pub /system/operation_mode/state autoware_adapi_v1_msgs/msg/OperationModeState \
  "{mode: 2, is_autoware_control_enabled: true, is_autonomous_mode_available: true}" \
  --once --qos-durability transient_local

ros2 topic pub /control/command/gear_cmd autoware_vehicle_msgs/msg/GearCommand "command: 2" \
  --once --qos-durability transient_local
```
   Both should complete instantly (no "Waiting for subscription...") if AWSIM is properly bridged.

4. Watch AWSIM's window — the vehicle should start driving. Keep NVTL streaming in a spare
   terminal while it drives, to catch localization drift before it causes a collision:
```bash
ros2 topic echo /localization/pose_estimator/nearest_voxel_transformation_likelihood
```

> Default max speed is capped at 15 km/h. To raise it, inside the container:
> ```bash
> sed -i 's/max_vel: 4.17/max_vel: 22.2/' \
>   /opt/autoware/autoware_core_planning/share/autoware_core_planning/config/planning/scenario_planning/common/common.param.yaml
> ```
> (path may vary by image version — adjust if not found)

---

## 9. Troubleshooting reference

| Symptom | Cause | Fix |
|---|---|---|
| Every container node crashes immediately, `Failed to find a free participant index` | `lo` missing multicast | Section 3 |
| `ros2 topic hz /clock` hangs, AWSIM window renders fine | AWSIM's ROS2 Unity plugins failed to load (`Failed to open plugin: libtf2_ros.so`, missing `librclcpp_action.so`/`libconsole_bridge.so.1.0`) | Install ROS 2 Humble on host (Section 2), source it before launching AWSIM |
| Plugins load (`ROS2 version: humble...` prints, no "Failed to open plugin"), still no `/clock` | RMW vendor mismatch (AWSIM=FastRTPS, container=CycloneDDS) | Force both to `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (Section 6a) |
| CycloneDDS matches on both sides, still no discovery | Host has no `cyclonedds.xml`, so `ParticipantIndex`/interface config differs from the container's | Section 4 — mirror the container's config on the host |
| `docker exec -it autoware_core bash` drops you in as root with nothing sourced | Default exec shell ≠ entrypoint context | `docker exec -it -u aw autoware_core bash`, then source both `/opt/ros/humble/setup.bash` and `/opt/autoware/setup.bash` |
| RViz: `Frame [map] does not exist`, `/tf` publishes nothing, `heading_rate` is a huge nonsense number | NDT/EKF localization diverged (usually from an imprecise initial pose) and Autoware auto-reset to `UNINITIALIZED` | Redo pose estimate using the GNSS-arrow method (Section 7); check NVTL before proceeding |
| Vehicle drives but ignores obstacles / drives into things | Localization was only loosely converged (NVTL below ~2.3) when driving started | Always gate on NVTL > 2.3 before setting the goal pose (Section 7) |
| `topic pub` on `/control/command/gear_cmd` hangs on "Waiting for subscription" | AWSIM not running, or AWSIM was launched before a network fix was applied (stale DDS participant) | Fully close and relaunch AWSIM after any host network/env change |

---

## Sanity-check commands (useful anytime)

```bash
# Is the host<->container DDS bridge alive at all, independent of AWSIM/Autoware?
# Container:
ros2 topic echo /handshake_test
# Host (separate terminal):
ros2 topic pub /handshake_test std_msgs/msg/String "data: hello from host" -r 1

# What nodes are actually alive right now
ros2 node list

# Check any enum-valued status topic's meaning
ros2 interface show <package>/msg/<MessageType>
```
