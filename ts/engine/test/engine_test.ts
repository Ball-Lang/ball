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

// ── Conformance tests ───────────────────────────────────────────────────────

console.log('\nConformance:');

const conformanceDir = join(import.meta.dirname ?? '.', '../../../tests/conformance');
// Fixtures that depend on host-only `BallEngine(...)` constructor knobs
// (timeoutMs, maxMemoryBytes, max* limits, sandbox) which the TS wrapper
// at ts/engine/src/index.ts doesn't pass. Skipped here so the suite
// finishes; the Dart parity test has a matching skip-list.
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

// ── Encoder-generated conformance ──────────────────────────────────────────
// Same tests the Dart engine runs from tests/fixtures/dart/_generated/.
// These are Dart source files encoded to Ball IR by the Dart encoder.

console.log('\nEncoder-generated conformance:');

const encoderGenDir = join(import.meta.dirname ?? '.', '../../../tests/fixtures/dart/_generated');
try {
  const genFiles = readdirSync(encoderGenDir).filter(f => f.endsWith('.ball.json'));
  for (const file of genFiles) {
    const name = file.replace('.ball.json', '');
    const expectedFile = join(encoderGenDir, `${name}.expected_output.txt`);

    await test(`encoder-generated: ${name}`, async () => {
      const programJson = readFileSync(join(encoderGenDir, file), 'utf-8');
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
    console.log('  (encoder-generated dir not found, skipping)');
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
