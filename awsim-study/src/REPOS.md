# Cloned repositories under `src/`

Read-only upstream evidence for the AWSIM + Autoware Core / Eclipse Cyclone DDS study.
Each entry lists the pinned branch and commit as checked out here. To reproduce the
exact state, clone the branch and then `git checkout <commit>`.

> Note: `autoware`, `autoware_adapi_msgs`, `autoware_msgs`, and `awsim` are checked out
> at a **detached tag/commit** (not tracking a branch); the others track the branch shown.

| Repo | Upstream | Branch / ref | Commit | Version |
|------|----------|--------------|--------|---------|
| `autoware` | autowarefoundation/autoware | main | `ae029bf` | 1.9.0-20-gae029bf |
| `autoware_adapi_msgs` | autowarefoundation/autoware_adapi_msgs | (detached) | `6c3faf2` | 1.9.1 |
| `autoware_msgs` | autowarefoundation/autoware_msgs | (detached) | `588f00d` | 1.11.0 |
| `awsim` | autowarefoundation/AWSIM | (detached) | `9e55528` | v2.0.1 |
| `cyclonedds` | eclipse-cyclonedds/cyclonedds | releases/0.10.x | `5041f356` | 0.10.5-7-g5041f356 |
| `rcl` | ros2/rcl | humble | `cbaee7c` | 5.3.13 |
| `rclcpp` | ros2/rclcpp | humble | `c07d2a5e` | 16.0.21 |
| `rcl_interfaces` | ros2/rcl_interfaces | humble | `82776fc` | 1.2.3 |
| `rmw` | ros2/rmw | humble | `566d17a` | 6.1.4 |
| `rmw_cyclonedds` | ros2/rmw_cyclonedds | humble | `e370e09` | 1.3.5 |
| `rmw_dds_common` | ros2/rmw_dds_common | humble | `e26ba10` | 1.6.0 |

## How to clone each

Run from the `src/` directory. Each command clones only the pinned branch;
append `&& git -C <dir> checkout <commit>` if you need the exact commit above.

### Autoware / AWSIM

```bash
# Autoware Core meta-repo
git clone https://github.com/autowarefoundation/autoware.git autowarefoundation/autoware

# ADAPI message definitions (operation_mode/state, etc.)
git clone https://github.com/autowarefoundation/autoware_adapi_msgs.git autowarefoundation/autoware_adapi_msgs

# Autoware message definitions (gear_cmd, etc.)
git clone https://github.com/autowarefoundation/autoware_msgs.git autowarefoundation/autoware_msgs

# AWSIM simulator (assets + cyclonedds_config.xml)
git clone https://github.com/autowarefoundation/AWSIM.git autowarefoundation/awsim
```

### Eclipse Cyclone DDS (the DDS vendor for this study)
```bash
git clone --branch releases/0.10.x https://github.com/eclipse-cyclonedds/cyclonedds.git eclipse-cyclonedds/cyclonedds
```

### ROS 2 middleware stack (all `humble`)

```bash
git clone --branch humble https://github.com/ros2/rcl.git ros2/rcl
git clone --branch humble https://github.com/ros2/rclcpp.git ros2/rclcpp
git clone --branch humble https://github.com/ros2/rcl_interfaces.git ros2/rcl_interfaces
git clone --branch humble https://github.com/ros2/rmw.git ros2/rmw
git clone --branch humble https://github.com/ros2/rmw_cyclonedds.git ros2/rmw_cyclonedds
git clone --branch humble https://github.com/ros2/rmw_dds_common.git ros2/rmw_dds_common
```

## Not in this checkout

- `ros2cs` — AWSIM's C# client surface. Absent from `src/`; claims about it are tagged
  `[UNVERIFIED]` in the reports.
