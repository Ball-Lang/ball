// Re-pins a Dart package's dependencies on its SIBLING workspace packages to
// whatever version those siblings currently declare, invoked from
// @semantic-release/exec's `prepareCmd` alongside set_manifest_version.mjs (see
// the .github/release/ball_*.releaserc.json configs).
//
// WHY THIS EXISTS: the nine Dart packages depend on each other with caret
// ranges pinned to an exact published version (`ball_base: ^0.3.0+3`). A caret
// on a 0.x version pins the MINOR, so `^0.3.0+3` does not admit `0.4.0`. Melos
// (`melos version`) used to rewrite those ranges as part of the same versioning
// run that bumped the packages. semantic-release's per-package model has no
// workspace-wide view, and set_manifest_version.mjs only rewrites a pubspec's
// own top-level `version:` — so without this step the first per-package release
// would publish `ball_cli 0.4.0` still requiring `ball_base ^0.3.0+3`: a
// resolvable, green, and semantically wrong package, where the CLI is built
// against APIs the pinned ball_base predates.
//
// HOW IT STAYS CORRECT: it reads each sibling's version from the working tree,
// not from a registry. `.github/workflows/pubdev-release.yml` runs
// semantic-release over the packages DEPS-FIRST in a single job, and each
// package's release commits its own bumped pubspec before the next package
// starts — so by the time `ball_cli` prepares, `dart/shared/pubspec.yaml`
// already reads `0.4.0` and this rewrites `ball_base: ^0.4.0`. That ordering is
// therefore load-bearing, not decorative.
//
// A package that has nothing to release in a given run keeps its old (still
// valid, still published) constraints and picks up the current ones on its next
// release — which is correct: the version already on pub.dev must keep the
// ranges it was published with.
//
// Only sibling packages listed in the root pubspec.yaml `workspace:` block are
// touched. Third-party constraints (protobuf, fixnum, yaml, test, lints) and
// any dependency declared as a block (`path:`/`hosted:`/`git:`) are left
// exactly as they are.
//
// Usage:
//   node tools/release/sync_pubspec_deps.mjs --file=dart/cli/pubspec.yaml
//   node tools/release/sync_pubspec_deps.mjs --self-test

import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';

function parseArgs(argv) {
  const args = {};
  for (const a of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(a);
    if (m) args[m[1]] = m[2] ?? true;
  }
  return args;
}

/** Top-level `version:` / `name:` of a pubspec, or null. */
function topLevel(text, key) {
  const m = new RegExp(`^${key}:\\s*(\\S+)`, 'm').exec(text);
  return m ? m[1] : null;
}

/**
 * name -> version for every package listed in the root pubspec's `workspace:`
 * block. A package with no `version:` (or marked `publish_to: none`) is still
 * included only if it declares a version — a private package can be depended on
 * in-workspace but never resolves from pub.dev, so re-pinning it would be wrong.
 */
export function readWorkspaceVersions(rootPubspecPath) {
  const root = readFileSync(rootPubspecPath, 'utf8');
  const block = /^workspace:\s*$((?:\s*-\s*\S+\s*$)+)/m.exec(root);
  if (!block) return {};
  const dirs = block[1]
    .split('\n')
    .map((l) => /^\s*-\s*(\S+)\s*$/.exec(l))
    .filter(Boolean)
    .map((m) => m[1]);

  const versions = {};
  for (const dir of dirs) {
    let text;
    try {
      text = readFileSync(join(dirname(rootPubspecPath), dir, 'pubspec.yaml'), 'utf8');
    } catch {
      continue;
    }
    if (/^publish_to:\s*none/m.test(text)) continue;
    const name = topLevel(text, 'name');
    const version = topLevel(text, 'version');
    if (name && version) versions[name] = version;
  }
  return versions;
}

/**
 * Rewrites `  <sibling>: <constraint>` lines to `^<current sibling version>`.
 * Returns { text, changes: [{name, from, to}] }.
 */
export function syncDeps(pubspecText, versions, selfName) {
  const changes = [];
  const text = pubspecText
    .split('\n')
    .map((line) => {
      // Exactly one level of indentation, an inline scalar constraint. A
      // dependency written as a nested block (`ball_base:\n    path: ...`) has
      // no inline value and is left alone by this pattern.
      const m = /^(\s{2})([A-Za-z_][A-Za-z0-9_]*):\s*(\S.*?)\s*$/.exec(line);
      if (!m) return line;
      const [, indent, name, value] = m;
      if (name === selfName) return line;
      const version = versions[name];
      if (!version) return line;
      // Only a plain version constraint is re-pinned; anything that is not a
      // caret/comparator range (a map, a quoted url, `any`) is left alone.
      if (!/^\^?\d/.test(value) && !/^['"]?[\^>=<~ .0-9+-]+['"]?$/.test(value)) return line;
      const next = `^${version}`;
      if (value === next) return line;
      changes.push({ name, from: value, to: next });
      return `${indent}${name}: ${next}`;
    })
    .join('\n');
  return { text, changes };
}

// ── Self-test: the rewrite logic, offline, on a synthetic workspace. Wired into
//    ci.yml's Proto Checks job, because a rewriter that silently stops
//    rewriting is indistinguishable from one with nothing to do.
function selfTest() {
  let pass = 0;
  let fail = 0;
  const ok = (m) => {
    pass++;
    console.log(`PASS  ${m}`);
  };
  const no = (m, detail) => {
    fail++;
    console.log(`FAIL  ${m}`);
    if (detail) console.log(`  ${detail}`);
  };

  const dir = mkdtempSync(join(tmpdir(), 'ball-syncdeps-'));
  mkdirSync(join(dir, 'a'));
  mkdirSync(join(dir, 'b'));
  mkdirSync(join(dir, 'priv'));
  writeFileSync(
    join(dir, 'pubspec.yaml'),
    'name: ws\nworkspace:\n  - a\n  - b\n  - priv\n',
  );
  writeFileSync(join(dir, 'a', 'pubspec.yaml'), 'name: pkg_a\nversion: 0.4.0\n');
  writeFileSync(join(dir, 'b', 'pubspec.yaml'), 'name: pkg_b\nversion: 1.2.3\n');
  writeFileSync(
    join(dir, 'priv', 'pubspec.yaml'),
    'name: pkg_priv\npublish_to: none\nversion: 0.0.0\n',
  );

  const versions = readWorkspaceVersions(join(dir, 'pubspec.yaml'));
  if (versions.pkg_a === '0.4.0' && versions.pkg_b === '1.2.3') {
    ok('reads sibling versions from the workspace block');
  } else {
    no('reads sibling versions from the workspace block', JSON.stringify(versions));
  }
  if (versions.pkg_priv === undefined) {
    ok('skips publish_to: none packages');
  } else {
    no('skips publish_to: none packages', 'pkg_priv must never be re-pinned');
  }

  const before = [
    'name: pkg_c',
    'version: 0.9.0',
    '',
    'dependencies:',
    '  pkg_a: ^0.3.0+3',
    '  pkg_priv: ^0.0.0',
    '  protobuf: ^6.0.0',
    '',
    'dev_dependencies:',
    '  pkg_b: ^1.0.0',
    '  test: ^1.25.0',
    '',
  ].join('\n');
  const { text, changes } = syncDeps(before, versions, 'pkg_c');

  if (/^ {2}pkg_a: \^0\.4\.0$/m.test(text)) {
    ok('re-pins a stale sibling caret (^0.3.0+3 -> ^0.4.0)');
  } else {
    no('re-pins a stale sibling caret (^0.3.0+3 -> ^0.4.0)', text);
  }
  if (/^ {2}pkg_b: \^1\.2\.3$/m.test(text)) {
    ok('re-pins siblings under dev_dependencies too');
  } else {
    no('re-pins siblings under dev_dependencies too', text);
  }
  if (/^ {2}protobuf: \^6\.0\.0$/m.test(text) && /^ {2}test: \^1\.25\.0$/m.test(text)) {
    ok('leaves third-party constraints untouched');
  } else {
    no('leaves third-party constraints untouched', text);
  }
  if (/^ {2}pkg_priv: \^0\.0\.0$/m.test(text)) {
    ok('leaves a private sibling untouched');
  } else {
    no('leaves a private sibling untouched', text);
  }
  if (changes.length === 2) {
    ok('reports exactly the two constraints it rewrote');
  } else {
    no('reports exactly the two constraints it rewrote', JSON.stringify(changes));
  }

  // Idempotence: a second pass must be a no-op, or a release commit would churn.
  const again = syncDeps(text, versions, 'pkg_c');
  if (again.changes.length === 0 && again.text === text) {
    ok('is idempotent');
  } else {
    no('is idempotent', JSON.stringify(again.changes));
  }

  // A block-form dependency has no inline constraint and must survive intact.
  const blockForm = 'dependencies:\n  pkg_a:\n    path: ../a\n';
  const blocked = syncDeps(blockForm, versions, 'pkg_c');
  if (blocked.text === blockForm && blocked.changes.length === 0) {
    ok('leaves block-form (path:/hosted:/git:) dependencies alone');
  } else {
    no('leaves block-form (path:/hosted:/git:) dependencies alone', blocked.text);
  }

  const total = pass + fail;
  const MIN = 8;
  if (total < MIN) {
    console.error(
      `::error::sync_pubspec_deps self-test ran ${total} cases, expected at least ${MIN} — the sweep itself is broken`,
    );
    process.exit(1);
  }
  console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);
  process.exit(fail === 0 ? 0 : 1);
}

const args = parseArgs(process.argv.slice(2));
if (args['self-test']) selfTest();

if (!args.file) {
  console.error('sync_pubspec_deps: require --file=<path/to/pubspec.yaml> (or --self-test)');
  process.exit(1);
}

const rootPubspec = resolve(args['workspace-root'] ?? '.', 'pubspec.yaml');
const versions = readWorkspaceVersions(rootPubspec);
if (Object.keys(versions).length === 0) {
  console.error(
    `sync_pubspec_deps: no workspace packages found via ${rootPubspec} — refusing to run, ` +
      'a silent no-op here would publish stale sibling constraints',
  );
  process.exit(1);
}

const original = readFileSync(args.file, 'utf8');
const selfName = topLevel(original, 'name');
const { text, changes } = syncDeps(original, versions, selfName);
if (changes.length === 0) {
  console.log(`sync_pubspec_deps: ${args.file} — sibling constraints already current`);
} else {
  writeFileSync(args.file, text);
  for (const c of changes) {
    console.log(`sync_pubspec_deps: ${args.file} — ${c.name}: ${c.from} -> ${c.to}`);
  }
}
