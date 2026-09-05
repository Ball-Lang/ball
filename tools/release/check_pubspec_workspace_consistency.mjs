// Consistency guard for the Dart pub WORKSPACE across a per-package release
// (#551). Runs offline on every PR, from ci.yml's `Proto Checks` job.
//
// WHY THIS EXISTS: `melos version` used to bump all nine publishable Dart
// packages in one transaction and rewrite every sibling constraint in the same
// commit. semantic-release's per-package model has no workspace-wide view, so
// the release lane has to reconstruct that invariant by hand
// (tools/release/sync_pubspec_deps.mjs) — and an invariant reconstructed by
// hand needs a gate, because the failure is silent in exactly the way #551 was:
//
//   * All ten packages under dart/ (nine publishable plus the private
//     ball_self_host_tests) are members of ONE pub workspace, and pub resolves
//     a workspace as a unit. Bump ball_base to 0.4.0 while any member still
//     asks for `^0.3.0+3` and `dart pub get` at the repo root fails outright —
//     for every contributor, and for the release job's own
//     `dart run tool/gen_version.dart` step. dart/self_host cannot fix itself:
//     a private package has no release config by design.
//   * The published tarball is worse than broken, it is plausible: `ball_cli
//     0.4.0` requiring `ball_base ^0.3.0+3` RESOLVES for an outside consumer,
//     because 0.3.0+3 is still on pub.dev. It is green and semantically wrong,
//     and no registry-side check can see it.
//   * The order the release loop walks the packages therefore matters. It must
//     be deps-first over the RUNTIME dependency graph, or a package publishes a
//     tarball pinned to a sibling version that only bumps later in the same run.
//     "Deps-first" written in a comment is documentation; this makes it a gate.
//
// Every leg is derived from the repo — no hardcoded package list, no hardcoded
// version — so a tenth Dart package is picked up automatically.
//
// It is a Node script rather than the repo's usual check_*.sh because it
// imports sync_pubspec_deps.mjs's own implementation: the guard and the
// rewriter share one definition of "satisfied" and one of "already current", so
// they cannot drift apart into a guard that passes what the rewriter breaks.
//
// Usage:
//   node tools/release/check_pubspec_workspace_consistency.mjs
//   node tools/release/check_pubspec_workspace_consistency.mjs --self-test

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  readWorkspaceDirs,
  readWorkspaceVersions,
  syncWorkspace,
  unsatisfiedConstraints,
} from './sync_pubspec_deps.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');

let pass = 0;
let fail = 0;
const ok = (m) => {
  pass++;
  console.log(`PASS  ${m}`);
};
const no = (m, ...detail) => {
  fail++;
  console.log(`FAIL  ${m}`);
  for (const d of detail) console.log(`  ${d}`);
};

/** Top-level scalar of a pubspec, or null. */
function topLevel(text, key) {
  const m = new RegExp(`^${key}:\\s*(\\S+)`, 'm').exec(text);
  return m ? m[1] : null;
}

/**
 * The names under one top-level section (`dependencies:` / `dev_dependencies:`)
 * of a pubspec. A section ends at the next column-0 key.
 */
export function sectionEntries(text, section) {
  const names = [];
  let inside = false;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (/^[A-Za-z_]/.test(line)) {
      inside = line.startsWith(`${section}:`);
      continue;
    }
    if (!inside) continue;
    const m = /^ {2}([A-Za-z_][A-Za-z0-9_]*):/.exec(line);
    if (m) names.push(m[1]);
  }
  return names;
}

/**
 * Is `order` a valid deps-first topological order of `graph` (name -> [deps])?
 * Returns the first violation, or null. Only edges between names present in
 * `order` count — a dependency outside the release loop cannot constrain it.
 */
export function firstOrderViolation(order, graph) {
  const position = new Map(order.map((n, i) => [n, i]));
  for (const name of order) {
    for (const dep of graph[name] ?? []) {
      if (!position.has(dep)) continue;
      if (position.get(dep) > position.get(name)) {
        return { name, dep, at: position.get(name), depAt: position.get(dep) };
      }
    }
  }
  return null;
}

/** The bare `  <name>` entries of the driver's PACKAGES heredoc list. */
export function driverPackageOrder(workflowText, known) {
  const order = [];
  for (const raw of workflowText.split('\n')) {
    const m = /^\s{2,}([a-z][a-z0-9_]*)\s*$/.exec(raw.replace(/\r$/, ''));
    if (m && known.has(m[1])) order.push(m[1]);
  }
  return order;
}

function checkRepo() {
  const rootPubspec = join(ROOT, 'pubspec.yaml');
  if (!existsSync(rootPubspec)) {
    console.error(`::error::missing ${rootPubspec}`);
    process.exit(1);
  }

  const dirs = readWorkspaceDirs(rootPubspec);
  const versions = readWorkspaceVersions(rootPubspec);
  const publishable = Object.keys(versions).sort();

  // Discovery floor (#439/#444): an exit code plus a zero failure count cannot
  // tell "all passed" from "nothing ran".
  if (dirs.length >= 2 && publishable.length >= 1) {
    ok(`discovered ${dirs.length} workspace members, ${publishable.length} of them publishable`);
  } else {
    no(
      'discovered the Dart pub workspace',
      `found ${dirs.length} members and ${publishable.length} publishable packages —`,
      'every leg below would be vacuous',
    );
    console.log(`Results: ${pass} passed, ${fail} failed, ${pass + fail} total`);
    process.exit(1);
  }

  // ── 1. No member asks for a sibling version the workspace does not contain.
  //      This is the shape that makes `dart pub get` at the repo root fail.
  const broken = unsatisfiedConstraints(rootPubspec);
  if (broken.length === 0) {
    ok('every workspace member\'s sibling constraints are satisfied by the in-tree versions');
  } else {
    no(
      'every workspace member\'s sibling constraints are satisfied by the in-tree versions',
      ...broken.map(
        (b) =>
          `${b.file.replace(ROOT, '').replace(/\\/g, '/')}: ${b.name} ${b.constraint} but the workspace has ${b.declared}`,
      ),
      '`dart pub get` at the repo root fails on this — "version solving failed".',
      'A release left a sibling behind; re-run: node tools/release/sync_pubspec_deps.mjs',
    );
  }

  // ── 2. Stronger than satisfiable: every sibling constraint is EXACTLY the
  //      sibling's current version, i.e. the release sweep has nothing to do.
  //      A satisfiable-but-stale pin resolves today and is one 0.x minor bump
  //      away from breaking the workspace, so it is caught here, not there.
  const pending = syncWorkspace(rootPubspec, { write: () => {} });
  if (pending.length === 0) {
    ok('the release-time sibling sweep is a no-op on this tree (every pin is current)');
  } else {
    no(
      'the release-time sibling sweep is a no-op on this tree (every pin is current)',
      ...pending.flatMap(({ file, changes }) =>
        changes.map(
          (c) => `${file.replace(ROOT, '').replace(/\\/g, '/')}: ${c.name} ${c.from} -> ${c.to}`,
        ),
      ),
      'Run: node tools/release/sync_pubspec_deps.mjs',
    );
  }

  // ── 3. Every publishable package's release config runs the WORKSPACE-wide
  //      sweep and commits what it rewrote. A config that only re-pins its own
  //      pubspec leaves the other members — including dart/self_host, which has
  //      no config of its own — asking for a version that no longer exists.
  const configDir = join(ROOT, '.github', 'release');
  for (const name of publishable) {
    const cfg = join(configDir, `${name}.releaserc.json`);
    if (!existsSync(cfg)) continue; // completeness is check_pubdev_release_wiring.sh's leg
    const text = readFileSync(cfg, 'utf8');
    const probs = [];
    if (!text.includes('sync_pubspec_deps.mjs --workspace-root=.')) {
      probs.push(
        'expected prepareCmd to run: node tools/release/sync_pubspec_deps.mjs --workspace-root=.',
      );
    }
    if (text.includes('sync_pubspec_deps.mjs --file=')) {
      probs.push(
        'a per-file sweep leaves every other workspace member pinned to a version that no longer exists',
      );
    }
    if (!text.includes('"dart/*/pubspec.yaml"')) {
      probs.push(
        'expected "dart/*/pubspec.yaml" in the @semantic-release/git assets — rewriting the siblings',
        'without committing them leaves main unresolvable all the same',
      );
    }
    if (probs.length === 0) {
      ok(`${name}.releaserc.json sweeps and commits the whole workspace's pubspecs`);
    } else {
      no(`${name}.releaserc.json sweeps and commits the whole workspace's pubspecs`, ...probs);
    }
  }

  // ── 4. The driver's package order is deps-first over the RUNTIME graph.
  //      dev_dependencies are excluded on purpose: they carry this workspace's
  //      only cycles (ball_base<->ball_protobuf, ball_engine<->ball_encoder),
  //      and pub never resolves a dependency's dev_dependencies for a consumer,
  //      so a dev-only edge cannot make a published tarball wrong. The runtime
  //      graph IS acyclic, so a real topological order exists and this is a
  //      checkable claim rather than a comment.
  const graph = {};
  for (const dir of dirs) {
    const file = join(ROOT, dir, 'pubspec.yaml');
    if (!existsSync(file)) continue;
    const text = readFileSync(file, 'utf8');
    const name = topLevel(text, 'name');
    if (!name) continue;
    graph[name] = sectionEntries(text, 'dependencies').filter((d) => versions[d] !== undefined);
  }

  const driver = join(ROOT, '.github', 'workflows', 'pubdev-release.yml');
  if (!existsSync(driver)) {
    no('pubdev-release.yml exists', 'the release driver is missing; nothing runs the configs');
  } else {
    const order = driverPackageOrder(readFileSync(driver, 'utf8'), new Set(publishable));
    const listed = [...order].sort();
    if (listed.length === publishable.length && listed.every((n, i) => n === publishable[i])) {
      ok(`pubdev-release.yml's release loop lists exactly the ${publishable.length} publishable packages`);
    } else {
      no(
        "pubdev-release.yml's release loop lists exactly the publishable packages",
        `loop: ${listed.join(' ') || '(none found)'}`,
        `repo: ${publishable.join(' ')}`,
      );
    }

    const violation = firstOrderViolation(order, graph);
    if (order.length > 0 && !violation) {
      ok(`pubdev-release.yml's release order is deps-first over the runtime dependency graph`);
    } else if (violation) {
      no(
        "pubdev-release.yml's release order is deps-first over the runtime dependency graph",
        `${violation.name} (position ${violation.at}) depends on ${violation.dep} (position ${violation.depAt})`,
        `so ${violation.name} publishes a tarball pinned to the OLD ${violation.dep}, which only bumps later`,
        'in the same run. Move the dependency earlier in the PACKAGES list.',
      );
    } else {
      no(
        "pubdev-release.yml's release order is deps-first over the runtime dependency graph",
        'no package names were found in the release loop — the parse, not the order, is broken',
      );
    }
  }
}

// ── Self-test: the order checker itself, on synthetic graphs. The repo legs
//    above are green today by construction; a checker that stopped rejecting a
//    bad order would stay green too.
function selfTest() {
  const graph = { a: [], b: ['a'], c: ['a', 'b'] };
  const cases = [
    [['a', 'b', 'c'], null, 'accepts a valid deps-first order'],
    [['c', 'b', 'a'], 'c', 'rejects a fully reversed order'],
    [['a', 'c', 'b'], 'c', 'rejects a single misplaced dependency'],
    [['b', 'a', 'c'], 'b', 'rejects a dependent ahead of its dependency'],
    [['b', 'c'], null, 'ignores an edge to a package outside the list (a is absent)'],
    [['c', 'b'], 'c', 'still checks edges among the names it was given'],
    [['a'], null, 'accepts a single-package order'],
  ];
  for (const [order, wantName, why] of cases) {
    const v = firstOrderViolation(order, graph);
    const got = v ? v.name : null;
    if (got === wantName) ok(why);
    else no(why, `expected violation at ${wantName}, got ${got}`);
  }

  // The runtime/dev split is the load-bearing modelling choice: a dev-only edge
  // must NOT constrain the order, or no order exists at all.
  const pubspec = [
    'name: pkg_x',
    'version: 1.0.0',
    '',
    'dependencies:',
    '  pkg_a: ^1.0.0',
    '  third_party: ^2.0.0',
    '',
    'dev_dependencies:',
    '  pkg_b: ^1.0.0',
    '',
    'executables:',
    '  ball:',
    '',
  ].join('\n');
  const runtime = sectionEntries(pubspec, 'dependencies');
  const dev = sectionEntries(pubspec, 'dev_dependencies');
  if (
    runtime.length === 2 &&
    runtime.includes('pkg_a') &&
    !runtime.includes('pkg_b') &&
    dev.length === 1 &&
    dev[0] === 'pkg_b'
  ) {
    ok('reads dependencies and dev_dependencies as separate sections');
  } else {
    no(
      'reads dependencies and dev_dependencies as separate sections',
      JSON.stringify({ runtime, dev }),
    );
  }

  // CRLF parity: a Windows checkout must classify identically.
  const crlf = sectionEntries(pubspec.replace(/\n/g, '\r\n'), 'dependencies');
  if (crlf.length === 2 && crlf.includes('pkg_a')) {
    ok('parses sections identically on a CRLF checkout');
  } else {
    no('parses sections identically on a CRLF checkout', JSON.stringify(crlf));
  }

  const order = driverPackageOrder(
    ['          PACKAGES="', '            ball_base', '            ball_cli', '          "'].join('\n'),
    new Set(['ball_base', 'ball_cli']),
  );
  if (order.length === 2 && order[0] === 'ball_base' && order[1] === 'ball_cli') {
    ok("reads the driver's PACKAGES list in order");
  } else {
    no("reads the driver's PACKAGES list in order", JSON.stringify(order));
  }
}

const selfTestMode = process.argv.slice(2).includes('--self-test');
if (selfTestMode) selfTest();
else checkRepo();

const total = pass + fail;
const MIN = selfTestMode ? 10 : 12;
if (total < MIN) {
  console.error(
    `::error::pubspec workspace consistency guard ran ${total} cases, expected at least ${MIN} — the sweep itself is broken`,
  );
  process.exit(1);
}
console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);
process.exit(fail === 0 ? 0 : 1);
