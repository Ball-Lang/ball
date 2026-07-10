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

# ── #18 carve-out: upstream protobuf conformance runner (opt-in) ──────────────
# Stage 5 made the default ball build libprotobuf-free. The Dart `ball_protobuf`
# package's upstream-conformance harness, however, still drives Ball's own
# codecs through the REAL protobuf `conformance_test_runner` (a C++ binary built
# from the protobuf source tree). Building THAT one binary needs a protobuf
# source, so it is FetchContent'd ONLY behind this opt-in option (default OFF) —
# the normal ball build (compiler/encoder/engine/tests) never fetches protobuf.
# The `editions-conformance-upstream` CI job turns it on. This exercises
# ball_protobuf-the-Dart-package, NOT the C++ ball target. See
# dart/ball_protobuf/conformance/README.md.
option(BALL_BUILD_UPSTREAM_CONFORMANCE
    "FetchContent protobuf + build its conformance_test_runner (opt-in, #18 carve-out)" OFF)
if(BALL_BUILD_UPSTREAM_CONFORMANCE)
    include(FetchContent)
    set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(protobuf_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(protobuf_INSTALL OFF CACHE BOOL "" FORCE)
    set(protobuf_ABSL_PROVIDER "module" CACHE STRING "" FORCE)
    set(protobuf_BUILD_CONFORMANCE ON CACHE BOOL "" FORCE)
    FetchContent_Declare(
        protobuf
        GIT_REPOSITORY https://github.com/protocolbuffers/protobuf.git
        GIT_TAG        v34.1
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(protobuf)
    message(STATUS "#18 carve-out: upstream protobuf conformance_test_runner ENABLED")
endif()

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

# Unified `ball` CLI (issue #367). Added AFTER `test` so it can link the
# multi-TU self-host engine object library (ball_selfhost_engine) when present;
# it otherwise gates `run` on the monolithic engine_rt.cpp and its self-hosted
# verbs on the generated cli_rt.h (both build without those artifacts, stubbing
# the affected subcommands, so the main cpp CI job's "build all targets" stays
# green).
add_subdirectory(cli)
