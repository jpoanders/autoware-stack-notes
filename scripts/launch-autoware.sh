#!/bin/bash

ros2 launch autoware_core autoware_core.launch.xml use_sim_time:=true \
  map_path:=/home/aw/autoware_data/maps \
  vehicle_model:=autoware_sample_vehicle \
  sensor_model:=autoware_awsim_sensor_kit
