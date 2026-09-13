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
# That ordering is LOAD-BEARING and, since #660, gated:
# `cpp/test/test_cache_gate_step_order.sh` (ci.yml's always-on `proto` job)
# asserts from ci.yml that the `Compiler cache applied (#594)` step precedes
# every full_e2e.sh step in the cpp job, with a negative control on a copy whose
# gate step is relocated. Moving the step below the smoke reds the ubuntu/macOS
# legs at 4 against a ceiling of 0, with a cause that points at build types and
# shared PDBs while nothing has regressed.
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
#
# Since #660 that is true of the non-cacheable count as well: NOTHING here reads
# `ccache -s`'s human table any more. Its lines still share the stats file (they
# go to the CI log, which is where a reader wants the number), and they cannot
# collide with a counter line because the human table is space-aligned and a
# counter line is `<id><TAB><int>`.

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

# ccache: the number comes from `--print-stats`'s counters, NEVER from the
# human `ccache -s` summary (issue #660).
#
# `--print-stats` is ccache's documented machine-parsable form — "Print
# statistics counter IDs and corresponding values in machine-parsable
# (tab-separated or JSON) format", https://ccache.dev/manual/4.14.html — and it
# emits EVERY counter field that is not flagged FLAG_NEVER, zeros included, plus
# `max_cache_size_kibibyte`, `max_files_in_cache` and
# `stats_updated_timestamp`.
#
# There is no single "uncacheable" counter, but there does not need to be: the
# human summary is itself derived, by ccache, as
#
#     hits        = direct_cache_hit + preprocessed_cache_hit
#     cacheable   = hits + cache_miss
#     total_calls = hits + cache_miss + errors + uncacheable
#
# where `uncacheable` sums every counter flagged FLAG_UNCACHEABLE and `errors`
# every counter flagged FLAG_ERROR (`src/core/Statistics.cpp` in 4.9.1,
# `src/ccache/core/statistics.cpp` in 4.14 — the same expression in both). So
# `total - cacheable`, the shortfall this gate used to read off the human line,
# is exactly `uncacheable + errors`, and both families are printed by
# `--print-stats`. Summing them is the same number, taken from the format ccache
# documents for machines instead of from the one it renders for people.
#
# WHY NOT the human line — stated precisely, because the sloppy version of this
# claim is itself a bug (it was in this comment until it was checked against
# ccache's source):
#
#   * ccache does NOT group its counters. Both pinned versions render a table
#     cell from a `uint64_t` as `fmt::format("{}", number)` — plain digits, no
#     locale, no thousands separator (`Cell::Cell(uint64_t)` in
#     `src/util/TextTable.cpp` 4.9.1 / `src/ccache/util/texttable.cpp` 4.14).
#     There is no `1,234 / 1,250` to mis-read and no version that emits one.
#   * What the old parse actually was: `Cacheable calls:` matched by a regex
#     over the RENDERED row, then `split($0, a, /[^0-9]+/)` taking the first two
#     numeric runs, sanity-checked only by `t >= c`. That is a parse of a
#     PRESENTATION layer. `TextTable::compute_column_widths()` sizes each column
#     to the widest cell across ALL rows, so the row's rendering is a function
#     of unrelated rows, and ccache re-cuts the summary's rows and labels
#     between releases (4.7 rewrote it wholesale).
#   * Its failure mode is therefore: a layout ccache is free to change stops
#     matching, and the leg goes red with `could not read a non-cacheable
#     compilation count` — a red C++ leg for a reason that has nothing to do
#     with the compiler cache. Feed the old parse any line it does not expect
#     and that is what happens; the self-test's case 26 pins it.
#     Worse, should a future row ever put a number ahead of the numerator, the
#     first-two-runs rule would take the WRONG numbers while still matching.
#   * And `ccache -s` failing used to be a cosmetic `::warning::` that blanked
#     the stats file, so the run limped on to that same misleading
#     `could not read` error instead of saying the instrument had failed.
#
# `--print-stats` has none of this: it is `<id><TAB><value>`, one line per
# counter, no alignment and no rendering.
#
# VERSION-PINNED, against the ccache the runners actually install rather than
# against a manual alone: ubuntu-latest has 4.9.1 (`ccache version 4.9.1`,
# apt `ccache_4.9.1-1_amd64.deb`; C++ (ubuntu-latest) job 103702029894 of main
# run 34749011196) and macos-latest 4.14 (`ccache version 4.14`, job
# 103702029887 of the same run). Their counter tables differ by exactly ONE id,
# `unsupported_source_encoding` (4.14+), which is why it is listed as OPTIONAL
# below while every other counted id must be present.
#
# The three lists below are that classification, transcribed from
# `k_statistics_fields`. An id in NONE of them fails the gate loud: a counter
# ccache grew could be a new uncacheable reason, and silently leaving it out of
# the sum is precisely the "the cache declines everything and the gate says 0"
# state this check exists to catch. Adding one is a one-line edit here.
CCACHE_UNCACHEABLE_IDS='autoconf_test bad_compiler_arguments called_for_link
  called_for_preprocessing compile_failed compiler_produced_empty_output
  compiler_produced_no_output compiler_produced_stdout could_not_use_modules
  could_not_use_precompiled_header disabled multiple_source_files no_input_file
  output_to_stdout preprocessor_error recache unsupported_code_directive
  unsupported_compiler_option unsupported_environment_variable
  unsupported_source_language'
# FLAG_UNCACHEABLE ids that only SOME pinned version prints (4.14 added this
# one), so their absence is not a schema change.
CCACHE_UNCACHEABLE_IDS_OPTIONAL='unsupported_source_encoding'
CCACHE_ERROR_IDS='bad_input_file bad_output_file compiler_check_failed
  could_not_find_compiler error_hashing_extra_file internal_error
  missing_cache_file modified_input_file'
# Everything else `--print-stats` prints: hit/miss counters, cache sizes,
# storage tallies, timestamps. Known, and deliberately NOT summed.
CCACHE_NEUTRAL_IDS='cache_miss cache_size_kibibyte cleanups_performed
  direct_cache_hit direct_cache_miss files_in_cache local_storage_hit
  local_storage_miss local_storage_read_hit local_storage_read_miss
  local_storage_write max_cache_size_kibibyte max_files_in_cache
  preprocessed_cache_hit preprocessed_cache_miss remote_storage_error
  remote_storage_hit remote_storage_miss remote_storage_read_hit
  remote_storage_read_miss remote_storage_timeout remote_storage_write
  stats_updated_timestamp stats_zeroed_timestamp'

parse_ccache_noncacheable() {
  # The lists are wrapped across lines for readability above; flatten them
  # before they reach `awk -v`, whose handling of a literal newline in an
  # assignment is not something to depend on across gawk / mawk / BSD awk.
  local counted optional neutral
  counted="$(printf '%s %s' "$CCACHE_UNCACHEABLE_IDS" "$CCACHE_ERROR_IDS" | tr '\n' ' ')"
  optional="$(printf '%s' "$CCACHE_UNCACHEABLE_IDS_OPTIONAL" | tr '\n' ' ')"
  neutral="$(printf '%s' "$CCACHE_NEUTRAL_IDS" | tr '\n' ' ')"
  awk -v counted="$counted" -v optional="$optional" -v neutral="$neutral" '
    BEGIN {
      n = split(counted, a, / +/)
      for (i = 1; i <= n; i++) if (a[i] != "") { is_counted[a[i]] = 1; required[a[i]] = 1; known[a[i]] = 1 }
      n = split(optional, a, / +/)
      for (i = 1; i <= n; i++) if (a[i] != "") { is_counted[a[i]] = 1; known[a[i]] = 1 }
      n = split(neutral, a, / +/)
      for (i = 1; i <= n; i++) if (a[i] != "") known[a[i]] = 1
    }
    # A --print-stats counter line, and nothing else: `<id><TAB><value>`.
    # `ccache -s`s human table shares this file and is space-aligned, so it
    # cannot match.
    /^[a-z][a-z0-9_]*\t/ {
      split($0, f, "\t"); id = f[1]; v = f[2]
      seen[id] = 1
      if (!(id in known)) { unknown = unknown " " id; next }
      if (v !~ /^[0-9]+$/) { nonint = nonint " " id; next }
      any = 1
      if (id in is_counted) total += v
    }
    END {
      if (!any) {
        print "::error::no ccache --print-stats counter lines (<id><TAB><int>) in the statistics." > "/dev/stderr"
        exit 1
      }
      if (unknown != "") {
        print "::error::ccache reported counter id(s) this gate does not classify:" unknown " — one of them may be a new uncacheable reason, which would be silently left out of the sum, so this fails rather than guesses. Classify each id into CCACHE_UNCACHEABLE_IDS / CCACHE_ERROR_IDS / CCACHE_NEUTRAL_IDS in cpp/test/check_compiler_cache_applied.sh, per its flags in ccache k_statistics_fields." > "/dev/stderr"
        exit 1
      }
      if (nonint != "") {
        print "::error::ccache reported a non-integer value for counter id(s):" nonint > "/dev/stderr"
        exit 1
      }
      for (id in required) if (!(id in seen)) missing = missing " " id
      if (missing != "") {
        print "::error::ccache --print-stats did not report counter id(s) this gate sums:" missing " — the uncacheable total would silently lose those terms." > "/dev/stderr"
        exit 1
      }
      print total + 0
    }
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
      # `ccache -s`'s human summary goes into the log, because that is the
      # number a reader scanning the job wants to see. Since #660 it is NOT
      # parsed — every number the gate compares comes from `--print-stats`
      # below — but its failure is still a HARD failure: a gate that cannot
      # run its own instrument has not measured anything, and this used to be
      # a cosmetic `::warning::` that let the run limp on to a different,
      # misleading error.
      if ! ccache -s >"$stats_file" 2>&1; then
        echo "::error::'ccache -s' failed; its output was:"
        cat "$stats_file"
        rm -f "$owned_stats"
        return 1
      fi
      cat "$stats_file"
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
    echo "::error::could not read a non-cacheable compilation count out of $tool's statistics — the gate cannot tell an applied cache from one that declined every compile, so it fails. (sccache: a 'Non-cacheable compilations <int>' line; ccache: the FLAG_UNCACHEABLE + FLAG_ERROR counters of 'ccache --print-stats' — see the parser above for the reason it rejected them.)"
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

  # run_case_out <name> <want-exit> <grep-pattern> [args...] — like run_case,
  # but also pins the NUMBER the gate derived. An exit code alone cannot tell
  # "read 4 declined, under the ceiling" from "read 0 because the parser gave up
  # on a counter and nothing was summed".
  run_case_out() {
    local name="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$(run_check "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -q "$pat"; then
      pass=$((pass + 1))
      echo "ok   $name (exit $rc)"
    else
      fail=$((fail + 1))
      echo "FAIL $name: expected exit $want and output matching '$pat', got exit $rc"
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
  # A complete, fabricated `ccache --print-stats` block: every counter id the
  # two pinned ccache versions emit, tab-separated, zeros included, sorted the
  # way ccache sorts them. Parameterised on the four numbers the gate cares
  # about so a case can state its intent in one line.
  #
  #   ccache_print_stats <direct hits> <preprocessed hits> <misses>
  #                      [called_for_link] [internal_error] [omit_encoding]
  #
  # `called_for_link` stands in for the FLAG_UNCACHEABLE family and
  # `internal_error` for FLAG_ERROR; `omit_encoding` drops the 4.14-only id to
  # reproduce the 4.9.1 shape.
  ccache_print_stats() {
    local d="$1" p="$2" m="$3" link="${4:-0}" ierr="${5:-0}" omit="${6:-}"
    printf 'autoconf_test\t0\n'
    printf 'bad_compiler_arguments\t0\n'
    printf 'bad_input_file\t0\n'
    printf 'bad_output_file\t0\n'
    printf 'cache_miss\t%s\n' "$m"
    printf 'cache_size_kibibyte\t176128\n'
    printf 'called_for_link\t%s\n' "$link"
    printf 'called_for_preprocessing\t0\n'
    printf 'cleanups_performed\t0\n'
    printf 'compile_failed\t0\n'
    printf 'compiler_check_failed\t0\n'
    printf 'compiler_produced_empty_output\t0\n'
    printf 'compiler_produced_no_output\t0\n'
    printf 'compiler_produced_stdout\t0\n'
    printf 'could_not_find_compiler\t0\n'
    printf 'could_not_use_modules\t0\n'
    printf 'could_not_use_precompiled_header\t0\n'
    printf 'direct_cache_hit\t%s\n' "$d"
    printf 'direct_cache_miss\t%s\n' "$m"
    printf 'disabled\t0\n'
    printf 'error_hashing_extra_file\t0\n'
    printf 'files_in_cache\t644\n'
    printf 'internal_error\t%s\n' "$ierr"
    printf 'local_storage_hit\t%s\n' "$((d + p))"
    printf 'local_storage_miss\t%s\n' "$m"
    printf 'local_storage_read_hit\t%s\n' "$((d + p))"
    printf 'local_storage_read_miss\t%s\n' "$m"
    printf 'local_storage_write\t%s\n' "$m"
    printf 'max_cache_size_kibibyte\t1048576\n'
    printf 'max_files_in_cache\t0\n'
    printf 'missing_cache_file\t0\n'
    printf 'modified_input_file\t0\n'
    printf 'multiple_source_files\t0\n'
    printf 'no_input_file\t0\n'
    printf 'output_to_stdout\t0\n'
    printf 'preprocessed_cache_hit\t%s\n' "$p"
    printf 'preprocessed_cache_miss\t0\n'
    printf 'preprocessor_error\t0\n'
    printf 'recache\t0\n'
    printf 'remote_storage_error\t0\n'
    printf 'remote_storage_hit\t0\n'
    printf 'remote_storage_miss\t0\n'
    printf 'remote_storage_read_hit\t0\n'
    printf 'remote_storage_read_miss\t0\n'
    printf 'remote_storage_timeout\t0\n'
    printf 'remote_storage_write\t0\n'
    printf 'stats_updated_timestamp\t1757700042\n'
    printf 'stats_zeroed_timestamp\t1757700000\n'
    printf 'unsupported_code_directive\t0\n'
    printf 'unsupported_compiler_option\t0\n'
    printf 'unsupported_environment_variable\t0\n'
    [ "$omit" = "omit_encoding" ] || printf 'unsupported_source_encoding\t0\n'
    printf 'unsupported_source_language\t0\n'
  }

  # One `ccache -s` human summary line, with its two numbers passed as LITERAL
  # strings so a case can render the row in a layout the old parse could not
  # read. (ccache itself always prints bare digits — see the parser's header —
  # so these are deliberately synthetic, standing in for ANY re-rendering of a
  # presentation-layer row.)
  ccache_human_line() {
    printf 'Cacheable calls: %5s / %s (99.99%%)\n' "$1" "$2"
  }

  # ccache's stats file carries BOTH forms, exactly as the gate collects them:
  # `ccache -s`'s human summary first (echoed to the CI log, and the shape the
  # gate used to PARSE) and then the tab-separated `--print-stats` counters,
  # which are what it reads now (#660). The human lines carry no tabs, so the
  # counter parsers never see them.
  ccache_stats() { # <direct hits> <preprocessed hits> <misses> [uncacheable]
    local d="$1" p="$2" m="$3" u="${4:-0}" cacheable total
    cacheable=$((d + p + m))
    total=$((cacheable + u))
    ccache_human_line "$cacheable" "$total"
    if [ "$u" -gt 0 ]; then
      printf 'Uncacheable calls: %3s / %s ( 1.23%%)\n' "$u" "$total"
    fi
    # The uncacheable calls land on `called_for_link` — the counter the real
    # ubuntu leg's four post-gate `g++` compile-and-link calls increment.
    ccache_print_stats "$d" "$p" "$m" "$u" 0
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
  # 23. ...and the mirror of that rule after #660: the human `Cacheable calls:`
  #     line is no longer an INPUT, only log decoration, so a stats file
  #     without it must still produce the number. This case used to assert the
  #     opposite — that a missing summary line is a hard failure — which is
  #     what made the gate's ceiling hostage to a presentation-layer row.
  grep -v '^Cacheable calls:' "$tmp/ccache_clean.txt" >"$tmp/ccache_no_summary.txt"
  run_case_out "ccache stats without the human summary still parse" 0 \
    'non-cacheable compilations: 0' \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_no_summary.txt"

  # 24. Misconfiguration of the new knob itself must be loud, like --compiled.
  run_case "non-integer --max-noncacheable rejected" 1 \
    --tool sccache --compiled 600 --max-noncacheable "none" \
    --stats-file "$tmp/sccache_clean.txt"

  # ── 25-34. ccache's MACHINE-READABLE non-cacheable count (issue #660) ─────
  #
  # The cases above read the uncacheable split out of `ccache -s`'s HUMAN
  # summary line (`Cacheable calls: <n> / <total>`), digit-split with
  # `split($0, a, /[^0-9]+/)` down to the first two numeric runs. That makes a
  # required CI gate depend on a PRESENTATION layer: `TextTable` sizes every
  # column to the widest cell across all rows, so the row's rendering is a
  # function of unrelated rows, and ccache re-cuts the summary between releases.
  # Any re-render the regex does not expect takes the leg red with
  # `could not read a non-cacheable compilation count` — a red C++ leg for a
  # non-cache reason. (NOT a silent mis-count from a thousands separator: ccache
  # renders these cells with `fmt::format("{}", number)` and never groups them.
  # That claim was in this file until it was checked against ccache's source.)
  # `ccache --print-stats` is the documented machine-parsable form:
  #
  #   "Print statistics counter IDs and corresponding values in machine-parsable
  #    (tab-separated or JSON) format."
  #        -- https://ccache.dev/manual/4.14.html (--print-stats)
  #
  # ccache derives its own human summary as
  #   total_calls   = hits + misses + errors + uncacheable
  #   cacheable     = hits + misses
  # with `uncacheable` = the sum of every counter flagged FLAG_UNCACHEABLE and
  # `errors` = every counter flagged FLAG_ERROR (src/core/Statistics.cpp in
  # 4.9.1, src/ccache/core/statistics.cpp in 4.14 — both the same expression).
  # So the shortfall the old parse read off the human line is exactly
  # `uncacheable + errors`, and every one of those counters is printed by
  # `--print-stats` (which emits every field without FLAG_NEVER, zeros
  # included, plus max_cache_size_kibibyte / max_files_in_cache /
  # stats_updated_timestamp).
  #
  # VERSION-PINNED: ubuntu-latest installs ccache 4.9.1 (apt, `ccache version
  # 4.9.1` in the C++ (ubuntu-latest) job log of main run 34749011196, job
  # 103702029894) and macos-latest 4.14 (`ccache version 4.14`, job
  # 103702029887 of the same run). Their counter tables differ by exactly ONE
  # id — 4.14 adds `unsupported_source_encoding` — so the fixtures below cover
  # both shapes.

  # 25. THE NEW SOURCE OF TRUTH: `--print-stats` counters alone, with NO human
  #     summary in the file at all. 4 uncacheable calls (the compile-and-link
  #     `g++` that full_e2e.sh's smoke runs through ccache), under an explicit
  #     ceiling of 5.
  ccache_print_stats 318 0 0 4 0 >"$tmp/ccache_counters_only.txt"
  run_case_out "ccache non-cacheable read from --print-stats counters alone" 0 \
    'non-cacheable compilations: 4' \
    --tool ccache --compiled 322 --max-noncacheable 5 \
    --stats-file "$tmp/ccache_counters_only.txt"

  # 26. THE DEFECT: a `Cacheable calls:` row rendered in a layout the old parse
  #     cannot read. The counters say 16 declined (1250 - 1234); the old
  #     digit-split regex does not match this row at all, so the gate reported
  #     `could not read a non-cacheable compilation count` and took the leg red
  #     for a reason that has nothing to do with the compiler cache. (The
  #     grouped digits here are SYNTHETIC — ccache never groups; see the
  #     parser's header. They stand in for any re-rendering of a row that is a
  #     presentation layer, which is the whole reason a gate must not parse it.)
  #     The case pins the NUMBER, not just the exit code: reading 16 and
  #     reading nothing both sit under a generous ceiling in exit-code terms.
  {
    ccache_human_line "1,234" "1,250"
    ccache_print_stats 1234 0 0 16 0
  } >"$tmp/ccache_relaid_human.txt"
  run_case_out "a human row the old parse could not read no longer matters" 0 \
    'non-cacheable compilations: 16' \
    --tool ccache --compiled 1250 --max-noncacheable 20 \
    --stats-file "$tmp/ccache_relaid_human.txt"

  # 27. ccache's own `total_calls` includes the FLAG_ERROR counters, so the
  #     shortfall the gate reports must too — otherwise a leg whose compiles
  #     all failed to hash reads as a perfectly cached one.
  {
    ccache_human_line 322 322
    ccache_print_stats 320 0 0 0 2
  } >"$tmp/ccache_errors.txt"
  run_case_out "error counters count toward the non-cacheable total" 0 \
    'non-cacheable compilations: 2' \
    --tool ccache --compiled 322 --max-noncacheable 5 \
    --stats-file "$tmp/ccache_errors.txt"

  # 28. The ubuntu leg's ccache 4.9.1 prints one counter FEWER than macOS's
  #     4.14 (`unsupported_source_encoding` is 4.14-only). Both shapes must
  #     parse; a required-id list that demanded the newer one would red the
  #     ubuntu leg for a version difference.
  ccache_print_stats 322 0 0 0 0 omit_encoding >"$tmp/ccache_491.txt"
  run_case_out "ccache 4.9.1's counter set (no unsupported_source_encoding) parses" 0 \
    'non-cacheable compilations: 0' \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_491.txt"

  # 29. A counter id this gate does not classify means ccache grew a counter —
  #     possibly an uncacheable one, which would then be silently UNDER-counted
  #     and the ceiling would pass while the cache declined. Fail loud and name
  #     it; the fix is one line in the id table.
  {
    ccache_human_line 322 322
    ccache_print_stats 322 0 0 0 0
    printf 'brand_new_uncacheable_reason\t7\n'
  } >"$tmp/ccache_unknown_id.txt"
  run_case "unclassified ccache counter id fails loud" 1 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_unknown_id.txt"

  # 30. A counter id that DISAPPEARED is the same defect from the other side:
  #     the sum silently loses a term. (Here `called_for_link`, the counter the
  #     real ubuntu leg's 4 uncacheable calls land on.)
  {
    ccache_human_line 322 322
    ccache_print_stats 322 0 0 0 0 | grep -v '^called_for_link	'
  } >"$tmp/ccache_missing_id.txt"
  run_case "ccache stats missing a required counter id fail loud" 1 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_missing_id.txt"

  # 31. A non-integer value on a counted counter must fail, exactly like the
  #     sccache `Non-cacheable compilations many` case above.
  {
    ccache_human_line 322 322
    ccache_print_stats 322 0 0 0 0 | grep -v '^called_for_link	'
    printf 'called_for_link\tmany\n'
  } >"$tmp/ccache_nan_counter.txt"
  run_case "non-integer ccache counter value fails loud" 1 \
    --tool ccache --compiled 322 --stats-file "$tmp/ccache_nan_counter.txt"

  # ── 32-34. The two ccache INVOCATIONS, through a stub on PATH ─────────────
  # The cases above all hand the gate a stats FILE. These drive the branch CI
  # actually takes — the gate shelling out to ccache itself — with a stub that
  # fails one sub-command at a time. `ccache -s` used to be a cosmetic
  # `::warning::` here; a gate that cannot read its own instrument is not a
  # gate, so it must be an `::error::` like every other unreadable-stats path.
  mkdir -p "$tmp/bin_s_fails" "$tmp/bin_ps_fails" "$tmp/bin_ok"
  ccache_print_stats 322 0 0 0 0 >"$tmp/stub_counters.txt"
  ccache_human_line 322 322 >"$tmp/stub_human.txt"
  cat >"$tmp/bin_s_fails/ccache" <<STUB
#!/usr/bin/env bash
case "\$1" in
  -s | --show-stats) echo "ccache: error: failed to read stats file" >&2; exit 1 ;;
  --print-stats) cat "$tmp/stub_counters.txt"; exit 0 ;;
esac
exit 2
STUB
  cat >"$tmp/bin_ps_fails/ccache" <<STUB
#!/usr/bin/env bash
case "\$1" in
  -s | --show-stats) cat "$tmp/stub_human.txt"; exit 0 ;;
  --print-stats) echo "ccache: error: unknown option --print-stats" >&2; exit 1 ;;
esac
exit 2
STUB
  cat >"$tmp/bin_ok/ccache" <<STUB
#!/usr/bin/env bash
case "\$1" in
  -s | --show-stats) cat "$tmp/stub_human.txt"; exit 0 ;;
  --print-stats) cat "$tmp/stub_counters.txt"; exit 0 ;;
esac
exit 2
STUB
  chmod +x "$tmp/bin_s_fails/ccache" "$tmp/bin_ps_fails/ccache" "$tmp/bin_ok/ccache"

  # run_case_path <name> <want-exit> <grep-pattern> <bindir> [args...]
  run_case_path() {
    local name="$1" want="$2" pat="$3" bindir="$4"; shift 4
    local out rc
    out="$(PATH="$bindir:$PATH"; run_check "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s' "$out" | grep -q "$pat"; then
      pass=$((pass + 1))
      echo "ok   $name (exit $rc)"
    else
      fail=$((fail + 1))
      echo "FAIL $name: expected exit $want and output matching '$pat', got exit $rc"
      echo "$out" | sed 's/^/     | /'
    fi
  }

  # 32. `ccache -s` failing is a HARD failure with its own message, not a
  #     warning the run limps past.
  run_case_path "'ccache -s' failure is a hard, named failure" 1 \
    "::error::'ccache -s' failed" "$tmp/bin_s_fails" \
    --tool ccache --compiled 322

  # 33. `ccache --print-stats` failing is the same (it is now the only source
  #     of the numbers the gate compares).
  run_case_path "'ccache --print-stats' failure is a hard, named failure" 1 \
    "::error::'ccache --print-stats' failed" "$tmp/bin_ps_fails" \
    --tool ccache --compiled 322

  # 34. ...and the happy path through the very same stub harness, so 32-33
  #     cannot pass merely because the stub is unusable.
  run_case_path "ccache invoked for real (both sub-commands OK) stays green" 0 \
    'non-cacheable compilations: 0' "$tmp/bin_ok" \
    --tool ccache --compiled 322

  rm -rf "$tmp"

  local total=$((pass + fail))
  # Positive floor: an exit code plus a failure count cannot tell "everything
  # passed" from "nothing ran".
  if [ "$total" -lt 34 ]; then
    echo "::error::compiler-cache gate self-test ran only $total case(s) — expected at least 34."
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
