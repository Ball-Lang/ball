cmake_minimum_required(VERSION 3.14)
project(ball_cli)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Single-sourced version (issue #363) ───────────────────────────────────────
# Read the CLI version from the Dart CLI's pubspec so `ball version` can never
# drift from the published package version (the Dart CLI does the same via
# dart/cli/lib/version.g.dart).
set(_pubspec "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/cli/pubspec.yaml")
set(BALL_CLI_VERSION "0.0.0")
if(EXISTS "${_pubspec}")
    file(STRINGS "${_pubspec}" _verline REGEX "^version:")
    if(_verline)
        string(REGEX REPLACE "^version:[ \t]*" "" BALL_CLI_VERSION "${_verline}")
        string(STRIP "${BALL_CLI_VERSION}" BALL_CLI_VERSION)
    endif()
endif()
message(STATUS "ball CLI version: ${BALL_CLI_VERSION}")

set(_selfhost_dir "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib")
set(_cli_rt_hdr "${_selfhost_dir}/cli_rt.h")

# main + the always-available compiler/encoder-backed verbs.
set(_cli_sources
    src/main.cpp
    src/cli_compile.cpp
    src/cli_encode.cpp
)

# ── Portable verbs (self-hosted cli_core) ─────────────────────────────────────
# Real when dart/self_host/lib/cli_rt.h was generated
# (dart run compiler/tool/gen_cli_cpp.dart); otherwise a fail-loud stub, so the
# `ball` target still builds in the build-isolated main cpp CI job.
set(_have_verbs FALSE)
if(EXISTS "${_cli_rt_hdr}")
    set(_have_verbs TRUE)
    list(APPEND _cli_sources src/cli_verbs.cpp)
    message(STATUS "ball CLI: self-hosted verbs ENABLED (cli_rt.h present)")
else()
    list(APPEND _cli_sources src/cli_verbs_stub.cpp)
    message(STATUS "ball CLI: self-hosted verbs stubbed (cli_rt.h absent)")
endif()

# ── run (self-hosted engine_rt) ───────────────────────────────────────────────
# Mirror cpp/test/CMakeLists.txt's detection: prefer the multi-TU engine_rt/
# object library (ball_selfhost_engine, built by the test subdir), else the
# monolithic engine_rt.cpp (#included by cli_run.cpp), else a fail-loud stub.
set(_rt_multi "${_selfhost_dir}/engine_rt/engine_rt_common.hpp")
set(_rt_mono "${_selfhost_dir}/engine_rt.cpp")
set(_have_run FALSE)
set(_run_multi_tu FALSE)
if(EXISTS "${_rt_multi}" AND TARGET ball_selfhost_engine)
    set(_have_run TRUE)
    set(_run_multi_tu TRUE)
    list(APPEND _cli_sources src/cli_run.cpp)
    message(STATUS "ball CLI: run ENABLED (multi-TU engine_rt)")
elseif(EXISTS "${_rt_mono}")
    set(_have_run TRUE)
    list(APPEND _cli_sources src/cli_run.cpp)
    message(STATUS "ball CLI: run ENABLED (monolithic engine_rt.cpp)")
else()
    list(APPEND _cli_sources src/cli_run_stub.cpp)
    message(STATUS "ball CLI: run stubbed (engine_rt absent)")
endif()

add_executable(ball ${_cli_sources})
target_include_directories(ball PRIVATE
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../encoder/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(ball PRIVATE
    ball_cpp_compiler_lib
    ball_cpp_encoder_lib
    ball_shared
)
target_compile_definitions(ball PRIVATE BALL_CLI_VERSION="${BALL_CLI_VERSION}")

# The self-hosted verbs / engine TUs pull the generated headers from the
# self-host dir; both are heavy template TUs that need /bigobj on MSVC.
if(_have_verbs OR _have_run)
    target_include_directories(ball PRIVATE "${_selfhost_dir}")
endif()
if(_run_multi_tu)
    target_include_directories(ball PRIVATE "${_selfhost_dir}/engine_rt")
    target_sources(ball PRIVATE $<TARGET_OBJECTS:ball_selfhost_engine>)
    target_compile_definitions(ball PRIVATE BALL_SELFHOST_MULTI_TU=1)
endif()
target_compile_options(ball PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/bigobj>)

# The self-hosted engine is a std::any-boxed tree-walker: each Ball call expands
# to many large C++ frames, so `ball run` needs the same 256 MB main-thread
# stack as the encoder / conformance harness. Also covers the compiler's deep
# protobuf ASTs (128 MB) — take the larger.
if(MSVC)
    target_link_options(ball PRIVATE /STACK:268435456)
elseif(APPLE)
    target_link_options(ball PRIVATE -Wl,-stack_size,0x10000000)
else()
    target_link_options(ball PRIVATE -Wl,-z,stacksize=268435456)
endif()

# Standard `install(TARGETS)` rule (issue #368) — lets `cmake --install` and
# packaging tooling (the GitHub Releases workflow, a future vcpkg port) stage
# just the `ball` binary via `cmake --build <dir> --target install`, without
# building the cpp/test/ suite: only targets reachable from an install() rule
# are pulled in by the generated `install` target, and `test/` registers none.
install(TARGETS ball RUNTIME DESTINATION bin)
