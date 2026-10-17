// Pure helper: prepend a semantic-release notes block to CHANGELOG.md the
// same way @semantic-release/changelog's `prepare` step does (issue #755).
//
// WHY THIS EXISTS: the root release line used to let @semantic-release/git
// push its CHANGELOG.md/package.json bump commit straight to `main`, which the
// `Protect main` ruleset (17056238) rejects outright (GH013 — 19 required
// status checks). The new shape (tools/release/open_release_pr.sh) computes
// `nextRelease` via a semantic-release DRY RUN (prepare/publish never run in
// dry mode — see lib/definitions/plugins.js upstream) and then has to apply
// the exact same file edits @semantic-release/changelog's `prepare` plugin
// would have applied, itself, before committing them to a release branch.
//
// This function is lifted byte-for-byte from the upstream algorithm
// (semantic-release/changelog lib/prepare.js, no `changelogTitle` configured
// here — see .releaserc.json) so the rendered CHANGELOG.md is identical to
// what the old direct-push flow produced. Keep it in lockstep if that
// package's prepare.js ever changes shape.
//
// @param {string} currentContent - the current CHANGELOG.md contents (or "").
// @param {string} notes - `nextRelease.notes` from semantic-release.
// @returns {string} the new CHANGELOG.md contents.
export function prependChangelogEntry(currentContent, notes) {
  const trimmedNotes = (notes ?? "").trim();
  if (!trimmedNotes) {
    // @semantic-release/changelog's prepare.js is a no-op when `notes` is
    // falsy — never truncate an existing file over an empty release note.
    return currentContent ?? "";
  }

  const trimmedCurrent = (currentContent ?? "").trim();
  return `${trimmedNotes}\n${trimmedCurrent ? `\n${trimmedCurrent}\n` : ""}`;
}

// The INVERSE of prependChangelogEntry (issue #923): given a changelog's
// contents before and after ONE release's prepend, return the entry that
// release added — which is exactly `nextRelease.notes`, trimmed — or "" when
// it added none.
//
// WHY THIS EXISTS: tools/release/finish_release.sh / finish_go_release.sh used
// to read a release's GitHub Release notes back out of the landed release
// commit's BODY (`git log -1 --format=%b`). Since `main` squash-merges with
// `squash_merge_commit_message: BLANK` (issue #881) every commit body on
// `main` is empty, so those notes went silently blank. The changelog entry is
// the same bytes, and it lives in the commit's TREE, which no squash setting
// can drop. See tools/release/release_notes_from_changelog.mjs.
//
// Throws when `after` is not `before` with something prepended at a line
// boundary: then which part is "this release's notes" would be a guess, and a
// guess published as a GitHub Release is the same silent wrongness #923 is
// about, just with words in it.
//
// @param {string} before - the changelog at the release commit's parent ("" if absent).
// @param {string} after - the changelog at the release commit.
// @returns {string} the trimmed entry the release prepended ("" if none).
export function extractPrependedChangelogEntry(before, after) {
  const previous = (before ?? "").trim();
  const current = (after ?? "").trim();
  if (!previous) {
    return current;
  }
  if (!current.endsWith(previous)) {
    throw new Error(
      "the changelog after this release does not END with the changelog before it, so the " +
        "release did not just prepend an entry (prependChangelogEntry's only edit) and its notes " +
        "cannot be told apart from the rest of the file"
    );
  }
  const added = current.slice(0, current.length - previous.length);
  if (added !== "" && !added.endsWith("\n")) {
    throw new Error(
      "the changelog's previous contents re-appear mid-line after this release, so whatever the " +
        "release changed is not a prepended entry"
    );
  }
  return added.trim();
}
