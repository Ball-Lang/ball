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

test('--version prints "ball <version>" (cli_core.versionLine, matching the Dart CLI)', () => {
  const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
  const r = runCli(['--version']);
  assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
  assert(
    r.stdout.trim() === `ball ${pkg.version}`,
    `expected "ball ${pkg.version}", got ${r.stdout.trim()}`,
  );
});

test('-v is a --version alias', () => {
  const r = runCli(['-v']);
  assert(r.status === 0, `exit ${r.status}`);
  assert(r.stdout.trim().startsWith('ball '), `expected "ball <version>", got ${r.stdout.trim()}`);
});

test('version (bare command) prints the same "ball <version>" text as --version', () => {
  const r = runCli(['version']);
  assert(r.status === 0, `exit ${r.status}`);
  const versionFlag = runCli(['--version']);
  assert(
    r.stdout === versionFlag.stdout,
    `expected 'version' and '--version' to match: ${JSON.stringify(r.stdout)} vs ${JSON.stringify(versionFlag.stdout)}`,
  );
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
    // Normalize CRLF: on a Windows checkout (.gitattributes text=auto) the
    // expected file carries \r\n while the CLI emits \n.
    const norm = (s: string) => s.replace(/\r\n/g, '\n').trim();
    const expected = norm(
      readFileSync(
        join(conformanceDir, '28_fibonacci.expected_output.txt'),
        'utf8',
      ),
    );
    const r = runCli(['run', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(
      norm(r.stdout) === expected,
      `output mismatch\nexpected: ${expected}\nactual:   ${norm(r.stdout)}`,
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

// A program that writes to stderr via std_io.print_error — exercises the
// `stderr` callback wired into `new BallEngine(...)` in cmdRun (line 188),
// which the stdout-only fibonacci happy-path test never triggers.
const stderrProgram = {
  name: 'writes_stderr',
  version: '1.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    { name: 'std_io', functions: [{ name: 'print_error', isBase: true }] },
    {
      name: 'main',
      functions: [
        {
          name: 'main',
          body: {
            call: {
              module: 'std_io',
              function: 'print_error',
              input: { messageCreation: { fields: [{ name: 'message', value: { literal: { stringValue: 'oops' } } }] } },
            },
          },
        },
      ],
    },
  ],
};

test('run wires a program\'s std_io.print_error to the process stderr stream', () => {
  const stderrProgramPath = join(tmpdir(), `ball-cli-stderr-${process.pid}.ball.json`);
  writeFileSync(stderrProgramPath, JSON.stringify(stderrProgram));
  try {
    const r = runCli(['run', stderrProgramPath]);
    assert(r.status === 0, `expected exit 0, got ${r.status}: ${r.stderr}`);
    assert(r.stderr.includes('oops'), `expected "oops" on stderr, got:\n${r.stderr}`);
    assert(!r.stdout.includes('oops'), 'stderr output leaked onto stdout');
  } finally {
    rmSync(stderrProgramPath, { force: true });
  }
});

// A program that throws at runtime (std.null_check on an explicit null) —
// exercises cmdRun's `catch (e) { fail(\`runtime error: ...\`) }` path, which
// the fibonacci happy-path test above never reaches.
const nullCheckProgram = {
  name: 'crashes',
  version: '1.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    { name: 'std', functions: [{ name: 'null_check', isBase: true }] },
    {
      name: 'main',
      functions: [
        {
          name: 'main',
          body: {
            block: {
              statements: [{ let: { name: 'x', value: { literal: {} } } }],
              result: {
                call: {
                  module: 'std',
                  function: 'null_check',
                  input: {
                    messageCreation: { fields: [{ name: 'value', value: { reference: { name: 'x' } } }] },
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

test('run reports a runtime error (not a silent crash) when the program throws', () => {
  const nullCheckPath = join(tmpdir(), `ball-cli-null-check-${process.pid}.ball.json`);
  writeFileSync(nullCheckPath, JSON.stringify(nullCheckProgram));
  try {
    const r = runCli(['run', nullCheckPath]);
    assert(r.status === 1, `expected exit 1, got ${r.status}`);
    assert(r.stderr.includes('runtime error:'), `missing "runtime error:" prefix in stderr:\n${r.stderr}`);
    assert(r.stderr.includes('Null check'), `missing null-check message in stderr:\n${r.stderr}`);
  } finally {
    rmSync(nullCheckPath, { force: true });
  }
});

test('run on a directory path reports the non-ENOENT read error, not "File not found"', () => {
  // Reading a directory throws EISDIR (not ENOENT) — exercises loadProgram's
  // second `fail()` branch, distinct from the "File not found" ENOENT case.
  const r = runCli(['run', projectRoot]);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('Could not read'), `missing "Could not read" in stderr:\n${r.stderr}`);
  assert(!r.stderr.includes('File not found'), 'should not be misreported as ENOENT');
});

test('run on malformed JSON reports an "Invalid JSON" error', () => {
  const badJsonPath = join(tmpdir(), `ball-cli-bad-json-${process.pid}.ball.json`);
  writeFileSync(badJsonPath, '{ not valid json');
  try {
    const r = runCli(['run', badJsonPath]);
    assert(r.status === 1, `expected exit 1, got ${r.status}`);
    assert(r.stderr.includes('Invalid JSON'), `missing "Invalid JSON" in stderr:\n${r.stderr}`);
  } finally {
    rmSync(badJsonPath, { force: true });
  }
});

test('run on a ball file with an unrecognized @type reports an "Invalid ball file" error', () => {
  const badTypePath = join(tmpdir(), `ball-cli-bad-type-${process.pid}.ball.json`);
  writeFileSync(badTypePath, JSON.stringify({ '@type': 'type.googleapis.com/ball.v1.Widget' }));
  try {
    const r = runCli(['run', badTypePath]);
    assert(r.status === 1, `expected exit 1, got ${r.status}`);
    assert(r.stderr.includes('Invalid ball file'), `missing "Invalid ball file" in stderr:\n${r.stderr}`);
  } finally {
    rmSync(badTypePath, { force: true });
  }
});

// ── info / validate / tree ────────────────────────────────────────────────
//
// All three delegate their report text to the compiled cli-core (issue #364)
// — `dart/self_host/cli.ball.json` compiled through `@ball-lang/compiler`,
// wrapped by `src/cli_core.ts`. The parity gate (`cli_core_parity_test.ts`)
// proves the computed report bytes match the native Dart CLI; these tests
// exercise the CLI-level argv wiring (usage errors, exit codes, streams).

console.log('\ninfo/validate/tree:');

if (existsSync(fib)) {
  test('info on a fixture reports its structure', () => {
    const r = runCli(['info', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(r.stdout.includes('Program:'), 'missing "Program:" header');
    assert(r.stdout.includes('Entry:'), 'missing "Entry:" line');
    assert(r.stdout.includes('Modules:'), 'missing "Modules:" line');
  });

  test('validate on a valid fixture reports Valid: and exits 0', () => {
    const r = runCli(['validate', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(r.stdout.trim().startsWith('Valid:'), `expected "Valid:" prefix, got: ${r.stdout}`);
  });

  test('tree on a fixture prints the module tree', () => {
    const r = runCli(['tree', fib]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    assert(r.stdout.includes('main'), 'missing "main" module');
  });
}

test('info without path errors out', () => {
  const r = runCli(['info']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('requires a program path'), 'missing error message');
});

test('validate without path errors out', () => {
  const r = runCli(['validate']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('requires a program path'), 'missing error message');
});

test('tree without path errors out', () => {
  const r = runCli(['tree']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('requires a program path'), 'missing error message');
});

// A Program with no entry_module/entry_function — validationErrors() must
// report both, and the CLI must route the "Invalid:" report to STDERR with
// exit 1 (the invalid-path branch of cmdValidate, never reached by the
// valid-fixture test above).
const invalidProgram = {
  name: 'incomplete',
  version: '1.0.0',
  entryModule: '',
  entryFunction: '',
  modules: [],
};

test('validate on an invalid program reports Invalid: on stderr and exits 1', () => {
  const invalidPath = join(tmpdir(), `ball-cli-invalid-${process.pid}.ball.json`);
  writeFileSync(invalidPath, JSON.stringify(invalidProgram));
  try {
    const r = runCli(['validate', invalidPath]);
    assert(r.status === 1, `expected exit 1, got ${r.status}`);
    assert(r.stderr.trim().startsWith('Invalid:'), `expected "Invalid:" on stderr, got: ${r.stderr}`);
    assert(r.stderr.includes('Missing entry_module'), 'missing entry_module error');
    assert(r.stderr.includes('Missing entry_function'), 'missing entry_function error');
    assert(!r.stdout.includes('Invalid:'), 'invalid report leaked onto stdout');
  } finally {
    rmSync(invalidPath, { force: true });
  }
});

// A ModuleImport with every `source` oneof variant set (http/file/git/
// registry/inline) plus a ref-only import (no source) — exercises every
// branch of cli_core.dart's `_importSource` (compiled into `compiled_cli.ts`
// and normalized by `cli_core.ts`'s `normalizeModuleImport`), including the
// RegistrySource.registry enum-name access that previously crashed with
// "hasHttp is not defined" (a real @ball-lang/compiler preamble gap fixed
// alongside this issue — see ts/compiler/src/preamble.ts).
const treeImportsProgram = {
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

test('tree renders every ModuleImport source kind (matches the Dart CLI byte-for-byte)', () => {
  const treePath = join(tmpdir(), `ball-cli-tree-imports-${process.pid}.ball.json`);
  writeFileSync(treePath, JSON.stringify(treeImportsProgram));
  try {
    const r = runCli(['tree', treePath]);
    assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
    const expected = [
      'synth v1.0.0',
      '  main — 1 functions',
      '    → reg_imp (REGISTRY_PUB: foo@^1.0.0)',
      '    → http_imp (http: https://example.com/x.ball.bin)',
      '    → file_imp (file: ./local.ball.bin)',
      '    → git_imp (git: https://example.com/repo.git@v1.0.0)',
      '    → inline_imp (inline)',
      '    → ref_only_imp (ref only)',
      '',
    ].join('\n');
    assert(r.stdout === expected, `output mismatch\nexpected:\n${expected}\nactual:\n${r.stdout}`);
  } finally {
    rmSync(treePath, { force: true });
  }
});

// ── audit ───────────────────────────────────────────────────────────────────

test('audit without path errors out', () => {
  const r = runCli(['audit']);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('requires a program path'), 'missing error message');
});

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

test('audit --output=<path> (inline "=" form) works the same as the two-token form', () => {
  const outPath = join(tmpDir, 'report-eq.json');
  const r = runCli(['audit', fsProgramPath, `--output=${outPath}`]);
  assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
  assert(existsSync(outPath), 'report file not written via --output=<path>');
});

test('a "--" separator forces everything after it to be positional, even flag-like text', () => {
  // Passing `--` before a path that starts with "-" proves it isn't
  // misparsed as a flag: parseArgs's `arg === "--"` branch drains the rest
  // of argv into `positional` unconditionally.
  const dashLikePath = join(tmpDir, '-looks-like-a-flag.ball.json');
  writeFileSync(dashLikePath, JSON.stringify(fsProgram));
  const r = runCli(['audit', '--', dashLikePath]);
  assert(r.status === 0, `exit ${r.status}: ${r.stderr}`);
  assert(r.stdout.includes('fs'), 'fs capability not mentioned; path may have been misparsed as a flag');
});

test('audit --output to an unwritable path reports a clean error, not a crash', () => {
  const outPath = join(tmpDir, 'no-such-subdir', 'report.json');
  const r = runCli(['audit', fsProgramPath, '--output', outPath]);
  assert(r.status === 1, `expected exit 1, got ${r.status}`);
  assert(r.stderr.includes('could not write'), `missing "could not write" in stderr:\n${r.stderr}`);
});

// A program whose `modules` field is missing entirely: analyzeCapabilities
// (called with no try/catch around it in cmdAudit) throws a raw TypeError,
// not a CliError — this exercises the top-level `else { throw e; }` rethrow
// in index.ts, which deliberately lets truly unexpected internal errors
// crash loudly instead of being reported as a normal `ball: <message>` error.
test('audit on a program missing `modules` crashes loudly (unexpected error, not swallowed)', () => {
  const malformedPath = join(tmpDir, 'malformed.ball.json');
  writeFileSync(malformedPath, JSON.stringify({ entryModule: 'main', entryFunction: 'main' }));
  const r = runCli(['audit', malformedPath]);
  assert(r.status !== 0, `expected a nonzero (crash) exit, got ${r.status}`);
  assert(!r.stderr.startsWith('ball:'), `expected an unhandled-exception crash, not a clean "ball:" error:\n${r.stderr}`);
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
