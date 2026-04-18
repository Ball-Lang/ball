# ball_base

Core protobuf types and std module builders for the [Ball programming language](https://ball-lang.dev).

`ball_base` is the foundation package that every Ball tool depends on. It re-exports the generated protobuf types defined in `proto/ball/v1/ball.proto` and provides canonical builders for the universal standard library modules (`std`, `std_collections`, `std_io`, `std_memory`).

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
| `buildStdModule()` | Universal `std` module (arithmetic, logic, control flow, ~73 base fns) |
| `buildStdCollectionsModule()` | `std_collections` (~43 list/map fns) |
| `buildStdIoModule()` | `std_io` (~10 console/process/time fns) |
| `buildStdMemoryModule()` | `std_memory` (~30 linear-memory fns for C/C++ interop) |
| `analyzeCapabilities`, `checkPolicy` | Static capability analysis over a `Program` |

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
