/**
 * Ball TypeScript Engine Tests
 *
 * Run: node --experimental-strip-types test/engine_test.ts
 */

import { readFileSync, readdirSync } from 'fs';
import { join } from 'path';
import { BallEngine } from '../src/index.ts';

let passed = 0;
let failed = 0;

async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.log(`  ✗ ${name}: ${e.message}`);
    failed++;
  }
}

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual: any, expected: any, label = '') {
  if (actual !== expected) {
    throw new Error(`${label}Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────

async function main() {

// ── Unit tests ──────────────────────────────────────────────────────────────

console.log('Ball TypeScript Engine Tests');
console.log('===========================\n');

console.log('Literals:');

await test('int literal', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { intValue: '42' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput()[0], '42');
});

await test('string literal', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'hello' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput()[0], 'hello');
});

console.log('\nArithmetic:');

await test('add', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [
        { name: 'add', isBase: true },
        { name: 'print', isBase: true },
      ],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: {
          call: { module: 'std', function: 'add', input: {
            messageCreation: { fields: [
              { name: 'left', value: { literal: { intValue: '3' } } },
              { name: 'right', value: { literal: { intValue: '4' } } },
            ] },
          } },
        } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput()[0], '7');
});

console.log('\nControl flow:');

await test('if-then-else', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [
        { name: 'if', isBase: true },
        { name: 'print', isBase: true },
        { name: 'greater_than', isBase: true },
      ],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: {
          call: { module: 'std', function: 'if', input: {
            messageCreation: { fields: [
              { name: 'condition', value: { call: { module: 'std', function: 'greater_than', input: {
                messageCreation: { fields: [
                  { name: 'left', value: { literal: { intValue: '5' } } },
                  { name: 'right', value: { literal: { intValue: '3' } } },
                ] },
              } } } },
              { name: 'then', value: { literal: { stringValue: 'yes' } } },
              { name: 'else', value: { literal: { stringValue: 'no' } } },
            ] },
          } },
        } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput()[0], 'yes');
});

await test('while loop', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [
        { name: 'while', isBase: true },
        { name: 'print', isBase: true },
        { name: 'less_than', isBase: true },
        { name: 'add', isBase: true },
        { name: 'assign', isBase: true },
      ],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { block: {
          statements: [
            { let: { name: 'i', value: { literal: { intValue: '0' } } } },
            { expression: { call: { module: 'std', function: 'while', input: {
              messageCreation: { fields: [
                { name: 'condition', value: { call: { module: 'std', function: 'less_than', input: {
                  messageCreation: { fields: [
                    { name: 'left', value: { reference: { name: 'i' } } },
                    { name: 'right', value: { literal: { intValue: '3' } } },
                  ] },
                } } } },
                { name: 'body', value: { block: { statements: [
                  { expression: { call: { module: 'std', function: 'print', input: { reference: { name: 'i' } } } } },
                  { expression: { call: { module: 'std', function: 'assign', input: {
                    messageCreation: { fields: [
                      { name: 'target', value: { reference: { name: 'i' } } },
                      { name: 'value', value: { call: { module: 'std', function: 'add', input: {
                        messageCreation: { fields: [
                          { name: 'left', value: { reference: { name: 'i' } } },
                          { name: 'right', value: { literal: { intValue: '1' } } },
                        ] },
                      } } } },
                    ] },
                  } } } },
                ] } } },
              ] },
            } } } },
          ],
        } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput().join(','), '0,1,2');
});

// ── Engine options tests ────────────────────────────────────────────────────

console.log('\nEngine options:');

await test('constructor accepts options object', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'ok' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, {});
  await engine.run();
  assertEqual(engine.getOutput()[0], 'ok');
});

await test('run() returns output array', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'hello' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  const result = await engine.run();
  assert(Array.isArray(result), 'run() should return an array');
  assertEqual(result[0], 'hello');
});

await test('getOutput() returns same array as run()', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'test' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  const runResult = await engine.run();
  const getResult = engine.getOutput();
  assertEqual(runResult.length, getResult.length);
  assertEqual(runResult[0], getResult[0]);
});

await test('accepts program as JSON string', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'from string' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(JSON.stringify(prog));
  await engine.run();
  assertEqual(engine.getOutput()[0], 'from string');
});

await test('custom stdout captures output', async () => {
  const captured: string[] = [];
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'custom' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, { stdout: (msg) => captured.push(msg) });
  await engine.run();
  assertEqual(captured[0], 'custom');
});

await test('with no stderr option, print_error uses the default no-op stderr sink', async () => {
  // options.stderr defaults to a no-op (() => {}) when the caller doesn't
  // provide one; std.print_error is the only base function that invokes it.
  // Every other test in this file supplies neither stdout nor stderr, but
  // none of them actually CALL print_error, so the default sink itself was
  // constructed but never invoked. Assert only that run() completes without
  // throwing -- the point is exercising the no-op, not its (nonexistent) effect.
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print_error', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print_error', input: { literal: { stringValue: 'oops' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
});

console.log('\nExecution timeout:');

await test('short timeout throws on infinite loop', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'while', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'while', input: {
          messageCreation: { fields: [
            { name: 'condition', value: { literal: { boolValue: true } } },
            { name: 'body', value: { block: { statements: [] } } },
          ] },
        } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  try {
    const engine = new BallEngine(prog, { timeoutMs: 1 });
    await engine.run();
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('timeout') || e.message.includes('Timeout') || e.message.includes('Execution timeout'),
      `Expected timeout error, got: ${e.message}`,
    );
  }
});

await test('generous timeout allows normal execution', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'completed' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, { timeoutMs: 10000 });
  await engine.run();
  assertEqual(engine.getOutput()[0], 'completed');
});

console.log('\nMemory limit:');

// list_filled allocates 8 bytes/element in the engine's memory accounting
// (200 elements = 1600 bytes > the 1000-byte limit) — see the composer
// registrations in engine_setup.ts (#24).
await test('small memory limit throws on large allocation', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'list_filled', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'list_filled', input: {
          messageCreation: { fields: [
            { name: 'count', value: { literal: { intValue: '200' } } },
            { name: 'value', value: { literal: { intValue: '0' } } },
          ] },
        } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  try {
    const engine = new BallEngine(prog, { maxMemoryBytes: 1000 });
    await engine.run();
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('Memory limit') || e.message.includes('memory'),
      `Expected memory limit error, got: ${e.message}`,
    );
  }
});

await test('generous memory limit allows normal execution', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [
        { name: 'list_filled', isBase: true },
        { name: 'list_length', isBase: true },
        { name: 'print', isBase: true },
        { name: 'to_string', isBase: true },
      ],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { block: { statements: [
          { let: { name: 'items', value: { call: { module: 'std', function: 'list_filled', input: {
            messageCreation: { fields: [
              { name: 'count', value: { literal: { intValue: '10' } } },
              { name: 'value', value: { literal: { intValue: '1' } } },
            ] },
          } } } } },
          { expression: { call: { module: 'std', function: 'print', input: {
            call: { module: 'std', function: 'to_string', input: {
              messageCreation: { fields: [
                { name: 'value', value: { call: { module: 'std', function: 'list_length', input: {
                  messageCreation: { fields: [
                    { name: 'list', value: { reference: { name: 'items' } } },
                  ] },
                } } } },
              ] },
            } },
          } } } },
        ] } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, { maxMemoryBytes: 100000 });
  await engine.run();
  assertEqual(engine.getOutput()[0], '10');
});

console.log('\nInput validation:');

await test('throws when program has too many modules', async () => {
  const modules: any[] = [
    { name: 'std', functions: [{ name: 'print', isBase: true }] },
    { name: 'main', functions: [{
      name: 'main',
      body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'unreachable' } } } },
    }] },
  ];
  for (let i = 0; i < 99; i++) {
    modules.push({ name: `extra_${i}`, functions: [] });
  }
  const prog = { modules, entryModule: 'main', entryFunction: 'main' };
  try {
    const engine = new BallEngine(prog, { maxModules: 100 });
    await engine.run();
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('Too many modules') || e.message.includes('modules'),
      `Expected too-many-modules error, got: ${e.message}`,
    );
  }
});

// The wrapper exposes the program's UTF-8 JSON byte length through a
// `writeToBuffer` shim, so the compiled engine's size validation runs (#24).
await test('throws when program JSON size exceeds configured limit', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'unreachable' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  try {
    const engine = new BallEngine(prog, { maxProgramSizeBytes: 1 });
    await engine.run();
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('Program too large') || e.message.includes('too large') || e.message.includes('size'),
      `Expected program-too-large error, got: ${e.message}`,
    );
  }
});

await test('generous program size limit allows normal execution', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'fits' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, { maxProgramSizeBytes: 10_000_000 });
  await engine.run();
  assertEqual(engine.getOutput()[0], 'fits');
});

console.log('\nSandbox mode:');

await test('sandbox blocks file_read', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'file_read', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'file_read', input: {
          messageCreation: { fields: [
            { name: 'path', value: { literal: { stringValue: '/etc/passwd' } } },
          ] },
        } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  try {
    const engine = new BallEngine(prog, { sandbox: true });
    await engine.run();
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('Sandbox') || e.message.includes('sandbox') || e.message.includes('not allowed'),
      `Expected sandbox violation error, got: ${e.message}`,
    );
  }
});

await test('sandbox allows normal computation', async () => {
  const prog = {
    modules: [{
      name: 'std', functions: [{ name: 'print', isBase: true }],
    }, {
      name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: { literal: { stringValue: 'safe' } } } },
      }],
    }],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog, { sandbox: true });
  await engine.run();
  assertEqual(engine.getOutput()[0], 'safe');
});

// ── engine_setup std-function + method-dispatch coverage ─────────────────────
//
// These target the hand-written std registrations and the MethodDispatchHandler
// in engine_setup.ts that the conformance corpus doesn't fully exercise
// (collection higher-order functions with lambdas, set/map/string/number
// method dispatch, and the guard branches for malformed inputs).

console.log('\nengine_setup std functions:');

/** Wrap an expression as a single-print program and run it, returning output. */
async function runExpr(stdFns: string[], expr: any): Promise<string[]> {
  const prog = {
    modules: [
      { name: 'std', functions: stdFns.map(name => ({ name, isBase: true })) },
      {
        name: 'main',
        functions: [{
          name: 'main',
          body: { call: { module: 'std', function: 'print', input: expr } },
        }],
      },
    ],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  return engine.getOutput();
}

/** Build a std.<fn> call with the given messageCreation fields. */
function stdCall(fn: string, fields: Array<{ name: string; value: any }>, module = 'std'): any {
  return { call: { module, function: fn, input: { messageCreation: { typeName: '', fields } } } };
}

/** A list literal expression. */
function listLit(elements: any[]): any {
  return { literal: { listValue: { elements } } };
}
function intLit(n: number): any { return { literal: { intValue: String(n) } }; }
function strLit(s: string): any { return { literal: { stringValue: s } }; }

/** A lambda that returns `bodyExpr`, with parameter referenced as `input`. */
function lambda(bodyExpr: any): any {
  return {
    lambda: {
      name: '', body: bodyExpr,
      metadata: { kind: 'lambda', expression_body: true, has_return: true },
    },
  };
}

// ── Collection higher-order functions (with lambdas) ──────────────────────────

await test('list_where filters with a predicate lambda', async () => {
  // [1,2,3,4] where (input > 2) => [3, 4]
  const pred = lambda(stdCall('greater_than', [
    { name: 'left', value: { reference: { name: 'input' } } },
    { name: 'right', value: intLit(2) },
  ]));
  const out = await runExpr(
    ['print', 'list_where', 'greater_than'],
    stdCall('list_where', [
      { name: 'list', value: listLit([intLit(1), intLit(2), intLit(3), intLit(4)]) },
      { name: 'function', value: pred },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[3, 4]');
});

await test('list_any returns true when a predicate matches', async () => {
  const pred = lambda(stdCall('equals', [
    { name: 'left', value: { reference: { name: 'input' } } },
    { name: 'right', value: intLit(2) },
  ]));
  const out = await runExpr(
    ['print', 'list_any', 'equals'],
    stdCall('list_any', [
      { name: 'list', value: listLit([intLit(1), intLit(2), intLit(3)]) },
      { name: 'function', value: pred },
    ], 'std_collections'),
  );
  assertEqual(out[0], 'true');
});

await test('list_every returns false when one element fails', async () => {
  const pred = lambda(stdCall('greater_than', [
    { name: 'left', value: { reference: { name: 'input' } } },
    { name: 'right', value: intLit(0) },
  ]));
  const out = await runExpr(
    ['print', 'list_every', 'greater_than'],
    stdCall('list_every', [
      { name: 'list', value: listLit([intLit(1), intLit(2), intLit(0)]) },
      { name: 'function', value: pred },
    ], 'std_collections'),
  );
  assertEqual(out[0], 'false');
});

await test('list_find returns the first matching element', async () => {
  const pred = lambda(stdCall('greater_than', [
    { name: 'left', value: { reference: { name: 'input' } } },
    { name: 'right', value: intLit(1) },
  ]));
  const out = await runExpr(
    ['print', 'list_find', 'greater_than'],
    stdCall('list_find', [
      { name: 'list', value: listLit([intLit(1), intLit(2), intLit(3)]) },
      { name: 'function', value: pred },
    ], 'std_collections'),
  );
  assertEqual(out[0], '2');
});

await test('list_filter keeps matching elements', async () => {
  const pred = lambda(stdCall('less_than', [
    { name: 'left', value: { reference: { name: 'input' } } },
    { name: 'right', value: intLit(3) },
  ]));
  const out = await runExpr(
    ['print', 'list_filter', 'less_than'],
    stdCall('list_filter', [
      { name: 'list', value: listLit([intLit(1), intLit(2), intLit(3), intLit(4)]) },
      { name: 'function', value: pred },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[1, 2]');
});

await test('list_where guard: non-list input yields empty list', async () => {
  const out = await runExpr(
    ['print', 'list_where'],
    stdCall('list_where', [
      { name: 'list', value: intLit(5) },
      { name: 'function', value: strLit('not-a-fn') },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[]');
});

// ── Set operations ────────────────────────────────────────────────────────────

await test('set_union via std_collections', async () => {
  const out = await runExpr(
    ['print', 'set_from', 'set_union', 'set_to_list'],
    stdCall('set_to_list', [
      { name: 'set', value: stdCall('set_union', [
        { name: 'set', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(1), intLit(2)]) }], 'std_collections') },
        { name: 'other', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(2), intLit(3)]) }], 'std_collections') },
      ], 'std_collections') },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[1, 2, 3]');
});

await test('set_intersection keeps common elements', async () => {
  const out = await runExpr(
    ['print', 'set_from', 'set_intersection', 'set_to_list'],
    stdCall('set_to_list', [
      { name: 'set', value: stdCall('set_intersection', [
        { name: 'set', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(1), intLit(2), intLit(3)]) }], 'std_collections') },
        { name: 'other', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(2), intLit(3), intLit(4)]) }], 'std_collections') },
      ], 'std_collections') },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[2, 3]');
});

await test('set_difference removes shared elements', async () => {
  const out = await runExpr(
    ['print', 'set_from', 'set_difference', 'set_to_list'],
    stdCall('set_to_list', [
      { name: 'set', value: stdCall('set_difference', [
        { name: 'set', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(1), intLit(2), intLit(3)]) }], 'std_collections') },
        { name: 'other', value: stdCall('set_from', [{ name: 'list', value: listLit([intLit(2)]) }], 'std_collections') },
      ], 'std_collections') },
    ], 'std_collections'),
  );
  assertEqual(out[0], '[1, 3]');
});

// ── String helpers ────────────────────────────────────────────────────────────

await test('string_pad_left pads to the requested width', async () => {
  const out = await runExpr(
    ['print', 'string_pad_left'],
    stdCall('string_pad_left', [
      { name: 'value', value: strLit('7') },
      { name: 'width', value: intLit(3) },
      { name: 'padding', value: strLit('0') },
    ], 'std'),
  );
  assertEqual(out[0], '007');
});

await test('string_pad_right pads on the right', async () => {
  const out = await runExpr(
    ['print', 'string_pad_right'],
    stdCall('string_pad_right', [
      { name: 'value', value: strLit('7') },
      { name: 'width', value: intLit(3) },
      { name: 'padding', value: strLit('.') },
    ], 'std'),
  );
  assertEqual(out[0], '7..');
});

await test('string_repeat repeats the string', async () => {
  const out = await runExpr(
    ['print', 'string_repeat'],
    stdCall('string_repeat', [
      { name: 'value', value: strLit('ab') },
      { name: 'count', value: intLit(3) },
    ], 'std'),
  );
  assertEqual(out[0], 'ababab');
});

await test('string_from_char_code builds a character', async () => {
  const out = await runExpr(
    ['print', 'string_from_char_code'],
    stdCall('string_from_char_code', [
      { name: 'code', value: intLit(65) },
    ], 'std'),
  );
  assertEqual(out[0], 'A');
});

// ── Conversion + comparison helpers ───────────────────────────────────────────

await test('to_double formats an int with a decimal point', async () => {
  const out = await runExpr(
    ['print', 'to_double'],
    stdCall('to_double', [{ name: 'value', value: intLit(42) }], 'std'),
  );
  assertEqual(out[0], '42.0');
});

await test('compare_to orders two numbers', async () => {
  const out = await runExpr(
    ['print', 'compare_to'],
    stdCall('compare_to', [
      { name: 'left', value: intLit(2) },
      { name: 'right', value: intLit(5) },
    ], 'std'),
  );
  assertEqual(out[0], '-1');
});

await test('math_max picks the larger value', async () => {
  const out = await runExpr(
    ['print', 'math_max'],
    stdCall('math_max', [
      { name: 'left', value: intLit(3) },
      { name: 'right', value: intLit(8) },
    ], 'std'),
  );
  assertEqual(out[0], '8');
});

// ── Map helpers ───────────────────────────────────────────────────────────────

await test('map_keys lists the keys of a created map', async () => {
  // Build a map via map_create with explicit {key,value} entry messages.
  const realMap = stdCall('map_create', [
    { name: 'entries', value: listLit([
      { messageCreation: { typeName: '', fields: [
        { name: 'key', value: strLit('a') }, { name: 'value', value: intLit(1) },
      ] } },
      { messageCreation: { typeName: '', fields: [
        { name: 'key', value: strLit('b') }, { name: 'value', value: intLit(2) },
      ] } },
    ]) },
  ], 'std_collections');
  const out = await runExpr(
    ['print', 'map_create', 'map_keys'],
    stdCall('map_keys', [{ name: 'map', value: realMap }], 'std_collections'),
  );
  assertEqual(out[0], '[a, b]');
});

// ── Self-describing ball-file envelope (unwrapBallFile) ───────────────────────

console.log('\nBall-file envelope:');

await test('accepts an @type-wrapped Program envelope', async () => {
  const prog = {
    '@type': 'type.googleapis.com/ball.v1.Program',
    modules: [
      { name: 'std', functions: [{ name: 'print', isBase: true }] },
      { name: 'main', functions: [{
        name: 'main',
        body: { call: { module: 'std', function: 'print', input: strLit('wrapped') } },
      }] },
    ],
    entryModule: 'main', entryFunction: 'main',
  };
  const engine = new BallEngine(prog);
  await engine.run();
  assertEqual(engine.getOutput()[0], 'wrapped');
});

await test('throws on an unknown @type envelope', async () => {
  const bad = { '@type': 'type.googleapis.com/ball.v1.Widget', modules: [] };
  try {
    new BallEngine(bad);
    throw new Error('Should have thrown');
  } catch (e: any) {
    assert(
      e.message.includes('unknown ball file @type'),
      `Expected unknown-@type error, got: ${e.message}`,
    );
  }
});

// ── Conformance tests ───────────────────────────────────────────────────────

console.log('\nConformance:');

const conformanceDir = join(import.meta.dirname ?? '.', '../../../tests/conformance');
// These four programs have no .expected_output.txt because they require
// host-only constructor knobs (timeoutMs, maxMemoryBytes, etc.) and are
// tested as unit tests above instead.
const skipConformance = new Set<string>([
  '196_timeout',
  '197_memory_limit',
  '201_input_validation',
  '202_sandbox_mode',
]);
try {
  const files = readdirSync(conformanceDir).filter(f => f.endsWith('.ball.json'));
  for (const file of files) {
    const name = file.replace('.ball.json', '');
    if (skipConformance.has(name)) continue;
    const expectedFile = join(conformanceDir, `${name}.expected_output.txt`);

    await test(`conformance: ${name}`, async () => {
      const programJson = readFileSync(join(conformanceDir, file), 'utf-8');
      const expectedOutput = readFileSync(expectedFile, 'utf-8').replace(/\r\n/g, '\n').trim();

      const engine = new BallEngine(programJson);
      await engine.run();
      const actual = engine.getOutput().join('\n').trim();

      if (actual !== expectedOutput) {
        throw new Error(
          `Output mismatch.\nExpected: ${expectedOutput.substring(0, 100)}\nActual:   ${actual.substring(0, 100)}`,
        );
      }
    });
  }
} catch (e: any) {
  if (e.code === 'ENOENT') {
    console.log('  (conformance dir not found, skipping)');
  } else {
    throw e;
  }
}

// ── Summary ─────────────────────────────────────────────────────────────────

console.log(`\n===========================`);
console.log(`Results: ${passed} passed, ${failed} failed, ${passed + failed} total`);
process.exit(failed > 0 ? 1 : 0);

} // end main()

main();
