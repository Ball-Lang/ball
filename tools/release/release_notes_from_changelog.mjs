#!/usr/bin/env node
// Print the release notes a release-PR merge commit carries: the entry that
// commit prepended to its lane's changelog (issue #923).
//
// Usage (from the repo root, which both finish scripts `cd` into first):
//   node tools/release/release_notes_from_changelog.mjs <commit> <changelog-path>
//   node tools/release/release_notes_from_changelog.mjs "$COMMIT_SHA" CHANGELOG.md
//   node tools/release/release_notes_from_changelog.mjs "$COMMIT_SHA" go/CHANGELOG.md
//
// Exits 0 and prints the (non-empty) notes, or exits 1 with the reason on
// stderr. There is NO fallback that prints nothing: an empty answer is the
// failure this script exists to make loud.
//
// WHERE THE NOTES COME FROM, AND WHY THERE (the #923 design decision)
// -------------------------------------------------------------------
// Phase 1 (tools/release/open_release_pr.sh, open_go_release_pr.sh) computes
// `nextRelease.notes` with a semantic-release dry run and commits them TWICE:
// as the release commit's message body, and as the entry
// tools/release/lib/changelog_entry.mjs's prependChangelogEntry writes at the
// top of the lane's changelog. Phase 2 (finish_release.sh,
// finish_go_release.sh) used to read the first copy back with
// `git log -1 --format=%b`. `main` now squash-merges with
// `squash_merge_commit_title: PR_TITLE` + `squash_merge_commit_message: BLANK`
// (issue #881), so the body never reaches `main` and every GitHub Release
// would have shipped with no notes, green.
//
// The three sources that still reach `main` were weighed:
//   1. The changelog entry in the merged commit's TREE (chosen). A squash
//      setting can rewrite a commit's message but never its tree, so this is
//      immune to any future change of those settings by construction. It is
//      byte-for-byte the `nextRelease.notes` the old @semantic-release/github
//      step published, it was reviewed as part of the release PR's diff, and
//      reading it is offline and deterministic — no API call, no token scope,
//      no extra toolchain in the finish job.
//   2. The merged release PR's own body, through the GitHub API. Rejected: it
//      needs a commit -> PR lookup (the bare `chore(release): X` subject the
//      finish scripts also accept carries no `(#N)` to read it from), and the
//      GitHub token and API availability become release-blocking for a read
//      that git can answer locally. The body also wraps the notes in a
//      prose preamble that would have to be split off by a delimiter, and it
//      stays editable after the merge, so the published notes would be
//      whatever the body says at tag time rather than what was reviewed.
//   3. Recomputing the notes with semantic-release at tag time. Rejected: the
//      finish job runs later than the merge, on whatever `main` is by then (a
//      gap commit can land first — finish_release.sh's header), so the
//      recomputation would need a second, separately-pinned checkout of the
//      release commit's parent, plus the whole semantic-release toolchain in a
//      job that today needs none of it. It would also be a second computation
//      that can disagree with the first one the PR committed.
//
// The entry is recovered by diffing the changelog at <commit> against its
// first parent (extractPrependedChangelogEntry, the inverse of the prepend),
// not by parsing version headings — so it does not depend on the preset's
// heading format, which the conventionalcommits switch (also #923) changed.
import { execFileSync } from "node:child_process";
import process from "node:process";

import { extractPrependedChangelogEntry } from "./lib/changelog_entry.mjs";

const NAME = "release_notes_from_changelog";

function fail(message) {
  console.error(`${NAME}: ${message}`);
  process.exit(1);
}

/** Run git in the current directory; any failure throws (never swallowed). */
function git(args) {
  return execFileSync("git", args, {
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/**
 * The file's contents in `commit`'s tree, or null when that tree has no such
 * path. Absence is decided by `git ls-tree` (an empty listing), so a git
 * failure is an exception, never mistaken for "the file is not there".
 */
function fileAt(commit, path) {
  const listed = git(["ls-tree", "--name-only", commit, "--", path]).trim();
  if (listed === "") return null;
  return git(["show", `${commit}:${path}`]);
}

const [commitArg, changelogPath] = process.argv.slice(2);
if (!commitArg || !changelogPath) {
  console.error(`usage: ${NAME}.mjs <commit> <changelog-path>`);
  process.exit(2);
}

let notes;
try {
  const commit = git(["rev-parse", "--verify", `${commitArg}^{commit}`]).trim();
  const after = fileAt(commit, changelogPath);
  if (after === null) {
    fail(
      `release commit ${commit} has no ${changelogPath} at all, so it carries no release notes ` +
        "(the release PR's commit is what prepends them there)"
    );
  }
  // `rev-list --parents` prints "<commit> [<parent>...]"; a root commit has none.
  const [, firstParent] = git(["rev-list", "--parents", "-n", "1", commit]).trim().split(/\s+/);
  const before = firstParent ? (fileAt(firstParent, changelogPath) ?? "") : "";
  notes = extractPrependedChangelogEntry(before, after);
  if (!notes) {
    fail(
      `release commit ${commit} adds no entry to ${changelogPath}, so there are no release notes ` +
        "to publish. The release PR's commit must prepend this release's notes there " +
        "(open_release_pr.sh / open_go_release_pr.sh)"
    );
  }
} catch (error) {
  fail(`cannot read the release notes from ${changelogPath} at ${commitArg}: ${error.message}`);
}

process.stdout.write(`${notes}\n`);
