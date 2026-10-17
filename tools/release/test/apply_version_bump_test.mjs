// Self-test for tools/release/apply_version_bump.mjs (issue #755).
// Zero dependencies — runs with the Node 22 built-in test runner:
//
//   node --test tools/release/test/apply_version_bump_test.mjs
//
// Exercises applyVersionBump() against a throwaway temp directory shaped like
// the real repo's release assets (CHANGELOG.md + the four ts/*/package.json
// files) — it never touches the real repo tree.
import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { applyVersionBump, NPM_PACKAGE_ROOTS } from "../apply_version_bump.mjs";

async function makeFixtureRepo() {
  const root = await mkdtemp(path.join(os.tmpdir(), "ball-release-pr-"));
  await writeFile(path.join(root, "CHANGELOG.md"), "## [1.72.6](url) (2026-09-13)\n\n* old thing\n");
  for (const pkgRoot of NPM_PACKAGE_ROOTS) {
    await mkdir(path.join(root, pkgRoot), { recursive: true });
    await writeFile(
      path.join(root, pkgRoot, "package.json"),
      `{\n  "name": "@ball-lang/${path.basename(pkgRoot)}",\n  "version": "1.72.6"\n}\n`
    );
  }
  return root;
}

test("applyVersionBump: no-ops and touches nothing when release is false", async () => {
  const root = await makeFixtureRepo();
  try {
    const before = await readFile(path.join(root, "CHANGELOG.md"), "utf8");
    const written = await applyVersionBump(root, { release: false });
    assert.deepEqual(written, []);
    const after = await readFile(path.join(root, "CHANGELOG.md"), "utf8");
    assert.equal(after, before);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("applyVersionBump: writes CHANGELOG.md and bumps all four ts/*/package.json in lockstep", async () => {
  const root = await makeFixtureRepo();
  try {
    const notes = "## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing\n";
    const written = await applyVersionBump(root, { release: true, version: "1.73.0", notes });
    assert.equal(written.length, 1 + NPM_PACKAGE_ROOTS.length);

    const changelog = await readFile(path.join(root, "CHANGELOG.md"), "utf8");
    assert.equal(
      changelog,
      "## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing\n\n## [1.72.6](url) (2026-09-13)\n\n* old thing\n"
    );

    for (const pkgRoot of NPM_PACKAGE_ROOTS) {
      const pkg = JSON.parse(await readFile(path.join(root, pkgRoot, "package.json"), "utf8"));
      assert.equal(pkg.version, "1.73.0", `${pkgRoot}/package.json must be bumped`);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("applyVersionBump: release:true with no version fails loud", async () => {
  const root = await makeFixtureRepo();
  try {
    await assert.rejects(() => applyVersionBump(root, { release: true, notes: "x" }), /with no version/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
