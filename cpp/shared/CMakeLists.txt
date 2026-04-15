cmake_minimum_required(VERSION 3.14)
project(ball_cpp_shared)

set(CMAKE_CXX_STANDARD 17)
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

# Try system protobuf first; fall back to FetchContent.
find_package(Protobuf QUIET)
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
add_custom_target(ball_emit_runtime_gen
    DEPENDS "${BALL_EMIT_RUNTIME_EMBED}"
)

add_library(ball_shared
    src/ball_shared.cpp
    ${BALL_PROTO_SOURCES}
    "${BALL_EMIT_RUNTIME_EMBED}"
)
add_dependencies(ball_shared ball_emit_runtime_gen)

target_include_directories(ball_shared PUBLIC
    include
    ${BALL_PROTO_INCLUDE_DIR}
    "${CMAKE_CURRENT_BINARY_DIR}/gen"
)

target_link_libraries(ball_shared PUBLIC protobuf::libprotobuf)
