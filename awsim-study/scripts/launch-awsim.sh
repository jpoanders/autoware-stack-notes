#!/bin/bash

SIM_PATH_=${1:-~/AWSIM-Demo-Lightweight}

source /opt/ros/humble/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
cd ~/AWSIM-Demo-Lightweight
./AWSIM-Demo-Lightweight.x86_64 1>/dev/null 2>&1
