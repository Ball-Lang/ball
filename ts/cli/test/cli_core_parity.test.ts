/**
 * Self-host parity gate for the compiled cli-core verbs (issue #364).
 *
 * For a golden set of `tests/conformance/*.ball.json` fixtures (the same
 * slice `dart/cli/test/cli_core_parity_test.dart` uses) plus two synthetic
 * programs exercising edge cases the golden corpus doesn't reach, this
 * spawns BOTH the native Dart CLI (`dart/cli`, compiled to a native exe for
 * speed) and the TypeScript CLI (`ts/cli/src/index.ts`, via
 * `@ball-lang/compiler`'s compiled `cli_core.dart` → `compiled_cli.ts`) as
 * real subprocesses and asserts their `info` / `validate` / `tree` /
 * `version` output is byte-identical.
 *
 * This is the "run the Dart CLI via `dart run`" option (adapted to
 * `dart compile exe`, since JIT-starting `dart run` per invocation is too
 * slow for a fixture x verb matrix) rather than checked-in golden text files
 * — the Dart SDK is present in every environment this suite runs in (local
 * dev per CLAUDE.md's Build & Test, and the "typescript" CI job installs it
 * via `dart-lang/setup-dart` specifically because `ts/compiler`'s own
 * `engine_parse.test.ts` already needs it), and running the real CLI is a
 * stronger proof than a stale snapshot. When the Dart SDK genuinely isn't on
 * PATH (e.g. a slimmed-down local checkout), the whole suite skips instead
 * of failing.
 *
 * Regenerate `compiled_cli.ts` first if `dart/shared/lib/cli_core.dart`
 * changed — see CLAUDE.md's "Regenerate compiled TS CLI core" recipe.
 */

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = findRepoRoot(here);
const conformanceDir = join(repoRoot, 'tests', 'conformance');
const dartCliDir = join(repoRoot, 'dart', 'cli');
const tsCliEntry = join(repoRoot, 'ts', 'cli', 'src', 'index.ts');

function findRepoRoot(start: string): string {
  let dir = start;
  for (;;) {
    if (existsSync(join(dir, 'proto', 'ball', 'v1', 'ball.proto'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error('Could not locate repo root from ' + start);
    dir = parent;
  }
}

// On Windows the `dart` launcher on PATH is a `.bat` shim (bundled with the
// Flutter SDK); `child_process.spawnSync('dart', ...)` without `shell: true`
// fails to resolve it (ENOENT) — a well-known Node-on-Windows batch-file
// resolution gap, unrelated to whether Dart is actually installed.
const DART_SPAWN_OPTS = { encoding: 'utf8' as const, shell: process.platform === 'win32' };

function dartAvailable(): boolean {
  try {
    const r = spawnSync('dart', ['--version'], DART_SPAWN_OPTS);
    return r.status === 0;
  } catch {
    return false;
  }
}

/** Golden fixtures — mirrors dart/cli/test/cli_core_parity_test.dart's own slice. */
const GOLDEN_FIXTURES = [
  '100_complex_control_flow',
  '101_simple_class',
  '111_cascade_operator',
  '116_map_iteration',
  '118_set_operations',
];

const skipReason = dartAvailable() ? false : 'dart SDK not on PATH — skipping cli_core parity gate';

describe('cli_core parity: compiled TS cli-core vs the native Dart CLI', { skip: skipReason }, () => {
  let dartBin = '';
  let workDir = '';

  before(() => {
    // Compile the Dart CLI to a native binary once. `dart run` re-JITs the
    // whole package on every invocation (~15-30s); with 5 fixtures x 3 verbs
    // plus edge-case fixtures, that would make this suite prohibitively slow.
    workDir = mkdtempSync(join(tmpdir(), 'ball-cli-parity-'));
    dartBin = join(workDir, process.platform === 'win32' ? 'ball_dart_cli.exe' : 'ball_dart_cli');
    const r = spawnSync('dart', ['compile', 'exe', 'bin/ball.dart', '-o', dartBin], {
      cwd: dartCliDir,
      ...DART_SPAWN_OPTS,
    });
    assert.equal(r.status, 0, `dart compile exe failed:\n${r.stdout}\n${r.stderr}`);
  });

  after(() => {
    if (workDir) rmSync(workDir, { recursive: true, force: true });
  });

  function runDart(args: string[]) {
    const r = spawnSync(dartBin, args, { encoding: 'utf8' });
    return { stdout: r.stdout ?? '', stderr: r.stderr ?? '', status: r.status };
  }

  function runTs(args: string[]) {
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', tsCliEntry, ...args],
      { encoding: 'utf8' },
    );
    return { stdout: r.stdout ?? '', stderr: r.stderr ?? '', status: r.status };
  }

  for (const fixture of GOLDEN_FIXTURES) {
    const path = join(conformanceDir, `${fixture}.ball.json`);
    if (!existsSync(path)) continue;

    for (const verb of ['info', 'validate', 'tree'] as const) {
      test(`${verb} ${fixture}: TS output matches the native Dart CLI`, () => {
        const dart = runDart([verb, path]);
        const ts = runTs([verb, path]);
        assert.equal(ts.status, dart.status, `exit code mismatch (dart=${dart.status}, ts=${ts.status})`);
        assert.equal(ts.stdout, dart.stdout, `stdout mismatch for "${verb} ${fixture}"`);
      });
    }
  }

  // `ball version`'s FORMAT ("ball <version>\n", from the shared
  // cli_core.versionLine template) must match — the version NUMBER itself
  // legitimately differs, since ts/cli and dart/cli are independently
  // versioned/released packages (semantic-release per language).
  test('version: TS output matches the native Dart CLI\'s "ball <version>" format', () => {
    const dart = runDart(['version']);
    const ts = runTs(['version']);
    assert.equal(ts.status, dart.status);
    assert.match(dart.stdout, /^ball \S+\n$/, 'dart CLI: expected "ball <version>" format');
    assert.match(ts.stdout, /^ball \S+\n$/, 'ts CLI: expected "ball <version>" format');
  });

  // Edge case the golden fixtures never reach: validationErrors() reporting
  // both a missing entry_module and a missing entry_function, routed to
  // stderr with exit 1 on both CLIs.
  test('validate on an invalid program: TS matches the native Dart CLI (stderr, exit 1)', () => {
    const invalidProgram = {
      '@type': 'type.googleapis.com/ball.v1.Program',
      name: 'incomplete',
      version: '1.0.0',
      entryModule: '',
      entryFunction: '',
      modules: [],
    };
    const path = join(workDir, 'invalid.ball.json');
    writeFileSync(path, JSON.stringify(invalidProgram));

    const dart = runDart(['validate', path]);
    const ts = runTs(['validate', path]);
    assert.equal(ts.status, dart.status);
    assert.equal(ts.status, 1, 'expected exit 1 on both CLIs');
    assert.equal(ts.stderr, dart.stderr, 'stderr mismatch');
  });

  // Edge case the golden fixtures never reach: every ModuleImport.source
  // oneof variant (http/file/git/registry/inline) plus a ref-only import —
  // exercises cli_core.dart's _importSource end to end, including the
  // RegistrySource.registry enum-name access that used to crash the
  // compiled TS output with "hasHttp is not defined" (a genuine
  // @ball-lang/compiler preamble gap — see ts/compiler/src/preamble.ts).
  test('tree with every ModuleImport source kind: TS matches the native Dart CLI', () => {
    const treeProgram = {
      '@type': 'type.googleapis.com/ball.v1.Program',
      name: 'synth',
      version: '1.0.0',
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        {
          name: 'main',
          functions: [{ name: 'main', body: { literal: { intValue: 0 } } }],
          moduleImports: [
            { name: 'reg_imp', registry: { package: 'foo', version: '^1.0.0', registry: 'REGISTRY_PUB' } },
            { name: 'http_imp', http: { url: 'https://example.com/x.ball.bin' } },
            { name: 'file_imp', file: { path: './local.ball.bin' } },
            { name: 'git_imp', git: { url: 'https://example.com/repo.git', ref: 'v1.0.0' } },
            { name: 'inline_imp', inline: { json: '{}' } },
            { name: 'ref_only_imp' },
          ],
        },
      ],
    };
    const path = join(workDir, 'tree_imports.ball.json');
    writeFileSync(path, JSON.stringify(treeProgram));

    const dart = runDart(['tree', path]);
    const ts = runTs(['tree', path]);
    assert.equal(ts.status, 0);
    assert.equal(dart.status, 0);
    assert.equal(ts.stdout, dart.stdout, 'stdout mismatch');
  });
});
