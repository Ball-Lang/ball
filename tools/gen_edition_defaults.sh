#!/usr/bin/env bash
# gen_edition_defaults.sh — regenerate (or CI-check) the protobuf Editions
# FeatureSetDefaults golden files.
#
# Usage:
#   ./tools/gen_edition_defaults.sh            # regenerate in-place
#   ./tools/gen_edition_defaults.sh --check    # CI drift check (exit 1 on diff)
#
# Requires: protoc 28+ on PATH with its bundled include directory.
# The flag --edition_defaults_out is not printed by --help but it exists in
# protoc >=27; confirmed empirically with protoc 28.2.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (all relative to repo root, resolved from this script's location)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BINPB="$REPO_ROOT/tests/editions/featureset_defaults.binpb"
TXTPB="$REPO_ROOT/tests/editions/golden/featureset_defaults.txtpb"
VERSION_FILE="$REPO_ROOT/tests/editions/golden/PROTOC_VERSION.txt"

MIN_EDITION="PROTO2"
MAX_EDITION="2023"

# ---------------------------------------------------------------------------
# Locate protoc and its include directory
# ---------------------------------------------------------------------------
if ! command -v protoc &>/dev/null; then
  echo "ERROR: protoc not found on PATH" >&2
  exit 1
fi

PROTOC_BIN="$(command -v protoc)"
PROTOC_VERSION="$(protoc --version 2>&1)"  # e.g. "libprotoc 28.2"

# Resolve the include dir containing google/protobuf/descriptor.proto.
# Strategy:
#  1. Walk up from the real binary (handles symlinks / unix installs).
#  2. Walk up from the shim (handles Scoop on Windows where the shim is a
#     PE launcher, not a symlink — the real binary is under apps/<pkg>/current/).
#  3. Scan common Scoop paths.
#  4. Fall back to well-known system paths (/usr/include, /usr/local/include).
find_descriptor_proto() {
  local candidate
  # Try realpath / readlink first (unix installs, non-PE shims)
  local real_bin
  real_bin="$(realpath "$PROTOC_BIN" 2>/dev/null || readlink -f "$PROTOC_BIN" 2>/dev/null || true)"
  for bin in "$PROTOC_BIN" "$real_bin"; do
    [[ -z "$bin" ]] && continue
    local prefix
    prefix="$(cd "$(dirname "$bin")/.." 2>/dev/null && pwd)"
    candidate="$prefix/include/google/protobuf/descriptor.proto"
    [[ -f "$candidate" ]] && { echo "$prefix/include"; return 0; }
  done

  # Scoop on Windows: the shim is a PE; scan all versioned app dirs
  local scoop_root
  scoop_root="${SCOOP:-$HOME/scoop}"
  for candidate in \
      "$scoop_root/apps/protobuf/current/include/google/protobuf/descriptor.proto" \
      "$scoop_root/apps/protobuf/28.2/include/google/protobuf/descriptor.proto"; do
    [[ -f "$candidate" ]] && { echo "$(dirname "$(dirname "$(dirname "$candidate")")")"; return 0; }
  done

  # Generic well-known locations
  for dir in /usr/include /usr/local/include /opt/homebrew/include; do
    candidate="$dir/google/protobuf/descriptor.proto"
    [[ -f "$candidate" ]] && { echo "$dir"; return 0; }
  done

  return 1
}

PROTOC_INCLUDE="$(find_descriptor_proto)" || {
  echo "ERROR: descriptor.proto not found." >&2
  echo "       Make sure protoc's include directory is alongside its bin." >&2
  exit 1
}
DESCRIPTOR_PROTO="$PROTOC_INCLUDE/google/protobuf/descriptor.proto"

echo "protoc: $PROTOC_BIN"
echo "version: $PROTOC_VERSION"
echo "include: $PROTOC_INCLUDE"
echo "descriptor.proto: $DESCRIPTOR_PROTO"
echo "min edition: $MIN_EDITION  max edition: $MAX_EDITION"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CHECK_MODE=0
for arg in "$@"; do
  case "$arg" in
    --check|-check) CHECK_MODE=1 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Generate binary FeatureSetDefaults
# ---------------------------------------------------------------------------
run_protoc() {
  local out_binpb="$1"
  protoc \
    --proto_path="$PROTOC_INCLUDE" \
    --edition_defaults_out="$out_binpb" \
    --edition_defaults_minimum="$MIN_EDITION" \
    --edition_defaults_maximum="$MAX_EDITION" \
    "$DESCRIPTOR_PROTO"
}

# ---------------------------------------------------------------------------
# Decode binary -> text proto
# ---------------------------------------------------------------------------
run_decode() {
  local in_binpb="$1"
  protoc \
    --proto_path="$PROTOC_INCLUDE" \
    --decode=google.protobuf.FeatureSetDefaults \
    "$DESCRIPTOR_PROTO" \
    < "$in_binpb"
}

# ---------------------------------------------------------------------------
# CHECK mode: regenerate to a temp file and diff
# ---------------------------------------------------------------------------
if [[ "$CHECK_MODE" -eq 1 ]]; then
  echo ""
  echo "=== CHECK MODE ==="
  TMPDIR_LOCAL="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

  TMP_BINPB="$TMPDIR_LOCAL/featureset_defaults.binpb"
  run_protoc "$TMP_BINPB"

  if cmp -s "$TMP_BINPB" "$BINPB"; then
    echo "OK: regenerated binpb is byte-identical to committed golden."
    exit 0
  else
    echo "DRIFT DETECTED: regenerated binpb differs from committed golden." >&2
    echo "  committed : $BINPB" >&2
    echo "  generated : $TMP_BINPB" >&2
    echo "" >&2
    echo "Run  ./tools/gen_edition_defaults.sh  to refresh the golden files." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# GENERATE mode: write binary + text + version file in-place
# ---------------------------------------------------------------------------
echo ""
echo "=== GENERATE MODE ==="

run_protoc "$BINPB"
echo "Written: $BINPB  ($(wc -c < "$BINPB") bytes)"

mkdir -p "$(dirname "$TXTPB")"
run_decode "$BINPB" > "$TXTPB"
echo "Written: $TXTPB"

# Write version file
{
  echo "protoc $(echo "$PROTOC_VERSION" | sed 's/libprotoc //')"" (max edition $MAX_EDITION)"
  echo "$PROTOC_VERSION"
} > "$VERSION_FILE"
echo "Written: $VERSION_FILE"

echo ""
echo "Done. Verify with: ./tools/gen_edition_defaults.sh --check"
