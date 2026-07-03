#!/usr/bin/env bash
# Configures the coverage-instrumented build into a SEPARATE tree
# (build-cov) so build-wsl stays clean (issue #63).
set -uo pipefail
cd "$(dirname "$0")"
export CXXFLAGS="--coverage -O0 -g"
export CFLAGS="--coverage -O0 -g"
export LDFLAGS="--coverage"

# Pre-seed protobuf's FetchContent source from a WSL-native cache dir
# (~/.ball-cache/protobuf-src-v34.1) instead of letting CMake git-clone it
# straight into the build tree. Cloning protobuf's full working tree onto
# the 9p-mounted /mnt/d Windows drive is unreliable under concurrent
# builds ("fatal: unable to write new index file" / "Failed to remove
# directory") — this sidesteps that without touching cpp/shared's
# CMakeLists.txt. Populate the cache once with:
#   mkdir -p ~/.ball-cache && cd ~/.ball-cache && \
#     git clone --depth 1 --branch v34.1 \
#       https://github.com/protocolbuffers/protobuf.git protobuf-src-v34.1
PROTOBUF_CACHE="$HOME/.ball-cache/protobuf-src-v34.1"
EXTRA_ARGS=()
if [ -d "$PROTOBUF_CACHE" ]; then
  EXTRA_ARGS+=("-DFETCHCONTENT_SOURCE_DIR_PROTOBUF=$PROTOBUF_CACHE")
fi

cmake -S . -B build-cov -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="--coverage -O0 -g" \
  -DCMAKE_C_FLAGS="--coverage -O0 -g" \
  -DCMAKE_EXE_LINKER_FLAGS="--coverage" \
  -DCMAKE_SHARED_LINKER_FLAGS="--coverage" \
  "${EXTRA_ARGS[@]}"
