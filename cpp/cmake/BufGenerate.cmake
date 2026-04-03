# BufGenerate.cmake — Buf CLI integration for CMake.
#
# Provides:
#   buf_generate_cpp()  — Generate C++ protobuf sources from ball.proto via buf
#   buf_add_lint_target()     — Add a 'buf_lint' custom target
#   buf_add_breaking_target() — Add a 'buf_breaking' custom target
#   buf_add_format_target()   — Add a 'buf_format' custom target
#
# When buf is not found on PATH, generation falls back to checked-in files
# in cpp/shared/gen/ and lint/breaking/format targets are silently skipped.

cmake_minimum_required(VERSION 3.14)

# ── Find buf CLI ──────────────────────────────────────────────
find_program(BUF_EXECUTABLE buf)

if(BUF_EXECUTABLE)
    execute_process(
        COMMAND ${BUF_EXECUTABLE} --version
        OUTPUT_VARIABLE BUF_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    message(STATUS "Found buf CLI: ${BUF_EXECUTABLE} (${BUF_VERSION})")
    set(BUF_FOUND TRUE)
else()
    message(STATUS "buf CLI not found — using checked-in generated files")
    set(BUF_FOUND FALSE)
endif()

# ── buf_generate_cpp() ────────────────────────────────────────
# Runs `buf generate` with a C++-only template, outputting into
# ${OUTPUT_DIR}.  Returns the list of generated source files in
# the variable named by SOURCES_VAR.
#
# If buf is unavailable, populates SOURCES_VAR from the checked-in
# gen/ directory instead.
#
# Usage:
#   buf_generate_cpp(
#       PROTO_DIR   "${CMAKE_CURRENT_SOURCE_DIR}/../../proto"
#       TEMPLATE    "${CMAKE_CURRENT_SOURCE_DIR}/../buf.gen.cpp.yaml"
#       OUTPUT_DIR  "${CMAKE_CURRENT_BINARY_DIR}/gen"
#       FALLBACK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/gen"
#       SOURCES_VAR  BALL_PROTO_SOURCES
#       HEADERS_VAR  BALL_PROTO_HEADERS
#   )
function(buf_generate_cpp)
    cmake_parse_arguments(ARG "" "PROTO_DIR;TEMPLATE;OUTPUT_DIR;FALLBACK_DIR;SOURCES_VAR;HEADERS_VAR" "" ${ARGN})

    # Locate the .proto source file for dependency tracking
    set(_proto_file "${ARG_PROTO_DIR}/ball/v1/ball.proto")

    if(BUF_FOUND AND EXISTS "${ARG_TEMPLATE}")
        # Ensure output directory exists
        file(MAKE_DIRECTORY "${ARG_OUTPUT_DIR}")

        # Custom command: re-run buf generate when ball.proto changes
        add_custom_command(
            OUTPUT
                "${ARG_OUTPUT_DIR}/ball/v1/ball.pb.cc"
                "${ARG_OUTPUT_DIR}/ball/v1/ball.pb.h"
            COMMAND ${BUF_EXECUTABLE} generate
                --template "${ARG_TEMPLATE}"
                "${ARG_PROTO_DIR}"
            WORKING_DIRECTORY "${ARG_OUTPUT_DIR}"
            DEPENDS "${_proto_file}" "${ARG_TEMPLATE}"
            COMMENT "buf generate: regenerating C++ protobuf from ball.proto"
            VERBATIM
        )

        set(${ARG_SOURCES_VAR} "${ARG_OUTPUT_DIR}/ball/v1/ball.pb.cc" PARENT_SCOPE)
        set(${ARG_HEADERS_VAR} "${ARG_OUTPUT_DIR}/ball/v1/ball.pb.h" PARENT_SCOPE)
        set(BALL_PROTO_INCLUDE_DIR "${ARG_OUTPUT_DIR}" PARENT_SCOPE)

        message(STATUS "buf generate: C++ protos will regenerate from ${_proto_file}")
    else()
        # Fallback: use checked-in generated files
        if(NOT EXISTS "${ARG_FALLBACK_DIR}/ball/v1/ball.pb.cc")
            message(FATAL_ERROR
                "buf CLI not available and no fallback generated files at "
                "${ARG_FALLBACK_DIR}/ball/v1/ball.pb.cc — "
                "install buf (https://buf.build/docs/cli/installation/) or "
                "run 'buf generate' manually from the repo root.")
        endif()

        set(${ARG_SOURCES_VAR} "${ARG_FALLBACK_DIR}/ball/v1/ball.pb.cc" PARENT_SCOPE)
        set(${ARG_HEADERS_VAR} "${ARG_FALLBACK_DIR}/ball/v1/ball.pb.h" PARENT_SCOPE)
        set(BALL_PROTO_INCLUDE_DIR "${ARG_FALLBACK_DIR}" PARENT_SCOPE)

        message(STATUS "buf generate: using fallback files from ${ARG_FALLBACK_DIR}")
    endif()
endfunction()

# ── buf_add_lint_target() ─────────────────────────────────────
# Adds a 'buf_lint' target that runs `buf lint` on the proto dir.
function(buf_add_lint_target PROTO_DIR)
    if(NOT BUF_FOUND)
        return()
    endif()
    add_custom_target(buf_lint
        COMMAND ${BUF_EXECUTABLE} lint
        WORKING_DIRECTORY "${PROTO_DIR}"
        COMMENT "buf lint: checking proto schema"
        VERBATIM
    )
endfunction()

# ── buf_add_breaking_target() ─────────────────────────────────
# Adds a 'buf_breaking' target that checks backward compatibility.
# AGAINST is the git ref to compare against (default: HEAD~1).
function(buf_add_breaking_target PROTO_DIR)
    cmake_parse_arguments(ARG "" "AGAINST" "" ${ARGN})
    if(NOT BUF_FOUND)
        return()
    endif()
    if(NOT ARG_AGAINST)
        set(ARG_AGAINST ".git#subdir=proto")
    endif()
    add_custom_target(buf_breaking
        COMMAND ${BUF_EXECUTABLE} breaking --against "${ARG_AGAINST}"
        WORKING_DIRECTORY "${PROTO_DIR}"
        COMMENT "buf breaking: checking backward compatibility"
        VERBATIM
    )
endfunction()

# ── buf_add_format_target() ───────────────────────────────────
# Adds a 'buf_format' target that checks proto formatting.
function(buf_add_format_target PROTO_DIR)
    if(NOT BUF_FOUND)
        return()
    endif()
    add_custom_target(buf_format
        COMMAND ${BUF_EXECUTABLE} format --diff --exit-code
        WORKING_DIRECTORY "${PROTO_DIR}"
        COMMENT "buf format: checking proto formatting"
        VERBATIM
    )
endfunction()
