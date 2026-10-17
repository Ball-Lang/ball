// Self-test for tools/release/lib/{changelog_entry,bump_package_version}.mjs
// (issue #755). Zero dependencies — runs with the Node 22 built-in test
// runner, no `npm install` required:
//
//   node --test tools/release/test/release_pr_lib_test.mjs
//
// This is the RED evidence for the release-via-PR rewrite: both helpers are
// new, and this file fails to even resolve its imports before they exist.
import assert from "node:assert/strict";
import test from "node:test";

import { extractPrependedChangelogEntry, prependChangelogEntry } from "../lib/changelog_entry.mjs";
import { bumpPackageJsonVersion } from "../lib/bump_package_version.mjs";

test("prependChangelogEntry: prepends above existing content with one blank line between", () => {
  const current = "## [1.72.6](url) (2026-09-13)\n\n### Bug Fixes\n\n* old thing\n";
  const notes = "## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing\n";
  const result = prependChangelogEntry(current, notes);
  assert.equal(
    result,
    "## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing\n\n## [1.72.6](url) (2026-09-13)\n\n### Bug Fixes\n\n* old thing\n"
  );
});

test("prependChangelogEntry: writes just the trimmed notes when the file was empty", () => {
  const result = prependChangelogEntry("", "## [1.0.0](url) (2026-10-17)\n\n* first release\n");
  assert.equal(result, "## [1.0.0](url) (2026-10-17)\n\n* first release\n");
});

test("prependChangelogEntry: never truncates existing content on an empty/falsy notes", () => {
  const current = "## [1.72.6](url) (2026-09-13)\n\n* old thing\n";
  assert.equal(prependChangelogEntry(current, ""), current);
  assert.equal(prependChangelogEntry(current, undefined), current);
  assert.equal(prependChangelogEntry(current, "   \n  "), current);
});

// ── extractPrependedChangelogEntry (issue #923) ──────────────────────────
// The finish scripts publish THIS as the GitHub Release's notes, now that the
// release commit's body (`squash_merge_commit_message: BLANK`) is always
// empty. It must be the exact inverse of the prepend the release PR made.

const OLDER = "## [1.72.6](url) (2026-09-13)\n\n### Bug Fixes\n\n* old thing\n";
const NOTES = "## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing\n";

test("extractPrependedChangelogEntry: round-trips prependChangelogEntry over an existing changelog", () => {
  const after = prependChangelogEntry(OLDER, NOTES);
  assert.equal(extractPrependedChangelogEntry(OLDER, after), NOTES.trim());
});

test("extractPrependedChangelogEntry: the first entry of a brand-new changelog is the whole file", () => {
  const after = prependChangelogEntry("", NOTES);
  assert.equal(extractPrependedChangelogEntry("", after), NOTES.trim());
  assert.equal(extractPrependedChangelogEntry(undefined, after), NOTES.trim());
});

test("extractPrependedChangelogEntry: returns ONLY the newest entry, never the older ones", () => {
  const twoReleases = prependChangelogEntry(prependChangelogEntry("", OLDER), NOTES);
  const entry = extractPrependedChangelogEntry(prependChangelogEntry("", OLDER), twoReleases);
  assert.equal(entry, NOTES.trim());
  assert.ok(!entry.includes("1.72.6"), "an older entry leaked into the notes");
});

test("extractPrependedChangelogEntry: is heading-format agnostic (angular '#'/'##' or conventionalcommits)", () => {
  // The conventionalcommits preset switch (#923) changes the heading shape; the
  // diff-based inverse must not care, so a minor release's '#' heading and an
  // arbitrary first line both survive unchanged.
  for (const notes of ["# [2.0.0](url) (2026-10-17)\n\n### ⚠ BREAKING CHANGES\n\n* gone", "anything at all\n* x"]) {
    assert.equal(extractPrependedChangelogEntry(OLDER, prependChangelogEntry(OLDER, notes)), notes.trim());
  }
});

test("extractPrependedChangelogEntry: a release that added no entry yields '' (the caller fails loud)", () => {
  assert.equal(extractPrependedChangelogEntry(OLDER, OLDER), "");
  // prependChangelogEntry is a no-op on empty notes, so this is the shape an
  // empty `nextRelease.notes` would actually leave behind.
  assert.equal(extractPrependedChangelogEntry(OLDER, prependChangelogEntry(OLDER, "  \n")), "");
  assert.equal(extractPrependedChangelogEntry("", ""), "");
});

test("extractPrependedChangelogEntry: refuses to guess when the change is not a pure prepend", () => {
  // An older entry was rewritten in the same commit: the old file is no longer
  // the new file's tail, so no slice of it is reliably "this release's notes".
  const rewritten = `${NOTES}\n${OLDER.replace("old thing", "edited thing")}`;
  assert.throws(() => extractPrependedChangelogEntry(OLDER, rewritten), /does not END with/);
  // Appended at the bottom instead of the top.
  assert.throws(() => extractPrependedChangelogEntry(OLDER, `${OLDER}\n${NOTES}`), /does not END with/);
});

test("extractPrependedChangelogEntry: refuses a match that starts mid-line", () => {
  // "...thingthing" ends with "thing", but not at a line boundary.
  assert.throws(() => extractPrependedChangelogEntry("thing", "* new thing"), /mid-line/);
});

test("bumpPackageJsonVersion: rewrites only the top-level version field", () => {
  const before = [
    "{",
    '  "name": "@ball-lang/engine",',
    '  "version": "1.72.6",',
    '  "devDependencies": {',
    '    "@types/node": "^26.0.1"',
    "  }",
    "}",
    "",
  ].join("\n");
  const after = bumpPackageJsonVersion(before, "1.73.0");
  assert.equal(
    after,
    [
      "{",
      '  "name": "@ball-lang/engine",',
      '  "version": "1.73.0",',
      '  "devDependencies": {',
      '    "@types/node": "^26.0.1"',
      "  }",
      "}",
      "",
    ].join("\n")
  );
  // Byte-for-byte elsewhere: diffing before/after line-by-line except the
  // version line itself.
  const beforeLines = before.split("\n");
  const afterLines = after.split("\n");
  assert.equal(beforeLines.length, afterLines.length);
  for (let i = 0; i < beforeLines.length; i++) {
    if (i === 2) continue; // the version line, deliberately different
    assert.equal(afterLines[i], beforeLines[i], `line ${i} must be untouched`);
  }
});

test("bumpPackageJsonVersion: fails loud when there is no top-level version field", () => {
  assert.throws(() => bumpPackageJsonVersion('{\n  "name": "x"\n}\n', "1.0.0"), /no top-level "version" field/);
});

test("bumpPackageJsonVersion: does not touch a nested dependency range named like a version", () => {
  // Negative control: a package.json whose ONLY "version"-shaped text is a
  // dependency range must not be mistaken for the top-level field.
  const before = ['{', '  "name": "x",', '  "dependencies": {', '    "semver": "^7.0.0"', "  }", "}", ""].join("\n");
  assert.throws(() => bumpPackageJsonVersion(before, "1.0.0"), /no top-level "version" field/);
});
