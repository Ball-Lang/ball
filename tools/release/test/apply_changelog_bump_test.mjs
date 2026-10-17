// Self-test for tools/release/apply_changelog_bump.mjs (issue #879). Zero
// dependencies — runs with the Node 22 built-in test runner:
//
//   node --test tools/release/test/apply_changelog_bump_test.mjs
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { applyChangelogBump } from "../apply_changelog_bump.mjs";

test("applyChangelogBump: writes nothing when release is false", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "ball-changelog-bump-"));
  try {
    const written = await applyChangelogBump(dir, "go/CHANGELOG.md", { release: false });
    assert.equal(written, null);
    await assert.rejects(readFile(path.join(dir, "go/CHANGELOG.md")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("applyChangelogBump: creates the file under a nested path that does not exist yet", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "ball-changelog-bump-"));
  try {
    const notes = "## go v0.3.0\n\n### Features\n\n* a thing\n";
    const written = await applyChangelogBump(dir, "go/CHANGELOG.md", { release: true, notes });
    assert.equal(written, path.join(dir, "go/CHANGELOG.md"));
    const content = await readFile(written, "utf8");
    assert.equal(content, notes);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("applyChangelogBump: prepends above existing content at that path", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "ball-changelog-bump-"));
  try {
    const rel = "dart/shared/CHANGELOG.md";
    const full = path.join(dir, rel);
    await mkdir(path.dirname(full), { recursive: true });
    await writeFile(full, "## ball_base v0.3.0\n\n* old\n");

    const written = await applyChangelogBump(dir, rel, {
      release: true,
      notes: "## ball_base v0.4.0\n\n* new\n",
    });
    const content = await readFile(written, "utf8");
    assert.equal(content, "## ball_base v0.4.0\n\n* new\n\n## ball_base v0.3.0\n\n* old\n");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
