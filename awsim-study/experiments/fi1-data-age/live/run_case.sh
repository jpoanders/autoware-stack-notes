#!/usr/bin/env bash
# run_case.sh NAME DUR [injector args | --baseline]
NAME=$1; DUR=$2; shift 2
FI1=$(cd "$(dirname "$0")/.." && pwd)
L=$FI1/logs/live; mkdir -p $L
SP=$(dirname "$0")
source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
AW='source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash; source ~/install/setup.bash;'
TOPICS="/vehicle/status/velocity_status /sensing/vehicle_velocity_converter/twist_with_covariance /localization/kinematic_state /localization/pose_estimator/nearest_voxel_transformation_likelihood /localization/initialization_state /system/operation_mode/state /control/command/control_cmd /planning/route_state"
echo "== $NAME  $(date -Iseconds)  args: $*" | tee $L/$NAME.meta
docker exec -u aw autoware_core bash -c "rm -rf /tmp/bags/$NAME; mkdir -p /tmp/bags"
docker exec -d -u aw autoware_core bash -c "$AW ros2 bag record -o /tmp/bags/$NAME $TOPICS > /tmp/bag_$NAME.log 2>&1"
$FI1/bench/build/trusting_consumer > $L/${NAME}_consumer.log 2>&1 & CPID=$!
sleep 3
if [ "$1" = "--baseline" ]; then sleep "$DUR"
else docker exec -u aw autoware_core bash -c "$AW ros2 run fi1_injection fi1_stuck_sensor --sim-time --duration $DUR $*" > $L/${NAME}_writer.log 2>&1
     echo "injector exit=$?" | tee -a $L/$NAME.meta; fi
sleep 3
kill -INT $CPID; sleep 0.5; kill -9 $CPID 2>/dev/null
docker exec -u aw autoware_core bash -c "pkill -INT -f 'ros2 bag record'"; sleep 2
docker cp autoware_core:/tmp/bags/$NAME $L/bags_$NAME 2>/dev/null
grep -E "captured|done after|FATAL" $L/${NAME}_writer.log 2>/dev/null | sed 's/^.*\]: //' | tee -a $L/$NAME.meta
python3 $FI1/analysis/fi1_seu_check.py $L/${NAME}_consumer.log | tee -a $L/$NAME.meta
python3 $SP/per_guid.py $L/${NAME}_consumer.log | tee -a $L/$NAME.meta
docker exec -u aw autoware_core bash -c "$AW echo \"health: nvtl=\$(timeout 4 ros2 topic echo --once /localization/pose_estimator/nearest_voxel_transformation_likelihood | grep data) init=\$(timeout 4 ros2 topic echo --once /localization/initialization_state | grep state)\"" 2>/dev/null | tee -a $L/$NAME.meta
