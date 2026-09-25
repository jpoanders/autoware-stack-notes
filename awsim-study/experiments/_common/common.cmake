# common.cmake — shared harness pieces for the fault-injection experiments.
# include() this from an experiment's CMakeLists.txt. It generates the shared
# VelocityReport C bindings (target: vr_lib) and builds the shared tap
# (trusting_consumer), both from experiments/_common/. CMAKE_CURRENT_LIST_DIR
# here resolves to experiments/_common regardless of which experiment includes it.
find_package(CycloneDDS REQUIRED)

set(FI_COMMON_DIR "${CMAKE_CURRENT_LIST_DIR}")

# Shared type bindings from the one IDL (name-only discovery -> wire-faithful).
idlc_generate(TARGET vr_lib FILES "${FI_COMMON_DIR}/idl/VelocityReport.idl")

# Shared consumer/tap: the SEU trace source every experiment observes through.
add_executable(trusting_consumer "${FI_COMMON_DIR}/consumer/trusting_consumer.c")
target_link_libraries(trusting_consumer vr_lib CycloneDDS::ddsc)
