cmake_minimum_required(VERSION 3.14)
project(ball_cpp_engine)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Protobuf provided transitively via ball_shared
find_package(Protobuf QUIET)

add_library(ball_cpp_engine
    src/engine.cpp
)

target_include_directories(ball_cpp_engine PUBLIC
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)

target_link_libraries(ball_cpp_engine PUBLIC ball_shared)

add_executable(ball_cpp_runner src/main.cpp)
target_link_libraries(ball_cpp_runner ball_cpp_engine)
