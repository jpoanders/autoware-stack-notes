#!/bin/bash

docker exec -it -u aw autoware_core bash
source /opt/ros/humble/setup.bash
source /opt/autoware/setup.bash
ros2 topic hz /clock
