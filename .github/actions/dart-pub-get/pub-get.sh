#!/usr/bin/env bash
# Bounded-retry wrapper around `dart pub get` (issue #520).
#
# WHY THIS EXISTS: `dart pub get` resolves the whole pub workspace rooted at the
# repo-root pubspec.yaml, which declares public, unauthenticated dependencies
# (e.g. the `melos` dev_dependency) fetched from pub.dev over the network. Run
# 33640533368's `Python` job went red at `Because ball_workspace depends on
# melos any which doesn't exist (authorization failed) ... Insufficient
# permissions to the resource at the https://pub.dev package repository` — a
# transient pub.dev-side resolver hiccup, on a commit whose diff could not
# possibly have caused it. Every `dart pub get` in ci.yml was a bare,
# single-shot command, so one flaky second on an external index was enough to
# fail a required job.
#
# CONTRACT (deliberately narrow, modelled on the repo's own existing retry
# precedent in .github/workflows/publish-pypi.yml):
#   * BOUNDED — a fixed attempt count and a fixed sleep, never open-ended, so a
#     genuinely broken pubspec/version conflict fails in seconds-to-minutes
#     instead of burning the job's 90-minute timeout.
#   * LOUD — every attempt's stdout/stderr goes straight to the log (nothing is
#     captured or swallowed), and exhaustion emits a `::error::` naming the
#     attempt count and the last exit code. A real resolution failure still
#     reads exactly like it does today, just N times over.
#   * PURE — no cwd side effects on the calling job (a composite action's step
#     cwd is its own), so hoisting a `dart pub get` out of a multi-line `run:`
#     block cannot move the ground under the lines that follow it.
#
# Driven directly (no Actions runtime needed) by
# .github/actions/dart-pub-get/test/test_dart_pub_get_wiring.sh.

set -uo pipefail

ATTEMPTS="${INPUT_ATTEMPTS:-5}"
SLEEP_SECONDS="${INPUT_SLEEP_SECONDS:-15}"
WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-.}"

# Fail loud on a nonsensical configuration rather than silently degrading to
# "one attempt" (or to an unbounded loop) — a mistyped input must not quietly
# turn the retry off.
case "$ATTEMPTS" in
'' | *[!0-9]*)
  echo "::error::dart-pub-get: attempts must be a positive integer, got '$ATTEMPTS'"
  exit 1
  ;;
esac
if [ "$ATTEMPTS" -lt 1 ]; then
  echo "::error::dart-pub-get: attempts must be >= 1, got '$ATTEMPTS'"
  exit 1
fi
case "$SLEEP_SECONDS" in
'' | *[!0-9]*)
  echo "::error::dart-pub-get: sleep-seconds must be a non-negative integer, got '$SLEEP_SECONDS'"
  exit 1
  ;;
esac

cd "$WORKING_DIRECTORY" || {
  echo "::error::dart-pub-get: working-directory '$WORKING_DIRECTORY' does not exist"
  exit 1
}

succeeded=0
last_rc=0
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  echo "dart pub get (attempt $attempt of $ATTEMPTS) in $(pwd)"
  # No capture: the resolver's own output — including the final failure's — is
  # the diagnostic, and it belongs in the job log verbatim.
  if dart pub get; then
    succeeded=1
    break
  fi
  last_rc=$?
  echo "attempt $attempt of $ATTEMPTS failed (exit $last_rc); pub.dev may be momentarily flaky"
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    sleep "$SLEEP_SECONDS"
  fi
  attempt=$((attempt + 1))
done

if [ "$succeeded" -ne 1 ]; then
  echo "::error::dart pub get failed after $ATTEMPTS attempts (last exit $last_rc) in $(pwd) — this is not a transient pub.dev hiccup; read the resolver output above"
  exit 1
fi
