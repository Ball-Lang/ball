// Breaking-change detection from a squash-merged PR TITLE, on every release
// line (issue #923).
//
// WHY: `main` squash-merges with `squash_merge_commit_title: PR_TITLE` +
// `squash_merge_commit_message: BLANK` (issue #881), so the ONLY text of a PR
// that reaches `main` is "<PR title> (#N)" — no body, so no `BREAKING CHANGE:`
// footer, ever. Every release line used to run semantic-release's default
// `angular` preset, whose header pattern does not even match `feat(x)!: ...`
// (the `!` breaks it) and which recognises a breaking change ONLY from a body
// footer. So no PR could cut a major release on any line. Every config now
// runs @semantic-release/commit-analyzer and release-notes-generator with the
// `conventionalcommits` preset, whose `breakingHeaderPattern` makes
// conventional-commits-parser attach a BREAKING CHANGE note for a `!` header —
// and commit-analyzer's default `{ breaking: true, release: "major" }` rule
// fires on any note.
//
// WHAT THIS PROVES, for EVERY config semantic-release can be pointed at (the
// root .releaserc.json and each .github/release/*.releaserc.json), using that
// config's OWN plugin entry and options, not a hand-copied one:
//   1. it configures both plugins with preset `conventionalcommits` + a
//      `presetConfig` object (the plugins' READMEs: "For presets that expects
//      a configuration object, such as conventionalcommits, the presetConfig
//      option must be set");
//   2. against real commits in a throwaway git repo, with EMPTY bodies — the
//      shape GitHub now lands — the real commit-analyzer computes MAJOR for
//      `feat(scope)!:` / `fix!:`, MINOR for `feat`, PATCH for `fix`, and no
//      release for `chore`/`docs`/a release commit;
//   3. for the path-filtered lines, tools/release/only-package-commits.mjs
//      still composes with the preset: a breaking commit OUTSIDE the line's
//      paths changes neither the bump nor the notes;
//   4. the real release-notes-generator renders the preset through the
//      writer this toolchain pins (a preset/writer major mismatch — e.g.
//      conventionalcommits 10.x's render functions on writer 8 — throws here
//      instead of in a release run) and lists the breaking change.
// Plus a negative control: the same `feat(scope)!:` commit through the OLD
// configuration (no preset, i.e. angular) computes NO release — so this test
// can tell the two apart, and is red on the pre-#923 configs.
//
// Deterministic and offline: local git only, no network, no clock in any
// assertion. Needs the pinned toolchain installed (it imports the real
// plugins); CI's always-on Proto Checks job runs exactly:
//
//   cd tools/release && npm ci --ignore-scripts
//   node --test tools/release/test/conventional_commits_preset_test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, describe, test } from "node:test";

import { analyzeCommits as commitAnalyzer } from "@semantic-release/commit-analyzer";
import { generateNotes as releaseNotesGenerator } from "@semantic-release/release-notes-generator";

import { analyzeCommits as filteredAnalyze, generateNotes as filteredNotes } from "../only-package-commits.mjs";

const REPO_ROOT = path.resolve(import.meta.dirname, "..", "..", "..");
const ANALYZER = "@semantic-release/commit-analyzer";
const NOTES_GENERATOR = "@semantic-release/release-notes-generator";
const PATH_FILTER = "./tools/release/only-package-commits.mjs";
const PRESET = "conventionalcommits";
const REPOSITORY_URL = "https://github.com/Ball-Lang/ball.git";

// The lockstep override (#566) would turn a "no release" verdict into a forced
// one; it is set only by pubdev-release.yml for one invocation.
delete process.env.SR_FORCE_RELEASE;

const logger = { log() {}, warn() {}, error() {}, success() {} };

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// ── every config semantic-release can be pointed at ─────────────────────
function releaseConfigFiles() {
  const perLine = readdirSync(path.join(REPO_ROOT, ".github", "release"))
    .filter((name) => name.endsWith(".releaserc.json"))
    .sort()
    .map((name) => `.github/release/${name}`);
  return [".releaserc.json", ...perLine];
}

/** A config's plugin entries as {name, options} ("name" or ["name", opts]). */
function pluginEntries(config) {
  return (config.plugins ?? []).map((entry) =>
    Array.isArray(entry) ? { name: entry[0], options: entry[1] ?? {} } : { name: entry, options: {} }
  );
}

/**
 * How this release line analyzes commits and writes notes, derived from its
 * own config. semantic-release calls every plugin step as
 * `step({...globalOptions, ...pluginOptions}, context)` (lib/plugins/
 * normalize.js), so that is what `pluginConfig` is here too.
 */
function laneOf(file) {
  const config = JSON.parse(readFileSync(path.join(REPO_ROOT, file), "utf8"));
  const { plugins: _plugins, ...globalOptions } = config;
  const entries = pluginEntries(config);
  const filters = entries.filter((p) => p.name === PATH_FILTER);
  const analyzers = entries.filter((p) => p.name === ANALYZER);
  const generators = entries.filter((p) => p.name === NOTES_GENERATOR);
  const tag = (version) => (config.tagFormat ?? "v${version}").replace("${version}", version);

  if (filters.length === 1 && analyzers.length === 0 && generators.length === 0) {
    const pluginConfig = { ...globalOptions, ...filters[0].options };
    return {
      file,
      tag,
      paths: filters[0].options.paths,
      analyzerConfig: filters[0].options.commitAnalyzer,
      notesConfig: filters[0].options.releaseNotesGenerator,
      analyze: (context) => filteredAnalyze(pluginConfig, context),
      notes: (context) => filteredNotes(pluginConfig, context),
    };
  }
  if (filters.length === 0 && analyzers.length === 1 && generators.length === 1) {
    return {
      file,
      tag,
      paths: null,
      analyzerConfig: analyzers[0].options,
      notesConfig: generators[0].options,
      analyze: (context) => commitAnalyzer({ ...globalOptions, ...analyzers[0].options }, context),
      notes: (context) => releaseNotesGenerator({ ...globalOptions, ...generators[0].options }, context),
    };
  }
  // Two sources of analyzeCommits would both run (semantic-release takes the
  // highest), so an unfiltered analyzer beside the path filter would leak
  // every other line's commits into this one.
  throw new Error(
    `${file}: expected EITHER exactly one ${PATH_FILTER} entry OR exactly one ${ANALYZER} + one ` +
      `${NOTES_GENERATOR} entry; found ${filters.length} path filter(s), ${analyzers.length} analyzer(s), ` +
      `${generators.length} notes generator(s)`
  );
}

const FILES = releaseConfigFiles();
const LANES = FILES.map(laneOf);

// ── a throwaway repo with real commits, shaped the way `main` gets them ──
const FIXTURE = mkdtempSync(path.join(tmpdir(), "ball-sr-preset-"));
after(() => rmSync(FIXTURE, { recursive: true, force: true }));

function git(args, input) {
  return execFileSync(
    "git",
    ["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", ...args],
    { cwd: FIXTURE, encoding: "utf8", input, stdio: ["pipe", "pipe", "pipe"] }
  );
}

git(["init", "-q"]);
let fileCounter = 0;

/**
 * Commit one file under `dir` with `message` (subject, or subject + "\n\n" +
 * body). With no body this is exactly "<PR title> (#N)" + nothing, the only
 * shape a squash-merged PR reaches `main` in. Returns the commit the way
 * semantic-release's git log hands it to the plugins.
 */
function commitUnder(dir, message) {
  fileCounter += 1;
  const file = `${dir}/change_${fileCounter}.txt`;
  mkdirSync(path.join(FIXTURE, dir), { recursive: true });
  writeFileSync(path.join(FIXTURE, file), `${message}\n`);
  git(["add", "--", file]);
  git(["commit", "-q", "--no-verify", "-F", "-"], `${message}\n`);
  const hash = git(["rev-parse", "HEAD"]).trim();
  const raw = git(["log", "-1", "--format=%B", hash]);
  const [subject, ...rest] = raw.trimEnd().split("\n");
  return { hash, message: raw, subject, body: rest.join("\n").trim() };
}

// Each lane's commits live under ITS OWN paths, so the path filter keeps them;
// the unfiltered root line gets a directory no other line claims.
const SCENARIOS = [
  { name: "scoped feat! (the #923 case)", subject: "feat(api)!: drop the deprecated entry point (#9001)", want: "major" },
  { name: "unscoped fix!", subject: "fix!: change a default (#9002)", want: "major" },
  { name: "feat", subject: "feat(api): add an entry point (#9003)", want: "minor" },
  { name: "fix", subject: "fix(api): repair an edge case (#9004)", want: "patch" },
  { name: "perf", subject: "perf(api): cache a lookup (#9005)", want: "patch" },
  { name: "chore", subject: "chore(api): tidy up (#9006)", want: null },
  { name: "docs", subject: "docs: explain the entry point (#9007)", want: null },
  { name: "a release commit", subject: "chore(release): 1.73.0 (#912)", want: null },
  {
    name: "feat + BREAKING CHANGE footer (a non-squash commit's body)",
    subject: "feat(api): rework the entry point (#9008)",
    body: "BREAKING CHANGE: the old entry point is gone",
    want: "major",
  },
];

for (const lane of LANES) {
  const dir = lane.paths ? lane.paths[0] : "root-lane";
  lane.commits = new Map(
    SCENARIOS.map((s) => [s.name, commitUnder(dir, s.body ? `${s.subject}\n\n${s.body}` : s.subject)])
  );
}
// A breaking change that NO path-filtered line owns.
const OUTSIDER = commitUnder("unrelated-dir", "feat(elsewhere)!: break something no lane owns (#9100)");

function analyzerContext(commits) {
  return { cwd: FIXTURE, env: {}, commits, logger, options: { repositoryUrl: REPOSITORY_URL } };
}

function notesContext(lane, commits) {
  return {
    cwd: FIXTURE,
    env: {},
    commits,
    logger,
    options: { repositoryUrl: REPOSITORY_URL },
    lastRelease: { version: "1.0.0", gitTag: lane.tag("1.0.0") },
    nextRelease: { version: "2.0.0", gitTag: lane.tag("2.0.0"), type: "major" },
  };
}

// ── tests ────────────────────────────────────────────────────────────────

test("every release config is found, and the set is not vacuous", () => {
  assert.ok(FILES.includes(".releaserc.json"), "the root .releaserc.json must be covered");
  assert.ok(
    FILES.length >= 2,
    `expected the root config plus the .github/release/*.releaserc.json lines, found only: ${FILES.join(", ")}`
  );
  assert.equal(LANES.length, FILES.length);
  assert.ok(LANES.some((l) => l.paths === null), "no unfiltered (root) line found");
  assert.ok(LANES.some((l) => l.paths !== null), "no path-filtered line found");
});

test("negative control: the pre-#923 default (angular) computes NO release for `feat(api)!:`", async () => {
  // This is every line's configuration before #923: commit-analyzer with no
  // preset. If this ever returns "major", the test below cannot tell the old
  // and new configurations apart, and proves nothing.
  const breaking = LANES[0].commits.get("scoped feat! (the #923 case)");
  assert.equal(await commitAnalyzer({}, analyzerContext([breaking])), null);
  assert.equal(
    await commitAnalyzer({ preset: PRESET, presetConfig: {} }, analyzerContext([breaking])),
    "major"
  );
});

for (const lane of LANES) {
  describe(lane.file, () => {
    test(`configures both plugins with preset "${PRESET}" and a presetConfig object`, () => {
      for (const [role, cfg] of [
        ["commit-analyzer", lane.analyzerConfig],
        ["release-notes-generator", lane.notesConfig],
      ]) {
        assert.ok(isPlainObject(cfg), `${role}: no options object (it would run the default angular preset)`);
        assert.equal(cfg.preset, PRESET, `${role}: preset must be "${PRESET}" (got ${JSON.stringify(cfg.preset)})`);
        assert.ok(isPlainObject(cfg.presetConfig), `${role}: presetConfig must be set to an object for ${PRESET}`);
        assert.equal(cfg.config, undefined, `${role}: \`config\` is overwritten by \`preset\`; set only one`);
      }
    });

    for (const scenario of SCENARIOS) {
      test(`${scenario.name}: ${JSON.stringify(scenario.subject)} -> ${scenario.want ?? "no release"}`, async () => {
        const own = lane.commits.get(scenario.name);
        if (!scenario.body) {
          assert.equal(own.body, "", "fixture: a squash-merged commit has an EMPTY body");
        }
        // A path-filtered line also sees the outsider; it must be filtered out.
        const commits = lane.paths ? [own, OUTSIDER] : [own];
        assert.equal(await lane.analyze(analyzerContext(commits)), scenario.want);
      });
    }

    if (lane.paths) {
      test("a breaking commit outside this line's paths releases nothing here", async () => {
        assert.equal(await lane.analyze(analyzerContext([OUTSIDER])), null);
      });
    }

    test("release notes render through the pinned writer and list the breaking change", async () => {
      const breaking = lane.commits.get("scoped feat! (the #923 case)");
      const feature = lane.commits.get("feat");
      const commits = lane.paths ? [breaking, feature, OUTSIDER] : [breaking, feature];
      const notes = await lane.notes(notesContext(lane, commits));
      assert.equal(typeof notes, "string");
      assert.match(notes, /BREAKING CHANGES/, `no breaking-changes section in:\n${notes}`);
      assert.match(notes, /drop the deprecated entry point/);
      assert.match(notes, /add an entry point/);
      if (lane.paths) {
        assert.doesNotMatch(notes, /break something no lane owns/, "the path filter leaked into the notes");
      }
    });
  });
}
