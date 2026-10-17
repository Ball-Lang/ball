#!/usr/bin/env node
// Apply a computed next-release's file edits locally — the prepare-phase
// side effects @semantic-release/changelog + the four @semantic-release/npm
// entries would have made — WITHOUT running semantic-release for real
// (issue #755). Part of the release-via-PR rewrite: these edits are
// committed to a release BRANCH (tools/release/open_release_pr.sh), never
// pushed straight to `main`.
//
// The file list mirrors .releaserc.json's `@semantic-release/git` `assets`
// and the four `@semantic-release/npm` `pkgRoot` entries exactly — keep both
// lists in lockstep; tools/release/check_release_pr_wiring.sh asserts it.
//
// Usage:
//   node tools/release/compute_next_release.mjs > next_release.json
//   node tools/release/apply_version_bump.mjs next_release.json
//
// Exits 0 and touches nothing when next_release.json says `{"release": false}`.
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { prependChangelogEntry } from "./lib/changelog_entry.mjs";
import { bumpPackageJsonVersion } from "./lib/bump_package_version.mjs";

// The file list mirrors .releaserc.json's `@semantic-release/git` `assets`
// and the four `@semantic-release/npm` `pkgRoot` entries exactly — keep both
// lists in lockstep; tools/release/check_release_pr_wiring.sh asserts it.
export const NPM_PACKAGE_ROOTS = ["ts/engine", "ts/cli", "ts/compiler", "ts/encoder"];

/**
 * Apply one computed next-release's file edits under `repoRoot`.
 * @param {string} repoRoot - absolute path to the repo root.
 * @param {{release: boolean, version?: string, notes?: string}} nextRelease
 * @returns {Promise<string[]>} the list of files that were written (empty when
 *   `nextRelease.release` is false).
 */
export async function applyVersionBump(repoRoot, nextRelease) {
  if (!nextRelease.release) {
    return [];
  }

  const { version, notes } = nextRelease;
  if (!version) {
    throw new Error("applyVersionBump: release:true with no version");
  }

  const written = [];
  const changelogPath = path.join(repoRoot, "CHANGELOG.md");
  let currentChangelog = "";
  try {
    currentChangelog = await readFile(changelogPath, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  await writeFile(changelogPath, prependChangelogEntry(currentChangelog, notes));
  written.push(changelogPath);

  for (const pkgRoot of NPM_PACKAGE_ROOTS) {
    const pkgPath = path.join(repoRoot, pkgRoot, "package.json");
    const before = await readFile(pkgPath, "utf8");
    await writeFile(pkgPath, bumpPackageJsonVersion(before, version));
    written.push(pkgPath);
  }

  return written;
}

async function main() {
  const inputPath = process.argv[2];
  if (!inputPath) {
    console.error("usage: apply_version_bump.mjs <next_release.json>");
    process.exit(2);
  }

  const repoRoot = path.resolve(import.meta.dirname, "..", "..");
  const nextRelease = JSON.parse(await readFile(inputPath, "utf8"));
  const written = await applyVersionBump(repoRoot, nextRelease);
  if (written.length === 0) {
    console.error("apply_version_bump: nothing to release, touching no files");
  } else {
    for (const file of written) console.error(`apply_version_bump: wrote ${file}`);
  }
}

// Only run the CLI entry point when this module is the one invoked directly
// (`node apply_version_bump.mjs …`), never when imported by a test.
if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
