# ball_encoder

Dart -> Ball encoder for the [Ball programming language](https://ball-lang.dev).

`ball_encoder` translates any valid Dart source file -- or an entire Dart package with all of its transitive pub dependencies -- into a Ball `Program` message. It uses the official `package:analyzer` parser, so every Dart construct (classes, mixins, records, patterns, extensions, null-aware operators, cascades) is preserved.

## Install

```
dart pub add ball_encoder
```

## Quick start

```dart
import 'package:ball_encoder/encoder.dart';

void main() {
  final dart = '''
    int add(int a, int b) => a + b;
    void main() => print(add(2, 3));
  ''';

  final program = DartEncoder().encode(dart, name: 'my_app');
  print('Encoded ${program.modules.length} module(s)');
}
```

## Encoding a whole package

```dart
import 'dart:io';
import 'package:ball_encoder/package_encoder.dart';

Future<void> main() async {
  final encoder = PackageEncoder(
    Directory('/path/to/my_package'),
    resolveExternalDeps: true, // download transitive deps from pub
  );
  final program = await encoder.encodeAsync();
  print('Encoded package with ${program.modules.length} modules');
}
```

## Mapping summary

| Dart construct | Ball target |
|----------------|-------------|
| Operators (`+`, `&`, `??`, ...) | `std.add`, `std.bitwise_and`, `std.null_coalesce`, ... |
| Control flow (`if`, `for`, `while`, `try`, `switch`) | `std.if`, `std.for`, ... (lazy base functions) |
| Type ops (`is`, `as`, `!`) | `std.is`, `std.as`, `std.null_check` |
| Cascade, spread, null-aware, invoke, record | `dart_std.*` |
| Classes | `DescriptorProto` + method `FunctionDefinition`s |
| Lambdas / closures | Anonymous `FunctionDefinition` |

## Modes

- **Permissive (default)**: malformed metadata is collected in `encoder.warnings`.
- **Strict**: `DartEncoder(strict: true)` throws `EncoderError` on any encoding problem.

Language-specific metadata (import URIs, class modifiers, import show/hide lists) is preserved inside `google.protobuf.Struct metadata` fields so that `encode -> compile` round-trips produce byte-identical Dart output where possible.

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
