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

import { prependChangelogEntry } from "../lib/changelog_entry.mjs";
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
