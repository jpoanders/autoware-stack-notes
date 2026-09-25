#!/bin/bash
# Launch the Autoware Core container with THIS FI1 workspace's src/ mounted read-only,
# so you can `colcon build --packages-select fi1_injection` inside the container.
# NOTE: every -v/-e is an option to `docker run` and MUST come BEFORE the image name;
# anything after the image is the command run inside the container.

SIM_PATH=${1:-~/AWSIM-Demo-Lightweight}
WS_SRC="$(cd "$(dirname "$0")" && pwd)/src"   # this ws's src/, mounted read-only

xhost +local:
docker run --rm -it --net host --name autoware_core \
  -e DISPLAY="$DISPLAY" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "$SIM_PATH/Shinjuku-Map/map:/home/aw/autoware_data/maps" \
  -v "$WS_SRC:/home/aw/fi1_ws/src:ro" \
  ghcr.io/autowarefoundation/autoware:core-humble

# Inside the container (build from HOME, not the mount: Docker creates the mount's
# parent /home/aw/fi1_ws as root, so colcon cannot write build/log there; the src is :ro):
#   source /opt/ros/humble/setup.bash
#   cd ~
#   colcon build --base-paths /home/aw/fi1_ws/src --packages-select fi1_injection
#   source install/setup.bash
#   ros2 run fi1_injection fi1_stuck_sensor --sim-time --stamp-mode fresh --duration 10
