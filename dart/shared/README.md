# ball_base

Core protobuf types and std module builders for the [Ball programming language](https://ball-lang.dev).

`ball_base` is the foundation package that every Ball tool depends on. It exposes the generated protobuf types defined in `proto/ball/v1/ball.proto`, canonical builders for the standard-library modules (`std`, `std_collections`, `std_io`, `std_memory`, `std_concurrency`, `std_convert`, `std_fs`, `std_time`), and re-exports the Editions-capable protobuf runtime from [`ball_protobuf`](https://pub.dev/packages/ball_protobuf) (which was extracted into its own package).

## Install

```
dart pub add ball_base
```

## Quick start

```dart
import 'package:ball_base/ball_base.dart';

void main() {
  // Build a Program that imports the universal std module.
  final program = Program()
    ..modules.addAll([buildStdModule(), buildStdCollectionsModule()]);

  print('Modules: ${program.modules.map((m) => m.name).join(', ')}');
}
```

## What's exported

| Export | Purpose |
|--------|---------|
| `Program`, `Module`, `Expression`, `FunctionDefinition`, `Literal`, ... | Buf-generated `ball.v1` proto types |
| `DescriptorProto`, `FieldDescriptorProto` | Re-exported `google.protobuf` descriptor types |
| `buildStdModule()` | Universal `std` module (arithmetic, comparison, logic, bitwise, strings, math, control flow, type ops) |
| `buildStdCollectionsModule()`, `buildStdMemoryModule()` | `std_collections` (list/map) and `std_memory` (linear memory for C/C++ interop) |
| `buildStdIoModule()`, `buildStdConcurrencyModule()`, `buildStdConvertModule()`, `buildStdFsModule()`, `buildStdTimeModule()` | The platform std modules: io, concurrency, convert, fs, time |
| `buildBallProtoModule()` | The `ball_proto` module |
| `marshal`, `unmarshal`, Editions resolver, … | Re-exported from [`ball_protobuf`](https://pub.dev/packages/ball_protobuf) |
| `BallFile`, `decodeBallFileBinary`, `encodeBallFileJson`, … | Read/write `.ball.json` / `.ball.bin` (Any-enveloped `Program`/`Module`) |
| `analyzeCapabilities`, `checkPolicy`, `analyzeTermination` | Static capability + termination analysis over modules |

## Design notes

- Every Ball program is a single protobuf message. This package provides the types needed to read, write, and transform those messages.
- The std module builders are language-agnostic: the same proto definition is shared by every target compiler and engine (Dart, C++, and more).
- All generated files under `lib/gen/**` are produced by `buf generate`. Do not edit them by hand.

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
