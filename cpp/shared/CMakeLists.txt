cmake_minimum_required(VERSION 3.14)
project(ball_cpp_shared)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
        GIT_TAG        v33.4
        GIT_SHALLOW    TRUE
    )
    FetchContent_MakeAvailable(protobuf)
endif()

add_library(ball_shared
    src/ball_shared.cpp
    gen/ball/v1/ball.pb.cc
)

target_include_directories(ball_shared PUBLIC
    include
    gen
)

target_link_libraries(ball_shared PUBLIC protobuf::libprotobuf)
