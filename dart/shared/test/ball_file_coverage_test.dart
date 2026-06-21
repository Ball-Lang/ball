/// Coverage-focused tests for ball_file.dart: the binary/JSON decode error
/// branches (unknown type URL, non-object JSON, missing @type, unknown @type),
/// the Program/Module mismatch throws for every typed decoder, and the
/// _typeUrlFor ArgumentError for a non-top-level message.
library;

import 'package:ball_base/ball_base.dart'
    show
        BallFileFormatException,
        BallModuleFile,
        BallProgramFile,
        decodeBallFileBinary,
        decodeBallFileJson,
        decodeModuleBinary,
        decodeModuleJson,
        decodeProgramBinary,
        decodeProgramJson,
        encodeBallFileBinary,
        encodeBallFileJson,
        moduleTypeUrl,
        programTypeUrl;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
import 'package:test/test.dart';

Program _program(String name) => Program()..name = name;
Module _module(String name) => Module()..name = name;

void main() {
  group('binary decode', () {
    test('round-trips a Program and a Module envelope', () {
      final pf = decodeBallFileBinary(encodeBallFileBinary(_program('p')));
      expect(pf, isA<BallProgramFile>());
      expect((pf as BallProgramFile).program.name, 'p');

      final mf = decodeBallFileBinary(encodeBallFileBinary(_module('m')));
      expect(mf, isA<BallModuleFile>());
      expect((mf as BallModuleFile).module.name, 'm');
    });

    test('an unknown type URL throws BallFileFormatException', () {
      // A real google.protobuf.Any whose type URL is neither Program nor Module.
      final any = Any.pack(
        Module()..name = 'x',
        typeUrlPrefix: 'type.googleapis.com',
      )..typeUrl = 'type.googleapis.com/ball.v1.Nope';
      expect(
        () => decodeBallFileBinary(any.writeToBuffer()),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('unknown ball file type'),
          ),
        ),
      );
    });
  });

  group('JSON decode error branches', () {
    test('non-object JSON throws', () {
      expect(
        () => decodeBallFileJson('not an object'),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('must be an object'),
          ),
        ),
      );
    });

    test('missing @type throws', () {
      expect(
        () => decodeBallFileJson({'name': 'p'}),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('not self-describing'),
          ),
        ),
      );
    });

    test('unknown @type throws', () {
      expect(
        () => decodeBallFileJson({'@type': 'type.googleapis.com/ball.v1.Nope'}),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('unknown ball file @type'),
          ),
        ),
      );
    });

    test('round-trips a Program and a Module', () {
      final pf = decodeBallFileJson(encodeBallFileJson(_program('jp')));
      expect((pf as BallProgramFile).program.name, 'jp');
      final mf = decodeBallFileJson(encodeBallFileJson(_module('jm')));
      expect(mf, isA<BallModuleFile>());
    });
  });

  group('typed decoders enforce the wrapped type', () {
    test('decodeProgramJson on a Module throws', () {
      final moduleJson = encodeBallFileJson(_module('m'));
      expect(
        () => decodeProgramJson(moduleJson),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('expected a Program'),
          ),
        ),
      );
    });

    test('decodeModuleJson on a Program throws', () {
      final programJson = encodeBallFileJson(_program('p'));
      expect(
        () => decodeModuleJson(programJson),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('expected a Module'),
          ),
        ),
      );
    });

    test('decodeProgramBinary on a Module throws', () {
      final bytes = encodeBallFileBinary(_module('m'));
      expect(
        () => decodeProgramBinary(bytes),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('expected a Program'),
          ),
        ),
      );
    });

    test('decodeModuleBinary on a Program throws', () {
      final bytes = encodeBallFileBinary(_program('p'));
      expect(
        () => decodeModuleBinary(bytes),
        throwsA(
          isA<BallFileFormatException>().having(
            (e) => e.message,
            'm',
            contains('expected a Module'),
          ),
        ),
      );
    });

    test('the matching typed decoders succeed', () {
      expect(decodeProgramJson(encodeBallFileJson(_program('p'))).name, 'p');
      expect(decodeModuleJson(encodeBallFileJson(_module('m'))).name, 'm');
      expect(
        decodeProgramBinary(encodeBallFileBinary(_program('pb'))).name,
        'pb',
      );
      expect(
        decodeModuleBinary(encodeBallFileBinary(_module('mb'))).name,
        'mb',
      );
    });
  });

  group('encode rejects a non-top-level message', () {
    test('encodeBallFileBinary throws on a non-Program/Module message', () {
      // FunctionDefinition is not a top-level ball-file type.
      final fn = FunctionDefinition()..name = 'f';
      expect(() => encodeBallFileBinary(fn), throwsA(isA<ArgumentError>()));
    });

    test('encodeBallFileJson throws on a non-Program/Module message', () {
      final fn = FunctionDefinition()..name = 'f';
      expect(() => encodeBallFileJson(fn), throwsA(isA<ArgumentError>()));
    });
  });

  group('type URL constants', () {
    test('expose the canonical Program/Module type URLs', () {
      expect(programTypeUrl, 'type.googleapis.com/ball.v1.Program');
      expect(moduleTypeUrl, 'type.googleapis.com/ball.v1.Module');
    });
  });
}
