// Re-pins EVERY Dart workspace member's dependencies on its SIBLING workspace
// packages to whatever version those siblings currently declare, invoked from
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
// WHY IT SWEEPS THE WHOLE WORKSPACE AND NOT JUST THE RELEASING PACKAGE: all ten
// packages under dart/ (the nine publishable ones plus the private
// ball_self_host_tests) are members of ONE pub workspace, declared in the root
// pubspec.yaml's `workspace:` block, and pub resolves a workspace as a unit —
// every member's constraint on a sibling must be satisfied by that sibling's
// in-tree version, or `dart pub get` at the repo root fails outright:
//
//     Because probe_b depends on probe_a ^0.3.0+3 and ws_root depends on
//     probe_a, version solving failed.
//
// A member that has nothing to release in a given run is therefore NOT safe to
// leave alone: bumping ball_base to 0.4.0 while dart/self_host still asks for
// `^0.3.0+3` breaks resolution for the whole repo — including the
// `dart run tool/gen_version.dart` step later in the same release loop, and
// every contributor's next `dart pub get` on main. dart/self_host in particular
// can never fix itself, because a private package has no release config by
// design. So the sweep is workspace-wide and each release commits every pubspec
// it touched (the `dart/*/pubspec.yaml` glob in each config's
// @semantic-release/git assets).
//
// HOW IT STAYS CORRECT: it reads each sibling's version from the working tree,
// not from a registry. `.github/workflows/pubdev-release.yml` runs
// semantic-release over the packages in runtime-dependency order in a single
// job, and each package's release commits the whole workspace's pubspecs before
// the next package starts — so by the time `ball_cli` prepares,
// `dart/shared/pubspec.yaml` already reads `0.4.0` and every member already
// asks for `ball_base: ^0.4.0`.
//
// Private members are rewritten but never become a re-pin TARGET: a
// `publish_to: none` package never resolves from pub.dev, so pinning a
// published package to it would be wrong.
//
// Third-party constraints (protobuf, fixnum, yaml, test, lints) and any
// dependency declared as a block (`path:`/`hosted:`/`git:`) are left exactly as
// they are, and a trailing `# comment` on a re-pinned line is preserved.
//
// Usage:
//   node tools/release/sync_pubspec_deps.mjs                     # sweep from cwd
//   node tools/release/sync_pubspec_deps.mjs --workspace-root=.
//   node tools/release/sync_pubspec_deps.mjs --self-test

import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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

/** The `workspace:` block's directories, relative to the root pubspec. */
export function readWorkspaceDirs(rootPubspecPath) {
  const root = readFileSync(rootPubspecPath, 'utf8');
  const block = /^workspace:\s*$((?:\s*-\s*\S+\s*$)+)/m.exec(root);
  if (!block) return [];
  return block[1]
    .split('\n')
    .map((l) => /^\s*-\s*(\S+)\s*$/.exec(l))
    .filter(Boolean)
    .map((m) => m[1]);
}

/**
 * name -> version for every PUBLISHABLE package listed in the root pubspec's
 * `workspace:` block. A `publish_to: none` package is excluded: it never
 * resolves from pub.dev, so re-pinning anything to it would be wrong.
 */
export function readWorkspaceVersions(rootPubspecPath) {
  const versions = {};
  for (const dir of readWorkspaceDirs(rootPubspecPath)) {
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

// A dependency line: exactly one level of indentation, an inline scalar
// constraint, and an OPTIONAL trailing comment captured separately so re-pinning
// a documented dependency line does not silently delete its documentation. A
// dependency written as a nested block (`ball_base:\n    path: ...`) has no
// inline value and does not match.
//
// The trailing `(\r?)` is load-bearing on Windows checkouts: splitting a CRLF
// file on '\n' leaves a '\r' on every line, and a value group that swallowed it
// would compare unequal to the constraint it already equals — rewriting all ten
// pubspecs on a no-op sweep and stripping their line endings as it went.
const DEP_LINE = /^(\s{2})([A-Za-z_][A-Za-z0-9_]*):[ \t]*([^#\s][^#\r\n]*?)[ \t]*(#[^\r\n]*?)?[ \t]*(\r?)$/;

/**
 * Rewrites `  <sibling>: <constraint>` lines to `^<current sibling version>`.
 * Returns { text, changes: [{name, from, to}] }.
 */
export function syncDeps(pubspecText, versions, selfName) {
  const changes = [];
  const text = pubspecText
    .split('\n')
    .map((line) => {
      const m = DEP_LINE.exec(line);
      if (!m) return line;
      const [, indent, name, value, comment, cr] = m;
      if (name === selfName) return line;
      const version = versions[name];
      if (!version) return line;
      // Only a plain version constraint is re-pinned; anything that is not a
      // caret/comparator range (a map, a quoted url, `any`) is left alone.
      if (!/^\^?\d/.test(value) && !/^['"]?[\^>=<~ .0-9+-]+['"]?$/.test(value)) return line;
      const next = `^${version}`;
      if (value === next) return line;
      changes.push({ name, from: value, to: next });
      const suffix = comment ? `  ${comment}` : '';
      return `${indent}${name}: ${next}${suffix}${cr}`;
    })
    .join('\n');
  return { text, changes };
}

/**
 * Sweeps every workspace member's pubspec (private ones included) and re-pins
 * its sibling constraints. Returns [{file, changes}] for the files it rewrote.
 * `write` is injectable so the self-test can drive the real sweep offline.
 */
export function syncWorkspace(rootPubspecPath, { write = writeFileSync } = {}) {
  const versions = readWorkspaceVersions(rootPubspecPath);
  if (Object.keys(versions).length === 0) {
    throw new Error(
      `no publishable workspace packages found via ${rootPubspecPath} — refusing to run, ` +
        'a silent no-op here would publish stale sibling constraints',
    );
  }
  const results = [];
  for (const dir of readWorkspaceDirs(rootPubspecPath)) {
    const file = join(dirname(rootPubspecPath), dir, 'pubspec.yaml');
    let original;
    try {
      original = readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const { text, changes } = syncDeps(original, versions, topLevel(original, 'name'));
    if (changes.length === 0) continue;
    write(file, text);
    results.push({ file, changes });
  }
  return results;
}

/**
 * Parses `X.Y.Z(+build)` into a comparable tuple. Pre-release suffixes are not
 * used by any Ball package and are deliberately not modelled.
 */
function parseVersion(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$/.exec(String(v).trim());
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3]), m[4] === undefined ? -1 : Number(m[4])];
}

function cmpVersion(a, b) {
  for (let i = 0; i < 4; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/**
 * Does `^X.Y.Z` admit `version`? Pub's caret pins the leftmost NON-ZERO part:
 * `^1.2.3` means `>=1.2.3 <2.0.0`, `^0.3.0` means `>=0.3.0 <0.4.0`, and
 * `^0.0.3` means `>=0.0.3 <0.0.4`. The middle form is why a release matters
 * here at all — bumping ball_base 0.3.0+3 -> 0.4.0 puts it outside every
 * sibling's existing `^0.3.0+3`.
 *
 * Returns null for any constraint shape this does not model (a range, `any`, a
 * quoted URL); the caller treats null as "not our business", never as a
 * failure, so an unusual-but-valid constraint cannot false-red a guard.
 */
export function caretAdmits(constraint, version) {
  const c = /^\^(\d+\.\d+\.\d+(?:\+\d+)?)$/.exec(String(constraint).trim());
  if (!c) return null;
  const lower = parseVersion(c[1]);
  const v = parseVersion(version);
  if (!lower || !v) return null;
  if (cmpVersion(v, lower) < 0) return false;
  const [major, minor, patch] = lower;
  let upper;
  if (major !== 0) upper = [major + 1, 0, 0, -1];
  else if (minor !== 0) upper = [0, minor + 1, 0, -1];
  else upper = [0, 0, patch + 1, -1];
  return cmpVersion(v, upper) < 0;
}

/**
 * Every workspace member's sibling constraints, checked against the versions
 * those siblings declare. Returns the ones NO in-tree version satisfies — the
 * shape that makes `dart pub get` at the repo root fail outright:
 *
 *     Because ball_self_host_tests depends on ball_engine ^0.3.0+6 and
 *     ball_workspace depends on ball_engine, version solving failed.
 *
 * A constraint that is satisfiable but not exactly `^<declared>` (a hand-written
 * `^1.0.0` against a sibling at 1.2.3) is NOT reported: it resolves, and the
 * next release normalises it anyway. Exported so the consistency guard and the
 * self-test share one implementation.
 */
export function unsatisfiedConstraints(rootPubspecPath) {
  const versions = readWorkspaceVersions(rootPubspecPath);
  const problems = [];
  for (const dir of readWorkspaceDirs(rootPubspecPath)) {
    const file = join(dirname(rootPubspecPath), dir, 'pubspec.yaml');
    let text;
    try {
      text = readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const self = topLevel(text, 'name');
    for (const line of text.split('\n')) {
      const m = DEP_LINE.exec(line);
      if (!m) continue;
      const [, , name, value] = m;
      if (name === self) continue;
      const declared = versions[name];
      if (!declared) continue;
      if (caretAdmits(value, declared) === false) {
        problems.push({ file, name, constraint: value, declared });
      }
    }
  }
  return problems;
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
  mkdirSync(join(dir, 'c'));
  mkdirSync(join(dir, 'priv'));
  writeFileSync(
    join(dir, 'pubspec.yaml'),
    'name: ws\nworkspace:\n  - a\n  - b\n  - c\n  - priv\n',
  );
  writeFileSync(join(dir, 'a', 'pubspec.yaml'), 'name: pkg_a\nversion: 0.4.0\n');
  writeFileSync(join(dir, 'b', 'pubspec.yaml'), 'name: pkg_b\nversion: 1.2.3\n');

  const versions = readWorkspaceVersions(join(dir, 'pubspec.yaml'));
  if (versions.pkg_a === '0.4.0' && versions.pkg_b === '1.2.3') {
    ok('reads sibling versions from the workspace block');
  } else {
    no('reads sibling versions from the workspace block', JSON.stringify(versions));
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
  writeFileSync(join(dir, 'c', 'pubspec.yaml'), before);
  writeFileSync(
    join(dir, 'priv', 'pubspec.yaml'),
    [
      'name: pkg_priv',
      'publish_to: none',
      'version: 0.0.0',
      '',
      'dependencies:',
      '  pkg_a: ^0.3.0+3',
      '',
    ].join('\n'),
  );

  const versionsWithPriv = readWorkspaceVersions(join(dir, 'pubspec.yaml'));
  if (versionsWithPriv.pkg_priv === undefined) {
    ok('skips publish_to: none packages as a re-pin target');
  } else {
    no('skips publish_to: none packages as a re-pin target', 'pkg_priv must never be re-pinned to');
  }

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

  // A documented dependency line keeps its documentation. The repo's pubspecs
  // are heavily commented; a rewriter that eats the comment silently degrades
  // every file it touches.
  const commented = syncDeps('dependencies:\n  pkg_a: ^0.3.0+3  # descriptor types\n', versions, 'pkg_c');
  if (/^ {2}pkg_a: \^0\.4\.0 {2}# descriptor types$/m.test(commented.text)) {
    ok('preserves a trailing inline comment when re-pinning');
  } else {
    no('preserves a trailing inline comment when re-pinning', JSON.stringify(commented.text));
  }

  // A CRLF working tree (every Windows checkout of this repo) must behave
  // identically: an already-current constraint is a no-op, and a rewritten one
  // keeps its line ending. Without this the sweep rewrote all ten pubspecs on
  // every run and silently converted them to LF.
  const crlfCurrent = syncDeps('dependencies:\r\n  pkg_a: ^0.4.0\r\n', versions, 'pkg_c');
  const crlfStale = syncDeps('dependencies:\r\n  pkg_a: ^0.3.0+3\r\n', versions, 'pkg_c');
  if (crlfCurrent.changes.length === 0 && crlfStale.text === 'dependencies:\r\n  pkg_a: ^0.4.0\r\n') {
    ok('handles CRLF line endings (no phantom rewrite, endings preserved)');
  } else {
    no(
      'handles CRLF line endings (no phantom rewrite, endings preserved)',
      JSON.stringify({ current: crlfCurrent.changes, stale: crlfStale.text }),
    );
  }

  // ── Caret semantics. `^0.3.0+3` NOT admitting 0.4.0 is the entire reason a
  //    release must re-pin siblings; getting this backwards would make every
  //    consistency check below vacuously green.
  const caretCases = [
    ['^0.3.0+3', '0.4.0', false, 'a 0.x caret does not admit the next minor'],
    ['^0.3.0+3', '0.3.1', true, 'a 0.x caret admits a later patch'],
    ['^0.3.0+6', '0.3.0+3', false, 'a 0.x caret does not admit an earlier build'],
    ['^1.2.3', '1.9.0', true, 'a 1.x caret admits a later minor'],
    ['^1.2.3', '2.0.0', false, 'a 1.x caret does not admit the next major'],
    ['^0.0.3', '0.0.4', false, 'a 0.0.x caret pins the PATCH, not the minor'],
    ['^0.0.3', '0.0.3+1', true, 'a 0.0.x caret admits a later build of its own patch'],
    ['any', '1.0.0', null, 'an unmodelled constraint shape is not our business'],
  ];
  let caretOk = true;
  for (const [c, v, want, why] of caretCases) {
    if (caretAdmits(c, v) !== want) {
      caretOk = false;
      no(`caretAdmits('${c}', '${v}') === ${want} — ${why}`, String(caretAdmits(c, v)));
    }
  }
  if (caretOk) ok(`caret satisfaction is correct across ${caretCases.length} cases`);

  // ── The workspace-wide sweep, the part that keeps `dart pub get` resolvable.
  //    A sweep that only rewrote the releasing package's own pubspec left every
  //    OTHER member — including the private ball_self_host_tests, which has no
  //    release config and can never fix itself — asking for a version the
  //    workspace no longer contains, and pub fails the whole repo on that.
  const stale = unsatisfiedConstraints(join(dir, 'pubspec.yaml'));
  const staleFiles = stale.map((p) => p.file.replace(dir, '').replace(/\\/g, '/'));
  if (stale.length === 2 && staleFiles.some((f) => f.includes('/c/')) && staleFiles.some((f) => f.includes('/priv/'))) {
    ok('detects unsatisfied sibling constraints in BOTH a public and a private member');
  } else {
    no(
      'detects unsatisfied sibling constraints in BOTH a public and a private member',
      JSON.stringify(stale),
    );
  }

  const swept = syncWorkspace(join(dir, 'pubspec.yaml'));
  if (swept.length === 2) {
    ok('the workspace sweep rewrites every member that needed it, not just one');
  } else {
    no('the workspace sweep rewrites every member that needed it, not just one', JSON.stringify(swept));
  }
  const privAfter = readFileSync(join(dir, 'priv', 'pubspec.yaml'), 'utf8');
  if (/^ {2}pkg_a: \^0\.4\.0$/m.test(privAfter)) {
    ok('the sweep re-pins a private member (it has no release config to fix itself)');
  } else {
    no('the sweep re-pins a private member (it has no release config to fix itself)', privAfter);
  }
  const remaining = unsatisfiedConstraints(join(dir, 'pubspec.yaml'));
  if (remaining.length === 0) {
    ok('after the sweep no member has an unsatisfied sibling constraint');
  } else {
    no('after the sweep no member has an unsatisfied sibling constraint', JSON.stringify(remaining));
  }
  if (syncWorkspace(join(dir, 'pubspec.yaml')).length === 0) {
    ok('the workspace sweep is idempotent');
  } else {
    no('the workspace sweep is idempotent', 'a second sweep still reported rewrites');
  }

  const total = pass + fail;
  const MIN = 16;
  if (total < MIN) {
    console.error(
      `::error::sync_pubspec_deps self-test ran ${total} cases, expected at least ${MIN} — the sweep itself is broken`,
    );
    process.exit(1);
  }
  console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);
  process.exit(fail === 0 ? 0 : 1);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args['self-test']) {
    selfTest();
    return;
  }
  if (args.file) {
    console.error(
      'sync_pubspec_deps: --file is gone. A pub workspace resolves as a unit, so re-pinning one\n' +
        "  member's pubspec while its siblings keep constraints no workspace version satisfies breaks\n" +
        '  `dart pub get` for the whole repo. Run it with no arguments (or --workspace-root=<dir>).',
    );
    process.exit(1);
  }

  const rootPubspec = resolve(args['workspace-root'] ?? '.', 'pubspec.yaml');
  let results;
  try {
    results = syncWorkspace(rootPubspec);
  } catch (err) {
    console.error(`sync_pubspec_deps: ${err.message}`);
    process.exit(1);
  }
  if (results.length === 0) {
    console.log(`sync_pubspec_deps: ${rootPubspec} — every member's sibling constraints already current`);
    return;
  }
  for (const { file, changes } of results) {
    for (const c of changes) {
      console.log(`sync_pubspec_deps: ${file} — ${c.name}: ${c.from} -> ${c.to}`);
    }
  }
}

// Only run the CLI when this file IS the entry point. Importing it (the
// consistency guard imports unsatisfiedConstraints) must not parse argv or exit.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
