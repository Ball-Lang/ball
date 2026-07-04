/**
 * Tests for the static capability analyzer (src/capability_analyzer.ts).
 *
 * Dependency-free (no @ball-lang/engine import), so this suite runs standalone
 * even when the sibling workspace packages aren't linked (see AGENTS notes on
 * why test/cli_test.ts can't run in CI). Constructs proto3-JSON-shaped Ball
 * Program fixtures directly rather than compiling real source, since the
 * analyzer only cares about the expression-tree shape.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  analyzeCapabilities,
  formatCapabilityReport,
  checkPolicy,
  type Program,
  type Expression,
  type BallCapabilityReport,
} from '../src/capability_analyzer.ts';

// ── Fixture helpers ─────────────────────────────────────────────────────────

const STD_MODULE = {
  name: 'std',
  functions: [
    { name: 'add', isBase: true },
    { name: 'print', isBase: true },
  ],
};

const STD_FS_MODULE = {
  name: 'std_fs',
  functions: [{ name: 'file_read', isBase: true }],
};

const STD_IO_MODULE = {
  name: 'std_io',
  functions: [
    { name: 'print_error', isBase: true },
    { name: 'read_line', isBase: true },
    { name: 'env_get', isBase: true },
    { name: 'exit', isBase: true },
    { name: 'random_int', isBase: true },
    { name: 'timestamp_ms', isBase: true },
  ],
};

const STD_CONCURRENCY_MODULE = {
  name: 'std_concurrency',
  functions: [{ name: 'thread_spawn', isBase: true }],
};

function call(module: string, fn: string, input?: Expression): Expression {
  return { call: { module, function: fn, input } };
}

function lit(): Expression {
  return { literal: {} };
}

function ref(name: string): Expression {
  return { reference: { name } };
}

// ── analyzeCapabilities: analyzeAll mode ────────────────────────────────────

describe('analyzeCapabilities (analyzeAll)', () => {
  test('identifies fully-base modules and excludes them from the report', () => {
    const program: Program = {
      name: 'demo',
      version: '1.0.0',
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        STD_MODULE,
        {
          name: 'main',
          functions: [{ name: 'main', body: call('std', 'print', lit()) }],
        },
      ],
    };
    const report = analyzeCapabilities(program);
    assert.ok(!report.functions.some((f) => f.module === 'std'), 'std module excluded');
    assert.equal(report.functions.length, 1);
    assert.equal(report.functions[0]!.function, 'main');
    assert.deepEqual(report.functions[0]!.capabilities, ['io']);
  });

  test('a function calling an actual pure base function reports the "pure" capability entry', () => {
    const program: Program = {
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        STD_MODULE,
        { name: 'main', functions: [{ name: 'main', body: call('std', 'add', lit()) }] },
      ],
    };
    const report = analyzeCapabilities(program);
    const pureEntry = report.capabilities.find((c) => c.capability === 'pure');
    assert.ok(pureEntry, 'a "pure" capability entry is reported');
    assert.equal(pureEntry!.callSites.length, 0, 'pure calls have no call sites (only non-pure caps do)');
    assert.equal(pureEntry!.riskLevel, 'none');
  });

  test('a module with zero functions is skipped without crashing', () => {
    const program: Program = {
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        { name: 'empty', functions: [] },
        { name: 'main', functions: [{ name: 'main', body: lit() }] },
      ],
    };
    const report = analyzeCapabilities(program);
    assert.equal(report.functions.length, 1);
  });

  test('a function with no base calls at all counts as pure (vacuous)', () => {
    const program: Program = {
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        STD_MODULE,
        { name: 'main', functions: [{ name: 'main', body: lit() }] },
      ],
    };
    const report = analyzeCapabilities(program);
    assert.equal(report.summary.pureFunctions, 1);
    assert.equal(report.summary.effectfulFunctions, 0);
    assert.equal(report.summary.isPure, true);
  });

  test('a base function itself (fn.isBase true) is skipped in analyzeAll', () => {
    const program: Program = {
      entryModule: 'mixed',
      entryFunction: 'helper',
      modules: [
        {
          // Not ALL functions are base, so this module is not a "base module"
          // and analyzeAll walks its non-base members — but must still skip
          // the individual base one.
          name: 'mixed',
          functions: [
            { name: 'helper', body: lit() },
            { name: 'baseLike', isBase: true },
          ],
        },
      ],
    };
    const report = analyzeCapabilities(program);
    assert.ok(report.functions.some((f) => f.function === 'helper'));
    assert.ok(!report.functions.some((f) => f.function === 'baseLike'));
  });
});

// ── Expression-tree walking (all node shapes) ───────────────────────────────

describe('analyzeCapabilities (expression walking)', () => {
  test('walks block statements (let + expression), block result, lambda, messageCreation, fieldAccess, and list literals', () => {
    const body: Expression = {
      block: {
        statements: [
          { let: { name: 'x', value: call('std_io', 'read_line') } },
          { expression: call('std', 'print', ref('x')) },
        ],
        result: {
          lambda: {
            body: {
              messageCreation: {
                fields: [
                  {
                    name: 'f',
                    value: {
                      fieldAccess: {
                        object: call('std_io', 'timestamp_ms'),
                        field: 'value',
                      },
                    },
                  },
                  {
                    name: 'list',
                    value: {
                      literal: {
                        listValue: {
                          elements: [call('std_io', 'random_int'), lit()],
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        },
      },
    };
    const program: Program = {
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        STD_MODULE,
        STD_IO_MODULE,
        { name: 'main', functions: [{ name: 'main', body }] },
      ],
    };
    const report = analyzeCapabilities(program);
    const caps = report.functions.find((f) => f.function === 'main')!.capabilities;
    assert.ok(caps.includes('io'), 'read_line/print observed');
    assert.ok(caps.includes('time'), 'timestamp_ms via fieldAccess.object observed');
    assert.ok(caps.includes('random'), 'random_int inside list literal observed');
  });

  test('a call with no explicit module falls back to the enclosing function\'s own module', () => {
    // Same-module calls omit `module` in the wire format; walkCall must
    // resolve it from ctxModule rather than treating it as a callee lookup.
    const body: Expression = { call: { function: 'print', input: undefined } };
    const program: Program = {
      entryModule: 'std',
      entryFunction: 'main',
      modules: [{ name: 'std', functions: [
        { name: 'print', isBase: false, body },
      ] }],
    };
    const report = analyzeCapabilities(program);
    // lookupCapability('std', 'print') = 'io' (module resolved from ctxModule 'std').
    assert.deepEqual(report.functions[0]!.capabilities, ['io']);
  });

  test('a fieldAccess with no object, and a bare reference, contribute nothing', () => {
    const body: Expression = {
      fieldAccess: { field: 'onlyField' },
    };
    const program: Program = {
      entryModule: 'main',
      entryFunction: 'main',
      modules: [{ name: 'main', functions: [{ name: 'main', body }, { name: 'refFn', body: ref('x') }] }],
    };
    const report = analyzeCapabilities(program);
    assert.equal(report.functions.find((f) => f.function === 'main')!.capabilities.length, 0);
    assert.equal(report.functions.find((f) => f.function === 'refFn')!.capabilities.length, 0);
  });
});

// ── analyzeCapabilities: reachableOnly mode ─────────────────────────────────

describe('analyzeCapabilities (reachableOnly)', () => {
  const program: Program = {
    entryModule: 'main',
    entryFunction: 'entry',
    modules: [
      STD_FS_MODULE,
      {
        name: 'main',
        functions: [
          { name: 'entry', body: call('main', 'helper') },
          { name: 'helper', body: call('std_fs', 'file_read', lit()) },
          { name: 'unused', body: call('std_fs', 'file_read', lit()) },
        ],
      },
    ],
  };

  test('only walks functions transitively reachable from the entry point', () => {
    const report = analyzeCapabilities(program, { reachableOnly: true });
    const names = report.functions.map((f) => f.function).sort();
    assert.deepEqual(names, ['entry', 'helper']);
    assert.ok(!names.includes('unused'), 'unreachable function excluded');
  });

  test('propagates callee capabilities up to the caller', () => {
    const report = analyzeCapabilities(program, { reachableOnly: true });
    const entry = report.functions.find((f) => f.function === 'entry')!;
    assert.ok(entry.capabilities.includes('fs'), 'fs capability propagated from helper');
  });

  test('without reachableOnly, unused functions are still included', () => {
    const report = analyzeCapabilities(program, { reachableOnly: false });
    assert.ok(report.functions.some((f) => f.function === 'unused'));
  });

  test('entry module exists but the named function does not: empty report, no crash', () => {
    const missingFn: Program = { ...program, entryModule: 'main', entryFunction: 'nope' };
    const report = analyzeCapabilities(missingFn, { reachableOnly: true });
    assert.equal(report.functions.length, 0);
  });

  test('an entry pointing directly at a base-module function short-circuits (baseModules check)', () => {
    const baseEntry: Program = { ...program, entryModule: 'std_fs', entryFunction: 'file_read' };
    const report = analyzeCapabilities(baseEntry, { reachableOnly: true });
    assert.equal(report.functions.length, 0);
  });

  test('a cycle between reachable functions does not infinite-loop', () => {
    const cyclic: Program = {
      entryModule: 'main',
      entryFunction: 'a',
      modules: [
        {
          name: 'main',
          functions: [
            { name: 'a', body: call('main', 'b') },
            { name: 'b', body: call('main', 'a') },
          ],
        },
      ],
    };
    const report = analyzeCapabilities(cyclic, { reachableOnly: true });
    assert.deepEqual(report.functions.map((f) => f.function).sort(), ['a', 'b']);
  });

  test('an entry pointing at a nonexistent module/function yields an empty report', () => {
    const report = analyzeCapabilities(program, { reachableOnly: true });
    const missing: Program = { ...program, entryModule: 'nope', entryFunction: 'nope' };
    const emptyReport = analyzeCapabilities(missing, { reachableOnly: true });
    assert.equal(emptyReport.functions.length, 0);
    assert.notEqual(report.functions.length, 0);
  });

  test('reaching a base function directly short-circuits without walking its (absent) body', () => {
    const withBaseEntry: Program = {
      entryModule: 'mixed',
      entryFunction: 'baseLike',
      modules: [
        {
          name: 'mixed',
          functions: [
            { name: 'baseLike', isBase: true },
            { name: 'other', body: lit() },
          ],
        },
      ],
    };
    const report = analyzeCapabilities(withBaseEntry, { reachableOnly: true });
    assert.equal(report.functions.length, 0);
  });
});

// ── formatCapabilityReport ───────────────────────────────────────────────────

function baseSummary(overrides: Partial<BallCapabilityReport['summary']> = {}) {
  return {
    isPure: true,
    readsFilesystem: false,
    writesFilesystem: false,
    readsStdin: false,
    writesStdout: false,
    writesStderr: false,
    readsEnvironment: false,
    controlsProcess: false,
    usesMemory: false,
    usesTime: false,
    usesRandom: false,
    usesConcurrency: false,
    usesNetwork: false,
    totalFunctions: 1,
    pureFunctions: 1,
    effectfulFunctions: 0,
    ...overrides,
  };
}

describe('formatCapabilityReport', () => {
  test('a pure program reports NO RISK, a checkmark, and lists every absent capability', () => {
    const report: BallCapabilityReport = {
      programName: 'pure_demo',
      programVersion: '1.0.0',
      capabilities: [{ capability: 'pure', riskLevel: 'none', callSites: [] }],
      functions: [{ module: 'main', function: 'main', capabilities: ['pure'] }],
      summary: baseSummary(),
    };
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('pure_demo v1.0.0'));
    assert.ok(text.includes('✓ pure (pure computation)'));
    assert.ok(text.includes('NO RISK'));
    assert.ok(text.includes('NONE: filesystem, network, process, memory, concurrency, random'));
    assert.ok(text.includes('main.main → pure'));
  });

  test('a program using memory/process/network reports HIGH RISK with a warning icon and call sites', () => {
    const report: BallCapabilityReport = {
      programName: '',
      programVersion: '',
      capabilities: [
        {
          capability: 'memory',
          riskLevel: 'high',
          callSites: [
            { module: 'main', function: 'f', calleeModule: 'std_memory', calleeFunction: 'memory_alloc' },
          ],
        },
      ],
      functions: [{ module: 'main', function: 'f', capabilities: ['memory'] }],
      summary: baseSummary({
        isPure: false,
        usesMemory: true,
        totalFunctions: 1,
        pureFunctions: 0,
        effectfulFunctions: 1,
      }),
    };
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('<unnamed> v0.0.0'), 'falls back to placeholder name/version');
    assert.ok(text.includes('⚠ memory (1 call sites: main.f → std_memory.memory_alloc)'));
    assert.ok(text.includes('HIGH RISK'));
    assert.ok(text.includes('main.f → memory'), 'non-pure capabilities listed, pure filtered out');
  });

  test('filesystem/concurrency (without high-risk capabilities) reports MEDIUM RISK', () => {
    const report: BallCapabilityReport = {
      programName: 'fs_demo',
      programVersion: '2.0.0',
      capabilities: [{ capability: 'fs', riskLevel: 'medium', callSites: [
        { module: 'main', function: 'f', calleeModule: 'std_fs', calleeFunction: 'file_read' },
      ] }],
      functions: [{ module: 'main', function: 'f', capabilities: ['fs'] }],
      summary: baseSummary({
        isPure: false,
        readsFilesystem: true,
        writesFilesystem: true,
        totalFunctions: 1,
        pureFunctions: 0,
        effectfulFunctions: 1,
      }),
    };
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('MEDIUM RISK'));
  });

  test('io only (no fs/process/memory/network/concurrency/random) reports LOW RISK', () => {
    const report: BallCapabilityReport = {
      programName: 'io_demo',
      programVersion: '1.0.0',
      capabilities: [{ capability: 'io', riskLevel: 'low', callSites: [
        { module: 'main', function: 'f', calleeModule: 'std', calleeFunction: 'print' },
      ] }],
      functions: [{ module: 'main', function: 'f', capabilities: ['io'] }],
      summary: baseSummary({
        isPure: false,
        writesStdout: true,
        totalFunctions: 1,
        pureFunctions: 0,
        effectfulFunctions: 1,
      }),
    };
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('LOW RISK'));
    // io/time are never listed in the absent-capability roll-up (only
    // filesystem/network/process/memory/concurrency/random are), but every
    // one of those six IS absent here, so the NONE: line still appears.
    assert.ok(text.includes('NONE: filesystem, network, process, memory, concurrency, random'));
  });

  test('random usage removes just "random" from the absent-capabilities list', () => {
    const report: BallCapabilityReport = {
      programName: 'random_demo',
      programVersion: '1.0.0',
      capabilities: [{ capability: 'random', riskLevel: 'low', callSites: [
        { module: 'main', function: 'f', calleeModule: 'std_io', calleeFunction: 'random_int' },
      ] }],
      functions: [{ module: 'main', function: 'f', capabilities: ['random'] }],
      summary: baseSummary({
        isPure: false,
        usesRandom: true,
        totalFunctions: 1,
        pureFunctions: 0,
        effectfulFunctions: 1,
      }),
    };
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('NONE: filesystem, network, process, memory, concurrency'));
    assert.ok(!text.includes(', random'));
  });
});

// ── checkPolicy ──────────────────────────────────────────────────────────────

describe('checkPolicy', () => {
  const report: BallCapabilityReport = {
    programName: 'p',
    programVersion: '1.0.0',
    capabilities: [
      {
        capability: 'fs',
        riskLevel: 'medium',
        callSites: [
          { module: 'main', function: 'a', calleeModule: 'std_fs', calleeFunction: 'file_read' },
          { module: 'main', function: 'b', calleeModule: 'std_fs', calleeFunction: 'file_write' },
        ],
      },
      {
        capability: 'network',
        riskLevel: 'high',
        callSites: [
          { module: 'main', function: 'c', calleeModule: 'std_net', calleeFunction: 'connect' },
        ],
      },
    ],
    functions: [],
    summary: baseSummary({ isPure: false }),
  };

  test('an empty deny set produces no violations', () => {
    assert.deepEqual(checkPolicy(report, new Set()), []);
  });

  test('denying a capability not present in the report produces no violations', () => {
    assert.deepEqual(checkPolicy(report, new Set(['process'])), []);
  });

  test('denying "fs" reports one violation per fs call site, formatted as module.fn calls callee', () => {
    const violations = checkPolicy(report, new Set(['fs']));
    assert.deepEqual(violations, [
      'fs: main.a calls std_fs.file_read',
      'fs: main.b calls std_fs.file_write',
    ]);
  });

  test('denying multiple capabilities aggregates violations across all of them', () => {
    const violations = checkPolicy(report, new Set(['fs', 'network']));
    assert.equal(violations.length, 3);
    assert.ok(violations.some((v) => v.startsWith('network:')));
  });
});
