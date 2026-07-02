/// Unit tests for the non-`std` base-module dispatchers: std_memory,
/// std_collections, std_io, std_convert, std_fs, std_time, and ball_proto.
///
/// The Dart encoder routes almost everything through universal `std`, so these
/// module-specific lowerings are mostly exercised by hand-written / cross-language
/// Ball. We build the Ball IR directly and pin the emitted Dart for each arm.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_compiler/compiler.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

Expression _strLit(String s) =>
    Expression()..literal = (Literal()..stringValue = s);
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

Program _program(Expression expr) {
  Module baseModule(String name, List<String> fns) => Module()
    ..name = name
    ..functions.addAll([
      for (final f in fns)
        FunctionDefinition()
          ..name = f
          ..isBase = true,
    ]);
  final mainFn = FunctionDefinition()
    ..name = 'main'
    ..body = expr;
  return Program()
    ..name = 'base_modules_test'
    ..version = '1.0.0'
    ..entryModule = 'main'
    ..entryFunction = 'main'
    ..modules.addAll([
      baseModule('std', ['print']),
      baseModule('std_memory', ['memory_alloc']),
      baseModule('std_collections', ['list_push']),
      baseModule('std_io', ['exit']),
      baseModule('std_convert', ['json_encode']),
      baseModule('std_fs', ['file_read']),
      baseModule('std_time', ['now']),
      baseModule('ball_proto', ['whichExpr']),
      Module()
        ..name = 'main'
        ..functions.add(mainFn),
    ]);
}

String _compile(Expression expr) =>
    DartCompiler(_program(expr), noFormat: true).compile();

void main() {
  group('std_memory', () {
    final addr = _field('address', _intLit(16));
    test('memory_alloc emits bump-allocator IIFE', () {
      final out = _compile(
        _call('std_memory', 'memory_alloc', [_field('size', _intLit(8))]),
      );
      expect(out, contains('_ballHeapPtr += 8'));
    });
    test('memory_realloc allocates new_size and copies the old block', () {
      // ReallocInput carries `address` + `new_size` (NOT `size`) — the old
      // emission aliased memory_alloc, losing the contents and allocating
      // zero bytes (#141).
      final out = _compile(
        _call('std_memory', 'memory_realloc', [
          _field('address', _intLit(16)),
          _field('new_size', _intLit(8)),
        ]),
      );
      expect(out, contains('final __old = 16'));
      expect(out, contains('final __size = 8'));
      expect(out, contains('_ballHeapPtr += __size'));
      // The copy loop that preserves the old block's bytes.
      expect(
        out,
        contains(
          '_ballMemory.setUint8(__addr + __i, '
          '_ballMemory.getUint8(__old + __i))',
        ),
      );
    });
    test('memory_free is a noop comment', () {
      expect(
        _compile(_call('std_memory', 'memory_free', [addr])),
        contains('noop in Dart'),
      );
    });
    test('typed reads', () {
      final cases = {
        'memory_read_i8': 'getInt8',
        'memory_read_u8': 'getUint8',
        'memory_read_i16': 'getInt16',
        'memory_read_u16': 'getUint16',
        'memory_read_i32': 'getInt32',
        'memory_read_u32': 'getUint32',
        'memory_read_i64': 'getInt64',
        'memory_read_u64': 'getUint64',
        'memory_read_f32': 'getFloat32',
        'memory_read_f64': 'getFloat64',
      };
      cases.forEach((fn, method) {
        expect(
          _compile(_call('std_memory', fn, [addr])),
          contains('_ballMemory.$method(16'),
        );
      });
    });
    test('typed writes', () {
      final fields = [addr, _field('value', _intLit(42))];
      final cases = {
        'memory_write_i8': 'setInt8',
        'memory_write_u8': 'setUint8',
        'memory_write_i16': 'setInt16',
        'memory_write_u16': 'setUint16',
        'memory_write_i32': 'setInt32',
        'memory_write_u32': 'setUint32',
        'memory_write_i64': 'setInt64',
        'memory_write_u64': 'setUint64',
        'memory_write_f32': 'setFloat32',
        'memory_write_f64': 'setFloat64',
      };
      cases.forEach((fn, method) {
        expect(
          _compile(_call('std_memory', fn, fields)),
          contains('_ballMemory.$method(16, 42'),
        );
      });
    });
    test('bulk ops copy/set/compare', () {
      expect(
        _compile(
          _call('std_memory', 'memory_copy', [
            _field('dest', _intLit(0)),
            _field('src', _intLit(8)),
            _field('size', _intLit(4)),
          ]),
        ),
        contains('setUint8(0 + __i, _ballMemory.getUint8(8 + __i))'),
      );
      expect(
        _compile(
          _call('std_memory', 'memory_set', [
            addr,
            _field('value', _intLit(0)),
            _field('size', _intLit(4)),
          ]),
        ),
        contains('setUint8(16 + __i, 0)'),
      );
      expect(
        _compile(
          _call('std_memory', 'memory_compare', [
            _field('a', _intLit(0)),
            _field('b', _intLit(8)),
            _field('size', _intLit(4)),
          ]),
        ),
        contains('return __d'),
      );
    });
    test('pointer arithmetic', () {
      final fields = [
        _field('address', _intLit(16)),
        _field('offset', _intLit(2)),
        _field('element_size', _intLit(4)),
      ];
      expect(
        _compile(_call('std_memory', 'ptr_add', fields)),
        contains('(16 + (2 * 4))'),
      );
      expect(
        _compile(_call('std_memory', 'ptr_sub', fields)),
        contains('(16 - (2 * 4))'),
      );
      expect(
        _compile(_call('std_memory', 'ptr_diff', fields)),
        contains('((16 - 2) ~/ 4)'),
      );
    });
    test('stack frame ops', () {
      expect(
        _compile(
          _call('std_memory', 'stack_alloc', [_field('size', _intLit(8))]),
        ),
        contains('_ballStackPtr -= 8'),
      );
      expect(
        _compile(_call('std_memory', 'stack_push_frame', [])),
        contains('_ballStackFrames.add(_ballStackPtr)'),
      );
      expect(
        _compile(_call('std_memory', 'stack_pop_frame', [])),
        contains('_ballStackFrames.removeLast()'),
      );
    });
    test('memory_sizeof for each type bucket', () {
      String sizeof(String type) => _compile(
        _call('std_memory', 'memory_sizeof', [
          _field('type_name', _strLit(type)),
        ]),
      );
      expect(sizeof('int8'), contains('void main() { 1'));
      expect(sizeof('int16'), contains('void main() { 2'));
      expect(sizeof('int32'), contains('void main() { 4'));
      expect(sizeof('int64'), contains('void main() { 8'));
      expect(sizeof('void'), contains('void main() { 1'));
      expect(sizeof('unknown_type'), contains('void main() { 8'));
    });
    test('address_of / deref / nullptr / info', () {
      expect(
        _compile(
          _call('std_memory', 'address_of', [_field('value', _ref('x'))]),
        ),
        contains('address_of'),
      );
      expect(
        _compile(
          _call('std_memory', 'deref', [_field('pointer', _intLit(16))]),
        ),
        contains('getInt64(16'),
      );
      expect(
        _compile(_call('std_memory', 'nullptr', [])),
        contains('void main() { 0'),
      );
      expect(
        _compile(_call('std_memory', 'memory_heap_size', [])),
        contains('_ballMemory.lengthInBytes'),
      );
      expect(
        _compile(_call('std_memory', 'memory_stack_size', [])),
        contains('_ballMemory.lengthInBytes - _ballStackPtr'),
      );
    });
    test('unsupported std_memory function emits marker', () {
      expect(
        _compile(_call('std_memory', 'mystery', [])),
        contains('/* unsupported: std_memory.mystery */'),
      );
    });
  });

  group('std_collections', () {
    final list = _field('list', _ref('xs'));
    test('list push/pop/insert/remove/get/set', () {
      expect(
        _compile(
          _call('std_collections', 'list_push', [
            list,
            _field('value', _intLit(1)),
          ]),
        ),
        contains('xs..add(1)'),
      );
      expect(
        _compile(_call('std_collections', 'list_pop', [list])),
        contains('xs.removeLast()'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_insert', [
            list,
            _field('index', _intLit(0)),
            _field('value', _intLit(9)),
          ]),
        ),
        contains('xs..insert(0, 9)'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_remove_at', [
            list,
            _field('index', _intLit(0)),
          ]),
        ),
        contains('xs.removeAt(0)'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_get', [
            list,
            _field('index', _intLit(0)),
          ]),
        ),
        contains('xs[0]'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_set', [
            list,
            _field('index', _intLit(0)),
            _field('value', _intLit(9)),
          ]),
        ),
        contains('xs[0] = 9'),
      );
    });
    test('list query props', () {
      final cases = {
        'list_length': 'xs.length',
        'list_is_empty': 'xs.isEmpty',
        'list_first': 'xs.first',
        'list_last': 'xs.last',
      };
      cases.forEach((fn, frag) {
        expect(_compile(_call('std_collections', fn, [list])), contains(frag));
      });
    });
    test('list contains / index_of', () {
      final v = _field('value', _intLit(3));
      expect(
        _compile(_call('std_collections', 'list_contains', [list, v])),
        contains('xs.contains(3)'),
      );
      expect(
        _compile(_call('std_collections', 'list_index_of', [list, v])),
        contains('xs.indexOf(3)'),
      );
    });
    test('list higher-order ops', () {
      final cb = _field('callback', _ref('fn'));
      final cases = {
        'list_map': 'xs.map(fn).toList()',
        'list_filter': 'xs.where(fn).toList()',
        'list_reduce': 'xs.reduce(fn)',
        'list_any': 'xs.any(fn)',
        'list_every': 'xs.every(fn)',
        'list_flat_map': 'xs.expand(fn).toList()',
        'list_foreach': 'xs.forEach(fn)',
      };
      cases.forEach((fn, frag) {
        expect(
          _compile(_call('std_collections', fn, [list, cb])),
          contains(frag),
        );
      });
    });
    test('list_sort with and without comparator', () {
      expect(
        _compile(_call('std_collections', 'list_sort', [list])),
        contains('xs..sort()'),
      );
      // The encoder names the comparator arg `value` (see encoder.dart's
      // cascadeCollectionRoutes arg renaming), which `_cb()` reads.
      expect(
        _compile(
          _call('std_collections', 'list_sort', [
            list,
            _field('value', _ref('cmp')),
          ]),
        ),
        contains('xs..sort(cmp)'),
      );
    });
    test('list_reverse / to_list / clear / concat', () {
      expect(
        _compile(_call('std_collections', 'list_reverse', [list])),
        contains('xs.reversed.toList()'),
      );
      expect(
        _compile(_call('std_collections', 'list_to_list', [list])),
        contains('xs.toList()'),
      );
      expect(
        _compile(_call('std_collections', 'list_clear', [list])),
        contains('xs..clear()'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_concat', [
            _field('left', _ref('a')),
            _field('right', _ref('b')),
          ]),
        ),
        contains('[...a, ...b]'),
      );
    });
    test('list_slice 1-arg and 2-arg', () {
      expect(
        _compile(
          _call('std_collections', 'list_slice', [
            list,
            _field('start', _intLit(1)),
          ]),
        ),
        contains('xs.sublist(1)'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_slice', [
            list,
            _field('value', _intLit(1)),
            _field('value', _intLit(3)),
          ]),
        ),
        contains('xs.sublist(1, 3)'),
      );
    });
    test('list_join / string_join', () {
      expect(
        _compile(_call('std_collections', 'list_join', [list])),
        contains('xs.join()'),
      );
      expect(
        _compile(
          _call('std_collections', 'list_join', [
            list,
            _field('separator', _strLit('-')),
          ]),
        ),
        contains("xs.join('-')"),
      );
    });
    test('map operations', () {
      final map = _field('map', _ref('m'));
      final key = _field('key', _strLit('k'));
      expect(
        _compile(_call('std_collections', 'map_get', [map, key])),
        contains("m['k']"),
      );
      expect(
        _compile(
          _call('std_collections', 'map_set', [
            map,
            key,
            _field('value', _intLit(1)),
          ]),
        ),
        contains("m['k'] = 1"),
      );
      expect(
        _compile(
          _call('std_collections', 'map_put_if_absent', [
            map,
            key,
            _field('value', _intLit(1)),
          ]),
        ),
        contains('putIfAbsent'),
      );
      expect(
        _compile(_call('std_collections', 'map_delete', [map, key])),
        contains("m.remove('k')"),
      );
      expect(
        _compile(_call('std_collections', 'map_contains_key', [map, key])),
        contains("m.containsKey('k')"),
      );
      final mapCases = {
        'map_keys': 'm.keys.toList()',
        'map_values': 'm.values.toList()',
        'map_entries': 'm.entries.toList()',
        'map_is_empty': 'm.isEmpty',
        'map_length': 'm.length',
      };
      mapCases.forEach((fn, frag) {
        expect(_compile(_call('std_collections', fn, [map])), contains(frag));
      });
    });
    test('set operations', () {
      final set = _field('set', _ref('s'));
      final v = _field('value', _intLit(1));
      expect(
        _compile(_call('std_collections', 'set_add', [set, v])),
        contains('s..add(1)'),
      );
      expect(
        _compile(_call('std_collections', 'set_remove', [set, v])),
        contains('s.remove(1)'),
      );
      expect(
        _compile(_call('std_collections', 'set_contains', [set, v])),
        contains('s.contains(1)'),
      );
      final binFields = [_field('left', _ref('a')), _field('right', _ref('b'))];
      expect(
        _compile(_call('std_collections', 'set_union', binFields)),
        contains('a.union(b)'),
      );
      expect(
        _compile(_call('std_collections', 'set_intersection', binFields)),
        contains('a.intersection(b)'),
      );
      expect(
        _compile(_call('std_collections', 'set_difference', binFields)),
        contains('a.difference(b)'),
      );
      final setCases = {
        'set_length': 's.length',
        'set_is_empty': 's.isEmpty',
        'set_to_list': 's.toList()',
      };
      setCases.forEach((fn, frag) {
        expect(_compile(_call('std_collections', fn, [set])), contains(frag));
      });
    });
    test('unsupported std_collections function emits marker', () {
      expect(
        _compile(_call('std_collections', 'mystery', [])),
        contains('/* unsupported: std_collections.mystery */'),
      );
    });
  });

  group('std_io', () {
    test('all io ops', () {
      expect(
        _compile(
          _call('std_io', 'print_error', [_field('message', _strLit('boom'))]),
        ),
        contains("stderr.writeln('boom')"),
      );
      expect(
        _compile(_call('std_io', 'read_line', [])),
        contains('stdin.readLineSync() ?? ""'),
      );
      expect(
        _compile(_call('std_io', 'exit', [_field('code', _intLit(1))])),
        contains('exit(1)'),
      );
      expect(
        _compile(_call('std_io', 'panic', [_field('message', _strLit('x'))])),
        contains("(stderr.writeln('x'), exit(1))"),
      );
      expect(
        _compile(
          _call('std_io', 'sleep_ms', [_field('milliseconds', _intLit(10))]),
        ),
        contains('Future.delayed(Duration(milliseconds: 10))'),
      );
      expect(
        _compile(_call('std_io', 'timestamp_ms', [])),
        contains('DateTime.now().millisecondsSinceEpoch'),
      );
      expect(
        _compile(
          _call('std_io', 'random_int', [
            _field('min', _intLit(0)),
            _field('max', _intLit(10)),
          ]),
        ),
        contains('Random().nextInt(10 - 0) + 0'),
      );
      expect(
        _compile(_call('std_io', 'random_double', [])),
        contains('Random().nextDouble()'),
      );
      expect(
        _compile(_call('std_io', 'env_get', [_field('name', _strLit('HOME'))])),
        contains("Platform.environment['HOME'] ?? \"\""),
      );
      expect(
        _compile(_call('std_io', 'args_get', [])),
        contains('void main() { []'),
      );
      expect(
        _compile(_call('std_io', 'mystery', [])),
        contains('/* unsupported: std_io.mystery */'),
      );
    });
  });

  group('std_convert', () {
    test('json + utf8 + base64', () {
      expect(
        _compile(
          _call('std_convert', 'json_encode', [_field('value', _ref('o'))]),
        ),
        contains('jsonEncode(o)'),
      );
      expect(
        _compile(
          _call('std_convert', 'json_decode', [
            _field('source', _strLit('{}')),
          ]),
        ),
        contains("jsonDecode('{}')"),
      );
      expect(
        _compile(
          _call('std_convert', 'utf8_encode', [
            _field('source', _strLit('hi')),
          ]),
        ),
        contains("utf8.encode('hi')"),
      );
      expect(
        _compile(
          _call('std_convert', 'utf8_decode', [_field('bytes', _ref('b'))]),
        ),
        contains('utf8.decode(b)'),
      );
      expect(
        _compile(
          _call('std_convert', 'base64_encode', [_field('bytes', _ref('b'))]),
        ),
        contains('base64.encode(b)'),
      );
      expect(
        _compile(
          _call('std_convert', 'base64_decode', [
            _field('source', _strLit('aGk=')),
          ]),
        ),
        contains("base64.decode('aGk=')"),
      );
      expect(
        _compile(_call('std_convert', 'mystery', [])),
        contains('/* unsupported: std_convert.mystery */'),
      );
    });
  });

  group('std_fs', () {
    final path = _field('path', _strLit('/tmp/f'));
    test('file + dir ops', () {
      expect(
        _compile(_call('std_fs', 'file_read', [path])),
        contains("File('/tmp/f').readAsStringSync()"),
      );
      expect(
        _compile(_call('std_fs', 'file_read_bytes', [path])),
        contains("File('/tmp/f').readAsBytesSync()"),
      );
      expect(
        _compile(
          _call('std_fs', 'file_write', [
            path,
            _field('content', _strLit('x')),
          ]),
        ),
        contains("writeAsStringSync('x')"),
      );
      expect(
        _compile(
          _call('std_fs', 'file_write_bytes', [
            path,
            _field('content', _ref('b')),
          ]),
        ),
        contains('writeAsBytesSync(b)'),
      );
      expect(
        _compile(
          _call('std_fs', 'file_append', [
            path,
            _field('content', _strLit('x')),
          ]),
        ),
        contains('mode: FileMode.append'),
      );
      expect(
        _compile(_call('std_fs', 'file_exists', [path])),
        contains("File('/tmp/f').existsSync()"),
      );
      expect(
        _compile(_call('std_fs', 'file_delete', [path])),
        contains("File('/tmp/f').deleteSync()"),
      );
      expect(
        _compile(_call('std_fs', 'dir_list', [path])),
        contains('listSync().map((e) => e.path).toList()'),
      );
      expect(
        _compile(_call('std_fs', 'dir_create', [path])),
        contains('createSync(recursive: true)'),
      );
      expect(
        _compile(_call('std_fs', 'dir_exists', [path])),
        contains("Directory('/tmp/f').existsSync()"),
      );
      expect(
        _compile(_call('std_fs', 'mystery', [])),
        contains('/* unsupported: std_fs.mystery */'),
      );
    });
  });

  group('std_time', () {
    test('time ops', () {
      expect(
        _compile(_call('std_time', 'now', [])),
        contains('DateTime.now().millisecondsSinceEpoch'),
      );
      expect(
        _compile(_call('std_time', 'now_micros', [])),
        contains('DateTime.now().microsecondsSinceEpoch'),
      );
      expect(
        _compile(
          _call('std_time', 'format_timestamp', [
            _field('timestamp', _intLit(0)),
          ]),
        ),
        contains(
          'fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String()',
        ),
      );
      expect(
        _compile(
          _call('std_time', 'parse_timestamp', [
            _field('source', _strLit('2020-01-01')),
          ]),
        ),
        contains("DateTime.parse('2020-01-01').millisecondsSinceEpoch"),
      );
      expect(
        _compile(
          _call('std_time', 'duration_add', [
            _field('left', _ref('a')),
            _field('right', _ref('b')),
          ]),
        ),
        contains('(a + b)'),
      );
      expect(
        _compile(
          _call('std_time', 'duration_subtract', [
            _field('left', _ref('a')),
            _field('right', _ref('b')),
          ]),
        ),
        contains('(a - b)'),
      );
      for (final comp in ['year', 'month', 'day', 'hour', 'minute', 'second']) {
        expect(
          _compile(_call('std_time', comp, [])),
          contains('DateTime.now().$comp'),
        );
      }
      expect(
        _compile(_call('std_time', 'mystery', [])),
        contains('/* unsupported: std_time.mystery */'),
      );
    });
  });

  group('ball_proto', () {
    test('reflection helper maps to receiver method', () {
      expect(
        _compile(_call('ball_proto', 'whichExpr', [_field('obj', _ref('e'))])),
        contains('e.whichExpr()'),
      );
      expect(
        _compile(_call('ball_proto', 'hasBody', [_field('value', _ref('fn'))])),
        contains('fn.hasBody()'),
      );
    });
    test('missing object emits invalid marker', () {
      expect(
        _compile(_call('ball_proto', 'whichExpr', [])),
        contains('/* invalid ball_proto.whichExpr() */'),
      );
    });
  });
}
