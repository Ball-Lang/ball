// Lockstep planner for the pub.dev release loop (#566).
//
// WHY THIS EXISTS
// ---------------
// `pubdev-release.yml` runs one semantic-release per publishable Dart package,
// deps-first, and every package's prepareCmd runs the workspace-wide sibling
// sweep (`sync_pubspec_deps.mjs`), which re-pins EVERY member's constraints on
// its siblings to the versions in the tree. That sweep is committed to main by
// each release's @semantic-release/git step.
//
// A package that has no releasable commits of its own is still swept — its
// pubspec in the REPO is rewritten — but semantic-release does not publish it,
// so pub.dev keeps serving its OLD pubspec. The repo therefore looks perfectly
// consistent while the PUBLISHED graph splits in half. That is exactly what the
// first live run (33953248977) did:
//
//     ball_base      0.4.0     published, pins ball_protobuf ^0.4.0
//     ball_resolver  0.3.0+3   NOT released, still pins ball_base ^0.3.0+3
//     ball_engine    0.4.0     published, pins ball_base ^0.4.0 + ball_resolver ^0.3.0+3
//
//     Because ball_resolver >=0.3.0+3 depends on ball_base ^0.3.0+3 and
//     ball_engine >=0.4.0 depends on ball_base ^0.4.0, version solving failed.
//
// Every pre-publish gate the lane had validates the REPO workspace
// (`check_pubspec_workspace_consistency.mjs` + `dart pub get`), where a
// re-pinned-but-unreleased package is indistinguishable from a healthy one. The
// only gate that models pub.dev, `release-publish.yml`'s `verify-published`,
// runs AFTER the upload. This module is the missing oracle, moved before it:
//
//   for every package live on pub.dev after this run, its sibling constraints
//   must be satisfied by {the versions released this run} ∪ {the versions of
//   every package NOT released this run}.
//
// THE RULE IT ENFORCES
// --------------------
// A package must release (at least a patch) when its OWN PUBLISHED pubspec
// already fails that oracle — i.e. some workspace sibling it depends on will be
// live at a version its published constraint does not admit. Nothing else. In
// particular it does NOT force a release merely because the sweep rewrote a
// pin: `ball_cli 0.4.0` pinning `ball_resolver ^0.3.0+3` still admits a
// `ball_resolver 0.3.1`, so re-publishing ball_cli would be noise.
//
// That narrowness is what makes the rule TERMINATE. The tempting alternative —
// "a `chore(release):` commit touching this package's paths is a patch trigger"
// — is self-sustaining: every run's sweep commits touch every pubspec that pins
// a bumped sibling, so every run would republish all nine packages forever,
// including runs where nothing under dart/ changed at all.
//
// Because the loop is deps-first, ONE forward pass is a fixpoint: when a
// package is considered, every sibling it depends on has already been decided,
// so its effective (post-run) version is known.
//
// HOW IT IS WIRED
// ---------------
//   1. `pubdev-release.yml` snapshots pub.dev once, before the loop:
//        node tools/release/lockstep_plan.mjs --fetch-published
//   2. Before each package's semantic-release invocation the loop asks:
//        node tools/release/lockstep_plan.mjs --decide --package=<pkg>
//      which prints `patch` (and the reason on stderr) or nothing, and the loop
//      passes it through as SR_FORCE_RELEASE.
//   3. `only-package-commits.mjs` promotes a no-release verdict to
//      SR_FORCE_RELEASE when that variable is set.
//   4. Each config's @semantic-release/exec `verifyReleaseCmd` records what
//      semantic-release actually decided:
//        node tools/release/lockstep_plan.mjs --record --package=<pkg> \
//          --version=${nextRelease.version} --type=${nextRelease.type}
//      `verifyRelease` is one of the four steps semantic-release runs in
//      --dry-run mode too (lib/definitions/plugins.js marks prepare, publish,
//      addChannel, success and fail `dryRun: false`; verifyConditions,
//      analyzeCommits, verifyRelease and generateNotes `dryRun: true`), so a
//      dry-run rehearsal produces the SAME plan as the real run — the property
//      that makes the rehearsal proof worth anything.
//
// Usage:
//   node tools/release/lockstep_plan.mjs --fetch-published [--out=FILE]
//   node tools/release/lockstep_plan.mjs --decide  --package=NAME
//   node tools/release/lockstep_plan.mjs --record  --package=NAME --version=V --type=T
//   node tools/release/lockstep_plan.mjs --self-test
//
// `--published=FILE` / `--state=FILE` override the SR_LOCKSTEP_PUBLISHED and
// SR_LOCKSTEP_STATE environment variables the release job exports.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readWorkspaceDirs, readWorkspaceVersions, caretAdmits } from './sync_pubspec_deps.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');

export const BUMP_TYPES = ['patch', 'minor', 'major'];

// ── Pubspec reading ───────────────────────────────────────────────────────

/** Top-level scalar of a pubspec, or null. */
function topLevel(text, key) {
  const m = new RegExp(`^${key}:\\s*(\\S+)`, 'm').exec(text);
  return m ? m[1] : null;
}

/**
 * name -> inline constraint for the entries under the top-level
 * `dependencies:` section only.
 *
 * dev_dependencies are excluded on purpose, and it is the same reason the
 * release ORDER excludes them: pub never resolves a dependency's
 * dev_dependencies for a consumer, so a dev-only pin cannot make a published
 * graph unsolvable. Including them here would also reintroduce the churn the
 * rule is designed to avoid — this workspace's only dependency cycles
 * (ball_base<->ball_protobuf, ball_engine<->ball_encoder,
 * ball_protobuf_gen->ball_rpc) are all dev edges.
 */
export function runtimeDeps(pubspecText) {
  const deps = {};
  let inside = false;
  for (const raw of String(pubspecText).split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (/^[A-Za-z_]/.test(line)) {
      inside = line.startsWith('dependencies:');
      continue;
    }
    if (!inside) continue;
    const m = /^ {2}([A-Za-z_][A-Za-z0-9_]*):[ \t]*([^#\s][^#]*?)[ \t]*(?:#.*)?$/.exec(line);
    if (m) deps[m[1]] = m[2];
  }
  return deps;
}

/** The publishable workspace packages, in repo order: name -> {dir, deps}. */
export function readWorkspacePackages(rootPubspecPath) {
  const versions = readWorkspaceVersions(rootPubspecPath);
  const packages = {};
  for (const dir of readWorkspaceDirs(rootPubspecPath)) {
    const file = join(dirname(rootPubspecPath), dir, 'pubspec.yaml');
    if (!existsSync(file)) continue;
    const text = readFileSync(file, 'utf8');
    const name = topLevel(text, 'name');
    if (!name || versions[name] === undefined) continue;
    const siblings = {};
    for (const [dep, constraint] of Object.entries(runtimeDeps(text))) {
      if (versions[dep] !== undefined) siblings[dep] = constraint;
    }
    packages[name] = { dir, version: versions[name], deps: siblings };
  }
  return packages;
}

// ── Version arithmetic ────────────────────────────────────────────────────

/**
 * `semver.inc` for the shapes this repo publishes, which is what
 * semantic-release's getNextVersion() applies to the last tag's version.
 * Dart build metadata (`0.3.0+3`) is dropped by a bump exactly as semver does:
 * `inc('0.3.0+3', 'patch') === '0.3.1'`.
 */
export function nextVersion(version, type) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$/.exec(String(version).trim());
  if (!m) throw new Error(`lockstep_plan: cannot bump unsupported version "${version}"`);
  const [major, minor, patch] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (type === 'major') return `${major + 1}.0.0`;
  if (type === 'minor') return `${major}.${minor + 1}.0`;
  if (type === 'patch') return `${major}.${minor}.${patch + 1}`;
  throw new Error(`lockstep_plan: unknown release type "${type}"`);
}

// ── The oracle ────────────────────────────────────────────────────────────

/**
 * The sibling constraints of `deps` that the post-run world does NOT satisfy.
 *
 * `effective` maps a package name to the version that will be live on pub.dev
 * after this run. A constraint shape `caretAdmits` does not model returns null
 * and is skipped — never treated as a failure, so an unusual-but-valid
 * constraint cannot force a spurious release.
 */
export function unsatisfiedAgainst(deps, effective) {
  const problems = [];
  for (const [dep, constraint] of Object.entries(deps || {})) {
    const version = effective[dep];
    if (version === undefined) continue;
    if (caretAdmits(constraint, version) === false) {
      problems.push({ dep, constraint, version });
    }
  }
  return problems;
}

/**
 * Simulate a whole release run against pub.dev state.
 *
 *   order        deps-first package order the driver walks
 *   published    name -> {version, deps}  (the LIVE pub.dev pubspecs)
 *   workspace    name -> {deps}           (the repo's runtime sibling edges)
 *   releasable   name -> 'patch'|'minor'|'major'|null  (commit-analyzer verdict)
 *   lockstep     false models the loop as it shipped in #559; true adds the fix
 *
 * Returns { released, effective, live, problems }. `problems` is the oracle
 * from the issue: every package live after the run, checked against every other
 * package live after the run.
 */
export function simulateRun({ order, published, workspace, releasable = {}, lockstep = true }) {
  const effective = {};
  for (const [name, spec] of Object.entries(published)) effective[name] = spec.version;

  const live = {};
  for (const [name, spec] of Object.entries(published)) live[name] = { ...spec.deps };

  const released = {};
  for (const name of order) {
    const publishedSpec = published[name];
    const forcedBy = lockstep && publishedSpec ? unsatisfiedAgainst(publishedSpec.deps, effective) : [];
    const analyzed = releasable[name] || null;
    const type = analyzed || (forcedBy.length > 0 ? 'patch' : null);
    if (!type) continue;

    // A package with no published version at all is a first release; the
    // driver's semantic-release run picks 1.0.0 and there is nothing to bump.
    const version = publishedSpec ? nextVersion(publishedSpec.version, type) : '1.0.0';
    released[name] = { type, version, forced: !analyzed && forcedBy.length > 0, forcedBy };
    effective[name] = version;

    // The sweep this release commits re-pins every sibling to the version in
    // the tree AT THIS POINT IN THE LOOP — which is why a non-deps-first order
    // publishes a tarball pinned to a sibling's pre-release version.
    const swept = {};
    for (const dep of Object.keys((workspace[name] || {}).deps || {})) {
      if (effective[dep] !== undefined) swept[dep] = `^${effective[dep]}`;
    }
    live[name] = swept;
  }

  const problems = [];
  for (const [name, deps] of Object.entries(live)) {
    for (const p of unsatisfiedAgainst(deps, effective)) {
      problems.push({
        package: name,
        version: effective[name],
        released: released[name] !== undefined,
        ...p,
      });
    }
  }
  return { released, effective, live, problems };
}

// ── Live pub.dev snapshot ─────────────────────────────────────────────────

/** The pub.dev API's view of one package: its latest version and its pubspec. */
async function fetchPublished(name) {
  const url = `https://pub.dev/api/packages/${encodeURIComponent(name)}`;
  const response = await fetch(url, { headers: { accept: 'application/vnd.pub.v2+json' } });
  if (response.status === 404) return null; // never published: a first release
  if (!response.ok) {
    throw new Error(`lockstep_plan: GET ${url} returned ${response.status} ${response.statusText}`);
  }
  const body = await response.json();
  const latest = body && body.latest;
  if (!latest || typeof latest.version !== 'string') {
    throw new Error(`lockstep_plan: ${url} returned no latest.version`);
  }
  const deps = {};
  const raw = (latest.pubspec && latest.pubspec.dependencies) || {};
  for (const [dep, constraint] of Object.entries(raw)) {
    if (typeof constraint === 'string') deps[dep] = constraint;
  }
  return { version: latest.version, deps };
}

async function snapshotPublished(packages) {
  const published = {};
  for (const name of Object.keys(packages)) {
    const spec = await fetchPublished(name);
    if (spec) published[name] = spec;
  }
  return published;
}

// ── State files ───────────────────────────────────────────────────────────

function readJson(file, fallback) {
  if (!file || !existsSync(file)) return fallback;
  const text = readFileSync(file, 'utf8').trim();
  if (text === '') return fallback;
  return JSON.parse(text);
}

function stateFile(args) {
  const file = args.state || process.env.SR_LOCKSTEP_STATE;
  if (!file) {
    throw new Error('lockstep_plan: no state file — pass --state=FILE or set SR_LOCKSTEP_STATE');
  }
  return file;
}

function publishedFile(args) {
  const file = args.published || process.env.SR_LOCKSTEP_PUBLISHED;
  if (!file) {
    throw new Error(
      'lockstep_plan: no pub.dev snapshot — pass --published=FILE or set SR_LOCKSTEP_PUBLISHED',
    );
  }
  return file;
}

// ── CLI ───────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = {};
  for (const a of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(a);
    if (m) args[m[1]] = m[2] ?? true;
  }
  return args;
}

async function cmdFetchPublished(args) {
  const packages = readWorkspacePackages(join(ROOT, 'pubspec.yaml'));
  const names = Object.keys(packages);
  if (names.length === 0) {
    throw new Error(
      'lockstep_plan: found no publishable Dart packages — refusing to write an empty snapshot, ' +
        'every lockstep decision made from it would be vacuously "no force"',
    );
  }
  const published = await snapshotPublished(packages);
  if (Object.keys(published).length === 0) {
    throw new Error(
      `lockstep_plan: pub.dev returned nothing for any of the ${names.length} publishable packages`,
    );
  }
  const out = args.out || process.env.SR_LOCKSTEP_PUBLISHED;
  if (!out) throw new Error('lockstep_plan: --fetch-published needs --out=FILE or SR_LOCKSTEP_PUBLISHED');
  writeFileSync(out, `${JSON.stringify(published, null, 2)}\n`);
  for (const name of names) {
    const spec = published[name];
    console.log(spec ? `pub.dev  ${name}  ${spec.version}` : `pub.dev  ${name}  (never published)`);
  }
  console.log(`snapshot: ${Object.keys(published).length} of ${names.length} packages, written to ${out}`);
}

function cmdDecide(args) {
  const name = args.package;
  if (!name) throw new Error('lockstep_plan: --decide needs --package=NAME');
  const published = readJson(publishedFile(args), null);
  if (published === null) {
    throw new Error(`lockstep_plan: pub.dev snapshot ${publishedFile(args)} is missing or empty`);
  }
  const state = readJson(stateFile(args), {});

  const effective = {};
  for (const [pkg, spec] of Object.entries(published)) effective[pkg] = spec.version;
  for (const [pkg, rec] of Object.entries(state)) effective[pkg] = rec.version;

  const spec = published[name];
  if (!spec) {
    console.error(`lockstep: ${name} is not on pub.dev yet — nothing published to keep in step`);
    return;
  }
  const problems = unsatisfiedAgainst(spec.deps, effective);
  if (problems.length === 0) {
    console.error(`lockstep: ${name} ${spec.version} already resolves against the post-run graph`);
    return;
  }
  for (const p of problems) {
    console.error(
      `lockstep: ${name} ${spec.version} on pub.dev requires ${p.dep} ${p.constraint}, ` +
        `but ${p.dep} will be live at ${p.version} — forcing a patch release`,
    );
  }
  process.stdout.write('patch');
}

function cmdRecord(args) {
  const name = args.package;
  const version = args.version;
  const type = args.type;
  if (!name || !version || !type) {
    throw new Error('lockstep_plan: --record needs --package=NAME --version=V --type=T');
  }
  if (!BUMP_TYPES.includes(type)) {
    throw new Error(`lockstep_plan: --record got release type "${type}", expected one of ${BUMP_TYPES.join('/')}`);
  }
  const file = stateFile(args);
  const state = readJson(file, {});
  state[name] = { version, type };
  writeFileSync(file, `${JSON.stringify(state, null, 2)}\n`);
  console.log(`lockstep: recorded ${name} ${version} (${type}) as releasing in this run`);
}

// ── Self-test ─────────────────────────────────────────────────────────────
//
// The unit test the #559 lane was missing: a simulation that models pub.dev
// state, driven by a fixture in which a MIDDLE package of the deps-first order
// has no releasable commits. With `lockstep: false` — the loop exactly as it
// shipped — the simulation reports an unsolvable published graph. That is the
// red the repo-workspace gates could not produce.

function selfTest() {
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

  // ── The #566 fixture, in miniature and in the real thing's shape:
  //    base <- middle <- top, plus `leaf` which depends only on base.
  //    `middle` is the ball_resolver shape: no releasable commits, an old
  //    published pin on a package that IS releasing.
  const order = ['base', 'middle', 'leaf', 'top'];
  const workspace = {
    base: { deps: {} },
    middle: { deps: { base: '^0.4.0' } },
    leaf: { deps: { base: '^0.4.0' } },
    top: { deps: { base: '^0.4.0', middle: '^0.3.0+3' } },
  };
  const published = {
    base: { version: '0.3.0+3', deps: {} },
    middle: { version: '0.3.0+3', deps: { base: '^0.3.0+3' } },
    leaf: { version: '0.3.0+3', deps: { base: '^0.3.0+3' } },
    top: { version: '0.3.0+3', deps: { base: '^0.3.0+3', middle: '^0.3.0+3' } },
  };
  // base/leaf/top have work; `middle` does not. This is the run that broke.
  const releasable = { base: 'minor', leaf: 'minor', top: 'minor' };

  const before = simulateRun({ order, published, workspace, releasable, lockstep: false });
  const brokeOnMiddle = before.problems.filter((p) => p.package === 'middle' && p.dep === 'base');
  if (before.problems.length >= 1 && brokeOnMiddle.length === 1) {
    ok('models the shipped loop as leaving an unsolvable published graph (#566)');
    console.log(
      `  oracle: ${brokeOnMiddle[0].package} ${brokeOnMiddle[0].version} requires ` +
        `${brokeOnMiddle[0].dep} ${brokeOnMiddle[0].constraint}, but ${brokeOnMiddle[0].dep} ` +
        `is live at ${brokeOnMiddle[0].version === undefined ? '?' : before.effective.base}`,
    );
  } else {
    no(
      'models the shipped loop as leaving an unsolvable published graph (#566)',
      `expected a violation on middle -> base, got ${JSON.stringify(before.problems)}`,
    );
  }
  if (before.released.middle === undefined) {
    ok('the shipped loop skips a middle package with no releasable commits');
  } else {
    no('the shipped loop skips a middle package with no releasable commits', JSON.stringify(before.released));
  }

  const after = simulateRun({ order, published, workspace, releasable, lockstep: true });
  if (after.problems.length === 0) {
    ok('the lockstep rule leaves a fully solvable published graph');
  } else {
    no(
      'the lockstep rule leaves a fully solvable published graph',
      ...after.problems.map((p) => `${p.package} requires ${p.dep} ${p.constraint}, live at ${p.version}`),
    );
  }
  if (after.released.middle && after.released.middle.forced && after.released.middle.version === '0.3.1') {
    ok('the lockstep rule releases the re-pinned middle package as a patch (0.3.0+3 -> 0.3.1)');
  } else {
    no(
      'the lockstep rule releases the re-pinned middle package as a patch (0.3.0+3 -> 0.3.1)',
      JSON.stringify(after.released.middle),
    );
  }

  // ── The world the broken run left behind: `base`/`leaf`/`top` are live on
  //    0.4.0, `middle` is still on 0.3.0+3 pinning `base ^0.3.0+3`. Nobody has
  //    releasable commits. A repair-only run must fix it, and must fix ONLY it:
  //    `top` published `middle ^0.3.0+3`, which still admits the forced
  //    `middle 0.3.1`, so dragging `top` in would be churn, not lockstep.
  const broken = {
    base: { version: '0.4.0', deps: {} },
    middle: { version: '0.3.0+3', deps: { base: '^0.3.0+3' } },
    leaf: { version: '0.4.0', deps: { base: '^0.4.0' } },
    top: { version: '0.4.0', deps: { base: '^0.4.0', middle: '^0.3.0+3' } },
  };
  const stillBroken = simulateRun({ order, published: broken, workspace, releasable: {}, lockstep: false });
  if (stillBroken.problems.some((p) => p.package === 'middle' && p.dep === 'base')) {
    ok('without the rule, a run with no releasable commits leaves the split in place');
  } else {
    no('without the rule, a run with no releasable commits leaves the split in place', JSON.stringify(stillBroken.problems));
  }

  const quiet = simulateRun({ order, published: broken, workspace, releasable: {}, lockstep: true });
  const quietReleased = Object.keys(quiet.released).sort();
  if (quietReleased.length === 1 && quietReleased[0] === 'middle') {
    ok('forces only the package whose PUBLISHED pins actually break, not every re-pinned sibling');
  } else {
    no(
      'forces only the package whose PUBLISHED pins actually break, not every re-pinned sibling',
      quietReleased.join(' ') || '(none)',
    );
  }
  if (quiet.problems.length === 0) {
    ok('a repair-only run (no releasable commits anywhere) still lands a solvable graph');
  } else {
    no(
      'a repair-only run (no releasable commits anywhere) still lands a solvable graph',
      ...quiet.problems.map((p) => `${p.package} requires ${p.dep} ${p.constraint}, live at ${p.version}`),
    );
  }

  // Termination: re-running the planner on the world the previous run produced
  // must release nothing. A rule that keeps finding work is the churn failure.
  const settled = {};
  for (const name of order) {
    settled[name] = { version: after.effective[name], deps: { ...after.live[name] } };
  }
  const again = simulateRun({ order, published: settled, workspace, releasable: {}, lockstep: true });
  if (Object.keys(again.released).length === 0 && again.problems.length === 0) {
    ok('re-planning the world the fix produced releases nothing (the rule terminates)');
  } else {
    no(
      're-planning the world the fix produced releases nothing (the rule terminates)',
      JSON.stringify(again.released),
    );
  }

  // A clean run where every package has work must not be perturbed.
  const allWork = simulateRun({
    order,
    published,
    workspace,
    releasable: { base: 'minor', middle: 'minor', leaf: 'minor', top: 'minor' },
    lockstep: true,
  });
  if (Object.keys(allWork.released).length === 4 && allWork.problems.length === 0) {
    ok('a run where every package has releasable commits is unchanged by the rule');
  } else {
    no('a run where every package has releasable commits is unchanged by the rule', JSON.stringify(allWork.released));
  }

  // The oracle must still catch a NON-deps-first order: `middle` sweeping
  // before `base` releases pins itself to base's pre-release version.
  const badOrder = simulateRun({
    order: ['middle', 'base', 'leaf', 'top'],
    published,
    workspace,
    releasable: { base: 'minor', middle: 'minor', leaf: 'minor', top: 'minor' },
    lockstep: true,
  });
  if (badOrder.problems.some((p) => p.package === 'middle' && p.dep === 'base')) {
    ok('the oracle rejects a non-deps-first order (a tarball pinned to a pre-release sibling)');
  } else {
    no('the oracle rejects a non-deps-first order', JSON.stringify(badOrder.problems));
  }

  // ── The real #566 graph, from the live pub.dev state recorded in the issue.
  //    This is the case the fix-forward run has to solve.
  const liveOrder = [
    'ball_protobuf',
    'ball_base',
    'ball_resolver',
    'ball_encoder',
    'ball_engine',
    'ball_compiler',
    'ball_rpc',
    'ball_protobuf_gen',
    'ball_cli',
  ];
  const livePublished = {
    ball_protobuf: { version: '0.4.0', deps: {} },
    ball_base: { version: '0.4.0', deps: { ball_protobuf: '^0.4.0' } },
    ball_resolver: { version: '0.3.0+3', deps: { ball_base: '^0.3.0+3' } },
    ball_encoder: { version: '0.4.0', deps: { ball_base: '^0.4.0' } },
    ball_engine: { version: '0.4.0', deps: { ball_base: '^0.4.0', ball_resolver: '^0.3.0+3' } },
    ball_compiler: {
      version: '0.4.0',
      deps: {
        ball_base: '^0.4.0',
        ball_encoder: '^0.4.0',
        ball_engine: '^0.4.0',
        ball_resolver: '^0.3.0+3',
      },
    },
    ball_rpc: { version: '0.3.0+1', deps: { ball_protobuf: '^0.3.0+1' } },
    ball_protobuf_gen: { version: '0.3.1', deps: { ball_base: '^0.4.0', ball_protobuf: '^0.4.0' } },
    ball_cli: {
      version: '0.4.0',
      deps: {
        ball_base: '^0.4.0',
        ball_compiler: '^0.4.0',
        ball_encoder: '^0.4.0',
        ball_engine: '^0.4.0',
        ball_resolver: '^0.3.0+3',
      },
    },
  };
  const liveWorkspace = {};
  for (const [name, spec] of Object.entries(livePublished)) liveWorkspace[name] = { deps: spec.deps };

  const liveBroken = simulateRun({
    order: liveOrder,
    published: livePublished,
    workspace: liveWorkspace,
    releasable: {},
    lockstep: false,
  });
  if (
    liveBroken.problems.some((p) => p.package === 'ball_resolver' && p.dep === 'ball_base') &&
    liveBroken.problems.some((p) => p.package === 'ball_rpc' && p.dep === 'ball_protobuf')
  ) {
    ok('reproduces the live pub.dev split: ball_resolver and ball_rpc are the unsolvable nodes');
  } else {
    no(
      'reproduces the live pub.dev split: ball_resolver and ball_rpc are the unsolvable nodes',
      JSON.stringify(liveBroken.problems),
    );
  }

  const liveFixed = simulateRun({
    order: liveOrder,
    published: livePublished,
    workspace: liveWorkspace,
    releasable: {},
    lockstep: true,
  });
  const forced = Object.keys(liveFixed.released).sort();
  if (forced.length === 2 && forced[0] === 'ball_resolver' && forced[1] === 'ball_rpc') {
    ok('the fix-forward plan for the live graph is exactly ball_resolver + ball_rpc');
  } else {
    no('the fix-forward plan for the live graph is exactly ball_resolver + ball_rpc', forced.join(' ') || '(none)');
  }
  if (liveFixed.problems.length === 0) {
    ok('after that plan the live nine-package graph resolves for an external consumer');
  } else {
    no(
      'after that plan the live nine-package graph resolves for an external consumer',
      ...liveFixed.problems.map((p) => `${p.package} requires ${p.dep} ${p.constraint}, live at ${p.version}`),
    );
  }

  // ── Version arithmetic, the part the plan's predictions rest on.
  const bumps = [
    ['0.3.0+3', 'patch', '0.3.1'],
    ['0.3.0+3', 'minor', '0.4.0'],
    ['0.4.0', 'patch', '0.4.1'],
    ['0.4.0', 'major', '1.0.0'],
    ['1.2.3', 'minor', '1.3.0'],
  ];
  let bumpsOk = true;
  for (const [from, type, want] of bumps) {
    const got = nextVersion(from, type);
    if (got !== want) {
      bumpsOk = false;
      no('bumps versions the way semantic-release does', `${from} ${type} -> ${got}, expected ${want}`);
    }
  }
  if (bumpsOk) ok('bumps versions the way semantic-release does (build metadata dropped)');

  // ── Pubspec parsing: runtime section only, CRLF-safe.
  const pubspec = [
    'name: pkg_x',
    'version: 1.0.0',
    '',
    'dependencies:',
    '  pkg_a: ^1.0.0  # documented',
    '  third_party: ^2.0.0',
    '',
    'dev_dependencies:',
    '  pkg_b: ^1.0.0',
    '',
  ].join('\n');
  const parsed = runtimeDeps(pubspec);
  if (parsed.pkg_a === '^1.0.0' && parsed.third_party === '^2.0.0' && parsed.pkg_b === undefined) {
    ok('reads runtime dependency constraints and ignores dev_dependencies');
  } else {
    no('reads runtime dependency constraints and ignores dev_dependencies', JSON.stringify(parsed));
  }
  const crlf = runtimeDeps(pubspec.replace(/\n/g, '\r\n'));
  if (crlf.pkg_a === '^1.0.0' && crlf.pkg_b === undefined) {
    ok('parses a CRLF pubspec identically');
  } else {
    no('parses a CRLF pubspec identically', JSON.stringify(crlf));
  }

  // ── An unmodelled constraint shape must never force a release.
  const exotic = unsatisfiedAgainst({ pkg_a: 'any', pkg_b: '>=1.0.0 <2.0.0' }, { pkg_a: '9.9.9', pkg_b: '9.9.9' });
  if (exotic.length === 0) {
    ok('an unmodelled constraint shape (`any`, a range) never forces a release');
  } else {
    no('an unmodelled constraint shape never forces a release', JSON.stringify(exotic));
  }

  // ── The repo itself must parse: the planner reads real pubspecs in CI.
  const repo = readWorkspacePackages(join(ROOT, 'pubspec.yaml'));
  const repoNames = Object.keys(repo);
  if (repoNames.length >= 2 && repo.ball_base && repo.ball_base.deps.ball_protobuf) {
    ok(`reads the repo's ${repoNames.length} publishable packages and their sibling edges`);
  } else {
    no("reads the repo's publishable packages and their sibling edges", repoNames.join(' ') || '(none)');
  }

  const total = pass + fail;
  const MIN = 16;
  if (total < MIN) {
    console.error(
      `::error::lockstep planner self-test ran ${total} cases, expected at least ${MIN} — the sweep itself is broken`,
    );
    process.exit(1);
  }
  console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);
  process.exit(fail === 0 ? 0 : 1);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args['self-test']) return selfTest();
  if (args['fetch-published']) return cmdFetchPublished(args);
  if (args.decide) return cmdDecide(args);
  if (args.record) return cmdRecord(args);
  console.error(
    'usage: lockstep_plan.mjs --fetch-published [--out=FILE] | --decide --package=NAME | ' +
      '--record --package=NAME --version=V --type=T | --self-test',
  );
  process.exit(2);
}

const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  main().catch((error) => {
    console.error(`::error::${error && error.message ? error.message : error}`);
    process.exit(1);
  });
}
