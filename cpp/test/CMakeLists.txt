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

enable_testing()
add_test(NAME engine_tests COMMAND test_engine)
add_test(NAME compiler_tests COMMAND test_compiler)
