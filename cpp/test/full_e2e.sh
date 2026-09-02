#!/usr/bin/env bash
# Comprehensive C++ e2e: compile + build + run EVERY conformance program with
# an expected_output.txt, via direct g++ (fast, per-program timeout). Prints a
# category-tagged failure summary.
#
# Usage: full_e2e.sh [--compiler PATH] [--root PATH] [--fixtures "STEMS"]
#   --compiler  path to ball_cpp_compile binary (default: auto-detect)
#   --root      repo root (default: auto-detect from script location)
#   --fixtures  restrict the run to just these conformance fixture stems (bare
#               names, no dir, no .ball.json extension), space- or
#               comma-separated, e.g. --fixtures "400_switch_continue_label
#               401_foo". Mirrors ts/compiler/test/full_e2e.ts's --fixtures=
#               filter: used by ci.yml's per-PR gate to compile+run ONLY the
#               fixtures a PR added/changed (a few seconds) instead of the whole
#               ~350-fixture corpus — closing the escape class where the
#               main-only cpp-compiled matrix leg is the only thing that would
#               catch a PR-introduced regression (see #347). A requested stem
#               that doesn't exist under tests/conformance/ is a HARD ERROR
#               (fail loud, never a silent no-op). Omit to run the full corpus.
set -u

# Auto-detect repo root from script location (works in CI + local dev).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Auto-detect compiler: prefer build/ (CI), then build-wsl/ (local WSL dev).
COMPILER=""
for d in "$ROOT/cpp/build/compiler" "$ROOT/cpp/build-wsl/compiler"; do
  for bin in "$d/ball_cpp_compile" "$d/Release/ball_cpp_compile" "$d/Debug/ball_cpp_compile"; do
    [[ -x "$bin" ]] && COMPILER="$bin" && break 2
  done
done

# CLI overrides
FIXTURES_FILTER=""
FILTER_ACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiler) COMPILER="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --fixtures) FIXTURES_FILTER="$2"; FILTER_ACTIVE=1; shift 2 ;;
    --fixtures=*) FIXTURES_FILTER="${1#--fixtures=}"; FILTER_ACTIVE=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

CONF="$ROOT/tests/conformance"
[[ -n "$COMPILER" ]] || { echo "ERROR: ball_cpp_compile not found. Build first."; exit 1; }
[[ -x "$COMPILER" ]] || { echo "ERROR: $COMPILER is not executable."; exit 1; }

# Optional --fixtures filter: resolve the requested stems to a set, failing loud
# on any stem that has no tests/conformance/<stem>.ball.json (same hard-error
# semantics as ts/compiler/test/full_e2e.ts — never a silent no-op). Accepts
# space- and/or comma-separated stems.
declare -A WANT
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  missing=()
  for stem in ${FIXTURES_FILTER//,/ }; do
    [[ -z "$stem" ]] && continue
    if [[ -f "$CONF/$stem.ball.json" ]]; then
      WANT["$stem"]=1
    else
      missing+=("$stem")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "::error::--fixtures requested fixture(s) not found in $CONF: ${missing[*]}"
    exit 1
  fi
  if [[ ${#WANT[@]} -eq 0 ]]; then
    echo "::error::--fixtures was given but resolved to zero fixtures (empty argument?)"
    exit 1
  fi
  echo "C++ e2e FILTERED — ${#WANT[@]} requested fixture(s): ${!WANT[*]}"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skip=0; carved=0
COMPILE_ERR=(); GPP_ERR=(); MISMATCH=(); TIMEOUT=()

# Per-target carve-outs: fixtures the Ball->C++ COMPILER cannot yet handle.
# C++ is a roadmap target; each entry is a KNOWN, TRACKED gap. The reference
# Dart engine, the TS engine, AND the C++ self-host ENGINE all run these — only
# this compiled path skips them, and the skip is logged loudly below (never
# silent). Keep the list tiny + justified; delete an entry the moment the
# compiler supports it.
# (312_collection_for_capture was fixed by boxing the C-style collection_for's
# loop var, mirroring the statement-`for`'s existing shared_ptr cell +
# per-iteration shadow — issue #69. 400_switch_continue_label was fixed by
# lowering a labelled-case `switch` to a goto-based state machine — issue #352.)
#
# 416_user_method_name_arity_collision (#511): CppCompiler::compile_method_call
# dispatches on the method NAME alone and is arity-blind, so a user method named
# like one of its ~80 STL shortcuts is rerouted into that shortcut whatever the
# call's argument count. A missing operand becomes an EMPTY argument slot —
# `bag.clamp(7)` emits `…}(bag, 7, )` — and g++ rejects it with "expected
# primary-expression before ')' token". Ball->C++ compilation itself succeeds;
# only the g++ build fails. This is the C++ sibling of the Dart-encoder defect
# #494 fixed (see #488 for the receiver-type half). The fixture still runs on
# every ENGINE (Dart/TS/Rust/Go/Python/C#) and on the Rust/Go/Python/C#
# COMPILER legs — only this Ball->C++ compiled path skips it.
#
# 435_recursive_ctor_construction / 436_recursive_ctor_named /
# 437_recursive_ctor_tree (#513): a read through a NULLABLE, self-referential
# field (`Chain? next` -> `head.next.depth`) still takes the concrete-struct
# member-access path, but the field itself is emitted as a `BallDyn` because it
# is nullable, so g++ reports "'class BallDyn' has no member named 'depth'".
# Ball->C++ compilation succeeds; only the g++ build fails.
#
# 438_ctor_initializer_list_with_body (#514): a class whose ONLY constructor
# takes no arguments gets both that constructor and the synthesised default
# one, so g++ reports "'Flags::Flags()' cannot be overloaded with
# 'Flags::Flags()'". Again a g++ build failure, not a Ball->C++ one.
#
# All four were added by #512 for issue #499 (a constructor that builds another
# instance of its own class must not silently get `self` back). They pass on
# EVERY engine including the C++ self-hosted one, and on the Rust/Go/Python/C#
# compiler legs; only this Ball->C++ compiled path skips them.
CPP_COMPILE_CARVEOUTS=(
  "416_user_method_name_arity_collision"
  "435_recursive_ctor_construction"
  "436_recursive_ctor_named"
  "437_recursive_ctor_tree"
  "438_ctor_initializer_list_with_body"
)
_is_carved() { local n="$1" c; for c in "${CPP_COMPILE_CARVEOUTS[@]}"; do [[ "$c" == "$n" ]] && return 0; done; return 1; }

for prog in "$CONF"/*.ball.json; do
  name="$(basename "$prog" .ball.json)"
  # When a --fixtures filter is active, run only the requested stems.
  if [[ $FILTER_ACTIVE -eq 1 && -z "${WANT[$name]:-}" ]]; then continue; fi
  exp="$CONF/$name.expected_output.txt"
  [[ -f "$exp" ]] || { ((skip++)); continue; }
  if _is_carved "$name"; then ((carved++)); continue; fi

  if ! "$COMPILER" "$prog" > "$TMP/p.cpp" 2>"$TMP/cerr"; then
    COMPILE_ERR+=("$name"); ((fail++)); continue
  fi
  # -O0: faster builds, avoids false timeouts on large generator programs.
  if ! timeout 120 g++ -std=c++20 -O0 "$TMP/p.cpp" -o "$TMP/p.bin" 2>"$TMP/gerr"; then
    GPP_ERR+=("$name: $(grep -m1 'error:' "$TMP/gerr" | sed -E 's/.*error: //' | head -c 80)")
    ((fail++)); continue
  fi
  actual="$(timeout 15 "$TMP/p.bin" 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 124 ]]; then TIMEOUT+=("$name"); ((fail++)); continue; fi
  a="$(printf '%s' "$actual" | sed -e 's/[[:space:]]*$//')"
  e="$(printf '%s' "$(cat "$exp")" | sed -e 's/[[:space:]]*$//')"
  if [[ "$a" == "$e" ]]; then ((pass++)); else MISMATCH+=("$name"); ((fail++)); fi
done

total=$((pass+fail))
echo "=================================================="
echo "C++ e2e: $pass/$total passed ($fail failed, $skip skipped no-output, $carved compiler carve-outs)"
echo "=================================================="
echo ""
echo "C++ compiler carve-outs (${#CPP_COMPILE_CARVEOUTS[@]}, tracked gaps — run on Dart/TS/C++ engines): ${CPP_COMPILE_CARVEOUTS[*]:-none}"
echo ""
echo "Ball->C++ compile errors (${#COMPILE_ERR[@]}): ${COMPILE_ERR[*]:-none}"
echo ""
echo "g++ build errors (${#GPP_ERR[@]}):"
for x in "${GPP_ERR[@]:-}"; do [[ -n "$x" ]] && echo "  - $x"; done
echo ""
echo "Runtime timeouts (${#TIMEOUT[@]}): ${TIMEOUT[*]:-none}"
echo ""
echo "Output mismatches (${#MISMATCH[@]}): ${MISMATCH[*]:-none}"
echo ""
# Standard format line for CI conformance-matrix parsing.
echo "Results: $pass passed, $fail failed, $total total"

# Positive floor. "0 failed" and "0 ran" are indistinguishable to the caller,
# and ci.yml invokes this script directly (its own `passed < 1` guard lives in
# conformance-matrix.yml, not here). A `--fixtures` filter whose every entry is
# carved out or golden-less would otherwise exit 0 having compiled nothing —
# a required check that proves nothing. Widen the filter, or remove the
# carve-out, rather than accepting the fake green.
if [[ $pass -lt 1 && $fail -eq 0 ]]; then
  echo "::error::C++ compiled e2e ran NO fixture (passed=0, failed=0, carve-outs=$carved, no-output skips=$skip) — this leg proved nothing."
  exit 1
fi

# Exit with failure if any program failed.
[[ $fail -eq 0 ]]
