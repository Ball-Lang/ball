#!/usr/bin/env node
// Compute the next repo release (version + notes) WITHOUT publishing anything
// (issue #755 — "release via auto-merged PR").
//
// WHY THIS EXISTS: the old `release.yml` ran `npx semantic-release` for real
// against `main`. Its core `run()` function unconditionally pushes the
// version-bump commit and the new tag to the checked-out branch once a
// release is determined (see upstream index.js — this is CORE behavior, not
// a plugin, so no plugin list can suppress it). The `Protect main` ruleset
// (17056238) added on 2026-09-13 rejects that raw push with GH013
// ("19 of 19 required status checks are expected"), so every push to `main`
// since then has failed this step and silently skipped every downstream
// dispatch (npm/C++/Go/pub.dev).
//
// The new shape never lets semantic-release push to `main` at all. This
// script runs it in **dry-run** mode via its documented JS API
// (https://github.com/semantic-release/semantic-release — `export default
// async (options, {cwd, env, stdout, stderr}) => Result`). In dry-run mode,
// per upstream lib/definitions/plugins.js, the `prepare`/`publish`/
// `addChannel`/`success`/`fail` steps are skipped entirely (`dryRun: false`
// on each) — no commit, no tag, no push, no GitHub release — while
// `verifyConditions`/`analyzeCommits`/`verifyRelease`/`generateNotes` still
// run (`dryRun: true`), so `nextRelease.{version,notes,gitTag}` is computed
// for real.
//
// The ONE core side effect that is NOT plugin-gated is `verifyAuth()`
// (upstream lib/git.js), which runs a `git push --dry-run --no-verify`
// against the configured branch before anything else. This was verified
// empirically against the live `Protect main` ruleset (required status
// checks + non-fast-forward, no bypass) on 2026-10-17: a `--dry-run` push
// reports the would-be fast-forward update and exits 0 — GitHub's ruleset
// enforcement is NOT evaluated for a push that never actually updates the
// ref. So this script runs cleanly against the real protected branch and
// never needs a bypass.
//
// Usage:
//   node tools/release/compute_next_release.mjs > /tmp/next_release.json
//
// Output (stdout, the ONLY thing printed on the last line — everything else
// semantic-release itself logs goes to this process's stderr): a single JSON
// line, either:
//   {"release": false}
// or
//   {"release": true, "version": "1.73.0", "notes": "...", "gitTag": "v1.73.0"}
import semanticRelease from "semantic-release";

const result = await semanticRelease(
  { dryRun: true },
  { cwd: process.cwd(), env: process.env, stdout: process.stderr, stderr: process.stderr }
);

if (!result || !result.nextRelease) {
  process.stdout.write(`${JSON.stringify({ release: false })}\n`);
} else {
  const { version, notes, gitTag } = result.nextRelease;
  process.stdout.write(
    `${JSON.stringify({ release: true, version, notes: notes ?? "", gitTag })}\n`
  );
}
