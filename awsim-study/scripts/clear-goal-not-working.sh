#!/bin/bash
# clear the stuck route  →  state should return to UNSET(1)
ros2 service call /api/routing/clear_route autoware_adapi_v1_msgs/srv/ClearRoute {}

# verify
ros2 topic echo /planning/route_state --once      # expect state: 1

# if it won't clear while driving, drop to STOP first, then clear:
ros2 service call /system/operation_mode/change_operation_mode \
  autoware_adapi_v1_msgs/srv/ChangeOperationMode "{mode: 1}"   # 1 = STOP
