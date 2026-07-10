#!/usr/bin/env bash
# Configures the coverage-instrumented build into a SEPARATE tree
# (build-cov) so build-wsl stays clean (issue #63).
#
# Since #18 Stage 5 (the protobuf-free flip), the default C++ build no longer
# FetchContents Google protobuf (nlohmann/json only), so this configure is far
# cheaper and needs no protobuf source pre-seed — the former
# ~/.ball-cache/protobuf-src-v34.1 / FETCHCONTENT_SOURCE_DIR_PROTOBUF dance is
# gone (CMake reported it as an unused variable once protobuf left the build).
set -uo pipefail
cd "$(dirname "$0")"
export CXXFLAGS="--coverage -O0 -g"
export CFLAGS="--coverage -O0 -g"
export LDFLAGS="--coverage"

cmake -S . -B build-cov -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="--coverage -O0 -g" \
  -DCMAKE_C_FLAGS="--coverage -O0 -g" \
  -DCMAKE_EXE_LINKER_FLAGS="--coverage" \
  -DCMAKE_SHARED_LINKER_FLAGS="--coverage"
