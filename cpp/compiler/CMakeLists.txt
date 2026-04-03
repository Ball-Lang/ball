cmake_minimum_required(VERSION 3.14)
project(ball_cpp_compiler)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Protobuf provided transitively via ball_shared
find_package(Protobuf QUIET)

add_library(ball_cpp_compiler_lib
    src/compiler.cpp
)

target_include_directories(ball_cpp_compiler_lib PUBLIC
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)

target_link_libraries(ball_cpp_compiler_lib PUBLIC ball_shared)

add_executable(ball_cpp_compile src/main.cpp)
target_link_libraries(ball_cpp_compile ball_cpp_compiler_lib)

# Increase stack size for deep protobuf parsing (128 MB)
if(MSVC)
    target_link_options(ball_cpp_compile PRIVATE /STACK:134217728)
elseif(APPLE)
    target_link_options(ball_cpp_compile PRIVATE -Wl,-stack_size,0x8000000)
else()
    target_link_options(ball_cpp_compile PRIVATE -Wl,-z,stacksize=134217728)
endif()
