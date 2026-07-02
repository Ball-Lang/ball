/// #141 regression: compiled `memory_realloc` must MOVE the block — allocate
/// `new_size` bytes and copy the old contents — not silently alias
/// `memory_alloc` (which also read the wrong field and allocated 0 bytes).
///
/// std_memory has no engine implementation (it exists for compiled-target
/// C/C++ interop), so this can't be a conformance fixture: instead compile a
/// hand-built Ball program through [DartCompiler] and actually RUN the
/// emitted Dart, asserting bytes written before the realloc read back
/// identically from the new base address.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import 'support/pipeline_runners.dart';

Expression _intLit(int n) =>
    Expression()..literal = (Literal()..intValue = Int64(n));
Expression _ref(String name) =>
    Expression()..reference = (Reference()..name = name);

FieldValuePair _field(String name, Expression value) => FieldValuePair()
  ..name = name
  ..value = value;

Expression _call(String module, String fn, List<FieldValuePair> fields) =>
    Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = fn
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.addAll(fields))));

Expression _add(Expression left, int n) => _call('std', 'add', [
  _field('left', left),
  _field('right', _intLit(n)),
]);

Statement _let(String name, Expression value) =>
    Statement()..let = (LetBinding()
      ..name = name
      ..value = value);

Statement _stmt(Expression e) => Statement()..expression = e;

Expression _writeU8(Expression address, int value) =>
    _call('std_memory', 'memory_write_u8', [
      _field('address', address),
      _field('value', _intLit(value)),
    ]);

Expression _printReadU8(Expression address) => _call('std', 'print', [
  _field(
    'message',
    _call('std_memory', 'memory_read_u8', [_field('address', address)]),
  ),
]);

void main() {
  test('compiled memory_realloc moves the block and preserves contents',
      () async {
    final body = Expression()
      ..block = (Block()
        ..statements.addAll([
          // a = alloc(4); fill with 11,22,33,44.
          _let(
            'a',
            _call('std_memory', 'memory_alloc', [
              _field('size', _intLit(4)),
            ]),
          ),
          _stmt(_writeU8(_ref('a'), 11)),
          _stmt(_writeU8(_add(_ref('a'), 1), 22)),
          _stmt(_writeU8(_add(_ref('a'), 2), 33)),
          _stmt(_writeU8(_add(_ref('a'), 3), 44)),
          // b = realloc(a, 8) — must copy the 4 bytes to the new block.
          _let(
            'b',
            _call('std_memory', 'memory_realloc', [
              _field('address', _ref('a')),
              _field('new_size', _intLit(8)),
            ]),
          ),
          // Write into the grown tail, then read everything back via b.
          _stmt(_writeU8(_add(_ref('b'), 7), 99)),
          _stmt(_printReadU8(_ref('b'))),
          _stmt(_printReadU8(_add(_ref('b'), 1))),
          _stmt(_printReadU8(_add(_ref('b'), 2))),
          _stmt(_printReadU8(_add(_ref('b'), 3))),
          _stmt(_printReadU8(_add(_ref('b'), 7))),
        ]));

    Module baseModule(String name, List<String> fns) => Module()
      ..name = name
      ..functions.addAll([
        for (final f in fns)
          FunctionDefinition()
            ..name = f
            ..isBase = true,
      ]);
    final program = Program()
      ..name = 'memory_realloc_e2e'
      ..version = '1.0.0'
      ..entryModule = 'main'
      ..entryFunction = 'main'
      ..modules.addAll([
        baseModule('std', ['print', 'add']),
        baseModule('std_memory', [
          'memory_alloc',
          'memory_realloc',
          'memory_write_u8',
          'memory_read_u8',
        ]),
        Module()
          ..name = 'main'
          ..functions.add(FunctionDefinition()
            ..name = 'main'
            ..body = body),
      ]);

    final scratch = Directory.systemTemp.createTempSync('ball_realloc_e2e');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final out = await runRecompiledDart(program, scratch, 'realloc');
    expect(out.trim().split('\n').map((l) => l.trim()).toList(), [
      '11',
      '22',
      '33',
      '44',
      '99',
    ]);
  });
}
