/// Verifies the Dart ↔ Node round-trip for the ts-morph emitter.
///
/// These tests require `dart/compiler/tool/node_modules` (run
/// `cd dart/compiler/tool && npm install` once). They are skipped
/// automatically when node_modules is missing.
library;

import 'dart:io';

import 'package:ball_compiler/src/ts_emit_plan.dart';
import 'package:ball_compiler/src/ts_emit_runner.dart';
import 'package:test/test.dart';

bool _nodeModulesAvailable() {
  var dir = Directory.current;
  while (true) {
    final nm = Directory('${dir.path}/dart/compiler/tool/node_modules');
    if (nm.existsSync()) return true;
    final parent = dir.parent;
    if (parent.path == dir.path) return false;
    dir = parent;
  }
}

void main() {
  final skip = _nodeModulesAvailable()
      ? null
      : 'node_modules missing under dart/compiler/tool — '
            'run `cd dart/compiler/tool && npm install` once';

  group('ts_emit runner (Dart → Node → TS)', () {
    test('emits a minimal async function with generics', () async {
      final plan = TsEmitPlan(
        path: 'test.ts',
        statements: [
          TsFunction(
            name: 'identity',
            isAsync: true,
            isExported: true,
            typeParameters: [TsTypeParameter(name: 'T')],
            parameters: [TsParameter(name: 'x', type: 'T')],
            returnType: 'Promise<T>',
            body: 'return x;',
          ),
        ],
      );
      final out = await runTsEmitAsync(plan);
      expect(out, contains('export async function identity<T>'));
      expect(out, contains('(x: T): Promise<T>'));
      expect(out, contains('return x;'));
    }, skip: skip);

    test('emits a class with ctor, methods, getters, and inheritance',
        () async {
      final plan = TsEmitPlan(
        path: 'Point.ts',
        statements: [
          TsClass(
            name: 'Point',
            isExported: true,
            typeParameters: [TsTypeParameter(name: 'T')],
            extendsClause: 'BaseShape',
            implementsClause: ['Comparable<Point<T>>'],
            properties: [
              TsProperty(
                name: 'x',
                type: 'number',
                isReadonly: true,
                scope: 'public',
              ),
              TsProperty(name: '_tag', type: 'T', scope: 'private'),
            ],
            ctors: [
              TsCtor(
                parameters: [
                  TsParameter(name: 'x', type: 'number'),
                  TsParameter(name: 'tag', type: 'T'),
                ],
                body: 'super();\nthis.x = x;\nthis._tag = tag;',
              ),
            ],
            methods: [
              TsMethod(
                name: 'compareTo',
                parameters: [TsParameter(name: 'other', type: 'Point<T>')],
                returnType: 'number',
                body: 'return this.x - other.x;',
              ),
            ],
            getters: [
              TsGetter(
                name: 'tag',
                returnType: 'T',
                body: 'return this._tag;',
              ),
            ],
          ),
        ],
      );
      final out = await runTsEmitAsync(plan);
      expect(out, contains('export class Point<T> extends BaseShape'));
      expect(out, contains('implements Comparable<Point<T>>'));
      expect(out, contains('public readonly x: number;'));
      expect(out, contains('private _tag: T;'));
      expect(out, contains('constructor(x: number, tag: T)'));
      expect(out, contains('compareTo(other: Point<T>): number'));
      expect(out, contains('get tag(): T'));
    }, skip: skip);

    test('emits an enum with string members', () async {
      final plan = TsEmitPlan(
        path: 'Color.ts',
        statements: [
          TsEnum(
            name: 'Color',
            isExported: true,
            members: [
              TsEnumMember(name: 'Red', value: 'red'),
              TsEnumMember(name: 'Green', value: 'green'),
            ],
          ),
        ],
      );
      final out = await runTsEmitAsync(plan);
      expect(out, contains('export enum Color'));
      expect(out, contains('Red = "red"'));
      expect(out, contains('Green = "green"'));
    }, skip: skip);

    test('emits an import declaration', () async {
      final plan = TsEmitPlan(
        path: 'uses_fs.ts',
        statements: [
          TsImport(
            moduleSpecifier: 'node:fs',
            namedImports: ['readFileSync', 'writeFileSync'],
          ),
          TsImport(moduleSpecifier: 'node:path', namespaceImport: 'p'),
        ],
      );
      final out = await runTsEmitAsync(plan);
      expect(out, contains('import { readFileSync, writeFileSync }'));
      expect(out, contains('from "node:fs"'));
      expect(out, contains('import * as p'));
    }, skip: skip);

    test('synchronous runner works (via plan file)', () {
      final plan = TsEmitPlan(
        path: 'sync.ts',
        statements: [
          TsFunction(
            name: 'hi',
            parameters: [],
            returnType: 'string',
            body: "return 'hi';",
          ),
        ],
      );
      final out = runTsEmit(plan);
      expect(out, contains('function hi(): string'));
      expect(out, contains("return 'hi';"));
    }, skip: skip);
  });
}
