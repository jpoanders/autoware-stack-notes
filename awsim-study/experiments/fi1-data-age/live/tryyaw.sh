source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash
Y=$1
read QZ QW < <(python3 -c "import math;y=math.radians($Y);print(math.sin(y/2),math.cos(y/2))")
ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped "{header: {frame_id: map}, pose: {pose: {position: {x: 81377.98, y: 49917.33, z: 43.08}, orientation: {x: 0.0, y: 0.0, z: $QZ, w: $QW}}}}" >/dev/null
sleep 6
echo "yaw=$Y state=$(timeout 4 ros2 topic echo --once /localization/initialization_state 2>/dev/null | grep state | head -1) nvtl=$(timeout 4 ros2 topic echo --once /localization/pose_estimator/nearest_voxel_transformation_likelihood 2>/dev/null | grep data)"
