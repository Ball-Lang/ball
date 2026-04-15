cmake_minimum_required(VERSION 3.14)
project(ball_cpp_tests)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Engine tests
add_executable(test_engine test_engine.cpp)
target_include_directories(test_engine PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../engine/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_engine ball_cpp_engine ball_shared)

# Compiler tests
add_executable(test_compiler test_compiler.cpp)
target_include_directories(test_compiler PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../compiler/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_compiler ball_cpp_compiler_lib ball_shared)

# Conformance tests — runs all tests/conformance/*.ball.json through the
# C++ engine and compares output against the matching .expected_output.txt.
add_executable(test_conformance test_conformance.cpp)
target_include_directories(test_conformance PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../engine/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_conformance ball_cpp_engine ball_shared)
target_compile_definitions(test_conformance PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
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

# Performance regression harness — runs every conformance program
# through the C++ engine N times and writes per-program timings to a
# CSV under the build tree. Capture-only: no budget enforcement.
add_executable(test_perf test_perf.cpp)
target_include_directories(test_perf PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../engine/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_perf ball_cpp_engine ball_shared)
target_compile_definitions(test_perf PRIVATE
    BALL_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/conformance"
    BALL_PERF_CSV_OUT="${CMAKE_CURRENT_BINARY_DIR}/perf.csv"
    BALL_PERF_BASELINE="${CMAKE_CURRENT_SOURCE_DIR}/../../tests/perf_baseline.csv"
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
# hand-crafted minimal Clang AST JSON fixtures. Also links the engine
# for round-trip tests (AST → encoder → Program → engine → value).
add_executable(test_encoder test_encoder.cpp)
target_include_directories(test_encoder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../encoder/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../engine/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)
target_link_libraries(test_encoder
    ball_cpp_encoder_lib
    ball_cpp_engine
    ball_shared
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

enable_testing()
add_test(NAME engine_tests COMMAND test_engine)
add_test(NAME compiler_tests COMMAND test_compiler)
add_test(NAME conformance_tests COMMAND test_conformance)
add_test(NAME encoder_tests COMMAND test_encoder)
add_test(NAME e2e_tests COMMAND test_e2e)
add_test(NAME snapshot_tests COMMAND test_snapshot)
