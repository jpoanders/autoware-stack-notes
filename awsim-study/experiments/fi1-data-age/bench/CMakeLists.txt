cmake_minimum_required(VERSION 3.16)
project(fi1_data_age_bench C)
set(CMAKE_C_STANDARD 11)

# shared: vr_lib + trusting_consumer (from experiments/_common)
include(${CMAKE_CURRENT_LIST_DIR}/../../_common/common.cmake)

add_executable(fi1_stuck_sensor src/fi1_stuck_sensor.c)
target_link_libraries(fi1_stuck_sensor vr_lib CycloneDDS::ddsc)

# real_speed_monitor is owned by Module 1; referenced here (not copied) so the
# nominal writer used as the bench control cannot diverge between experiments.
add_executable(real_speed_monitor
  ${CMAKE_CURRENT_LIST_DIR}/../../module1-freshness-loss/src/real_speed_monitor.c)
target_link_libraries(real_speed_monitor vr_lib CycloneDDS::ddsc)
