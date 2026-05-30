#!/usr/bin/env bash
# Regenerate the upstream-conformance FileDescriptorSet that the ball_protobuf
# descriptor bridge consumes (tests/editions/descriptors/test_messages.fds.binpb).
# Covers all three conformance message families: proto2, proto3, and edition2023.
#
# The test-message .proto files ship with the protobuf source, which CMake
# fetches under cpp/<build>/_deps/protobuf-src. We locate that checkout and run
# protoc (--include_imports for a self-contained set). Pin: protoc 28.2 supports
# edition 2023; do NOT regenerate against an older protoc.
#
# Usage: tools/gen_conformance_descriptors.sh [--check]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/tests/editions/descriptors/test_messages.fds.binpb"

# Find a fetched protobuf source tree.
PB=""
for d in "$ROOT"/cpp/build3/_deps/protobuf-src "$ROOT"/cpp/build/_deps/protobuf-src \
         "$ROOT"/cpp/ci-build/_deps/protobuf-src "$ROOT"/cpp/build-conformance/_deps/protobuf-src; do
  if [ -f "$d/conformance/test_protos/test_messages_edition2023.proto" ]; then PB="$d"; break; fi
done
if [ -z "$PB" ]; then
  echo "error: protobuf source not found; configure a cpp build first (it FetchContent's protobuf)." >&2
  exit 1
fi
echo "protoc:    $(command -v protoc)"
protoc --version
echo "protobuf:  $PB"

GEN="$OUT"
if [ "${1:-}" = "--check" ]; then GEN="$(mktemp)"; fi
mkdir -p "$(dirname "$OUT")"
protoc --include_imports \
  -I "$PB/src" -I "$PB/conformance/test_protos" \
  --descriptor_set_out="$GEN" \
  test_messages_edition2023.proto \
  google/protobuf/test_messages_proto2.proto \
  google/protobuf/test_messages_proto3.proto

if [ "${1:-}" = "--check" ]; then
  if cmp -s "$GEN" "$OUT"; then echo "OK: descriptor set is up to date."; rm -f "$GEN";
  else echo "::error::test_messages.fds.binpb is stale — run tools/gen_conformance_descriptors.sh"; rm -f "$GEN"; exit 1; fi
else
  echo "wrote $OUT"
fi
