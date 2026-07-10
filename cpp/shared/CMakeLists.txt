cmake_minimum_required(VERSION 3.14)
project(ball_cpp_shared)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── #18 — Google protobuf is GONE ─────────────────────────────
# Stage 5 (the final flip, closing #18/#25/#330/#333): ball_shared no longer
# FetchContents Google's libprotobuf/abseil (~90% of C++ build time + the
# abseil-mutex deadlock #25 + the gencode/runtime skew #330/#333). All ball-file
# loading now runs through the protobuf-free `ball::ir` IR (nlohmann/json) for
# JSON, and through Ball's OWN compiled protobuf runtime (`ball_protobuf_rt.h`
# via `ball_rt_decode.cpp`) for the binary `.ball.pb`/`.ball.bin` Any form. The
# checked-in `gen/ball/v1/ball.pb.*` bindings are deleted (nothing consumes
# them) and `buf generate` no longer emits C++.

# ── nlohmann/json (the only remaining external dep) ───────────
if(NOT TARGET nlohmann_json::nlohmann_json)
    find_package(nlohmann_json QUIET)
endif()
if(NOT TARGET nlohmann_json::nlohmann_json)
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz)
    FetchContent_MakeAvailable(json)
endif()

# Generate ball_emit_runtime_embed.h from ball_emit_runtime.h — the
# compiler splices this string into the preamble of every emitted
# C++ program, so the runtime helpers live in exactly one source file.
set(BALL_EMIT_RUNTIME_SRC "${CMAKE_CURRENT_SOURCE_DIR}/include/ball_emit_runtime.h")
set(BALL_EMIT_RUNTIME_EMBED "${CMAKE_CURRENT_BINARY_DIR}/gen/ball_emit_runtime_embed.h")
add_custom_command(
    OUTPUT  "${BALL_EMIT_RUNTIME_EMBED}"
    COMMAND ${CMAKE_COMMAND}
            -DIN=${BALL_EMIT_RUNTIME_SRC}
            -DOUT=${BALL_EMIT_RUNTIME_EMBED}
            -P  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedRuntimeHeader.cmake"
    DEPENDS "${BALL_EMIT_RUNTIME_SRC}"
            "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedRuntimeHeader.cmake"
    COMMENT "Generating ball_emit_runtime_embed.h"
    VERBATIM
)

# Generate ball_dyn_embed.h from ball_dyn.h — the dynamic value type
# for Ball compiled programs that need dynamic typing.
set(BALL_DYN_SRC "${CMAKE_CURRENT_SOURCE_DIR}/include/ball_dyn.h")
set(BALL_DYN_EMBED "${CMAKE_CURRENT_BINARY_DIR}/gen/ball_dyn_embed.h")
add_custom_command(
    OUTPUT  "${BALL_DYN_EMBED}"
    COMMAND ${CMAKE_COMMAND}
            -DIN=${BALL_DYN_SRC}
            -DOUT=${BALL_DYN_EMBED}
            -DVAR_NAME=BALL_DYN_SOURCE
            -P  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedRuntimeHeader.cmake"
    DEPENDS "${BALL_DYN_SRC}"
            "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedRuntimeHeader.cmake"
    COMMENT "Generating ball_dyn_embed.h"
    VERBATIM
)

add_custom_target(ball_emit_runtime_gen
    DEPENDS "${BALL_EMIT_RUNTIME_EMBED}" "${BALL_DYN_EMBED}"
)

# ball_shared — protobuf-free. `ball_rt_decode.cpp` (Ball's own compiled
# protobuf runtime, confining its global `BallDyn` universe to one TU) is now
# ALWAYS part of the library: it is the sole binary `.ball.pb`/`.ball.bin`
# decoder (`ball_file.h` calls `ball::rt::DecodeAnyPayloadJson` unconditionally).
add_library(ball_shared
    src/ball_shared.cpp
    ball_rt_decode.cpp
    "${BALL_EMIT_RUNTIME_EMBED}"
    "${BALL_DYN_EMBED}"
)
add_dependencies(ball_shared ball_emit_runtime_gen)

target_include_directories(ball_shared PUBLIC
    include
    "${CMAKE_CURRENT_SOURCE_DIR}"          # ball_rt_decode.h / ball_protobuf_rt.h / ball_program_descriptor.h
    "${CMAKE_CURRENT_BINARY_DIR}/gen"      # the *_embed.h generated headers
)

target_link_libraries(ball_shared PUBLIC nlohmann_json::nlohmann_json)

# ball_protobuf_rt.h is a generated single TU (~9k lines, huge functions): give
# MSVC /bigobj and silence its warnings, only for this one file so the rest of
# ball_shared keeps its normal diagnostics.
set_source_files_properties(ball_rt_decode.cpp PROPERTIES COMPILE_OPTIONS
    "$<$<CXX_COMPILER_ID:MSVC>:/W0;/bigobj>;$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>")

# ── #18 canary: build the Ball-compiled protobuf runtime standalone ──────────
# `ball_protobuf_rt.h` is Ball's own `ball_protobuf` runtime, compiled
# Ball→C++ (header-only, `--library` mode). It is deliberately self-contained —
# only <std> headers, NO libprotobuf/abseil/nlohmann. This opt-in target
# compiles + links + runs `ball_protobuf_rt_smoke.cpp` (which #includes the
# header and round-trips real values through the compiled codecs) as a CI canary
# that links NOTHING — proving the runtime stands entirely on its own.
if(BALL_BUILD_PROTOBUF_RT)
    add_executable(ball_protobuf_rt_smoke ball_protobuf_rt_smoke.cpp)
    set_target_properties(ball_protobuf_rt_smoke PROPERTIES
        CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
    target_compile_options(ball_protobuf_rt_smoke PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>)
    add_test(NAME protobuf_rt_smoke COMMAND ball_protobuf_rt_smoke)
endif()
