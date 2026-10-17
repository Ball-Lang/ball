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
