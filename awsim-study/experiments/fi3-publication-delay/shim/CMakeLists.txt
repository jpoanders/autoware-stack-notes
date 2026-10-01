cmake_minimum_required(VERSION 3.16)
project(fi3_delay_shim C)
set(CMAKE_C_STANDARD 11)

# shared: vr_lib + trusting_consumer (from experiments/_common)
include(${CMAKE_CURRENT_LIST_DIR}/../../_common/common.cmake)

# The shim: Cyclone headers only, NOT linked to ddsc (resolved at runtime, see src).
add_library(fi3_delay SHARED src/fi3_delay_shim.c)
target_include_directories(fi3_delay PRIVATE
  $<TARGET_PROPERTY:CycloneDDS::ddsc,INTERFACE_INCLUDE_DIRECTORIES>)
target_compile_options(fi3_delay PRIVATE -Wall -Wextra -O2)
target_link_libraries(fi3_delay dl pthread)

# Bench writer: Module 1's nominal 30 Hz writer (monotonic stamps, same clock as the tap).
add_executable(real_speed_monitor
  ${CMAKE_CURRENT_LIST_DIR}/../../module1-freshness-loss/src/real_speed_monitor.c)
target_link_libraries(real_speed_monitor vr_lib CycloneDDS::ddsc)
