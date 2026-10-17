#!/usr/bin/env node
// Apply ONE changelog-prepend edit — the prepare-phase side effect
// @semantic-release/changelog's `prepare.js` would have made — WITHOUT
// running semantic-release for real (issue #879, the go-release.yml /
// pubdev-release.yml sibling of tools/release/apply_version_bump.mjs, which
// only ever touched the ROOT CHANGELOG.md + the four npm package.json files).
//
// Every per-line release config in .github/release/ (go.releaserc.json, each
// ball_*.releaserc.json) runs `@semantic-release/changelog` against its OWN
// changelogFile. Rather than hardcode N file paths into N near-duplicates of
// apply_version_bump.mjs, this takes the target path as an argument and is
// shared by tools/release/open_go_release_pr.sh and the pub.dev per-package
// loop (tools/release/open_pubdev_release_pr.sh).
//
// Usage:
//   node tools/release/compute_next_release.mjs > next_release.json   # (or
//     the go/pub.dev equivalent — any {release,version,notes} shape works)
//   node tools/release/apply_changelog_bump.mjs <changelog-rel-path> next_release.json
//
// Exits 0 and touches nothing when next_release.json says `{"release": false}`.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { prependChangelogEntry } from "./lib/changelog_entry.mjs";

/**
 * @param {string} repoRoot - absolute path to the repo root.
 * @param {string} changelogRelPath - e.g. "go/CHANGELOG.md", "dart/shared/CHANGELOG.md".
 * @param {{release: boolean, notes?: string}} nextRelease
 * @returns {Promise<string|null>} the absolute path written, or null when
 *   nextRelease.release is false.
 */
export async function applyChangelogBump(repoRoot, changelogRelPath, nextRelease) {
  if (!nextRelease.release) {
    return null;
  }

  const changelogPath = path.join(repoRoot, changelogRelPath);
  let currentChangelog = "";
  try {
    currentChangelog = await readFile(changelogPath, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  await mkdir(path.dirname(changelogPath), { recursive: true });
  await writeFile(changelogPath, prependChangelogEntry(currentChangelog, nextRelease.notes));
  return changelogPath;
}

async function main() {
  const [changelogRelPath, inputPath] = process.argv.slice(2);
  if (!changelogRelPath || !inputPath) {
    console.error("usage: apply_changelog_bump.mjs <changelog-rel-path> <next_release.json>");
    process.exit(2);
  }

  const repoRoot = path.resolve(import.meta.dirname, "..", "..");
  const nextRelease = JSON.parse(await readFile(inputPath, "utf8"));
  const written = await applyChangelogBump(repoRoot, changelogRelPath, nextRelease);
  if (!written) {
    console.error("apply_changelog_bump: nothing to release, touching no files");
  } else {
    console.error(`apply_changelog_bump: wrote ${written}`);
  }
}

// Only run the CLI entry point when this module is the one invoked directly
// (`node apply_changelog_bump.mjs …`), never when imported by a test.
if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
