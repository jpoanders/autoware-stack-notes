#!/bin/bash

SIM_PATH=${1:-~/AWSIM-Demo-Lightweight}
LAUNCH_PATH=${2:-~/src/github.com/jpoanders/autoware-stack-notes/scripts/launch-autoware.sh}

xhost +local:
docker run --rm -it --net host --name autoware_core \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v $SIM_PATH/Shinjuku-Map/map:/home/aw/autoware_data/maps \
  ghcr.io/autowarefoundation/autoware:core-humble \
