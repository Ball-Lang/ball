cmake_minimum_required(VERSION 3.14)
project(ball_cpp_shared)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Buf CLI integration ───────────────────────────────────────
# Adds buf_generate_cpp(), buf_add_lint_target(), etc.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
include(BufGenerate)

# ── Protobuf runtime library ─────────────────────────────────
# NOTE: This version (v34.1) MUST match the plugin version pinned in
#       cpp/buf.gen.cpp.yaml  (remote: buf.build/protocolbuffers/cpp:v34.1).
#       Mismatched versions cause #error at compile time.
set(BALL_PROTOBUF_TAG "v34.1" CACHE STRING "Protobuf Git tag (must match buf.gen.cpp.yaml)")

# By default, always use the pinned FetchContent protobuf (BALL_PROTOBUF_TAG)
# so the checked-in generated code in gen/ — which targets that exact version
# and includes headers like runtime_version.h — compiles everywhere. An
# incompatible system protobuf (e.g. Ubuntu apt's older libprotobuf-dev) must
# NOT be silently preferred; that caused CI build failures. Opt into a system
# protobuf only when you know it matches BALL_PROTOBUF_TAG:
#   cmake -S cpp -B build -DBALL_USE_SYSTEM_PROTOBUF=ON
option(BALL_USE_SYSTEM_PROTOBUF "Use system protobuf instead of the pinned FetchContent version" OFF)
if(BALL_USE_SYSTEM_PROTOBUF)
    find_package(Protobuf QUIET)
endif()
if(NOT Protobuf_FOUND)
    message(STATUS "System protobuf not found — fetching from GitHub …")
    include(FetchContent)
    set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(protobuf_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(protobuf_INSTALL OFF CACHE BOOL "" FORCE)
    # Use abseil bundled with protobuf
    set(protobuf_ABSL_PROVIDER "module" CACHE STRING "" FORCE)
    FetchContent_Declare(
        protobuf
        GIT_REPOSITORY https://github.com/protocolbuffers/protobuf.git
        GIT_TAG        ${BALL_PROTOBUF_TAG}
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(protobuf)
endif()

# ── Generate C++ protobuf sources via buf ─────────────────────
# When buf is on PATH: regenerates into build tree when ball.proto changes.
# When buf is not available: uses checked-in files in gen/.
buf_generate_cpp(
    PROTO_DIR    "${CMAKE_CURRENT_SOURCE_DIR}/../../proto"
    TEMPLATE     "${CMAKE_CURRENT_SOURCE_DIR}/../buf.gen.cpp.yaml"
    OUTPUT_DIR   "${CMAKE_CURRENT_BINARY_DIR}/gen"
    FALLBACK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/gen"
    SOURCES_VAR  BALL_PROTO_SOURCES
    HEADERS_VAR  BALL_PROTO_HEADERS
)

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

add_library(ball_shared
    src/ball_shared.cpp
    ${BALL_PROTO_SOURCES}
    "${BALL_EMIT_RUNTIME_EMBED}"
    "${BALL_DYN_EMBED}"
)
add_dependencies(ball_shared ball_emit_runtime_gen)

target_include_directories(ball_shared PUBLIC
    include
    ${BALL_PROTO_INCLUDE_DIR}
    "${CMAKE_CURRENT_BINARY_DIR}/gen"
)

target_link_libraries(ball_shared PUBLIC protobuf::libprotobuf)

# ── #18 Stage 3: descriptor-driven binary decode via ball_protobuf (default OFF) ──
# When ON, ball_file.h's `.ball.pb`/`.ball.bin` wire path routes through Ball's
# own compiled protobuf runtime (`ball_protobuf_rt.h` + the generated
# `ball_program_descriptor.h`) instead of google's Any/Program parser. The
# entire ball_protobuf `BallDyn` universe is confined to `ball_rt_decode.cpp`
# (pure-std interface in `ball_rt_decode.h`), so the default build is byte-for-
# byte unchanged — google stays the sole binary decoder unless you opt in:
#   cmake -S cpp -B build -DBALL_USE_BALL_PROTOBUF=ON
# google's libprotobuf is still linked (Stage 4 removes it once the compiler /
# encoder migrate off the generated `ball::v1::` accessor types).
option(BALL_USE_BALL_PROTOBUF
    "Route ball_file.h binary loading through ball_protobuf_rt (default OFF)" OFF)
if(BALL_USE_BALL_PROTOBUF)
    target_sources(ball_shared PRIVATE ball_rt_decode.cpp)
    # ball_file.h (in include/) does `#include "ball_rt_decode.h"` under the
    # option; that header — and ball_protobuf_rt.h / ball_program_descriptor.h —
    # live in the shared ROOT, so put it on the PUBLIC path for all consumers.
    target_include_directories(ball_shared PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
    # ball_protobuf_rt.h is a generated single TU (~9k lines, huge functions):
    # give MSVC /bigobj and silence its warnings, only for this one file so the
    # rest of ball_shared keeps its normal diagnostics.
    set_source_files_properties(ball_rt_decode.cpp PROPERTIES COMPILE_OPTIONS
        "$<$<CXX_COMPILER_ID:MSVC>:/W0;/bigobj>;$<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>")
    # PUBLIC so ball_file.h consumers (compiler, tests) compile the same branch
    # and link the ball::rt::DecodeAnyPayload symbol from ball_shared.
    target_compile_definitions(ball_shared PUBLIC BALL_USE_BALL_PROTOBUF)
    message(STATUS "#18 Stage 3: ball_protobuf binary decode ENABLED (BALL_USE_BALL_PROTOBUF)")
endif()

# ── #18 canary: build the Ball-compiled protobuf runtime standalone ──────────
# `ball_protobuf_rt.h` is Ball's own `ball_protobuf` runtime, compiled
# Ball→C++ (header-only, `--library` mode) by the Ball C++ compiler
# (regenerate via `dart/compiler/tool/compile_ball_protobuf_cpp.dart`, or
# directly: `ball_cpp_compile dart/shared/ball_protobuf.json --library --ns
# ball_protobuf --out cpp/shared/ball_protobuf_rt.h`). It is deliberately
# self-contained — only <std> headers, NO libprotobuf, NO abseil, NO
# nlohmann/json — which is the whole point of #18/#25 (drop Google protobuf and
# its abseil-mutex deadlock).
#
# Nothing in the DEFAULT build compiles it yet: the compiler/encoder still
# consume the generated `ball::v1::` protobuf types (migrating their ~600 KB of
# emission call-sites from `ball::v1::` accessors to the protobuf-free
# `ball::ir` loader in include/ball_ir.h is the deferred full cutover). Because
# nothing builds it, it can silently rot. This opt-in target compiles + links +
# runs `ball_protobuf_rt_smoke.cpp` — which #includes the header and round-trips
# real values (varint/zigzag/fixed32) through the compiled encode/decode
# functions — as a CI canary: if the Ball→C++ runtime stops building OR its wire
# codecs regress, CI goes red HERE instead of the breakage only surfacing during
# the eventual cutover.
#
# Links NOTHING on purpose — proving the runtime stands entirely on its own.
if(BALL_BUILD_PROTOBUF_RT)
    add_executable(ball_protobuf_rt_smoke ball_protobuf_rt_smoke.cpp)
    set_target_properties(ball_protobuf_rt_smoke PROPERTIES
        CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
    # ball_protobuf_rt.h is a generated single TU (~9k lines, huge functions):
    # silence its warnings and give MSVC the large object-section count
    # (/bigobj) it needs. ball_protobuf_rt_smoke.cpp itself is hand-written and
    # warning-clean, but the flags apply per-target, not per-file.
    target_compile_options(ball_protobuf_rt_smoke PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>)
    add_test(NAME protobuf_rt_smoke COMMAND ball_protobuf_rt_smoke)
endif()
