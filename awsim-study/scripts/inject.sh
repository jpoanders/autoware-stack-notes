#!/bin/bash

source /opt/ros/humble/setup.bash; source /opt/autoware/setup.bash
python3 /home/aw/fi1_src/fi1_injection/fi1_injection/fi1_stuck_sensor_node.py --sim-time --duration 15 \
    --topic /localization/kinematic_state --msg-type nav_msgs/msg/Odometry \
    --value-source capture --value-mode stuck --stamp-mode fresh
