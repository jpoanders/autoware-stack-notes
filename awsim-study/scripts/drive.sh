#Immediately verify convergence** — do not proceed until this passes:
ros2 topic echo /localization/pose_estimator/nearest_voxel_transformation_likelihood --once
#Value should be comfortably **above ~2.3** (ideally 3+). Also confirm:
ros2 topic echo /localization/initialization_state --once
#Should read `state: 3` (`INITIALIZED`). If NVTL is low or state reverts to `1`
#(`UNINITIALIZED`), redo the pose estimate more carefully — a close position with a wrong
#heading is the most common cause of slow-motion localization divergence.


## 8. Set the goal and start autonomous driving

#Click **2D Goal Pose** in RViz, then click-drag a destination clearly on a road within the map.
#Confirm the route registered:
ros2 topic echo /planning/route_state --once
#```
#   `state: 2` = `SET` (route accepted).
#
#3. Enable autonomous mode and set gear to Drive:
ros2 topic pub /system/operation_mode/state autoware_adapi_v1_msgs/msg/OperationModeState \
  "{mode: 2, is_autoware_control_enabled: true, is_autonomous_mode_available: true}" \
  --once --qos-durability transient_local

ros2 topic pub /control/command/gear_cmd autoware_vehicle_msgs/msg/GearCommand "command: 2" \
  --once --qos-durability transient_local
#Both should complete instantly (no "Waiting for subscription...") if AWSIM is properly bridged.

#4. Watch AWSIM's window — the vehicle should start driving. Keep NVTL streaming in a spare
#   terminal while it drives, to catch localization drift before it causes a collision:
ros2 topic echo /localization/pose_estimator/nearest_voxel_transformation_likelihood

