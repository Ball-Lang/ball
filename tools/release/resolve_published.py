#!/usr/bin/env python3
"""Read a freshly published package back out of pub.dev (#568).

WHY THIS EXISTS: `release-publish.yml`'s verify job waits for the version it just
uploaded to appear on the pub.dev API, then resolves it from a scratch package
with no workspace and no path overrides — the two steps that prove an upload is
*installable*. Both used to be inline, each with a flat
`for attempt in 1 2 3 4 5 6; do ... sleep 20` loop that treated every failure
alike.

Run 33957914166 (`ball_resolver-v0.3.1`) shows why that is wrong. The upload
succeeded at 09:25:24Z; six resolutions 20 s apart, the last at 09:27:35Z, all
failed with:

    Because ball_publish_verification depends on ball_resolver 0.3.1
    which doesn't match any versions, version solving failed.

The release was fine — pub.dev's *resolution* index simply had not caught up
with the upload yet (the same package resolves cleanly now, and the sibling run
33957929283 for `ball_rpc-v0.3.1` was resolvable within ~25 s). The 2-minute
budget was sized for the loop's own message, "a dependency may still be
publishing", not for the package's own index propagation, so a correct release
went red — which trains people to ignore the one check that caught #566 for
real.

So the retry is no longer blind. The solver's own text says which package it
could not satisfy:

  * it names THE PACKAGE UNDER VERIFICATION  -> the index is still propagating.
    Keep polling on a bounded budget (default 15 min, 30 s apart).
  * it names a SIBLING pin (`ball_cli` requiring `ball_resolver ^0.4.0` that
    nothing satisfies — the #566 shape)  -> a real, permanent conflict. Fail
    immediately with the verbatim solver output; waiting cannot fix it.
  * anything else (an SDK constraint, a network error, an unrecognised shape)
    -> fail, loudly, with the verbatim output. Never retried, never swallowed.

The index poll (`--await-index`) is the same story one step earlier and shares
the same budget: the API can lag an upload too, and 2 minutes was never measured
to be enough for anything.

`--self-test` drives every classification and both budget loops offline (fake
clock, injected resolver/fetcher) from ci.yml's always-on `Proto Checks` job,
because the live steps only run during a real publish and would otherwise never
be exercised until the day they had to be right.

Usage:
  python3 tools/release/resolve_published.py --await-index --package <pkg> --version <ver>
  python3 tools/release/resolve_published.py --package <pkg> --version <ver> \
      --dir <scratch-dir> [--budget-seconds N] [--interval-seconds N]
  python3 tools/release/resolve_published.py --self-test

Env overrides (the workflow passes none; they exist for a recovery re-run):
  BALL_PUBDEV_RESOLVE_BUDGET_SECONDS    total polling budget   (default 900)
  BALL_PUBDEV_RESOLVE_INTERVAL_SECONDS  delay between attempts (default 30)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

# ── Verdicts. ────────────────────────────────────────────────────────────────
STILL_PROPAGATING = "still-propagating"
SIBLING_CONFLICT = "sibling-conflict"
UNCLASSIFIED = "unclassified"

# 15 minutes at 30 s. The measured lag that motivated this (#568) was >131 s on
# one package and <25 s on its sibling in the same loop, so the budget is sized
# an order of magnitude above the worst observation rather than just above it.
DEFAULT_BUDGET_SECONDS = 900
DEFAULT_INTERVAL_SECONDS = 30

_BUDGET_ENV = "BALL_PUBDEV_RESOLVE_BUDGET_SECONDS"
_INTERVAL_ENV = "BALL_PUBDEV_RESOLVE_INTERVAL_SECONDS"

# pub's solver names an unsatisfiable dependency as
#   "<name> <constraint> which doesn't match any versions"
# The constraint is matched as version-shaped tokens (`0.3.1`, `^0.4.0`,
# `>=0.4.0 <0.5.0`, `any`) rather than "anything", so the leftmost-match engine
# cannot swallow the surrounding prose and report `Because` as the package.
_CONSTRAINT_TOKEN = r"(?:[\^~]?[<>=]{0,2}\s?[0-9][0-9A-Za-z.+\-]*|any|\*)"
_NO_MATCH = re.compile(
    rf"([A-Za-z_][A-Za-z0-9_]*)\s+"
    rf"((?:{_CONSTRAINT_TOKEN})(?:\s+(?:{_CONSTRAINT_TOKEN}))*)\s+"
    r"which\s+doesn[’']t\s+match\s+any\s+versions"
)

_PUBSPEC = """\
name: ball_publish_verification
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  {package}: {version}
"""


class ConfigError(Exception):
    """A budget/interval that cannot be honoured — never a silent fallback."""


def unsatisfied_packages(output: str) -> list[tuple[str, str]]:
    """Every `<name> <constraint> which doesn't match any versions` in the text."""
    text = output.replace("\r\n", "\n").replace("\r", "\n")
    return [(m[1], " ".join(m[2].split())) for m in _NO_MATCH.finditer(text)]


def classify(output: str, package: str) -> str:
    """Which of the three verdicts this solver output carries."""
    unsatisfied = unsatisfied_packages(output)
    if any(name != package for name, _ in unsatisfied):
        # A sibling pin nothing on pub.dev satisfies. Permanent: the fix is a
        # new release of that sibling, not another 30 seconds of waiting.
        return SIBLING_CONFLICT
    if unsatisfied:
        return STILL_PROPAGATING
    return UNCLASSIFIED


class Outcome:
    """What the polling loop concluded, for the caller and for the self-test."""

    def __init__(self, code: int, verdict: str, attempts: int, waited: float, output: str):
        self.code = code
        self.verdict = verdict
        self.attempts = attempts
        self.waited = waited
        self.output = output

    def __repr__(self) -> str:  # pragma: no cover - self-test failure detail only
        return (
            f"Outcome(code={self.code}, verdict={self.verdict!r}, "
            f"attempts={self.attempts}, waited={self.waited})"
        )


def resolve_with_budget(
    package: str,
    version: str,
    attempt_fn,
    *,
    budget_seconds: int = DEFAULT_BUDGET_SECONDS,
    interval_seconds: int = DEFAULT_INTERVAL_SECONDS,
    sleep=time.sleep,
    clock=time.monotonic,
    log=print,
) -> Outcome:
    """Poll `attempt_fn` until it resolves, the budget runs out, or it fails hard.

    `attempt_fn()` returns `(ok, combined_output)`. Everything about time is
    injected so the whole loop is exercised offline by `--self-test`.
    """
    started = clock()
    deadline = started + budget_seconds
    attempts = 0
    last = ""
    while True:
        attempts += 1
        ok, last = attempt_fn()
        if ok:
            log(f"{package} {version} resolved as an external consumer on attempt {attempts}")
            return Outcome(0, "resolved", attempts, clock() - started, last)

        verdict = classify(last, package)
        if verdict == SIBLING_CONFLICT:
            log(
                f"::error::{package} {version} does not resolve from pub.dev: a dependency "
                "constraint names a sibling version pub.dev does not serve. This is a "
                "permanent conflict, not index propagation — failing fast on attempt "
                f"{attempts} instead of waiting out the budget."
            )
            return Outcome(1, verdict, attempts, clock() - started, last)
        if verdict == UNCLASSIFIED:
            log(
                f"::error::{package} {version} failed to resolve from pub.dev for a reason "
                "this guard does not recognise as index propagation (see the solver output "
                f"above), on attempt {attempts}. Failing rather than retrying blindly."
            )
            return Outcome(1, verdict, attempts, clock() - started, last)

        remaining = deadline - clock()
        if remaining <= 0:
            log(
                f"::error::{package} {version} still does not resolve from pub.dev for an "
                f"external consumer after {attempts} attempts over {budget_seconds}s. "
                "pub.dev's index normally catches up within seconds; this is now longer "
                "than any lag this lane has measured, so it is reported as a failure."
            )
            return Outcome(1, STILL_PROPAGATING, attempts, clock() - started, last)

        wait = min(interval_seconds, remaining)
        log(
            f"attempt {attempts}: pub.dev does not serve {package} {version} to the solver "
            f"yet; its index is still propagating. Retrying in {wait:g}s "
            f"({remaining:g}s of the {budget_seconds}s budget left)."
        )
        sleep(wait)


def version_in_index(body: str, version: str) -> tuple[bool, str]:
    """Is `version` in the pub.dev API document's `versions[]`?

    Membership, not `latest.version ==`: re-running an older tag for failure
    recovery must still verify the right thing. A malformed body is not a
    verdict — it is a reason to poll again.
    """
    try:
        doc = json.loads(body)
    except Exception as exc:  # noqa: BLE001 - any malformed body is a retry
        return False, f"could not parse the pub.dev response: {exc}"
    if not isinstance(doc, dict):
        return False, "the pub.dev response was not a JSON object"
    known = [v.get("version") for v in doc.get("versions", []) if isinstance(v, dict)]
    latest = (doc.get("latest") or {}).get("version")
    return version in known, f"latest={latest} known={len(known)} looking-for={version}"


def await_index(
    package: str,
    version: str,
    fetch_fn,
    *,
    budget_seconds: int = DEFAULT_BUDGET_SECONDS,
    interval_seconds: int = DEFAULT_INTERVAL_SECONDS,
    sleep=time.sleep,
    clock=time.monotonic,
    log=print,
) -> Outcome:
    """Poll the pub.dev API until it lists `version`, on the same bounded budget."""
    started = clock()
    deadline = started + budget_seconds
    attempts = 0
    detail = ""
    while True:
        attempts += 1
        body = fetch_fn()
        found, detail = version_in_index(body, version)
        log(detail)
        if found:
            log(f"{package} {version} is on pub.dev (attempt {attempts})")
            return Outcome(0, "indexed", attempts, clock() - started, detail)
        remaining = deadline - clock()
        if remaining <= 0:
            log(
                f"::error::{package} {version} never appeared on "
                f"https://pub.dev/api/packages/{package} after {attempts} attempts over "
                f"{budget_seconds}s"
            )
            return Outcome(1, "not-indexed", attempts, clock() - started, detail)
        wait = min(interval_seconds, remaining)
        log(
            f"attempt {attempts}: {package} {version} is not on pub.dev yet; the index may "
            f"still be propagating. Retrying in {wait:g}s ({remaining:g}s of the "
            f"{budget_seconds}s budget left)."
        )
        sleep(wait)


def _fetch_pubdev(package: str) -> str:
    """One read of the pub.dev package document; any error is a retryable body."""
    url = f"https://pub.dev/api/packages/{package}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 - fixed https URL
            return response.read().decode("utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001 - a transient failure is a retry, not a verdict
        return f"::pub.dev request failed:: {exc}"


def write_consumer_pubspec(directory: str, package: str, version: str) -> str:
    """The scratch consumer: no workspace, no path overrides, an exact pin."""
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "pubspec.yaml")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(_PUBSPEC.format(package=package, version=version))
    return path


def resolve_dart(which=shutil.which) -> str:
    """The `dart` executable, or a configuration error naming what is missing.

    Looked up once, up front: a missing SDK is a broken job, not a resolution
    failure to be retried for fifteen minutes or classified as a conflict.
    """
    found = which("dart")
    if not found:
        raise ConfigError(
            "no `dart` executable on PATH — the verify job must set up the Dart SDK "
            "before resolving a published package"
        )
    return found


def _dart_pub_get(dart: str, directory: str):
    """One `dart pub get`, with stdout and stderr echoed verbatim."""
    proc = subprocess.run(
        [dart, "pub", "get"],
        cwd=directory,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
    )
    output = proc.stdout or ""
    if output:
        sys.stdout.write(output if output.endswith("\n") else output + "\n")
        sys.stdout.flush()
    return proc.returncode == 0, output


def _env_seconds(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw.strip())
    except ValueError as exc:
        raise ConfigError(f"{name}={raw!r} is not an integer number of seconds") from exc
    if value <= 0:
        raise ConfigError(f"{name}={raw!r} must be a positive number of seconds")
    return value


# ── Self-test ────────────────────────────────────────────────────────────────

# Verbatim from run 33957914166's "Resolve the published package as an external
# consumer" step (timestamp prefixes stripped): ball_resolver 0.3.1, published
# 09:25:24.195Z, still unresolvable at 09:27:35Z.
RUN_33957914166 = """\
Resolving dependencies...
Because ball_publish_verification depends on ball_resolver 0.3.1 which doesn't match any versions, version solving failed.


You can try the following suggestion to make the pubspec resolve:
* Consider downgrading your constraint on ball_resolver: dart pub add ball_resolver:'^0.3.0+3'
"""

# The #566 shape: a published package pinned to a sibling version pub.dev never
# got. No amount of waiting fixes it — the sibling has to be released.
SIBLING_566 = """\
Resolving dependencies...
Because every version of ball_cli depends on ball_resolver ^0.4.0 which doesn't match any versions, ball_cli 0.4.0 is forbidden.
So, because ball_publish_verification depends on ball_cli 0.4.0, version solving failed.
"""

SDK_FAILURE = """\
Resolving dependencies...
The current Dart SDK version is 3.9.0.

Because ball_publish_verification requires SDK version ^3.99.0, version solving failed.
"""

NETWORK_FAILURE = """\
Resolving dependencies...
Got socket error trying to find package ball_resolver at https://pub.dev.
"""

SUGGESTION_ONLY = """\
Resolving dependencies...
* Consider downgrading your constraint on ball_resolver: dart pub add ball_resolver:'^0.3.0+3'
"""


class _FakeClock:
    """Deterministic time: only an explicit sleep advances it."""

    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


def _fails_until(clock: _FakeClock, seconds: float, output: str):
    """A resolver that starts succeeding once the fake clock passes `seconds`."""

    def attempt():
        if clock.now >= seconds:
            return True, "Got dependencies!\n"
        return False, output

    return attempt


def _quiet(*_args, **_kwargs) -> None:
    """The loop's log sink, muted while the self-test drives it."""


def self_test() -> int:
    results: list[tuple[str, bool, str]] = []

    def check(label: str, condition: bool, detail: str = "") -> None:
        results.append((label, condition, detail))

    # ── Classification. ──────────────────────────────────────────────────────
    check(
        "classifies run 33957914166's verbatim output as still propagating",
        classify(RUN_33957914166, "ball_resolver") == STILL_PROPAGATING,
        classify(RUN_33957914166, "ball_resolver"),
    )
    check(
        "reads the package and constraint out of the solver text, not the prose",
        unsatisfied_packages(RUN_33957914166) == [("ball_resolver", "0.3.1")],
        repr(unsatisfied_packages(RUN_33957914166)),
    )
    check(
        "classifies a #566-shaped sibling pin conflict as a conflict",
        classify(SIBLING_566, "ball_cli") == SIBLING_CONFLICT,
        classify(SIBLING_566, "ball_cli"),
    )
    check(
        "classifies an SDK-constraint failure as unrecognised, never as propagation",
        classify(SDK_FAILURE, "ball_resolver") == UNCLASSIFIED,
        classify(SDK_FAILURE, "ball_resolver"),
    )
    check(
        "classifies a network failure as unrecognised, never as propagation",
        classify(NETWORK_FAILURE, "ball_resolver") == UNCLASSIFIED,
        classify(NETWORK_FAILURE, "ball_resolver"),
    )
    check(
        "does not treat pub's downgrade suggestion alone as a propagation verdict",
        classify(SUGGESTION_ONLY, "ball_resolver") == UNCLASSIFIED,
        classify(SUGGESTION_ONLY, "ball_resolver"),
    )
    crlf_curly = RUN_33957914166.replace("'", "’").replace("\n", "\r\n")
    check(
        "classifies the same output identically with CRLF and a curly apostrophe",
        classify(crlf_curly, "ball_resolver") == STILL_PROPAGATING,
        classify(crlf_curly, "ball_resolver"),
    )

    # ── The budget loop. ─────────────────────────────────────────────────────
    clock = _FakeClock()
    outcome = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 0, ""),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "a first-attempt resolution exits 0 without sleeping",
        outcome.code == 0 and outcome.attempts == 1 and clock.sleeps == [],
        repr((outcome, clock.sleeps)),
    )

    clock = _FakeClock()
    outcome = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 90, RUN_33957914166),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "keeps polling through a propagating index instead of giving up",
        outcome.code == 0 and outcome.attempts == 4,
        repr(outcome),
    )

    # THE REGRESSION: the retired 6 x 20 s budget against this very output.
    clock = _FakeClock()
    old = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 840, RUN_33957914166),
        budget_seconds=120,
        interval_seconds=20,
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    clock = _FakeClock()
    new = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 840, RUN_33957914166),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "the retired 6 x 20 s budget fails on run 33957914166's output; this one does not",
        old.code == 1 and new.code == 0 and new.attempts >= 20,
        repr((old, new)),
    )

    clock = _FakeClock()
    outcome = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 10**9, RUN_33957914166),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "the poll is BOUNDED: a package that never appears fails after the budget",
        outcome.code == 1
        and outcome.verdict == STILL_PROPAGATING
        and clock.now == DEFAULT_BUDGET_SECONDS,
        repr((outcome, clock.now)),
    )

    clock = _FakeClock()
    outcome = resolve_with_budget(
        "ball_cli",
        "0.4.0",
        _fails_until(clock, 10**9, SIBLING_566),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "a sibling pin conflict fails FAST — one attempt, no waiting",
        outcome.code == 1
        and outcome.verdict == SIBLING_CONFLICT
        and outcome.attempts == 1
        and clock.sleeps == [],
        repr((outcome, clock.sleeps)),
    )
    check(
        "the sibling-conflict failure carries the verbatim solver text",
        outcome.output == SIBLING_566,
        repr(outcome.output),
    )

    clock = _FakeClock()
    outcome = resolve_with_budget(
        "ball_resolver",
        "0.3.1",
        _fails_until(clock, 10**9, SDK_FAILURE),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "an unrecognised failure fails FAST rather than being retried blindly",
        outcome.code == 1 and outcome.verdict == UNCLASSIFIED and outcome.attempts == 1,
        repr(outcome),
    )

    # ── The index poll that runs one step earlier, on the same budget. ───────
    index_doc = json.dumps(
        {
            "name": "ball_resolver",
            "latest": {"version": "0.3.1"},
            "versions": [{"version": "0.3.0+3"}, {"version": "0.3.1"}],
        }
    )
    stale_doc = json.dumps(
        {
            "name": "ball_resolver",
            "latest": {"version": "0.3.0+3"},
            "versions": [{"version": "0.3.0+3"}],
        }
    )
    found, detail = version_in_index(index_doc, "0.3.1")
    check("finds the published version in the pub.dev API document", found, detail)
    check(
        "verifies MEMBERSHIP, so re-running an older tag still checks the right version",
        version_in_index(index_doc, "0.3.0+3")[0],
        "0.3.0+3 is not latest but is published",
    )
    check(
        "does not report a version the index does not list",
        not version_in_index(stale_doc, "0.3.1")[0],
        repr(version_in_index(stale_doc, "0.3.1")),
    )
    check(
        "treats a malformed pub.dev body as 'not yet', never as a crash",
        not version_in_index("::pub.dev request failed:: timed out", "0.3.1")[0],
        "a transient fetch failure is retryable",
    )

    clock = _FakeClock()
    bodies = ["::pub.dev request failed:: timed out", stale_doc, index_doc]
    outcome = await_index(
        "ball_resolver",
        "0.3.1",
        lambda: bodies.pop(0),
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "the index poll rides out a transient fetch failure and a stale document",
        outcome.code == 0 and outcome.attempts == 3,
        repr(outcome),
    )

    clock = _FakeClock()
    outcome = await_index(
        "ball_resolver",
        "0.3.1",
        lambda: stale_doc,
        sleep=clock.sleep,
        clock=clock.monotonic,
        log=_quiet,
    )
    check(
        "the index poll is BOUNDED on the same budget as the resolution",
        outcome.code == 1 and clock.now == DEFAULT_BUDGET_SECONDS,
        repr((outcome, clock.now)),
    )

    # ── Budget configuration. ────────────────────────────────────────────────
    check(
        "the default budget is at least 15 minutes at 30-60 s per attempt",
        DEFAULT_BUDGET_SECONDS >= 900 and 30 <= DEFAULT_INTERVAL_SECONDS <= 60,
        f"budget={DEFAULT_BUDGET_SECONDS} interval={DEFAULT_INTERVAL_SECONDS}",
    )

    saved = {key: os.environ.get(key) for key in (_BUDGET_ENV, _INTERVAL_ENV)}
    try:
        os.environ.pop(_BUDGET_ENV, None)
        os.environ.pop(_INTERVAL_ENV, None)
        check(
            "an unset env leaves the defaults in place",
            _env_seconds(_BUDGET_ENV, DEFAULT_BUDGET_SECONDS) == DEFAULT_BUDGET_SECONDS
            and _env_seconds(_INTERVAL_ENV, DEFAULT_INTERVAL_SECONDS) == DEFAULT_INTERVAL_SECONDS,
            "defaults",
        )
        os.environ[_BUDGET_ENV] = "1800"
        os.environ[_INTERVAL_ENV] = "45"
        check(
            "the budget and interval are overridable by env",
            _env_seconds(_BUDGET_ENV, DEFAULT_BUDGET_SECONDS) == 1800
            and _env_seconds(_INTERVAL_ENV, DEFAULT_INTERVAL_SECONDS) == 45,
            "1800/45",
        )
        os.environ[_BUDGET_ENV] = "soon"
        rejected = False
        try:
            _env_seconds(_BUDGET_ENV, DEFAULT_BUDGET_SECONDS)
        except ConfigError:
            rejected = True
        check(
            "a malformed budget override is an error, never a silent fallback",
            rejected,
            "expected ConfigError for BUDGET=soon",
        )
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    missing_dart = False
    try:
        resolve_dart(which=lambda _name: None)
    except ConfigError:
        missing_dart = True
    check(
        "a missing Dart SDK is a configuration error, not fifteen minutes of retries",
        missing_dart and resolve_dart(which=lambda name: f"/usr/bin/{name}") == "/usr/bin/dart",
        "expected ConfigError with no dart on PATH",
    )

    # ── The scratch consumer the loop resolves. ──────────────────────────────
    tmp = tempfile.mkdtemp(prefix="ball-resolve-published-")
    path = write_consumer_pubspec(os.path.join(tmp, "consumer"), "ball_resolver", "0.3.1")
    with open(path, encoding="utf-8") as fh:
        pubspec = fh.read()
    check(
        "writes an exact-pinned scratch consumer with no workspace or path overrides",
        "  ball_resolver: 0.3.1\n" in pubspec
        and "publish_to: none" in pubspec
        and "path:" not in pubspec
        and "resolution:" not in pubspec,
        repr(pubspec),
    )

    passed = sum(1 for _, condition, _ in results if condition)
    failed = len(results) - passed
    for label, condition, detail in results:
        print(f"{'PASS' if condition else 'FAIL'}  {label}")
        if not condition and detail:
            print(f"  {detail}")
    total = len(results)
    minimum = 24
    if total < minimum:
        print(
            f"::error::published-resolution guard self-test ran {total} cases, "
            f"expected at least {minimum} — the sweep itself is broken"
        )
        return 1
    print(f"Results: {passed} passed, {failed} failed, {total} total")
    return 0 if failed == 0 else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Read a published package back out of pub.dev")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--await-index",
        action="store_true",
        help="poll the pub.dev API until it lists the version, instead of resolving it",
    )
    parser.add_argument("--package")
    parser.add_argument("--version")
    parser.add_argument("--dir")
    parser.add_argument("--budget-seconds", type=int)
    parser.add_argument("--interval-seconds", type=int)
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.package or not args.version:
        parser.error("--package and --version are required without --self-test")
    if not args.await_index and not args.dir:
        parser.error("--dir is required for the consumer resolution")

    try:
        budget = args.budget_seconds or _env_seconds(_BUDGET_ENV, DEFAULT_BUDGET_SECONDS)
        interval = args.interval_seconds or _env_seconds(_INTERVAL_ENV, DEFAULT_INTERVAL_SECONDS)
        dart = None if args.await_index else resolve_dart()
    except ConfigError as exc:
        print(f"::error::{exc}")
        return 2
    if budget <= 0 or interval <= 0:
        print("::error::--budget-seconds and --interval-seconds must both be positive")
        return 2

    if args.await_index:
        print(
            f"waiting for {args.package} {args.version} to appear on pub.dev "
            f"(budget {budget}s, {interval}s between attempts)"
        )
        return await_index(
            args.package,
            args.version,
            lambda: _fetch_pubdev(args.package),
            budget_seconds=budget,
            interval_seconds=interval,
        ).code

    path = write_consumer_pubspec(args.dir, args.package, args.version)
    with open(path, encoding="utf-8") as fh:
        sys.stdout.write(fh.read())
    print(
        f"resolving {args.package} {args.version} from pub.dev as an external consumer "
        f"(budget {budget}s, {interval}s between attempts)"
    )
    outcome = resolve_with_budget(
        args.package,
        args.version,
        lambda: _dart_pub_get(dart, args.dir),
        budget_seconds=budget,
        interval_seconds=interval,
    )
    return outcome.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
