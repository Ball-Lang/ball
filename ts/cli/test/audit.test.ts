/**
 * Unit tests for `cli_core.ts`'s audit surface (issue #362): the capability +
 * termination analyzers now self-host through the compiled cli-core, so these
 * exercise the Map/List report API directly, plus the deep expression-tree
 * normalizer (`matExpr`/`matLiteral`/`matStmt`) branches — fieldAccess-with-
 * object, lambda body, and literal list elements — that the end-to-end
 * `cli_test.ts` fixtures don't all hit, and the reachability-scoped path.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  analyzeCapabilities,
  formatCapabilityReport,
  checkPolicy,
  auditReport,
  analyzeTermination,
  formatTerminationReport,
} from '../src/cli_core.ts';

// A program whose entry function's body threads every expression-node kind the
// deep normalizer descends: block + let-statement (value = fieldAccess whose
// object is a reference) + expression-statement (call whose input is a literal
// list containing a reference and a lambda). `main` also calls a `helper`, and
// `helper` calls `std.print` — so reachability analysis has a real callee to
// merge io up through.
const richProgram = {
  name: 'rich',
  version: '2.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    { name: 'std', functions: [{ name: 'print', isBase: true }] },
    {
      name: 'main',
      functions: [
        {
          name: 'main',
          body: {
            block: {
              statements: [
                {
                  let: {
                    name: 'x',
                    value: {
                      fieldAccess: {
                        object: { reference: { name: 'obj' } },
                        field: 'f',
                      },
                    },
                  },
                },
                {
                  expression: {
                    call: {
                      module: 'main',
                      function: 'helper',
                      input: {
                        literal: {
                          listValue: {
                            elements: [
                              { reference: { name: 'x' } },
                              { lambda: { body: { reference: { name: 'x' } } } },
                            ],
                          },
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        },
        {
          name: 'helper',
          body: {
            call: {
              module: 'std',
              function: 'print',
              input: {
                messageCreation: {
                  typeName: 'PrintInput',
                  fields: [
                    {
                      name: 'message',
                      value: { literal: { stringValue: 'hi' } },
                    },
                  ],
                },
              },
            },
          },
        },
      ],
    },
  ],
};

describe('cli_core.ts — audit (self-hosted capability + termination)', () => {
  test('analyzeCapabilities walks every expression-node kind without throwing', () => {
    const report = analyzeCapabilities(richProgram) as {
      summary: { writesStdout: boolean };
      functions: unknown[];
    };
    // helper calls std.print → io; main is pure (its own body has no base call).
    assert.equal(report.summary.writesStdout, true);
    assert.equal(report.functions.length, 2, 'both functions analyzed');
  });

  test('reachableOnly scopes to the entry closure and merges callee capabilities', () => {
    const report = analyzeCapabilities(richProgram, {
      reachableOnly: true,
    }) as { summary: { writesStdout: boolean } };
    // main → helper → std.print, so io propagates up to main.
    assert.equal(report.summary.writesStdout, true);
  });

  test('formatCapabilityReport + checkPolicy operate on the Map report', () => {
    const report = analyzeCapabilities(richProgram);
    const text = formatCapabilityReport(report);
    assert.ok(text.includes('Ball Capability Audit: rich v2.0.0'));
    assert.ok(text.endsWith('\n'), 'report ends with a trailing newline');

    const violations = checkPolicy(report, new Set(['io']));
    assert.ok(violations.length > 0, 'io is denied → a violation is reported');
    assert.equal(checkPolicy(report, new Set(['fs'])).length, 0);
  });

  test('auditReport renders the capability report (no termination warnings)', () => {
    const text = auditReport(richProgram);
    assert.ok(text.includes('Ball Capability Audit: rich v2.0.0'));
    // A clean program appends no Termination Analysis section.
    assert.ok(!text.includes('Termination Analysis'));
  });

  // Maximally-sparse expression nodes (every optional sub-field genuinely
  // omitted) exercise the "field absent" side of the deep normalizer's guards:
  // a call with no input, a messageCreation/block/literal-list with no repeated
  // children, a fieldAccess with no object, a lambda with no body, a function
  // with no body/metadata, and a module with no functions.
  const sparseProgram = {
    name: 'sparse',
    version: '0.0.1',
    entryModule: 'main',
    entryFunction: 'main',
    modules: [
      { name: 'empty' },
      { name: 'imp', moduleImports: [{ name: 'x', inline: {} }] },
      {
        name: 'main',
        functions: [
          { name: 'main', body: { block: {} } },
          { name: 'bodyless' },
          {
            name: 'withmeta',
            body: { reference: { name: 'r' } },
            metadata: { k: 1 },
          },
          { name: 'callNoInput', body: { call: { module: 'std', function: 'f' } } },
          { name: 'msgNoFields', body: { messageCreation: { typeName: 'T' } } },
          { name: 'listNoElems', body: { literal: { listValue: {} } } },
          { name: 'faNoObject', body: { fieldAccess: { field: 'z' } } },
          { name: 'lambdaNoBody', body: { lambda: {} } },
          {
            name: 'blockResult',
            body: { block: { result: { reference: { name: 'q' } } } },
          },
        ],
      },
    ],
  };

  test('analyzeCapabilities materializes maximally-sparse expression nodes', () => {
    assert.doesNotThrow(() => auditReport(sparseProgram));
    const report = analyzeCapabilities(sparseProgram) as { functions: unknown[] };
    // Every non-base function in `main` is analyzed (empty/imp have none).
    assert.equal(report.functions.length, 9);
  });

  // A `while(true)` loop with a non-exiting body: the only shape the termination
  // analyzer flags. `analyzeTermination`/`formatTerminationReport` are exposed
  // separately from `auditReport` so the `--reachable-only` audit path (which
  // scopes the capability report to the reachable closure but still runs
  // termination on the WHOLE program) can append the section — issue #412.
  const loopProgram = {
    name: 'loopy',
    version: '1.0.0',
    entryModule: 'main',
    entryFunction: 'main',
    modules: [
      { name: 'std', functions: [{ name: 'while', isBase: true }] },
      {
        name: 'main',
        functions: [
          {
            name: 'main',
            body: {
              call: {
                module: 'std',
                function: 'while',
                input: {
                  messageCreation: {
                    typeName: 'WhileInput',
                    fields: [
                      { name: 'condition', value: { literal: { boolValue: true } } },
                      { name: 'body', value: { reference: { name: 'x' } } },
                    ],
                  },
                },
              },
            },
          },
        ],
      },
    ],
  };

  test('analyzeTermination flags an infinite loop; formatTerminationReport renders it', () => {
    const warnings = analyzeTermination(loopProgram);
    assert.ok(warnings.length > 0, 'while(true) without break/return is flagged');

    const text = formatTerminationReport(warnings);
    assert.ok(text.includes('Termination Analysis'));
    assert.ok(text.includes('Potential Infinite Loops'));
    assert.ok(text.includes('while(true)'));
  });

  // #609: a program that declares its OWN `isBase` module (the host-extension
  // seam) must be reported under the explicit `custom` capability, not pure.
  // On TS the audit IS the whole gate — `new BallEngine(...)` builds a full,
  // uninjectable std handler — so this is where a pure/NO RISK verdict on a
  // custom-module call hurts most.
  const customProgram = {
    name: 'custom',
    version: '1.0.0',
    entryModule: 'main',
    entryFunction: 'main',
    modules: [
      { name: 'std', functions: [{ name: 'print', isBase: true }] },
      { name: 'mymodule', functions: [{ name: 'exec_shell', isBase: true }] },
      {
        name: 'main',
        functions: [
          {
            name: 'main',
            body: {
              call: {
                module: 'mymodule',
                function: 'exec_shell',
                input: { messageCreation: { fields: [] } },
              },
            },
          },
        ],
      },
    ],
  };

  test('a call into a declared custom base module is `custom`, never pure (#609)', () => {
    const report = analyzeCapabilities(customProgram) as {
      summary: { isPure: boolean };
    };
    assert.equal(report.summary.isPure, false);
    assert.ok(
      checkPolicy(report, new Set(['custom'])).length > 0,
      '--deny custom must trip',
    );

    const text = auditReport(customProgram);
    assert.ok(text.includes('main.main → mymodule.exec_shell'));
    assert.ok(text.includes('REVIEW REQUIRED — calls into custom base modules'));
    assert.ok(!text.includes('NO RISK'));
    // The termination half says out loud that it cannot analyze the callee.
    assert.ok(text.includes('Unknown Termination (1):'));
  });

  // #609 follow-up: the engine dispatches a base call by function identity, not
  // by `call.module`, so an unqualified (or benign-looking) call site reaches
  // the very same host handler. Classifying only the truthfully qualified
  // spelling left both of those reading NO RISK with `--deny custom` empty.
  for (const [label, callModule] of [
    ['unqualified', undefined],
    ['spoofed', 'harmless_looking_module'],
  ] as const) {
    test(`a ${label} call into a declared custom base module is \`custom\` (#609)`, () => {
      const program = {
        ...customProgram,
        modules: [
          customProgram.modules[0],
          customProgram.modules[1],
          {
            name: 'main',
            functions: [
              {
                name: 'main',
                body: {
                  call: {
                    ...(callModule === undefined ? {} : { module: callModule }),
                    function: 'exec_shell',
                    input: { messageCreation: { fields: [] } },
                  },
                },
              },
            ],
          },
        ],
      };
      const report = analyzeCapabilities(program) as {
        summary: { isPure: boolean };
      };
      assert.equal(report.summary.isPure, false);
      const violations = checkPolicy(report, new Set(['custom']));
      assert.ok(violations.length > 0, '--deny custom must trip');
      assert.ok(
        violations.some((v: string) =>
          v.includes(
            `mymodule.exec_shell (call site: ${callModule ?? 'main'}.exec_shell)`,
          ),
        ),
        `violation must name the declaring module: ${JSON.stringify(violations)}`,
      );

      // The DECLARING module leads; the call-site spelling follows it.
      const callSite = `${callModule ?? 'main'}.exec_shell`;
      const text = auditReport(program);
      assert.ok(
        text.includes(`mymodule.exec_shell (call site: ${callSite})`),
        `report must name the declaring module and the call site: ${text}`,
      );
      assert.ok(
        text.includes('REVIEW REQUIRED — calls into custom base modules'),
      );
      assert.ok(!text.includes('NO RISK'));
      assert.ok(text.includes('Unknown Termination (1):'));
    });
  }

  test('analyzeTermination returns no warnings for a clean program', () => {
    // richProgram has no loops → an empty warning list, and the formatter still
    // produces a (warning-free) section rather than throwing.
    const warnings = analyzeTermination(richProgram);
    assert.equal(warnings.length, 0);
    assert.ok(formatTerminationReport(warnings).includes('Termination Analysis'));
  });
});
