#!/usr/bin/env bash
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
