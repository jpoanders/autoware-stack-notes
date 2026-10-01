#!/usr/bin/env bash
# restart the Autoware stack in the running container, re-localize, set the 60 m route
for f in tryyaw.sh goal.sh engage.sh bag_an.py
do docker cp $f autoware_core:/tmp/ > /dev/null; 
done

AW='source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash;'
# put the AWSIM vehicle back on the spawn pose (yaw 33.76 deg) and in PARK
docker exec -u aw autoware_core bash -c "$AW timeout 8 ros2 topic pub --once /control/command/gear_cmd autoware_vehicle_msgs/msg/GearCommand 'command: 22' --qos-durability transient_local >/dev/null; timeout 8 ros2 topic pub --once /awsim/awsim_rviz_plugins/pose_teleport/pose_with_covariance geometry_msgs/msg/PoseWithCovarianceStamped '{header: {frame_id: map}, pose: {pose: {position: {x: 81377.98, y: 49917.33, z: 43.08}, orientation: {z: 0.29036, w: 0.95692}}}}' >/dev/null"
docker exec -u aw autoware_core bash -c "pkill -INT -f 'ros2 launch autoware_core'; sleep 8; pkill -9 -f '/opt/autoware' ; pkill -9 -f 'ros2 launch'; true"
sleep 3
docker exec -d -u aw autoware_core bash -c "$AW ros2 launch autoware_core autoware_core.launch.xml use_sim_time:=true map_path:=/home/aw/autoware_data/maps vehicle_model:=autoware_sample_vehicle sensor_model:=autoware_awsim_sensor_kit > /tmp/aw_launch.log 2>&1"
sleep 12
for y in 33.76 45 90; do
  out=$(docker exec -u aw autoware_core bash /tmp/tryyaw.sh $y); echo "$out"
  n=$(echo "$out" | sed -n 's/.*data: \([0-9.]*\).*/\1/p')
  python3 -c "import sys; sys.exit(0 if float('${n:-0}')>2.8 else 1)" && break
done
docker exec -u aw autoware_core bash /tmp/goal.sh ${1:-60}
