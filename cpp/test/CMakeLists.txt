cmake_minimum_required(VERSION 3.14)
project(ball_cpp_tests)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
include(BallSelfhostEngine)

# Compiler tests
add_executable(test_compiler test_compiler.cpp)
target_include_directories(test_compiler PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_compiler ball_cpp_compiler_lib ball_shared)
# BALL_CONFORMANCE_DIR lets the CLI-mode coverage tests (compile_split /
# compile_module) drive real class/enum/top-level-var-bearing programs
# loaded from the corpus — those orchestration paths are never reached by
# the single-TU compile() the numbered-fixture e2e uses (issue #63).
target_compile_definitions(test_compiler PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
)

# Coverage-only corpus driver (issue #63) — compiles every e2e fixture through
# CppCompiler::compile() with NO nested per-fixture g++ builds, giving
# CI-equivalent instrumented compiler.cpp coverage in ~11s. EXCLUDE_FROM_ALL so
# the default `cmake --build` and CI's ctest never touch it; build-cov-build.sh
# names it explicitly.
add_executable(corpus_driver EXCLUDE_FROM_ALL corpus_driver.cpp)
target_include_directories(corpus_driver PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(corpus_driver ball_cpp_compiler_lib ball_shared)
target_compile_definitions(corpus_driver PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
    BALL_GENERATED_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/dart/_generated"
)

# Shared-library tests — the std module descriptor builders
# (build_std_module/build_std_memory_module/build_std_collections_module/
# build_std_io_module) and the Struct<->BallMap conversion helpers in
# cpp/shared/src/ball_shared.cpp. Not exercised by the compiler/encoder/
# engine themselves, so they need their own direct coverage.
add_executable(test_shared test_shared.cpp)
target_include_directories(test_shared PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_shared ball_shared)

# ball_file.h tests — the self-describing google.protobuf.Any envelope
# reader (DecodeBallFile/DecodeBallFileJson/DecodeBallFileBinary/LoadProgram/
# LoadModule/DecodeProgram). Not exercised by test_compiler/test_encoder/
# test_shared (they never feed a malformed or wrong-kind ball file through
# the loader), so its error branches sat largely uncovered (issue #63).
add_executable(test_ball_file test_ball_file.cpp)
target_include_directories(test_ball_file PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_ball_file ball_shared)

# #18 Stage 5: the byte-equivalence harness (test_ball_rt_equivalence) retired
# WITH the google path — its whole purpose was to prove ball_protobuf's binary
# decode matched google's, which is inherently a google-oracle comparison. Its
# regression value (the rt binary path decodes correctly) is preserved by
# test_ball_file's golden Any-wire vectors, which pin the rt path without google.

# BallDyn / BallOrderedMap / ball_emit_runtime.h runtime tests — the
# compiled-program runtime (issue #63). Neither header is reachable from
# test_compiler/test_encoder/test_shared (those drive the compiler/encoder,
# not the emitted-program runtime it emits): their heaviest real exercise is
# the SEPARATE stringified ball_dyn_embed.h/ball_emit_runtime_embed.h copies
# spliced into generated programs, compiled in a non-instrumented subprocess
# by test_e2e/self-host and invisible to gcov. Mirrors scope_probe.cpp's
# include order (standard headers, then ball_emit_runtime.h, then
# ball_dyn.h — NOT ball_shared.h, whose `ball::BallMap` collides with the
# global `::BallMap` these headers define).
add_executable(test_ball_dyn test_ball_dyn.cpp)
target_include_directories(test_ball_dyn PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
set_target_properties(test_ball_dyn PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
# Same MSVC options as scope_probe (both directly instantiate the wide
# BallDyn/BallOrderedMap template surface): /bigobj for the object file's
# section count, /W0 to match the rest of the suite's warning posture for
# this header.
target_compile_options(test_ball_dyn PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
)

# End-to-end compiler tests — compile selected conformance programs to C++
# source, invoke the system C++ compiler to build a binary, run it, and
# diff the stdout against the expected output.
add_executable(test_e2e test_e2e.cpp)
target_include_directories(test_e2e PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_e2e ball_cpp_compiler_lib ball_shared)
# The e2e test delegates the actual compile to a tiny CMake sub-project
# so we inherit the full toolchain setup (MSVC needs INCLUDE/LIB env vars
# that CMake's generator knows how to produce, but a freestanding cl.exe
# invocation does not). The test writes the generated .cpp files into a
# scratch directory then invokes `cmake -S ... -B ...` + `cmake --build`.
target_compile_definitions(test_e2e PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
    BALL_GENERATED_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/dart/_generated"
    BALL_E2E_CMAKE="${CMAKE_COMMAND}"
    BALL_E2E_GENERATOR="${CMAKE_GENERATOR}"
    BALL_E2E_BUILD_TYPE="$<CONFIG>"
)

# Snapshot tests — pins the exact CppCompiler output for each fixture.
add_executable(test_snapshot test_snapshot.cpp)
target_include_directories(test_snapshot PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_snapshot ball_cpp_compiler_lib ball_shared)
target_compile_definitions(test_snapshot PRIVATE
    BALL_SNAPSHOT_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/snapshots/cpp"
    BALL_GENERATED_JSON_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/dart/_generated"
)

# Encoder tests — exercises CppEncoder::encode_from_clang_ast using
# hand-crafted minimal Clang AST JSON fixtures. #18: the encoder returns the
# protobuf-free ball::ir IR, so the test links only the (protobuf-free)
# encoder lib — NOT ball_shared. nlohmann/json comes transitively from the
# encoder lib's PUBLIC link.
add_executable(test_encoder test_encoder.cpp)
target_include_directories(test_encoder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../encoder/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_encoder
    ball_cpp_encoder_lib
)
# Path to real clang AST fixtures. Checked in under
# tests/fixtures/cpp_ast/ast/ so tests run without needing clang
# on PATH; regenerate via the script in the same directory.
target_compile_definitions(test_encoder PRIVATE
    BALL_CLANG_AST_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/cpp_ast/ast"
)
# Match the encoder binary's 256 MB thread stack — encoder frames are
# large and the kMaxEncodeDepth=512 guard assumes room to recurse.
if(MSVC)
    target_link_options(test_encoder PRIVATE /STACK:268435456)
elseif(APPLE)
    target_link_options(test_encoder PRIVATE -Wl,-stack_size,0x10000000)
else()
    target_link_options(test_encoder PRIVATE -Wl,-z,stacksize=268435456)
endif()

# Protobuf-free Ball IR loader (#18) — parses the whole conformance corpus via
# nlohmann/json with NO libprotobuf / generated ball.pb.*. The foundation of the
# "drop google::protobuf" effort: proves Ball loads its own IR without Google's
# protobuf runtime.
add_executable(test_ball_ir test_ball_ir.cpp)
target_include_directories(test_ball_ir PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
if(NOT TARGET nlohmann_json::nlohmann_json)
    find_package(nlohmann_json QUIET)
endif()
if(NOT TARGET nlohmann_json::nlohmann_json)
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz)
    FetchContent_MakeAvailable(json)
endif()
target_link_libraries(test_ball_ir PRIVATE nlohmann_json::nlohmann_json)
target_compile_definitions(test_ball_ir PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
)
set_target_properties(test_ball_ir PROPERTIES
    CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON
)

# P4 descriptor-WRITE builder test (#18) — exercises ball_ir.h's hand-rolled
# DescriptorProto/EnumDescriptorProto JSON construction. #18 Stage 5: the google
# oracle retired with libprotobuf — the test now pins P4's output against GOLDEN
# proto3-JSON (authored from the spec + an independent type table) via nlohmann
# equality, so it links only nlohmann/json (NOT ball_shared / libprotobuf).
add_executable(test_ball_ir_descriptor test_ball_ir_descriptor.cpp)
target_include_directories(test_ball_ir_descriptor PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_ball_ir_descriptor PRIVATE
    nlohmann_json::nlohmann_json
)
set_target_properties(test_ball_ir_descriptor PROPERTIES
    CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON
)

# Self-hosted engine compilation test — multi-TU engine_rt/ (preferred) or
# legacy monolithic engine_rt.cpp. Both are gitignored and regenerated
# locally; skip self-host targets when absent (CI builds native engine only).
set(BALL_SELFHOST_RT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib/engine_rt")
set(BALL_SELFHOST_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib/engine_rt.cpp")
set(BALL_SELFHOST_AVAILABLE FALSE)
if(EXISTS "${BALL_SELFHOST_RT_DIR}/engine_rt_common.hpp")
    set(BALL_SELFHOST_AVAILABLE TRUE)
    ball_add_selfhost_engine_target(ball_selfhost_engine)
    add_library(test_selfhost_compile ALIAS ball_selfhost_engine)
elseif(EXISTS "${BALL_SELFHOST_CPP}")
    set(BALL_SELFHOST_AVAILABLE TRUE)
    add_library(test_selfhost_compile OBJECT "${BALL_SELFHOST_CPP}")
    target_compile_options(test_selfhost_compile PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
    )
    set_target_properties(test_selfhost_compile PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
    )
else()
    message(STATUS "Skipping self-host C++ targets: engine_rt not generated")
endif()

# Scope-machinery probe — isolates bind/child/has/lookup from the full engine
# so scope-identity bugs can be debugged in seconds, not minutes.
add_executable(scope_probe scope_probe.cpp)
target_include_directories(scope_probe PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
set_target_properties(scope_probe PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_options(scope_probe PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
)

# Self-hosted engine conformance tests — runs conformance programs through
# the compiled Ball engine (multi-TU engine_rt/ or legacy engine_rt.cpp).
if(BALL_SELFHOST_AVAILABLE)
add_executable(test_selfhost_conformance test_selfhost_conformance.cpp)
target_include_directories(test_selfhost_conformance PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
if(TARGET ball_selfhost_engine)
    target_include_directories(test_selfhost_conformance PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib/engine_rt
    )
    target_sources(test_selfhost_conformance PRIVATE $<TARGET_OBJECTS:ball_selfhost_engine>)
    target_compile_definitions(test_selfhost_conformance PRIVATE BALL_SELFHOST_MULTI_TU=1)
endif()
# Monolithic engine_rt.cpp is #included by test_selfhost_conformance.cpp — do not
# also compile it as a separate TU (MSVC elides the include body → LNK2019).
target_link_libraries(test_selfhost_conformance ball_shared)
target_compile_options(test_selfhost_conformance PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
    $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
)
target_compile_definitions(test_selfhost_conformance PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
)
set_target_properties(test_selfhost_conformance PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
)
# Stack: 256 MB reserve, 4 MB commit. The compiled engine is a tree-walking
# interpreter — each Ball function call expands to many large C++ frames
# (deeply nested BallDyn(...) temporaries), so it needs a stack as large as the
# encoder's. The harness runs each fixture on the MAIN thread (these linker
# flags size only the main-thread stack) — one fixture per CTest process — so
# this reserve is what protects against stack overflow (a worker thread would
# get the small default pthread stack on POSIX instead).
if(MSVC)
    target_link_options(test_selfhost_conformance PRIVATE /STACK:268435456,4194304)
elseif(APPLE)
    target_link_options(test_selfhost_conformance PRIVATE -Wl,-stack_size,0x10000000)
else()
    target_link_options(test_selfhost_conformance PRIVATE -Wl,-z,stacksize=268435456)
endif()
endif()

# CLI entry-point tests — subprocess-invokes the REAL ball_cpp_compile /
# ball_cpp_encode executables (issue #63: cpp/{compiler,encoder}/src/main.cpp
# were 0% in every prior coverage sweep — no other test binary invokes them,
# they only drive the compiler/encoder LIBRARIES in-process). $<TARGET_FILE:>
# resolves the built binary path portably across single- and multi-config
# generators; add_dependencies ensures they're built before test_cli runs.
add_executable(test_cli test_cli.cpp)
target_compile_definitions(test_cli PRIVATE
    BALL_CPP_COMPILE_EXE="$<TARGET_FILE:ball_cpp_compile>"
    BALL_CPP_ENCODE_EXE="$<TARGET_FILE:ball_cpp_encode>"
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
    BALL_CLANG_AST_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/fixtures/cpp_ast/ast"
)
add_dependencies(test_cli ball_cpp_compile ball_cpp_encode)

# CLI-verb parity gate (issue #367) — the C++ mirror of
# dart/cli/test/cli_core_parity_test.dart. Built ONLY when the self-hosted
# cli_core header (dart/self_host/lib/cli_rt.h) has been generated
# (dart run compiler/tool/gen_cli_cpp.dart); it links that header and asserts
# the compiled verbs match the Dart-native goldens
# (dart run cli/tool/gen_cli_parity_goldens.dart <dir>). Skipped otherwise, so
# the build-isolated main cpp CI job (no Dart, no cli_rt.h) stays green.
set(BALL_CLI_RT_HDR "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib/cli_rt.h")
set(BALL_CLI_PARITY_AVAILABLE FALSE)
if(EXISTS "${BALL_CLI_RT_HDR}")
    set(BALL_CLI_PARITY_AVAILABLE TRUE)
    # Single-source the version from the Dart CLI pubspec (matches cpp/cli).
    set(_cli_pubspec "${CMAKE_CURRENT_SOURCE_DIR}/../../dart/cli/pubspec.yaml")
    set(_cli_ver "0.0.0")
    if(EXISTS "${_cli_pubspec}")
        file(STRINGS "${_cli_pubspec}" _vl REGEX "^version:")
        if(_vl)
            string(REGEX REPLACE "^version:[ \t]*" "" _cli_ver "${_vl}")
            string(STRIP "${_cli_ver}" _cli_ver)
        endif()
    endif()
    add_executable(test_cli_parity test_cli_parity.cpp)
    target_include_directories(test_cli_parity PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/../../dart/self_host/lib
        ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
    )
    # test_cli_parity.cpp includes <nlohmann/json.hpp>; link the interface
    # target that carries its include path. test_ball_ir (above) already made
    # the target available (find_package / FetchContent), but re-guard here so
    # this block does not depend on that ordering — without the link, the header
    # is only found incidentally on some toolchains (Linux) and the macOS
    # release build fails with "'nlohmann/json.hpp' file not found".
    if(NOT TARGET nlohmann_json::nlohmann_json)
        find_package(nlohmann_json QUIET)
    endif()
    if(NOT TARGET nlohmann_json::nlohmann_json)
        include(FetchContent)
        FetchContent_Declare(json
            URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz)
        FetchContent_MakeAvailable(json)
    endif()
    target_link_libraries(test_cli_parity PRIVATE nlohmann_json::nlohmann_json)
    target_compile_definitions(test_cli_parity PRIVATE
        BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
        BALL_CLI_PARITY_GOLDENS="${CMAKE_BINARY_DIR}/cli_parity_goldens"
        BALL_CLI_VERSION="${_cli_ver}"
    )
    target_compile_options(test_cli_parity PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W0 /bigobj>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-w>
    )
    set_target_properties(test_cli_parity PROPERTIES
        CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
endif()

enable_testing()
add_test(NAME compiler_tests COMMAND test_compiler)
add_test(NAME cli_tests COMMAND test_cli)
add_test(NAME shared_tests COMMAND test_shared)
add_test(NAME ball_file_tests COMMAND test_ball_file)
add_test(NAME encoder_tests COMMAND test_encoder)
add_test(NAME e2e_tests COMMAND test_e2e)
add_test(NAME snapshot_tests COMMAND test_snapshot)
add_test(NAME ball_ir_loader COMMAND test_ball_ir)
add_test(NAME ball_ir_descriptor COMMAND test_ball_ir_descriptor)
add_test(NAME ball_dyn_tests COMMAND test_ball_dyn)
# scope_probe was previously a build-only debug tool (never run under ctest,
# so its own bind/child/has/lookup exercise of ball_dyn.h's scope machinery
# never counted toward coverage). It's a real pass/fail harness (returns
# nonzero on any FAIL) — registering it costs nothing and closes that gap.
add_test(NAME scope_probe_tests COMMAND scope_probe)
if(BALL_CLI_PARITY_AVAILABLE)
    # Requires the goldens to be generated first (CI does this before ctest):
    #   cd dart && dart run cli/tool/gen_cli_parity_goldens.dart \
    #       "${CMAKE_BINARY_DIR}/cli_parity_goldens"
    add_test(NAME cli_parity_tests COMMAND test_cli_parity)
endif()
if(BALL_SELFHOST_AVAILABLE)
    # One CTest test per conformance fixture: each runs in its OWN PROCESS
    # (CTest's native, cross-platform isolation) on the binary's main thread, so
    # a fixture that overflows the stack or hangs fails only its own test —
    # never the whole suite. (The previous single in-process run executed every
    # fixture on a detached worker thread and died uncatchably when one
    # overflowed the small default thread stack on POSIX.) Run them with
    # `ctest -L selfhost -j N`; CONFIGURE_DEPENDS re-globs as fixtures change.
    file(GLOB _ball_selfhost_fixtures CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance/*.ball.json")
    foreach(_fx ${_ball_selfhost_fixtures})
        get_filename_component(_fxfile "${_fx}" NAME)
        string(REGEX REPLACE "\\.ball\\.json$" "" _fxname "${_fxfile}")
        add_test(NAME "selfhost/${_fxname}"
                 COMMAND test_selfhost_conformance "${_fxname}")
        # 1200s: the self-host engine is a std::any-boxed tree-walker (~1000x
        # slower than native), so a few fixtures take a minute or two even alone
        # (e.g. 143_perfect_number ~110s, more on slower CI). The budget clears
        # that with wide margin. CI runs these SEQUENTIALLY (ctest, no -j) so
        # heavy fixtures don't contend for cores/RAM and swap — see
        # .github/workflows/regression-gates.yml.
        set_tests_properties("selfhost/${_fxname}" PROPERTIES
            TIMEOUT 1200 LABELS "selfhost")
    endforeach()
    # Self-host-only std_fs directory-ops regression (fail-loud dir stubs). Not
    # backed by a tests/conformance/*.ball.json — filesystem side effects aren't
    # portable golden output — so the harness runs it via the synthetic
    # "std_fs_dir" case (see run_fs_dir_selfhost in test_selfhost_conformance.cpp),
    # which owns its temp dir + cleanup. Labeled selfhost so the tally job
    # (`ctest -L selfhost`) includes it.
    add_test(NAME "selfhost/std_fs_dir"
             COMMAND test_selfhost_conformance "std_fs_dir")
    set_tests_properties("selfhost/std_fs_dir" PROPERTIES
        TIMEOUT 300 LABELS "selfhost")
    # Self-host-only std_fs write-ops regression (issue #310 — fail-loud byte
    # writes + append mode). Same rationale as std_fs_dir above: filesystem
    # side effects aren't portable golden output, so it runs via the
    # synthetic "std_fs_write" case (see run_fs_write_selfhost in
    # test_selfhost_conformance.cpp), which owns its own temp dir + cleanup.
    add_test(NAME "selfhost/std_fs_write"
             COMMAND test_selfhost_conformance "std_fs_write")
    set_tests_properties("selfhost/std_fs_write" PROPERTIES
        TIMEOUT 300 LABELS "selfhost")
endif()
