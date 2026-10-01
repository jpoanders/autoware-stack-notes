source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash
D=$1; YAW=${2:-33.76}
read X Y QZ QW < <(python3 -c "import math;y=math.radians($YAW);print(81377.36+$D*math.cos(y),49916.91+$D*math.sin(y),math.sin(y/2),math.cos(y/2))")
ros2 topic pub --once /planning/mission_planning/goal geometry_msgs/msg/PoseStamped "{header: {frame_id: map}, pose: {position: {x: $X, y: $Y, z: 43.08}, orientation: {z: $QZ, w: $QW}}}" >/dev/null
sleep 3; echo "goal d=$D yaw=$YAW -> $(timeout 4 ros2 topic echo --once /planning/route_state 2>/dev/null | grep state)"
