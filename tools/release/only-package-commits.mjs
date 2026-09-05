// Local semantic-release plugin: path-based commit filtering for the
// per-package release matrix (issue #-release-unification, docs/RELEASE.md).
//
// WHY THIS EXISTS
// ---------------
// Ball is a polyglot monorepo (pub.dev + npm + crates.io) with NO root
// package.json, so the usual monorepo runners do not fit:
//   - @qiwi/multi-semantic-release discovers packages only via npm `workspaces`
//     in a root package.json (can't see dart/ or rust/).
//   - semantic-release-monorepo path-filters correctly but hard-requires a
//     package.json up-tree from each package (pkg-up + read-pkg), which the
//     Dart/Rust trees do not have.
// The commit *scopes* in this repo are language/component-level
// (`feat(cpp)`, `fix(rust-compiler)`), never package names, so scope-based
// filtering cannot tell ball_engine from ball_compiler. Path-based filtering —
// which files a commit actually touched — is the only precise model.
//
// WHAT IT DOES
// ------------
// This is a self-contained re-implementation of semantic-release-monorepo's
// `withOnlyPackageCommits` decorator (same git mechanics, no package.json
// dependency): it exports the `analyzeCommits` and `generateNotes` lifecycle
// steps, each of which filters `context.commits` down to the commits that
// touched this package's paths and then delegates to the REAL
// @semantic-release/commit-analyzer / @semantic-release/release-notes-generator
// with the filtered commit list. Wrapping (rather than mutating the shared
// context in an earlier plugin) is the supported mechanism — the exact pattern
// semantic-release-plugin-decorators / semantic-release-monorepo use — because
// semantic-release does not document cross-plugin context.commits mutation.
//
// Sources verified against current upstream (2026-07):
//   - filter/git mechanics: semantic-release-monorepo src/only-package-commits.js
//     + src/git-utils.js  (`git diff-tree --root --no-commit-id --name-only -r <hash>`,
//     segment-prefix match `pkgSegments.every((s,i) => s === fileSegments[i])`).
//   - lifecycle step signatures `(pluginConfig, context)` and the fact that
//     analyzeCommits/generateNotes named exports exist on the two analyzers:
//     semantic-release/commit-analyzer + release-notes-generator index.js.
//
// CONFIG
// ------
//   ["./tools/release/only-package-commits.mjs", {
//     "paths": ["dart/engine"],            // repo-relative roots for this package
//     "commitAnalyzer": { ... },           // optional: forwarded to commit-analyzer
//     "releaseNotesGenerator": { ... }     // optional: forwarded to release-notes-generator
//   }]
// `paths` may also be supplied via the SR_PKG_PATHS env var (comma-separated);
// an explicit `paths` in the config wins. A commit is kept when ANY of its
// changed files sits at or under ANY configured root.
//
// LOCKSTEP OVERRIDE (SR_FORCE_RELEASE, issue #566)
// -----------------------------------------------
// A package that this filter finds no releasable commits for is normally not
// released — and that is exactly right for a package nothing touched. It is
// WRONG for a package the release loop's workspace-wide sibling sweep left
// behind: its pubspec in the repo now pins a sibling version that its PUBLISHED
// pubspec does not admit, so pub.dev keeps serving an unsolvable graph
// (`ball_resolver 0.3.0+3` requiring `ball_base ^0.3.0+3` while ball_base is
// live at 0.4.0). `tools/release/lockstep_plan.mjs --decide` computes exactly
// which packages are in that state, and `pubdev-release.yml` passes its verdict
// in as SR_FORCE_RELEASE for that one semantic-release invocation.
//
// The override only ever PROMOTES a no-release verdict to the given level; a
// real analyzer verdict always wins, so a genuine `feat` still cuts a minor.
// An unrecognised value throws rather than being ignored: a typo that silently
// disabled the lockstep rule would reproduce #566 with a guard in place.

import { execFileSync } from 'node:child_process';
import { analyzeCommits as commitAnalyzer } from '@semantic-release/commit-analyzer';
import { generateNotes as releaseNotesGenerator } from '@semantic-release/release-notes-generator';

/** Repo-relative roots for this package, from config `paths` or SR_PKG_PATHS. */
function resolvePaths(pluginConfig) {
  const fromConfig = pluginConfig && pluginConfig.paths;
  if (Array.isArray(fromConfig) && fromConfig.length > 0) return fromConfig;
  const env = process.env.SR_PKG_PATHS;
  if (env && env.trim() !== '') {
    return env
      .split(',')
      .map((p) => p.trim())
      .filter((p) => p !== '');
  }
  throw new Error(
    'only-package-commits: no package paths configured. Set `paths` in the ' +
      'plugin config or the SR_PKG_PATHS env var (comma-separated).',
  );
}

/** git uses forward slashes in diff-tree output on every platform. */
function toSegments(p) {
  return p.replace(/^[./]+/, '').replace(/\/+$/, '').split('/').filter((s) => s !== '');
}

// Cache files-per-commit across the two lifecycle hooks (analyzeCommits +
// generateNotes) so `git diff-tree` runs at most once per commit per release —
// mirrors semantic-release-monorepo's memoizeWith(identity, getCommitFiles).
const filesCache = new Map();

/** Files touched by a single commit (`--root` so the initial commit counts). */
function commitFiles(hash, cwd) {
  if (filesCache.has(hash)) return filesCache.get(hash);
  const files = readCommitFiles(hash, cwd);
  filesCache.set(hash, files);
  return files;
}

function readCommitFiles(hash, cwd) {
  try {
    const out = execFileSync(
      'git',
      ['diff-tree', '--root', '--no-commit-id', '--name-only', '-r', hash],
      { cwd, encoding: 'utf8' },
    );
    return out.split('\n').filter((l) => l.trim() !== '');
  } catch {
    // Missing history (shallow clone) or a bad hash: treat as touching nothing
    // so the commit is excluded rather than crashing the release run. CI checks
    // out with fetch-depth: 0, so this is only a defensive fallback.
    return [];
  }
}

/** Keep commits with at least one file at/under one of `paths`. */
function filterCommits(commits, paths, cwd) {
  const rootSegs = paths.map(toSegments);
  return (commits || []).filter((commit) => {
    const files = commitFiles(commit.hash, cwd);
    return files.some((file) => {
      const fileSegs = toSegments(file);
      return rootSegs.some((segs) => segs.every((seg, i) => seg === fileSegs[i]));
    });
  });
}

/** Build a context whose commits are filtered to this package's paths. */
function scopedContext(pluginConfig, context) {
  const paths = resolvePaths(pluginConfig);
  const cwd = context.cwd || process.cwd();
  const commits = filterCommits(context.commits, paths, cwd);
  if (context.logger && typeof context.logger.log === 'function') {
    context.logger.log(
      'only-package-commits: %d of %d commits touch %s',
      commits.length,
      (context.commits || []).length,
      paths.join(', '),
    );
  }
  return { ...context, commits };
}

const FORCE_LEVELS = ['patch', 'minor', 'major'];

/** The lockstep level SR_FORCE_RELEASE asks for, or null when unset. */
function forcedLevel() {
  const raw = (process.env.SR_FORCE_RELEASE || '').trim();
  if (raw === '') return null;
  if (!FORCE_LEVELS.includes(raw)) {
    throw new Error(
      `only-package-commits: SR_FORCE_RELEASE="${raw}" is not one of ${FORCE_LEVELS.join('/')}. ` +
        'It is set by pubdev-release.yml from tools/release/lockstep_plan.mjs --decide; ' +
        'refusing to run rather than silently skipping the lockstep release (#566).',
    );
  }
  return raw;
}

export async function analyzeCommits(pluginConfig, context) {
  const analyzerConfig = (pluginConfig && pluginConfig.commitAnalyzer) || {};
  const type = await commitAnalyzer(analyzerConfig, scopedContext(pluginConfig, context));
  if (type) return type;
  const forced = forcedLevel();
  if (!forced) return type;
  if (context.logger && typeof context.logger.log === 'function') {
    context.logger.log(
      'only-package-commits: no releasable commits, but the pub.dev lockstep planner ' +
        'requires a %s release for this package (SR_FORCE_RELEASE) — see #566',
      forced,
    );
  }
  return forced;
}

export async function generateNotes(pluginConfig, context) {
  const notesConfig = (pluginConfig && pluginConfig.releaseNotesGenerator) || {};
  return releaseNotesGenerator(notesConfig, scopedContext(pluginConfig, context));
}
