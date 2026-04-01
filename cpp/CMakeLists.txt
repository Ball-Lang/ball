cmake_minimum_required(VERSION 3.14)
project(ball_cpp)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

# Shared library (protobuf types + helpers)
add_subdirectory(shared)

# Engine (interpreter)
add_subdirectory(engine)

# Compiler (Ball → C++ code generation)
add_subdirectory(compiler)

# Encoder (C++ Clang AST → Ball program) — requires nlohmann/json
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/encoder/src/encoder.cpp")
    add_subdirectory(encoder)
endif()

# Tests
add_subdirectory(test)
