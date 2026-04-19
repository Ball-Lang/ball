cmake_minimum_required(VERSION 3.14)
project(ball_cpp_engine)

set(CMAKE_CXX_STANDARD 20)
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

# Bump the runner's thread stack so deep recursion (e.g. Ball programs
# that recurse ~1000 frames via closures) doesn't hit the OS stack
# limit in Debug builds before user code can produce meaningful output.
# Matches the compiler (128 MB) and encoder (256 MB) strategy.
if(MSVC)
    target_link_options(ball_cpp_runner PRIVATE /STACK:134217728)
elseif(APPLE)
    target_link_options(ball_cpp_runner PRIVATE -Wl,-stack_size,0x8000000)
else()
    target_link_options(ball_cpp_runner PRIVATE -Wl,-z,stacksize=134217728)
endif()
