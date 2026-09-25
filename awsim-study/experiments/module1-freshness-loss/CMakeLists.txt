cmake_minimum_required(VERSION 3.16)
project(module1_freshness_loss C)
set(CMAKE_C_STANDARD 11)

# shared: vr_lib + trusting_consumer
include(${CMAKE_CURRENT_LIST_DIR}/../_common/common.cmake)

add_executable(real_speed_monitor src/real_speed_monitor.c)
target_link_libraries(real_speed_monitor vr_lib CycloneDDS::ddsc)

add_executable(injector_presence src/injector_presence.c)
target_link_libraries(injector_presence CycloneDDS::ddsc)
