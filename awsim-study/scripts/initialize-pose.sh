#!/bin/bash

YAW_DEG=${1:-0}   # heading in the map frame: 0 = +x (east), 90 = +y (north)
read QZ QW < <(python3 -c "import math;y=math.radians($YAW_DEG);print(math.sin(y/2),math.cos(y/2))")

ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped "{
  header: {frame_id: map},
  pose: {pose: {
    position: {x: 81377.98, y: 49917.33, z: 43.08},
    orientation: {x: 0.0, y: 0.0, z: $QZ, w: $QW}
  }}
}"
