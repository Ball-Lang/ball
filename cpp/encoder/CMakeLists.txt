cmake_minimum_required(VERSION 3.14)
project(ball_cpp_encoder)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# #18: the encoder is now protobuf-free. It builds the plain-struct
# ball::ir IR (cpp/shared/include/ball_ir.h) straight from the Clang JSON
# AST, so it links NO libprotobuf/abseil — only nlohmann/json. The shared
# include dir is on the path for ball_ir.h (a header-only IR), NOT for the
# protobuf-carrying ball_shared target.
add_library(ball_cpp_encoder_lib
    src/encoder.cpp
)

target_include_directories(ball_cpp_encoder_lib PUBLIC
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/../shared/include
)

# nlohmann/json — try find_package, fall back to FetchContent
find_package(nlohmann_json QUIET)
if(nlohmann_json_FOUND)
    target_link_libraries(ball_cpp_encoder_lib PUBLIC nlohmann_json::nlohmann_json)
else()
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    )
    FetchContent_MakeAvailable(json)
    target_link_libraries(ball_cpp_encoder_lib PUBLIC nlohmann_json::nlohmann_json)
endif()

add_executable(ball_cpp_encode src/main.cpp)
target_link_libraries(ball_cpp_encode ball_cpp_encoder_lib)

# Increase stack size for deep AST processing (256 MB)
if(MSVC)
    target_link_options(ball_cpp_encode PRIVATE /STACK:268435456)
elseif(APPLE)
    target_link_options(ball_cpp_encode PRIVATE -Wl,-stack_size,0x10000000)
else()
    target_link_options(ball_cpp_encode PRIVATE -Wl,-z,stacksize=268435456)
endif()
