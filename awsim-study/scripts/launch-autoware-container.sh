#!/bin/bash

SIM_PATH=${1:-~/AWSIM-Demo-Lightweight}
SCRIPTS_PATH=~/src/github.com/jpoanders/autoware-stack-notes/awsim-study/scripts
FI1_SRC_PATH=~/src/github.com/jpoanders/autoware-stack-notes/awsim-study/experiments/fi1-data-age/fi1_ros2_ws/src 

xhost +local:
docker run --rm -it --net host --name autoware_core \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v $SIM_PATH/Shinjuku-Map/map:/home/aw/autoware_data/maps \
  -v $SCRIPTS_PATH:/home/aw/scripts:ro \
  -v $FI1_SRC_PATH:/home/aw/fi1_src:ro \
  ghcr.io/autowarefoundation/autoware:core-humble \
