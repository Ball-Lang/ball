/**
 * Unit tests for `cli_core.ts`'s `normalizeProgram` and the verb wrappers it
 * feeds (issue #364).
 *
 * `dart/shared/lib/cli_core.dart`'s compiled verbs access proto3-JSON fields
 * via direct, un-guarded property access (see `cli_core.ts`'s file header),
 * so `normalizeProgram` must materialize a proto3 default for every field a
 * verb touches — even when a real `.ball.json` omits it entirely. These
 * tests feed maximally sparse inputs (every optional field genuinely
 * absent, not just empty) to exercise the `?? <default>` fallback side of
 * every branch in the normalizer — the "value present" side is already
 * covered end to end by `test/cli_test.ts` and `test/cli_core_parity.test.ts`
 * against real conformance fixtures.
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { infoReport, treeReport, validateReport, validateOk, versionLine } from '../src/cli_core.ts';

describe('cli_core.ts — normalization defaults (sparse proto3-JSON input)', () => {
  test('a Program with every optional field omitted does not throw', () => {
    // No name/version/entryModule/entryFunction/modules at all.
    const sparse = {};
    assert.doesNotThrow(() => infoReport(sparse));
    assert.doesNotThrow(() => treeReport(sparse));
    assert.doesNotThrow(() => validateReport(sparse));
    assert.equal(validateOk(sparse), false, 'a Program with no entry_module/entry_function is invalid');
  });

  test('infoReport on a fully sparse Program renders empty-string defaults', () => {
    const report = infoReport({});
    assert.match(report, /^Program: {2}v\n/, 'expected empty name/version defaults');
    assert.match(report, /Entry: {3}\.\n/, 'expected empty entryModule.entryFunction');
    assert.match(report, /Modules: 0/, 'expected an empty modules list, not a crash');
  });

  test('a Module with every optional field omitted (bare {name}) does not throw', () => {
    const program = { modules: [{ name: 'main' }] };
    assert.doesNotThrow(() => infoReport(program));
    assert.doesNotThrow(() => treeReport(program));
    const info = infoReport(program);
    assert.match(info, /main/, 'module name must still render');
  });

  test('a FunctionDefinition with no name/isBase/body/metadata does not throw', () => {
    const program = { modules: [{ name: 'main', functions: [{}] }] };
    assert.doesNotThrow(() => infoReport(program));
    assert.doesNotThrow(() => validateReport(program));
    // A nameless, non-base function with neither body nor metadata is exactly
    // the "non-base function with no body or metadata" validation error.
    assert.equal(validateOk(program), false);
  });

  test('every ModuleImport.source variant with an empty (defaultless) nested message does not throw', () => {
    const program = {
      name: 'p',
      version: '1',
      entryModule: 'main',
      entryFunction: 'main',
      modules: [
        {
          name: 'main',
          functions: [{ name: 'main' }],
          moduleImports: [
            { http: {} },
            { file: {} },
            { git: {} },
            { registry: {} },
          ],
        },
      ],
    };
    assert.doesNotThrow(() => treeReport(program));
    const tree = treeReport(program);
    assert.match(tree, /→ .* \(http: \)/);
    assert.match(tree, /→ .* \(file: \)/);
    assert.match(tree, /→ .* \(git: @\)/);
    assert.match(tree, /→ .* \(REGISTRY_UNSPECIFIED: @\)/);
  });

  test('versionLine matches the shared cli_core.dart template', () => {
    assert.equal(versionLine('9.9.9'), 'ball 9.9.9');
    assert.equal(versionLine(''), 'ball ');
  });
});
