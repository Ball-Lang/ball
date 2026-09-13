#!/usr/bin/env bash
# Fail loud when a C++ CI leg compiled cacheable translation units but the
# compiler cache recorded ZERO requests — i.e. a launcher that is configured
# but never applied (issue #594).
#
# WHY THIS EXISTS: ci.yml's `cpp` job sets up ccache/sccache and passes
# -DCMAKE_{C,CXX}_COMPILER_LAUNCHER on all three OS legs, and on Windows the
# Visual Studio (MSBuild) generator silently IGNORES that variable. The cache
# was therefore never applied there: main run 33673078770's Windows leg
# finished with sccache reporting `Compile requests 0` while the job compiled
# ~600 TUs, and every `Run tests` step since has been a permanently cold
# 15-19 minutes. Nothing was red, because nothing asserted that the cache is
# used: a step-time budget cannot tell "cold today" from "no cache, ever"
# (#521/#522 sized the Windows budget against a cold run, so an always-cold leg
# sits under it forever).
#
# The assertion is deliberately one-sided and cheap:
#
#     compiled_tus > 0 AND cache requests == 0   ->   FAIL
#
# It never asserts a hit RATE. A cold cache (a new key, an evicted entry, a
# change to the Ball->C++ emitter that invalidates every generated TU) is a
# normal, blameless event and must stay green; "the launcher is not wired at
# all" is a defect and must not.
#
# `compiled_tus` is MEASURED, not assumed: object files under the parent build
# directory (the runner starts from a fresh checkout, so every one of them was
# produced by THIS job) plus the fixture count test_e2e wrote to its coverage
# file (the nested scratch project's TUs, which live in a temp dir).
#
# Usage (CI):
#   bash cpp/test/check_compiler_cache_applied.sh --tool sccache \
#        --build-dir cpp/build --coverage-file cpp/build/test/e2e_coverage.txt
#   bash cpp/test/check_compiler_cache_applied.sh --self-test
#
# Options:
#   --tool <ccache|sccache>  which cache to interrogate (required)
#   --build-dir DIR          parent build tree, for the compiled-TU count
#   --coverage-file FILE     test_e2e's "Fixtures: N expected, N executed" file
#   --compiled N             override the compiled-TU count (tests)
#   --stats-file FILE        parse this instead of invoking the tool (tests)
#   --self-test              run the built-in parser cases and exit

set -uo pipefail

# ── parsers ────────────────────────────────────────────────────────────────
#
# Machine-readable input on both sides, never the pretty summary:
#   sccache --show-stats      "Compile requests <int>" (the first such line;
#                             "Compile requests executed" is a DIFFERENT line
#                             and must not match — hence the numeric $3 test).
#   ccache --print-stats      "<counter-id>\t<int>" per line. Cacheable calls =
#                             direct_cache_hit + preprocessed_cache_hit +
#                             cache_miss, exactly how ccache's own human
#                             summary derives its hits/misses.
#
# Each prints one bare integer on stdout, or exits non-zero when the input is
# not recognisable as that tool's statistics at all. "Unrecognisable" is a hard
# failure upstream — a gate that cannot read its own instrument is not a gate.

parse_sccache_requests() {
  awk '
    /^Compile requests[ \t]/ { if ($3 ~ /^[0-9]+$/) { print $3; found = 1; exit } }
    END { if (!found) exit 1 }
  ' "$1"
}

parse_sccache_hits() {
  awk '
    /^Cache hits[ \t]/ { if ($3 ~ /^[0-9]+$/) { print $3; exit } }
  ' "$1"
}

# ccache: `any` proves the file really is tab-separated counter output, so an
# empty/garbage file is told apart from a genuine all-zero cache.
parse_ccache_requests() {
  awk -F'\t' '
    NF >= 2 && $2 ~ /^[0-9]+$/ { any = 1 }
    $1 == "direct_cache_hit"       { d = $2 }
    $1 == "preprocessed_cache_hit" { p = $2 }
    $1 == "cache_miss"             { m = $2 }
    END { if (!any) exit 1; print d + p + m }
  ' "$1"
}

parse_ccache_hits() {
  awk -F'\t' '
    NF >= 2 && $2 ~ /^[0-9]+$/ { any = 1 }
    $1 == "direct_cache_hit"       { d = $2 }
    $1 == "preprocessed_cache_hit" { p = $2 }
    END { if (any) print d + p }
  ' "$1"
}

# is_uint <value> — a bare non-negative integer, nothing else. Every number this
# gate compares goes through here first: `[ "$x" -gt 0 ]` on a non-numeric $x
# exits 2, and a failing `[` INSIDE an `if` silently skips the branch and falls
# through to exit 0 — a gate that looks wired and checks nothing.
is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# count_objects <dir> — object files produced by this job's parent build.
count_objects() {
  local dir="$1" n
  [ -d "$dir" ] || { echo 0; return 0; }
  n="$(find "$dir" -type f \( -name '*.o' -o -name '*.obj' \) 2>/dev/null | wc -l | tr -d '[:space:]')"
  is_uint "$n" || n=0
  echo "$n"
}

# count_fixtures <coverage-file> — the nested scratch project's TUs, from
# test_e2e's own "Fixtures: N expected, N executed" line. 0 when the file is
# absent: ci.yml's "C++ e2e fixture coverage" step is what asserts it exists.
count_fixtures() {
  local f="$1" n
  [ -s "$f" ] || { echo 0; return 0; }
  n="$(sed -n 's/.*= \([0-9][0-9]*\) expected, \([0-9][0-9]*\) executed.*/\2/p' "$f" | head -1)"
  is_uint "$n" || n=0
  echo "$n"
}

# ── main check ─────────────────────────────────────────────────────────────
run_check() {
  local tool="" build_dir="" coverage_file="" compiled="" stats_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tool) tool="${2:-}"; shift 2 ;;
      --build-dir) build_dir="${2:-}"; shift 2 ;;
      --coverage-file) coverage_file="${2:-}"; shift 2 ;;
      --compiled) compiled="${2:-}"; shift 2 ;;
      --stats-file) stats_file="${2:-}"; shift 2 ;;
      *) echo "::error::unknown argument '$1'"; return 1 ;;
    esac
  done

  case "$tool" in
    ccache | sccache) ;;
    *) echo "::error::--tool must be 'ccache' or 'sccache' (got '${tool}')"; return 1 ;;
  esac

  # ── how many cacheable TUs did this job compile? ──
  if [ -n "$compiled" ]; then
    if ! is_uint "$compiled"; then
      echo "::error::--compiled must be a non-negative integer (got '$compiled')"
      return 1
    fi
  else
    if [ -z "$build_dir" ]; then
      echo "::error::need --build-dir (or --compiled): without a compiled-TU count this check cannot distinguish 'cache unused' from 'nothing to compile'."
      return 1
    fi
    local objs fixtures
    objs="$(count_objects "$build_dir")"
    fixtures="$(count_fixtures "$coverage_file")"
    compiled=$((objs + fixtures))
    echo "compiled TUs: $objs object file(s) under $build_dir + $fixtures scratch fixture(s)"
  fi

  # ── what did the cache record? ──
  local owned_stats=""
  if [ -z "$stats_file" ]; then
    owned_stats="$(mktemp)"
    stats_file="$owned_stats"
    # Human-readable form into the log (this is the number a reader wants to
    # see), machine-readable form into the file the parser reads.
    if [ "$tool" = "sccache" ]; then
      if ! sccache --show-stats >"$stats_file" 2>&1; then
        echo "::error::'sccache --show-stats' failed; its output was:"
        cat "$stats_file"
        rm -f "$owned_stats"
        return 1
      fi
      cat "$stats_file"
    else
      ccache -s || true
      if ! ccache --print-stats >"$stats_file" 2>&1; then
        echo "::error::'ccache --print-stats' failed (needs ccache >= 4.4); its output was:"
        cat "$stats_file"
        rm -f "$owned_stats"
        return 1
      fi
    fi
  fi

  local requests hits
  if [ "$tool" = "sccache" ]; then
    requests="$(parse_sccache_requests "$stats_file")" || requests=""
    hits="$(parse_sccache_hits "$stats_file")" || hits=""
  else
    requests="$(parse_ccache_requests "$stats_file")" || requests=""
    hits="$(parse_ccache_hits "$stats_file")" || hits=""
  fi
  [ -n "$owned_stats" ] && rm -f "$owned_stats"

  if ! is_uint "$requests"; then
    echo "::error::could not read a compile-request count out of $tool's statistics — the gate cannot prove anything, so it fails."
    return 1
  fi
  is_uint "$hits" || hits="n/a"

  echo "compiler cache: tool=$tool requests=$requests hits=$hits compiled_tus=$compiled"

  if [ "$compiled" -gt 0 ] && [ "$requests" -eq 0 ]; then
    echo "::error::$tool recorded 0 compile requests while this job compiled $compiled cacheable TU(s) — the compiler launcher is configured but never applied, so every compile on this leg is uncached. See issue #594."
    return 1
  fi

  if [ "$compiled" -eq 0 ]; then
    echo "No cacheable TUs were compiled in this job; nothing for the cache to record."
  else
    echo "Compiler cache OK: the launcher is applied ($requests request(s) for $compiled compiled TU(s))."
  fi
  return 0
}

# ── self-test ──────────────────────────────────────────────────────────────
# Drives the parsers and the decision against synthetic statistics — no
# compiler, no ccache/sccache binary, sub-second. Wired into ci.yml's always-on
# `proto` job, so a gate that stopped gating cannot reach main.
self_test() {
  local pass=0 fail=0 tmp
  tmp="$(mktemp -d)"

  # run_case <name> <want-exit> [args...]
  run_case() {
    local name="$1" want="$2"; shift 2
    local out rc
    out="$(run_check "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then
      pass=$((pass + 1))
      echo "ok   $name (exit $rc)"
    else
      fail=$((fail + 1))
      echo "FAIL $name: expected exit $want, got $rc"
      echo "$out" | sed 's/^/     | /'
    fi
  }

  # Verbatim shapes of the two tools' machine-readable output.
  sccache_stats() { # <requests> <hits>
    printf 'Compile requests %39s\n' "$1"
    printf 'Compile requests executed %30s\n' "$1"
    printf 'Cache hits %45s\n' "$2"
    printf 'Cache misses %43s\n' "$(($1 - $2))"
  }
  ccache_stats() { # <direct hits> <preprocessed hits> <misses>
    printf 'cache_miss\t%s\n' "$3"
    printf 'direct_cache_hit\t%s\n' "$1"
    printf 'files_in_cache\t17\n'
    printf 'preprocessed_cache_hit\t%s\n' "$2"
    printf 'stats_zeroed_timestamp\t1757700000\n'
  }

  # 1. THE BUG: sccache saw zero requests while the job compiled ~600 TUs.
  sccache_stats 0 0 >"$tmp/sccache_zero.txt"
  run_case "sccache zero requests after real compiles" 1 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_zero.txt"

  # 2. Healthy cold cache: every compile a miss, but the launcher IS applied.
  sccache_stats 600 0 >"$tmp/sccache_cold.txt"
  run_case "sccache cold cache (all misses) stays green" 0 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_cold.txt"

  # 3. Healthy warm cache.
  sccache_stats 600 580 >"$tmp/sccache_warm.txt"
  run_case "sccache warm cache stays green" 0 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_warm.txt"

  # 4. Same bug on the ccache side (a launcher dropped from the Linux leg).
  ccache_stats 0 0 0 >"$tmp/ccache_zero.txt"
  run_case "ccache zero requests after real compiles" 1 \
    --tool ccache --compiled 292 --stats-file "$tmp/ccache_zero.txt"

  # 5. The real measured cold Linux run (22 hits of 292 cacheable calls).
  ccache_stats 22 0 270 >"$tmp/ccache_cold.txt"
  run_case "ccache cold cache stays green" 0 \
    --tool ccache --compiled 292 --stats-file "$tmp/ccache_cold.txt"

  # 6. Counter ids absent entirely (a stats format that stopped reporting
  #    them) — still tab-separated output, so it reads as zero requests.
  printf 'files_in_cache\t17\ncache_size_kibibyte\t4096\n' >"$tmp/ccache_noids.txt"
  run_case "ccache output without hit/miss counters fails loud" 1 \
    --tool ccache --compiled 292 --stats-file "$tmp/ccache_noids.txt"

  # 7-8. An unreadable instrument must FAIL, never pass by default.
  : >"$tmp/empty.txt"
  run_case "empty sccache stats fail loud" 1 \
    --tool sccache --compiled 600 --stats-file "$tmp/empty.txt"
  printf 'sccache: error: failed to connect to server\n' >"$tmp/garbage.txt"
  run_case "garbage ccache stats fail loud" 1 \
    --tool ccache --compiled 292 --stats-file "$tmp/garbage.txt"

  # 9. Nothing compiled -> nothing to prove. Zero requests is correct here, and
  #    must not red a job (e.g. a hypothetical fully-prebuilt leg).
  run_case "no compiles, zero requests stays green" 0 \
    --tool sccache --compiled 0 --stats-file "$tmp/sccache_zero.txt"

  # 10. Compiled count DERIVED from the build tree + the e2e coverage file:
  #     5 object files + 269 scratch fixtures, cache idle -> red.
  mkdir -p "$tmp/build/a" "$tmp/build/b/test"
  : >"$tmp/build/a/one.o"; : >"$tmp/build/a/two.o"
  : >"$tmp/build/b/three.obj"; : >"$tmp/build/b/four.obj"; : >"$tmp/build/b/five.obj"
  : >"$tmp/build/b/not_an_object.txt"
  printf 'Fixtures: = 269 expected, 269 executed\n' >"$tmp/build/b/test/e2e_coverage.txt"
  local out rc
  out="$(run_check --tool sccache --build-dir "$tmp/build" \
    --coverage-file "$tmp/build/b/test/e2e_coverage.txt" \
    --stats-file "$tmp/sccache_zero.txt" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'compiled_tus=274'; then
    pass=$((pass + 1)); echo "ok   derived compiled count (5 objects + 269 fixtures)"
  else
    fail=$((fail + 1))
    echo "FAIL derived compiled count: expected exit 1 and compiled_tus=274, got exit $rc"
    echo "$out" | sed 's/^/     | /'
  fi

  # 11. A derived count with an EMPTY build tree and no coverage file is 0 —
  #     which is exactly the shape that would silently disable this gate, so
  #     it must be visible rather than asserted away. It stays green (nothing
  #     compiled), and ci.yml's coverage step is what proves fixtures ran.
  mkdir -p "$tmp/empty-build"
  run_case "empty build tree derives zero and stays green" 0 \
    --tool sccache --build-dir "$tmp/empty-build" --stats-file "$tmp/sccache_zero.txt"

  # 12-14. Misconfiguration of the gate itself must be loud.
  run_case "unknown tool rejected" 1 \
    --tool msvc --compiled 5 --stats-file "$tmp/sccache_warm.txt"
  run_case "non-integer --compiled rejected" 1 \
    --tool sccache --compiled "many" --stats-file "$tmp/sccache_warm.txt"
  run_case "missing compiled source rejected" 1 \
    --tool sccache --stats-file "$tmp/sccache_warm.txt"

  rm -rf "$tmp"

  local total=$((pass + fail))
  # Positive floor: an exit code plus a failure count cannot tell "everything
  # passed" from "nothing ran".
  if [ "$total" -lt 10 ]; then
    echo "::error::compiler-cache gate self-test ran only $total case(s) — expected at least 10."
    return 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

run_check "$@"
exit $?
