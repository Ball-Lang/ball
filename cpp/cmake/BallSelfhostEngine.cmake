# BallSelfhostEngine.cmake — OBJECT library for multi-TU self-hosted engine_rt.
#
# Usage (after regenerating dart/self_host/lib/engine_rt/):
#   include(BallSelfhostEngine)
#   ball_add_selfhost_engine_target(ball_selfhost_engine)

function(ball_add_selfhost_engine_target target_name)
    set(BALL_SELFHOST_RT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib/engine_rt")
    set(BALL_SELFHOST_COMMON "${BALL_SELFHOST_RT_DIR}/engine_rt_common.hpp")
    if(NOT EXISTS "${BALL_SELFHOST_COMMON}")
        message(STATUS "Self-host engine_rt not generated (${BALL_SELFHOST_COMMON} missing)")
        return()
    endif()
    file(GLOB BALL_SELFHOST_SHARDS CONFIGURE_DEPENDS
         "${BALL_SELFHOST_RT_DIR}/engine_rt_shard_*.cpp")
    add_library(${target_name} OBJECT ${BALL_SELFHOST_SHARDS})
    target_include_directories(${target_name} PUBLIC
        "${BALL_SELFHOST_RT_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../shared/include"
    )
    target_compile_options(${target_name} PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
    )
    set_target_properties(${target_name} PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
    )
endfunction()
