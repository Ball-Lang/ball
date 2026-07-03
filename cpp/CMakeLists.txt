cmake_minimum_required(VERSION 3.14)
project(ball_cpp)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

# ── #18: drop-Google-protobuf staging ────────────────────────
# When ON, builds `cpp/shared/ball_protobuf_rt.h` (Ball's own protobuf
# runtime, compiled Ball→C++) plus a hand-written smoke driver that round-trips
# real values through it, as a standalone proof/canary executable that links NO
# libprotobuf / abseil / nlohmann. Default OFF so the normal build is
# byte-for-byte unchanged; CI enables it with -DBALL_BUILD_PROTOBUF_RT=ON. The
# target lives in cpp/shared/CMakeLists.txt; deferral notes + the full cutover
# plan are in cpp/shared/AGENTS.md.
option(BALL_BUILD_PROTOBUF_RT
    "Build ball_protobuf_rt.h + its smoke driver as a standalone proof target (#18 canary)" OFF)

# ── Buf CLI targets (lint, breaking, format) ──────────────────
# These are available when buf is on PATH; silently skipped otherwise.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(BufGenerate)

set(BALL_PROTO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../proto")
buf_add_lint_target("${BALL_PROTO_DIR}")
buf_add_breaking_target("${BALL_PROTO_DIR}")
buf_add_format_target("${BALL_PROTO_DIR}")

# Convenience: 'buf_check' runs lint + format in one shot
if(BUF_FOUND)
    add_custom_target(buf_check
        DEPENDS buf_lint buf_format
        COMMENT "buf check: lint + format"
    )
endif()

# Shared library (protobuf types + helpers)
add_subdirectory(shared)

# Compiler (Ball → C++ code generation)
add_subdirectory(compiler)

# Encoder (C++ Clang AST → Ball program) — requires nlohmann/json
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/encoder/src/encoder.cpp")
    add_subdirectory(encoder)
endif()

# Tests
add_subdirectory(test)
