cmake_minimum_required(VERSION 3.16)
project(seu_poc_harness C)
set(CMAKE_C_STANDARD 11)
find_package(CycloneDDS REQUIRED)

# Generate C bindings from the IDL at configure/build time.
idlc_generate(TARGET vr_lib FILES idl/VelocityReport.idl)

add_executable(real_speed_monitor src/real_speed_monitor.c)
target_link_libraries(real_speed_monitor vr_lib CycloneDDS::ddsc)

add_executable(trusting_consumer src/trusting_consumer.c)
target_link_libraries(trusting_consumer vr_lib CycloneDDS::ddsc)

add_executable(injector_presence src/injector_presence.c)
target_link_libraries(injector_presence CycloneDDS::ddsc)
