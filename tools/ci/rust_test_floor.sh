#!/usr/bin/env bash
# Assert a POSITIVE FLOOR over NAMED Rust tests actually running as `ok` in a
# captured `cargo test` log (issue #735).
#
# Why this exists: by default `cargo test` stops enumerating tests the moment
# an EARLIER target in the same invocation fails — this is cross-TARGET
# fail-fast, not merely "the overall exit code is non-zero" — so a real,
# unrelated red elsewhere in the workspace can mask brand-new tests never
# having run at all. That is exactly what happened on PR #725 (CI job
# 103825892782, workflow run 34794837901): `compile_reencode_roundtrip`
# failed first, and grepping that job's raw log for the three new
# `compiler_output.rs` tests finds neither `ok` nor `FAILED` for any of
# them — they never ran. "the `cargo test` invocation exited non-zero" and
# "this specific test never ran" are different claims, and nothing before
# this asserted the second one positively (the repo's own
# test-count-positive-floor-gate doctrine: a `failed == 0` check alone cannot
# distinguish "everything passed" from "nothing ran").
#
# Contract:
#
#   rust_test_floor.sh <cargo-test-exit-code> <log-file> <required-test-name> [...]
#
#   cargo-test-exit-code  the exit status of the `cargo test` invocation that
#                         produced <log-file>. Reported and GATED ON — unlike
#                         `roundtrip_floor.sh`'s leg-exit-code (which is
#                         expected to be non-zero while fixtures still fail),
#                         a non-zero `cargo test --workspace` is always a real
#                         failure. MUST be a bare integer; refusing a blank or
#                         non-numeric value, rather than letting a broken `[`
#                         comparison silently skip the gate, is the same
#                         lesson `roundtrip_floor.sh` already encodes.
#   log-file              a file holding `cargo test`'s combined
#                         stdout+stderr. The CALLER is responsible for
#                         running it with `--no-fail-fast` first — so that an
#                         earlier target's failure cannot keep LATER targets
#                         from running at all, the other half of #735's fix —
#                         and for capturing real output into this file
#                         (never through a bare pipe whose own exit status
#                         then gets lost: redirect to a file, not `| tee`).
#   required-test-name    one or more BARE test function names (no module
#                         path prefix) that MUST appear in the log as
#                         `test <name> ... ok`. This is the positive floor:
#                         it fails loud on MISSING (never ran at all) and on
#                         FAILED (ran, but red) alike, and says which.
#
# Gates, in order:
#   1. the exit code argument is itself a bare integer (never silently
#      skipped by a malformed comparison);
#   2. the log file exists and is non-empty;
#   3. every required test name is present as `... ok` somewhere in the log —
#      reported as MISSING (no line at all, matching #735's exact symptom) or
#      FAILED (ran, but red) when it is not;
#   4. the cargo test exit code itself is 0.
#
# Deliberately at most TWO reads of the log per required name (one for `ok`,
# one for `FAILED`) rather than one broad `grep -c` over the whole file: a
# test's own stdout can legitimately contain the substring `... ok` (this
# repo's Rust tests print plenty of arbitrary program output), so the match
# is anchored at the START of the line with `^test ` — never a bare
# substring search.
set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "::error::rust_test_floor.sh: usage: rust_test_floor.sh <cargo-test-exit-code> <log-file> <required-test-name> [...]"
  exit 2
fi

cargo_exit=$1
log_file=$2
shift 2

# ── 1. The exit code argument must itself be trustworthy ───────────────────
case "$cargo_exit" in
  ''|*[!0-9]*)
    echo "::error::rust_test_floor.sh: cargo-test-exit-code argument is '$cargo_exit', not a bare integer. Refusing to run an ungated check."
    exit 2;;
esac

# ── 2. The log must exist and hold something ────────────────────────────────
if [ ! -s "$log_file" ]; then
  echo "::error::rust_test_floor.sh: log file '$log_file' is missing or empty — nothing to check. A \`cargo test\` invocation that produced no output measured nothing."
  exit 1
fi

# ── 3. Positive floor: every required test ran as `ok` ──────────────────────
missing=0
for name in "$@"; do
  # A test declared inside a `mod` block prints its module-qualified path
  # (`mod_name::test_name`); a top-level test prints its bare name. Either
  # shape ends the line in ` ... ok` — anchored at line start so a test's
  # own printed stdout line containing that substring is never mistaken for
  # the harness's own result line.
  if grep -qE "^test ([A-Za-z0-9_]+::)*${name} \.\.\. ok\$" "$log_file"; then
    continue
  fi
  if grep -qE "^test ([A-Za-z0-9_]+::)*${name} \.\.\. FAILED\$" "$log_file"; then
    echo "::error::rust_test_floor.sh: required test '$name' ran and FAILED."
  else
    echo "::error::rust_test_floor.sh: required test '$name' never appears as 'ok' (or 'FAILED') anywhere in the captured log — it did not run at all. This is the exact #735 failure mode: an earlier failing target can silently skip a later one."
  fi
  missing=1
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "rust_test_floor.sh: all $# required test(s) observed as 'ok'."

# ── 4. The invocation itself must have exited clean ─────────────────────────
if [ "$cargo_exit" -ne 0 ]; then
  echo "::error::rust_test_floor.sh: cargo test exited $cargo_exit — every required test ran as 'ok', but something else in the workspace failed."
  exit 1
fi

exit 0
