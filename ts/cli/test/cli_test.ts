/**
 * Ball CLI tests.
 *
 * Run: node --experimental-strip-types --disable-warning=ExperimentalWarning test/cli_test.ts
 */

import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(here, '..');
const cliEntry = join(projectRoot, 'src', 'index.ts');
const repoRoot = join(projectRoot, '..', '..');
const conformanceDir = join(repoRoot, 'tests', 'conformance');

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.log(`  ✗ ${name}: ${e?.message ?? e}`);
    failed++;
  }
}

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

interface RunResult {
  stdout: string;
  stderr: string;
  status: number | null;
}

function runCli(args: string[]): RunResult {
  const result = spawnSync(
    process.execPath,
    [
      '--experimental-strip-types',
      '--disable-warning=ExperimentalWarning',
      cliEntry,
      ...args,
    ],
    { encoding: 'utf8' },
  );
  return {
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    status: result.status,
  };
}

console.log('Ball CLI Tests');
console.log('==============\n');

// ── --version / --help ──────────────────────────────────────────────────────

console.log('Meta:');

test('--version prints the version from package.json', () => {
  const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  const r = runCli(['--version']);
  assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
  assert(
    r.stdout.trim() === String(pkg.version),
    `expected ${pkg.version}, got ${r.stdout.trim()}`,
  );
});

test('-v is a --version alias', () => {
  const r = runCli(['-v']);
  assert(r.status === 0, `exit ${r.status}`);
  assert(r.stdout.trim().length > 0, 'empty output');
});

test('--help prints usage', () => {
  const r = runCli(['--help']);
  assert(r.status === 0, `exit ${r.status}`);
  assert(r.stdout.includes('USAGE'), 'missing USAGE section');
  assert(r.stdout.includes('run '), 'missing run command');
  assert(r.stdout.includes('audit '), 'missing audit command');
});

test('no args prints usage', () => {
  const r = runCli([]);
  assert(r.status === 0, `exit ${r.status}`);
  assert(r.stdout.includes('USAGE'), 'missing USAGE');
});

test('unknown command exits non-zero', () => {
  const r = runCli(['nonsense']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('unknown command'), 'missing error message');
});

// ── run ─────────────────────────────────────────────────────────────────────

console.log('\nrun:');

const fib = join(conformanceDir, '28_fibonacci.ball.json');

if (existsSync(fib)) {
  test('run produces correct fibonacci output', () => {
    const expected = readFileSync(
      join(conformanceDir, '28_fibonacci.expected_output.txt'),
      'utf8',
    ).trim();
    const r = runCli(['run', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(
      r.stdout.trim() === expected,
      `output mismatch\nexpected: ${expected}\nactual:   ${r.stdout.trim()}`,
    );
  });
} else {
  console.log('  (skipping run test: fibonacci conformance file not found)');
}

test('run without path errors out', () => {
  const r = runCli(['run']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('requires a program path'), 'missing error message');
});

test('run on missing file errors out', () => {
  const r = runCli(['run', '/nonexistent/file.ball.json']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('File not found'), 'missing error message');
});

// ── audit ───────────────────────────────────────────────────────────────────

console.log('\naudit:');

if (existsSync(fib)) {
  test('audit on pure program reports no effectful', () => {
    const r = runCli(['audit', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(r.stdout.includes('Ball Capability Audit'), 'missing header');
    assert(r.stdout.includes('Summary:'), 'missing summary');
  });

  test('audit --json emits valid JSON', () => {
    const r = runCli(['audit', fib, '--json']);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    const report = JSON.parse(r.stdout);
    assert(typeof report.summary === 'object', 'missing summary');
    assert(Array.isArray(report.capabilities), 'missing capabilities');
    assert(Array.isArray(report.functions), 'missing functions');
  });
}

// Synthetic program that calls std_fs.file_read — must trip --deny fs.
const fsProgram = {
  name: 'fs_using',
  version: '1.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    {
      name: 'std',
      functions: [{ name: 'print', isBase: true }],
    },
    {
      name: 'std_fs',
      functions: [{ name: 'file_read', isBase: true }],
    },
    {
      name: 'main',
      functions: [
        {
          name: 'main',
          body: {
            call: {
              module: 'std',
              function: 'print',
              input: {
                call: {
                  module: 'std_fs',
                  function: 'file_read',
                  input: {
                    messageCreation: {
                      fields: [
                        {
                          name: 'path',
                          value: { literal: { stringValue: '/etc/hosts' } },
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
        },
      ],
    },
  ],
};

import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const tmpDir = mkdtempSync(join(tmpdir(), 'ball-cli-test-'));
const fsProgramPath = join(tmpDir, 'fs.ball.json');
writeFileSync(fsProgramPath, JSON.stringify(fsProgram));

test('audit --deny fs on fs-using program exits 1', () => {
  const r = runCli(['audit', fsProgramPath, '--deny', 'fs']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(
    r.stderr.includes('Policy violations'),
    `missing policy-violations header in stderr:\n${r.stderr}`,
  );
  assert(
    r.stderr.includes('std_fs.file_read'),
    'missing violation for std_fs.file_read',
  );
});

test('audit without --deny on fs-using program exits 0', () => {
  const r = runCli(['audit', fsProgramPath]);
  assert(r.status === 0, `expected exit 0, got ${r.status}: ${r.stderr}`);
  assert(r.stdout.includes('fs'), 'fs capability not mentioned');
});

test('audit --output writes JSON file', () => {
  const outPath = join(tmpDir, 'report.json');
  const r = runCli(['audit', fsProgramPath, '--output', outPath]);
  assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
  assert(existsSync(outPath), 'report file not written');
  const report = JSON.parse(readFileSync(outPath, 'utf8'));
  assert(report.summary.readsFilesystem === true, 'fs not detected in JSON report');
});

// ── Summary ─────────────────────────────────────────────────────────────────

try {
  rmSync(tmpDir, { recursive: true, force: true });
} catch {
  // Ignore cleanup errors.
}

console.log(`\n==============`);
console.log(`Results: ${passed} passed, ${failed} failed, ${passed + failed} total`);
process.exit(failed > 0 ? 1 : 0);
