source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash
timeout 8 ros2 service call /system/operation_mode/change_operation_mode autoware_system_msgs/srv/ChangeOperationMode "{mode: 2}" | grep -E "success|message"
# setup-guide §8: Autoware Core has no gear/mode publisher for AWSIM; latch them as the guide does
timeout 8 ros2 topic pub /system/operation_mode/state autoware_adapi_v1_msgs/msg/OperationModeState "{mode: 2, is_autoware_control_enabled: true, is_autonomous_mode_available: true}" --once --qos-durability transient_local >/dev/null
timeout 8 ros2 topic pub /control/command/gear_cmd autoware_vehicle_msgs/msg/GearCommand "command: 2" --once --qos-durability transient_local >/dev/null
sleep 5; echo "speed after 5s: $(timeout 4 ros2 topic echo --once /vehicle/status/velocity_status | grep longitudinal)"
