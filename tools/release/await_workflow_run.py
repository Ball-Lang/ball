#!/usr/bin/env python3
"""Dispatch a workflow and WAIT for the run it started (#627).

WHY THIS EXISTS: `.github/release/go.releaserc.json`'s `publishCmd` used to be

    gh workflow run tag-go-modules.yml --ref go-modules/v${nextRelease.version}

and that command returns the moment GitHub *accepts* the dispatch. It says
nothing about what the dispatched run then did. A `tag-go-modules.yml` run that
failed, was cancelled, hit its deliberate half-tagged refusal, or never started
at all left the `go-release` run green — so the Go lane's only post-release
signal was, once again, "the automation ran". That is the #551/#361 failure
shape verbatim: every automated part reporting success while the channel ships
nothing (PR #623's review, advisory B).

So the dispatch is now awaited. The polling is the `resolve_published.py`
pattern — a bounded budget, a fixed interval, and a classification that can
never mistake "I do not know yet" for "it worked":

  * no run on the ref yet      -> keep polling. GitHub creates the run row a
                                  few seconds after accepting the dispatch.
  * queued / in_progress / …   -> keep polling.
  * completed, conclusion
    `success`                  -> DONE, exit 0.
  * completed, any other
    conclusion (failure,
    cancelled, timed_out,
    startup_failure, skipped,
    action_required, neutral,
    stale)                     -> FAIL NOW, with the run URL. Waiting cannot
                                  turn a finished run into a different one, and
                                  `skipped` in particular means zero tags were
                                  cut.
  * `gh` itself errored        -> unknown; keep polling within the budget. An
                                  API hiccup must not abort a release, and it is
                                  never allowed to read as success — the budget
                                  running out is a failure.
  * budget exhausted           -> FAIL, naming what it last saw.

WHICH RUN IS "THE" RUN. The ref is the channel tag `go-modules/vX.Y.Z`, which
semantic-release creates exactly once per release and which nothing else is ever
dispatched on. Every workflow_dispatch run on that ref is therefore this
publishCmd's run; when several exist (someone re-ran it), the NEWEST is the
authority, because that is the one whose outcome is current. Matching is done
here, on `headBranch`, rather than through `gh run list --branch`, so a tag ref
that the server-side filter treats differently from a branch cannot silently
return an empty list forever.

`--self-test` drives every classification and both loops offline (fake clock,
injected `gh` runner) from ci.yml's always-on `Proto Checks` job, because this
code only executes inside a real release and would otherwise never be exercised
until the day it had to be right.

Usage:
  python3 tools/release/await_workflow_run.py --dispatch \\
      --workflow tag-go-modules.yml --ref go-modules/v1.2.3
  python3 tools/release/await_workflow_run.py --workflow tag-go-modules.yml --ref main
  python3 tools/release/await_workflow_run.py --self-test

Env overrides (the release config passes none; they exist for a recovery re-run):
  BALL_AWAIT_RUN_BUDGET_SECONDS    total polling budget   (default 1200 = 20 min)
  BALL_AWAIT_RUN_INTERVAL_SECONDS  delay between attempts (default 30)
"""

from __future__ import annotations

import argparse
import inspect
import json
import os
import subprocess
import sys
import time

# ── Verdicts. ────────────────────────────────────────────────────────────────
SUCCEEDED = "succeeded"
PENDING = "pending"
FAILED = "failed"
UNKNOWN = "unknown"

# 20 minutes at 30 s. tag-go-modules.yml's own job timeout is 15 minutes
# (.github/workflows/tag-go-modules.yml), so the budget has to exceed that plus
# runner acquisition or a healthy-but-slow run would be reported as a timeout.
DEFAULT_BUDGET_SECONDS = 1200
DEFAULT_INTERVAL_SECONDS = 30

# Sentinel for "this self-test case did not ask for a baseline at all", so the
# back-compatible call shape (no after_run_id keyword) stays exercised.
_NO_BASELINE = object()

_BUDGET_ENV = "BALL_AWAIT_RUN_BUDGET_SECONDS"
_INTERVAL_ENV = "BALL_AWAIT_RUN_INTERVAL_SECONDS"

# Every GitHub run status that is not a finished state. Anything outside this
# set AND outside "completed" is unrecognised and is treated as pending, never
# as success: a new status GitHub introduces must not end the wait early.
_PENDING_STATUSES = {
    "queued",
    "in_progress",
    "waiting",
    "pending",
    "requested",
    "action_required",
}


def _positive_int(env_name: str, default: int) -> int:
    raw = os.environ.get(env_name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"{env_name} must be an integer, got {raw!r}")
    if value <= 0:
        raise SystemExit(f"{env_name} must be positive, got {value}")
    return value


def _run_gh(args: list[str]) -> tuple[int, str, str]:
    """Run `gh` and return (returncode, stdout, stderr). Never raises."""
    try:
        proc = subprocess.run(
            ["gh", *args], capture_output=True, text=True, check=False
        )
    except OSError as exc:  # gh missing, not executable, …
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def classify(run: dict | None) -> tuple[str, str]:
    """Classify one run row (or None for "no run found yet").

    Returns (verdict, detail). Pure: the self-test drives it directly.
    """
    if run is None:
        return PENDING, "no workflow run on that ref yet"

    status = (run.get("status") or "").strip()
    conclusion = (run.get("conclusion") or "").strip()
    url = run.get("url") or "<no url>"

    if not status:
        return UNKNOWN, f"run {url} reported no status"
    if status != "completed":
        if status in _PENDING_STATUSES:
            return PENDING, f"run {url} is {status}"
        # Unrecognised, not finished: wait rather than guess. The budget is what
        # stops this being an unbounded hang.
        return PENDING, f"run {url} reported an unrecognised status {status!r}; still waiting"
    if conclusion == "success":
        return SUCCEEDED, f"run {url} completed successfully"
    if not conclusion:
        return UNKNOWN, f"run {url} is completed with no conclusion"
    return FAILED, f"run {url} completed with conclusion {conclusion!r}"


def newest_matching(runs: list[dict], ref: str) -> dict | None:
    """The newest workflow_dispatch run whose head ref is `ref`, or None.

    `gh run list --branch` is deliberately not used: the ref here is a TAG, and
    a server-side filter that treats a tag differently from a branch would
    return an empty list forever — a silent wait to the budget instead of an
    answer. Filtering here on the rows `gh` returns cannot do that.
    """
    matching = [
        r
        for r in runs
        if (r.get("headBranch") or "") == ref
        and (r.get("event") or "workflow_dispatch") == "workflow_dispatch"
    ]
    if not matching:
        return None
    # `gh run list` returns newest-first; sort on createdAt anyway so the choice
    # does not depend on that. ISO-8601 UTC strings sort lexicographically.
    matching.sort(key=lambda r: r.get("createdAt") or "", reverse=True)
    return matching[0]


def await_run(
    *,
    workflow: str,
    ref: str,
    budget_seconds: int,
    interval_seconds: int,
    list_runs,
    sleep,
    now,
    log,
) -> int:
    """Poll until the dispatched run finishes. Returns a process exit code."""
    deadline = now() + budget_seconds
    attempt = 0
    last_detail = "nothing observed"
    while True:
        attempt += 1
        rows, err = list_runs()
        if rows is None:
            verdict, detail = UNKNOWN, f"could not list runs: {err}"
        else:
            verdict, detail = classify(newest_matching(rows, ref))
        last_detail = detail

        if verdict == SUCCEEDED:
            log(f"attempt {attempt}: {detail}")
            log(f"{workflow} at {ref}: SUCCESS")
            return 0
        if verdict == FAILED:
            log(f"attempt {attempt}: {detail}")
            log(
                f"::error::{workflow} was dispatched at {ref} and did not succeed: {detail}. "
                "The six go/<module> tags may be missing or half-cut; do not treat this "
                "release as tagged."
            )
            return 1

        remaining = deadline - now()
        if remaining <= 0:
            log(
                f"::error::{workflow} at {ref} did not complete within {budget_seconds}s "
                f"({attempt} attempts). Last seen: {last_detail}. A dispatch that never "
                "produced a finished run is not a tagged release."
            )
            return 1
        log(f"attempt {attempt}: {detail}; {int(remaining)}s of budget left")
        sleep(min(interval_seconds, remaining))


def _live_list_runs(workflow: str, limit: int):
    def call():
        code, out, err = _run_gh(
            [
                "run",
                "list",
                "--workflow",
                workflow,
                "--limit",
                str(limit),
                "--json",
                "databaseId,status,conclusion,url,createdAt,headBranch,event",
            ]
        )
        if code != 0:
            return None, (err or out).strip() or f"gh exited {code}"
        try:
            return json.loads(out), ""
        except json.JSONDecodeError as exc:
            return None, f"unreadable gh output: {exc}"

    return call


# ─────────────────────────────────────────────────────────────────────────────
# Self-test.
# ─────────────────────────────────────────────────────────────────────────────
def _self_test() -> int:
    passed = 0
    failed = 0
    log: list[str] = []

    def ok(label):
        nonlocal passed
        passed += 1
        print(f"PASS  {label}")

    def no(label, *lines):
        nonlocal failed
        failed += 1
        print(f"FAIL  {label}")
        for line in lines:
            print(f"  {line}")

    def expect_verdict(want, label, run):
        got, _ = classify(run)
        if got == want:
            ok(f"{label} -> {want}")
        else:
            no(f"{label} -> {want}", f"classify returned {got!r}")

    REF = "go-modules/v1.2.3"

    def row(**kw):
        base = {
            "url": "https://example.invalid/run/1",
            "headBranch": REF,
            "event": "workflow_dispatch",
            "createdAt": "2026-09-13T10:00:00Z",
        }
        base.update(kw)
        return base

    # ── classification ────────────────────────────────────────────────────
    expect_verdict(PENDING, "no run row yet", None)
    expect_verdict(PENDING, "queued", row(status="queued", conclusion=None))
    expect_verdict(PENDING, "in_progress", row(status="in_progress", conclusion=None))
    expect_verdict(
        PENDING,
        "an unrecognised non-completed status keeps waiting",
        row(status="something_new", conclusion=None),
    )
    expect_verdict(SUCCEEDED, "completed/success", row(status="completed", conclusion="success"))
    for bad in ("failure", "cancelled", "timed_out", "startup_failure", "skipped", "stale", "neutral", "action_required"):
        expect_verdict(FAILED, f"completed/{bad}", row(status="completed", conclusion=bad))
    expect_verdict(
        UNKNOWN, "completed with no conclusion", row(status="completed", conclusion=None)
    )
    expect_verdict(UNKNOWN, "no status at all", row(status="", conclusion=""))

    # ── run selection ─────────────────────────────────────────────────────
    other = row(headBranch="main", status="completed", conclusion="success")
    if newest_matching([other], REF) is None:
        ok("a run on a DIFFERENT ref is never mistaken for ours")
    else:
        no("a run on a DIFFERENT ref is never mistaken for ours", "it matched")

    pushed = row(event="push", status="completed", conclusion="success")
    if newest_matching([pushed], REF) is None:
        ok("a non-dispatch run on the same ref is ignored")
    else:
        no("a non-dispatch run on the same ref is ignored", "it matched")

    older = row(createdAt="2026-09-13T09:00:00Z", status="completed", conclusion="failure")
    newer = row(createdAt="2026-09-13T11:00:00Z", status="completed", conclusion="success")
    picked = newest_matching([older, newer], REF)
    if picked is newer:
        ok("the newest matching run wins when a run was re-run")
    else:
        no("the newest matching run wins when a run was re-run", f"picked {picked}")

    # ── the budget loop ───────────────────────────────────────────────────
    class Clock:
        def __init__(self):
            self.t = 0.0

        def now(self):
            return self.t

        def sleep(self, seconds):
            self.t += seconds

    def drive(sequences, budget=1200, interval=30, after=_NO_BASELINE):
        """sequences: list of (rows|None, err) returned one per attempt; the last
        entry repeats forever. `after` is the pre-dispatch baseline run id; the
        sentinel means "call await_run the way a no-dispatch await does".
        """
        clock = Clock()
        calls = {"n": 0}

        def list_runs():
            i = min(calls["n"], len(sequences) - 1)
            calls["n"] += 1
            return sequences[i]

        kwargs = {}
        if after is not _NO_BASELINE:
            kwargs["after_run_id"] = after
        code = await_run(
            workflow="tag-go-modules.yml",
            ref=REF,
            budget_seconds=budget,
            interval_seconds=interval,
            list_runs=list_runs,
            sleep=clock.sleep,
            now=clock.now,
            log=log.append,
            **kwargs,
        )
        return code, calls["n"], clock.t

    code, calls, elapsed = drive([([row(status="completed", conclusion="success")], "")])
    if code == 0 and calls == 1 and elapsed == 0:
        ok("an already-successful run exits 0 on the first poll")
    else:
        no("an already-successful run exits 0 on the first poll", f"code={code} calls={calls} elapsed={elapsed}")

    code, calls, _ = drive(
        [
            ([], ""),
            ([row(status="queued", conclusion=None)], ""),
            ([row(status="in_progress", conclusion=None)], ""),
            ([row(status="completed", conclusion="success")], ""),
        ]
    )
    if code == 0 and calls == 4:
        ok("it waits through no-run -> queued -> in_progress -> success")
    else:
        no("it waits through no-run -> queued -> in_progress -> success", f"code={code} calls={calls}")

    code, calls, _ = drive(
        [
            ([row(status="in_progress", conclusion=None)], ""),
            ([row(status="completed", conclusion="failure")], ""),
        ]
    )
    if code == 1 and calls == 2:
        ok("a failed run fails FAST, without burning the budget")
    else:
        no("a failed run fails FAST, without burning the budget", f"code={code} calls={calls}")

    code, calls, elapsed = drive([([], "")], budget=300, interval=30)
    if code == 1 and elapsed >= 300 and calls == 11:
        ok("a run that never appears exhausts the budget and FAILS")
    else:
        no(
            "a run that never appears exhausts the budget and FAILS",
            f"code={code} calls={calls} elapsed={elapsed}",
        )

    code, _, _ = drive([(None, "gh: API rate limit exceeded")], budget=120, interval=30)
    if code == 1:
        ok("a gh that errors for the whole budget FAILS (never reads as success)")
    else:
        no("a gh that errors for the whole budget FAILS (never reads as success)", f"code={code}")

    code, calls, _ = drive(
        [
            (None, "gh: transient 502"),
            ([row(status="completed", conclusion="success")], ""),
        ]
    )
    if code == 0 and calls == 2:
        ok("a transient gh error is ridden out, not fatal")
    else:
        no("a transient gh error is ridden out, not fatal", f"code={code} calls={calls}")

    code, _, _ = drive(
        [([row(headBranch="main", status="completed", conclusion="success")], "")],
        budget=60,
        interval=30,
    )
    if code == 1:
        ok("a success on another ref does not end the wait")
    else:
        no("a success on another ref does not end the wait", f"code={code}")

    # ── the pre-dispatch baseline (#656) ──────────────────────────────────
    # A workflow_dispatch run may ALREADY exist on the channel tag when the
    # publishCmd dispatches: docs/RELEASE.md documents
    # `gh workflow run tag-go-modules.yml --ref go-modules/vX.Y.Z` as the manual
    # repair for a release whose tags never landed, and GitHub's re-run button
    # produces one too. GitHub creates the NEW run's row a few seconds AFTER
    # accepting the dispatch, so the first poll lands in a window where only the
    # OLD row exists — and a stale `success` there is indistinguishable from
    # "this release's six tags were cut". The only row that can answer for this
    # dispatch is one strictly newer than the newest one seen BEFORE it.
    STALE_ID = 100
    FRESH_ID = 200

    def idrow(run_id, **kw):
        return row(databaseId=run_id, url=f"https://example.invalid/run/{run_id}", **kw)

    stale_success = idrow(STALE_ID, status="completed", conclusion="success")
    fresh_failure = idrow(FRESH_ID, status="completed", conclusion="failure")
    fresh_success = idrow(FRESH_ID, status="completed", conclusion="success")

    baseline_fn = globals().get("baseline_run_id")
    supports_baseline = (
        "after_run_id" in inspect.signature(newest_matching).parameters
        and "after_run_id" in inspect.signature(await_run).parameters
        and callable(baseline_fn)
    )
    if not supports_baseline:
        no(
            "the poller demands a run strictly newer than the pre-dispatch baseline (#656)",
            "expected newest_matching(runs, ref, after_run_id=…), await_run(…, after_run_id=…)",
            "and a baseline_run_id() that records the newest existing run BEFORE --dispatch.",
            "Without them the first poll answers with whatever workflow_dispatch row already",
            "existed on that ref, so a stale SUCCESS is read as this release's tag cut and the",
            "fresh FAILURE is never seen.",
        )
    else:
        if newest_matching([stale_success], REF, after_run_id=STALE_ID) is None:
            ok("a run that is not strictly newer than the baseline is never ours")
        else:
            no(
                "a run that is not strictly newer than the baseline is never ours",
                "the run that existed BEFORE the dispatch matched",
            )

        picked = newest_matching([stale_success, fresh_failure], REF, after_run_id=STALE_ID)
        if picked is fresh_failure:
            ok("with a baseline, the strictly newer run is the one classified")
        else:
            no("with a baseline, the strictly newer run is the one classified", f"picked {picked}")

        if newest_matching([stale_success], REF) is stale_success:
            ok("with NO baseline (a dispatch-less await) the newest matching run still wins")
        else:
            no(
                "with NO baseline (a dispatch-less await) the newest matching run still wins",
                "the back-compatible path stopped matching",
            )

        idless = row(status="completed", conclusion="success")
        idless.pop("databaseId", None)
        if newest_matching([idless], REF, after_run_id=STALE_ID) is None:
            ok("a row with no databaseId cannot be ordered against the baseline, so it is not ours")
        else:
            no(
                "a row with no databaseId cannot be ordered against the baseline, so it is not ours",
                "an unorderable row matched",
            )

        code, calls, _ = drive(
            [([stale_success], ""), ([stale_success, fresh_failure], "")],
            after=STALE_ID,
        )
        if code == 1 and calls == 2:
            ok("a stale SUCCESS from before the dispatch does not mask the fresh FAILURE")
        else:
            no(
                "a stale SUCCESS from before the dispatch does not mask the fresh FAILURE",
                f"code={code} calls={calls} (code=0 means the pre-existing run answered for us)",
            )

        code, calls, elapsed = drive([([stale_success], "")], budget=300, interval=30, after=STALE_ID)
        if code == 1 and elapsed >= 300 and calls == 11:
            ok("a stale row and no new run exhausts the budget and FAILS honestly")
        else:
            no(
                "a stale row and no new run exhausts the budget and FAILS honestly",
                f"code={code} calls={calls} elapsed={elapsed}",
            )

        code, calls, _ = drive(
            [([stale_success], ""), ([stale_success, fresh_success], "")],
            after=STALE_ID,
        )
        if code == 0 and calls == 2:
            ok("the run the dispatch actually started is what ends the wait")
        else:
            no("the run the dispatch actually started is what ends the wait", f"code={code} calls={calls}")

        # ── capturing the baseline itself ─────────────────────────────────
        def capture(sequences, attempts=3):
            seen = {"n": 0}

            def list_runs():
                i = min(seen["n"], len(sequences) - 1)
                seen["n"] += 1
                return sequences[i]

            got = baseline_fn(
                ref=REF,
                list_runs=list_runs,
                attempts=attempts,
                interval_seconds=1,
                sleep=lambda _seconds: None,
                log=log.append,
            )
            return got, seen["n"]

        other_ref = row(
            headBranch="main", databaseId=999, status="completed", conclusion="success"
        )
        (found, run_id, _detail), _ = capture([([stale_success, other_ref], "")])
        if found and run_id == STALE_ID:
            ok("the baseline is the newest MATCHING run that existed before the dispatch")
        else:
            no(
                "the baseline is the newest MATCHING run that existed before the dispatch",
                f"found={found} run_id={run_id}",
            )

        (found, run_id, _detail), _ = capture([([], "")])
        if found and run_id is None:
            ok("no pre-existing run on the ref is itself a valid baseline")
        else:
            no("no pre-existing run on the ref is itself a valid baseline", f"found={found} run_id={run_id}")

        (found, _run_id, _detail), attempts_made = capture(
            [(None, "gh: API rate limit exceeded")], attempts=3
        )
        if not found and attempts_made == 3:
            ok("a baseline that cannot be established is NOT silently read as 'no prior run'")
        else:
            no(
                "a baseline that cannot be established is NOT silently read as 'no prior run'",
                f"found={found} attempts={attempts_made}",
            )

    total = passed + failed
    MIN = 15
    if total < MIN:
        print(
            f"::error::awaited-dispatch poller self-test ran {total} cases, expected at "
            f"least {MIN} — the sweep itself is broken"
        )
        return 1
    print(f"Results: {passed} passed, {failed} failed, {total} total")
    return 0 if failed == 0 else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", help="workflow file name, e.g. tag-go-modules.yml")
    parser.add_argument("--ref", help="the git ref the run was dispatched on")
    parser.add_argument(
        "--dispatch",
        action="store_true",
        help="run `gh workflow run <workflow> --ref <ref>` first, then await it",
    )
    parser.add_argument("--budget-seconds", type=int, default=None)
    parser.add_argument("--interval-seconds", type=int, default=None)
    parser.add_argument("--limit", type=int, default=50, help="run rows to fetch per poll")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.workflow or not args.ref:
        parser.error("--workflow and --ref are required (or pass --self-test)")

    budget = args.budget_seconds or _positive_int(_BUDGET_ENV, DEFAULT_BUDGET_SECONDS)
    interval = args.interval_seconds or _positive_int(_INTERVAL_ENV, DEFAULT_INTERVAL_SECONDS)

    def log(message):
        print(message, flush=True)

    if args.dispatch:
        log(f"Dispatching {args.workflow} at {args.ref} …")
        code, out, err = _run_gh(["workflow", "run", args.workflow, "--ref", args.ref])
        if out.strip():
            log(out.strip())
        if code != 0:
            log(
                f"::error::`gh workflow run {args.workflow} --ref {args.ref}` failed "
                f"(exit {code}): {(err or out).strip()}"
            )
            return 1

    log(
        f"Awaiting the {args.workflow} run at {args.ref} "
        f"(budget {budget}s, polling every {interval}s) …"
    )
    return await_run(
        workflow=args.workflow,
        ref=args.ref,
        budget_seconds=budget,
        interval_seconds=interval,
        list_runs=_live_list_runs(args.workflow, args.limit),
        sleep=time.sleep,
        now=time.monotonic,
        log=log,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
