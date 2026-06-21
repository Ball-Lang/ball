// Coverage-focused tests for the std_fs base-function handlers in
// engine_std.dart (file read/write/append/exists/delete, byte variants, and
// dir create/list/exists) plus the sandbox gate that blocks them. Driven by
// invoking the engine's StdModuleHandler dispatch directly (base functions are
// not reachable through the user-facing callFunction resolver) against a real
// temp directory.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// A minimal program (no entry needed — we call base functions directly).
Program _emptyProgram() => Program()
  ..mergeFromProto3Json({
    'name': 't',
    'entryModule': 'main',
    'entryFunction': 'main',
    'modules': [
      {'name': 'std', 'functions': []},
      {'name': 'main', 'functions': []},
    ],
  });

void main() {
  late Directory tmp;
  late BallEngine engine;
  late StdModuleHandler std;
  late BallEngine sandboxedEngine;
  late StdModuleHandler sandboxedStd;

  /// Invokes a std-module base function through the handler dispatch.
  Future<Object?> fs(
    StdModuleHandler handler,
    BallEngine eng,
    String fn,
    Object? input,
  ) async {
    final r = handler.call(fn, input, eng.callFunction);
    return r is Future ? await r : r;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ball_fs_cov_');
    engine = BallEngine(_emptyProgram());
    std = engine.moduleHandlers.first as StdModuleHandler;
    sandboxedEngine = BallEngine(_emptyProgram(), sandbox: true);
    sandboxedStd = sandboxedEngine.moduleHandlers.first as StdModuleHandler;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String p(String name) => '${tmp.path}/$name';

  group('file lifecycle', () {
    test('write then read a text file', () async {
      await fs(std, engine, 'file_write', {
        'path': p('a.txt'),
        'content': 'hello',
      });
      final read = await fs(std, engine, 'file_read', {'path': p('a.txt')});
      expect(read, 'hello');
    });

    test('append extends an existing file', () async {
      await fs(std, engine, 'file_write', {'path': p('b.txt'), 'content': 'a'});
      await fs(std, engine, 'file_append', {
        'path': p('b.txt'),
        'content': 'b',
      });
      expect(await fs(std, engine, 'file_read', {'path': p('b.txt')}), 'ab');
    });

    test('write then read bytes', () async {
      await fs(std, engine, 'file_write_bytes', {
        'path': p('c.bin'),
        'content': [1, 2, 3],
      });
      final bytes = await fs(std, engine, 'file_read_bytes', {
        'path': p('c.bin'),
      });
      expect(bytes, [1, 2, 3]);
    });

    test('file_exists reports presence, file_delete removes it', () async {
      await fs(std, engine, 'file_write', {'path': p('d.txt'), 'content': 'x'});
      expect(
        await fs(std, engine, 'file_exists', {'path': p('d.txt')}),
        isTrue,
      );
      await fs(std, engine, 'file_delete', {'path': p('d.txt')});
      expect(
        await fs(std, engine, 'file_exists', {'path': p('d.txt')}),
        isFalse,
      );
    });
  });

  group('directory ops', () {
    test('dir_create / dir_exists / dir_list', () async {
      final dir = p('sub');
      expect(await fs(std, engine, 'dir_exists', {'path': dir}), isFalse);
      await fs(std, engine, 'dir_create', {'path': dir});
      expect(await fs(std, engine, 'dir_exists', {'path': dir}), isTrue);
      await fs(std, engine, 'file_write', {
        'path': '$dir/f.txt',
        'content': 'y',
      });
      final listing = await fs(std, engine, 'dir_list', {'path': dir});
      expect(listing, isA<List>());
      expect((listing as List).any((e) => '$e'.endsWith('f.txt')), isTrue);
    });
  });

  group('sandbox gate blocks every fs op', () {
    for (final op in const [
      'file_read',
      'file_read_bytes',
      'file_exists',
      'file_delete',
      'dir_list',
      'dir_create',
      'dir_exists',
    ]) {
      test('$op throws under sandbox', () {
        expect(
          () => fs(sandboxedStd, sandboxedEngine, op, {'path': p('z')}),
          throwsA(
            isA<BallRuntimeError>().having(
              (e) => e.message,
              'm',
              contains('Sandbox violation'),
            ),
          ),
        );
      });
    }

    test('file_write throws under sandbox', () {
      expect(
        () => fs(sandboxedStd, sandboxedEngine, 'file_write', {
          'path': p('z'),
          'content': 'x',
        }),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });

  group('std_io base functions', () {
    test('read_line returns the injected stdin line', () async {
      final eng = BallEngine(_emptyProgram(), stdinReader: () => 'typed input');
      final ioStd = eng.moduleHandlers.first as StdModuleHandler;
      expect(await fs(ioStd, eng, 'read_line', null), 'typed input');
    });

    test(
      'read_line returns empty string when no reader is configured',
      () async {
        expect(await fs(std, engine, 'read_line', null), '');
      },
    );

    test('sleep_ms with a positive delay completes', () async {
      expect(await fs(std, engine, 'sleep_ms', 1), isNull);
    });

    test('sleep_ms with a non-numeric / zero input is a no-op', () async {
      expect(await fs(std, engine, 'sleep_ms', 'nope'), isNull);
    });

    test('print_error writes to the stderr sink', () async {
      final errs = <String>[];
      final eng = BallEngine(_emptyProgram(), stderr: errs.add);
      final ioStd = eng.moduleHandlers.first as StdModuleHandler;
      await fs(ioStd, eng, 'print_error', {'message': 'oops'});
      expect(errs, ['oops']);
    });

    test('env_get is blocked under sandbox', () {
      expect(
        () => fs(sandboxedStd, sandboxedEngine, 'env_get', {'name': 'PATH'}),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'm',
            contains('Sandbox violation'),
          ),
        ),
      );
    });

    test('exit / panic are blocked under sandbox', () {
      expect(
        () => fs(sandboxedStd, sandboxedEngine, 'exit', {'code': 0}),
        throwsA(isA<BallRuntimeError>()),
      );
      expect(
        () => fs(sandboxedStd, sandboxedEngine, 'panic', {'message': 'x'}),
        throwsA(isA<BallRuntimeError>()),
      );
    });
  });
}
