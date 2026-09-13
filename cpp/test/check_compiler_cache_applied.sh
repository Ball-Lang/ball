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
# The first assertion is deliberately one-sided and cheap:
#
#     compiled_tus > 0 AND cache requests == 0   ->   FAIL
#
# It never asserts a hit RATE. A cold cache (a new key, an evicted entry, a
# change to the Ball->C++ emitter that invalidates every generated TU) is a
# normal, blameless event and must stay green; "the launcher is not wired at
# all" is a defect and must not.
#
# The second assertion (issue #599) covers that check's blind spot — the cache
# IS consulted and DECLINES every compile:
#
#     compiled_tus > 0 AND non_cacheable > <per-OS ceiling>   ->   FAIL
#
# Requests, hits and misses all read healthy in that state while nothing is
# ever cached, so the check above cannot see it. It is not hypothetical: #594's
# own first Ninja run on Windows reported `Non-cacheable compilations 296` —
# every generated fixture — because CMake's MSVC module defaults an unset build
# type to Debug, whose `/Zi` writes a PDB shared by a target's TUs, and sccache
# refuses to cache that. ci.yml now configures the scratch project with an
# explicitly EMPTY CMAKE_BUILD_TYPE; nothing asserted that it stays that way.
#
# ── the per-OS ceiling, MEASURED ───────────────────────────────────────────
#
# Read out of this gate's own step in three consecutive green ci.yml runs on
# main (`gh api repos/Ball-Lang/ball/actions/jobs/<id>/logs`), at the point the
# script itself reads the statistics:
#
#   run 34749011196 (92148281) / 34746079068 (97927362) / 34743380631 (1207d677)
#     windows-latest  sccache  Non-cacheable compilations  0 / 0 / 0
#     ubuntu-latest   ccache   Cacheable calls 322/322     0 / 0 / 0
#     macos-latest    ccache   Cacheable calls 321/321     0 / 0 / 0
#
# All three toolchains agree on the same number across all three runs, so the
# ceiling sits AT the measurement — 0 — and the gate fails only on a RISE, the
# same ratchet discipline cpp/build-cov-floor.sh's coverage floors use. There
# is no variance buffer to add: a single declined compile on a leg that has
# never had one is the #594 shape returning, at whatever scale.
#
# NOTE on the ubuntu leg specifically: the job's POST-JOB ccache summary shows
# `322 / 326 (98.77%)`, i.e. 4 uncacheable calls. Those accrue AFTER this gate
# runs, from the `full_e2e.sh` smoke step that prefixes ccache to a
# compile-and-link `g++` invocation (a link is uncacheable by construction).
# They are outside what this script reads and must not be folded into the
# ceiling — read the number from THIS step, not from the post-job block.
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
#   --max-noncacheable N     override the per-OS non-cacheable ceiling (tests)
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

# ── non-cacheable parsers (issue #599) ─────────────────────────────────────
#
# sccache reports the number directly. `Non-cacheable compilations` and
# `Non-cacheable calls` are DIFFERENT counters printed one after the other, so
# this anchors on the two-word prefix and takes the numeric $3 — the same
# discipline parse_sccache_requests uses against "Compile requests executed".
parse_sccache_noncacheable() {
  awk '
    /^Non-cacheable compilations[ \t]/ { if ($3 ~ /^[0-9]+$/) { print $3; found = 1; exit } }
    END { if (!found) exit 1 }
  ' "$1"
}

# ccache has no cacheable/uncacheable counter PAIR in `--print-stats` (its
# "uncacheable" total is derived from a long, version-specific set of reason
# counters), so the number comes from the one place ccache states it outright:
# `ccache -s`'s "Cacheable calls: <cacheable> / <total>" line, which the CI step
# already prints today and whose two numbers are plain integers. The gate
# collects both forms into one stats file; the human lines carry no tabs, so
# the counter parsers above ignore them and this one ignores the counters.
parse_ccache_noncacheable() {
  awk '
    /^[ \t]*Cacheable calls:[ \t]*[0-9]+[ \t]*\/[ \t]*[0-9]+/ {
      n = split($0, a, /[^0-9]+/)
      c = ""; t = ""
      for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        if (c == "") c = a[i]; else { t = a[i]; break }
      }
      if (c != "" && t != "" && t + 0 >= c + 0) { print t - c; found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$1"
}

# noncacheable_ceiling <tool> — the measured per-OS ceiling (see the header).
# Keyed by tool because this repo's CI maps them one-to-one: sccache is the
# windows-latest leg, ccache is ubuntu-latest + macos-latest. A `case` rather
# than an associative array so the script keeps running under bash 3.2 (the
# macOS system bash).
noncacheable_ceiling() {
  case "$1" in
    sccache) echo 0 ;; # windows-latest
    ccache) echo 0 ;;  # ubuntu-latest, macos-latest
    *) echo "" ;;
  esac
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
  local tool="" build_dir="" coverage_file="" compiled="" stats_file="" max_nc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tool) tool="${2:-}"; shift 2 ;;
      --build-dir) build_dir="${2:-}"; shift 2 ;;
      --coverage-file) coverage_file="${2:-}"; shift 2 ;;
      --compiled) compiled="${2:-}"; shift 2 ;;
      --stats-file) stats_file="${2:-}"; shift 2 ;;
      --max-noncacheable) max_nc="${2:-}"; shift 2 ;;
      *) echo "::error::unknown argument '$1'"; return 1 ;;
    esac
  done

  case "$tool" in
    ccache | sccache) ;;
    *) echo "::error::--tool must be 'ccache' or 'sccache' (got '${tool}')"; return 1 ;;
  esac

  # The non-cacheable ceiling: explicit override, else this tool's measured row.
  if [ -n "$max_nc" ]; then
    if ! is_uint "$max_nc"; then
      echo "::error::--max-noncacheable must be a non-negative integer (got '$max_nc')"
      return 1
    fi
  else
    max_nc="$(noncacheable_ceiling "$tool")"
    if ! is_uint "$max_nc"; then
      echo "::error::no measured non-cacheable ceiling for tool '$tool' — add its row to noncacheable_ceiling() rather than letting the check pass unmeasured."
      return 1
    fi
  fi

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
      # BOTH forms go into the stats file. `--print-stats` carries the machine-
      # readable counters the request/hit parsers read; `ccache -s`'s human
      # summary is the only place ccache states the cacheable/uncacheable split
      # (#599). Its lines carry no tabs, so neither parser sees the other's
      # input. The human half is echoed to the log as it always was.
      if ccache -s >"$stats_file" 2>&1; then
        cat "$stats_file"
      else
        echo "::warning::'ccache -s' failed; its output was:"
        cat "$stats_file"
        # Drop it rather than letting an error message reach the parsers.
        : >"$stats_file"
      fi
      if ! ccache --print-stats >>"$stats_file" 2>&1; then
        echo "::error::'ccache --print-stats' failed (needs ccache >= 4.4); its output was:"
        cat "$stats_file"
        rm -f "$owned_stats"
        return 1
      fi
    fi
  fi

  local requests hits noncacheable
  if [ "$tool" = "sccache" ]; then
    requests="$(parse_sccache_requests "$stats_file")" || requests=""
    hits="$(parse_sccache_hits "$stats_file")" || hits=""
    noncacheable="$(parse_sccache_noncacheable "$stats_file")" || noncacheable=""
  else
    requests="$(parse_ccache_requests "$stats_file")" || requests=""
    hits="$(parse_ccache_hits "$stats_file")" || hits=""
    noncacheable="$(parse_ccache_noncacheable "$stats_file")" || noncacheable=""
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
    return 0
  fi

  # ── did the cache DECLINE those compiles? (issue #599) ──
  # Only meaningful when something was compiled, which is why it sits after the
  # zero-compiles branch above. It also runs BEFORE the success line: a gate
  # that prints "OK" and then fails reads as a flake to whoever scans the log.
  if ! is_uint "$noncacheable"; then
    echo "::error::could not read a non-cacheable compilation count out of $tool's statistics — the gate cannot tell an applied cache from one that declined every compile, so it fails. (sccache: a 'Non-cacheable compilations <int>' line; ccache: 'ccache -s''s 'Cacheable calls: <n> / <total>' line.)"
    return 1
  fi

  echo "non-cacheable compilations: $noncacheable (ceiling: $max_nc)"
  if [ "$noncacheable" -gt "$max_nc" ]; then
    echo "::error::$tool declined to cache $noncacheable compilation(s), above the measured ceiling of $max_nc — the cache is consulted but caches nothing, so this leg is uncached however healthy the request count looks. The known cause is a build-type change putting a shared PDB (MSVC /Zi) back into the generated fixtures' compile lines; see issues #594 / #599 and cpp/test/AGENTS.md."
    return 1
  fi

  echo "Compiler cache OK: the launcher is applied ($requests request(s) for $compiled compiled TU(s))."
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
  #
  # `Non-cacheable compilations` and `Non-cacheable calls` are DIFFERENT sccache
  # counters and the gate reads the first one, so the fixtures carry both and a
  # case below drives them apart to pin the anchor.
  sccache_stats() { # <requests> <hits> [non-cacheable compilations] [non-cacheable calls]
    local nc="${3:-0}"
    printf 'Compile requests %39s\n' "$1"
    printf 'Compile requests executed %30s\n' "$1"
    printf 'Cache hits %45s\n' "$2"
    printf 'Cache misses %43s\n' "$(($1 - $2))"
    printf 'Non-cacheable compilations %29s\n' "$nc"
    printf 'Non-cacheable calls %36s\n' "${4:-$nc}"
  }
  # ccache's stats file carries BOTH forms, exactly as the gate collects them:
  # `ccache -s`'s human summary first (the only place ccache reports the
  # cacheable/uncacheable split — `--print-stats` has no such counter pair),
  # then the tab-separated `--print-stats` counters. The human lines are not
  # tab-separated, so the counter parsers ignore them and vice versa.
  ccache_stats() { # <direct hits> <preprocessed hits> <misses> [uncacheable]
    local u="${4:-0}" cacheable total
    cacheable=$(($1 + $2 + $3))
    total=$((cacheable + u))
    awk -v c="$cacheable" -v t="$total" \
      'BEGIN { printf "Cacheable calls: %5d / %d (%.2f%%)\n", c, t, (t ? 100 * c / t : 0) }'
    if [ "$u" -gt 0 ]; then
      awk -v u="$u" -v t="$total" \
        'BEGIN { printf "Uncacheable calls: %3d / %d (%.2f%%)\n", u, t, (t ? 100 * u / t : 0) }'
    fi
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

  # ── 15-24. The NON-CACHEABLE ceiling (issue #599) ────────────────────────
  #
  # The cases above all describe one failure mode: the cache is never consulted
  # (`requests == 0`). Its mirror image — the cache IS consulted and declines
  # every single compile — is invisible to them: requests, hits and misses all
  # look healthy while nothing is ever cached. That is not hypothetical, it is
  # #594's own first Ninja run on Windows (`Non-cacheable compilations 296`,
  # every generated fixture, because CMake's MSVC module defaulted the scratch
  # project to Debug and sccache refuses a `/Zi` shared PDB). The fix landed;
  # nothing asserts it stays fixed.

  # 15. THE REGRESSION SHAPE: every generated TU declined, at the measured
  #     ceiling of 0.
  sccache_stats 600 304 296 >"$tmp/sccache_declined.txt"
  run_case "sccache declining every compile fails" 1 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_declined.txt"

  # 16. The healthy measured shape: nothing declined.
  sccache_stats 600 600 0 >"$tmp/sccache_clean.txt"
  run_case "sccache with zero non-cacheable stays green" 0 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_clean.txt"

  # 17. `Non-cacheable calls` is a DIFFERENT counter and must not be read in
  #     place of `Non-cacheable compilations` (the same anchoring bug the
  #     "Compile requests executed" $3 test above guards against).
  sccache_stats 600 600 0 296 >"$tmp/sccache_other_counter.txt"
  run_case "sccache reads compilations, not calls" 0 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_other_counter.txt"

  # 18. Same ceiling on the ccache side: 322 of 326 calls cacheable -> 4
  #     declined, above the measured ceiling of 0.
  ccache_stats 322 0 0 4 >"$tmp/ccache_declined.txt"
  run_case "ccache with uncacheable calls fails" 1 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_declined.txt"

  # 19. The healthy measured shape on ccache: 322 / 322.
  ccache_stats 322 0 0 0 >"$tmp/ccache_clean.txt"
  run_case "ccache with zero uncacheable stays green" 0 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_clean.txt"

  # 20-21. The comparison is a real `<=`, not a hardcoded "is it zero": at or
  #     below an explicit ceiling passes, above it fails.
  run_case "non-cacheable at/below an explicit ceiling stays green" 0 \
    --tool ccache --compiled 322 --max-noncacheable 5 \
    --stats-file "$tmp/ccache_declined.txt"
  ccache_stats 320 0 0 6 >"$tmp/ccache_over.txt"
  run_case "non-cacheable above an explicit ceiling fails" 1 \
    --tool ccache --compiled 320 --max-noncacheable 5 \
    --stats-file "$tmp/ccache_over.txt"

  # 22-23. An unreadable non-cacheable count must FAIL, never pass by default —
  #     the same rule the request count already lives under.
  {
    printf 'Compile requests %39s\n' 600
    printf 'Cache hits %45s\n' 600
    printf 'Non-cacheable compilations %29s\n' 'many'
  } >"$tmp/sccache_nan.txt"
  run_case "non-integer non-cacheable count fails loud" 1 \
    --tool sccache --compiled 600 --stats-file "$tmp/sccache_nan.txt"
  grep -v '^Cacheable calls:' "$tmp/ccache_clean.txt" >"$tmp/ccache_no_summary.txt"
  run_case "ccache stats without the cacheable/total summary fail loud" 1 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_no_summary.txt"

  # 24. Misconfiguration of the new knob itself must be loud, like --compiled.
  run_case "non-integer --max-noncacheable rejected" 1 \
    --tool sccache --compiled 600 --max-noncacheable "none" \
    --stats-file "$tmp/sccache_clean.txt"

  rm -rf "$tmp"

  local total=$((pass + fail))
  # Positive floor: an exit code plus a failure count cannot tell "everything
  # passed" from "nothing ran".
  if [ "$total" -lt 20 ]; then
    echo "::error::compiler-cache gate self-test ran only $total case(s) — expected at least 20."
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
