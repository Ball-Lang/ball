# ball_compiler

Ball -> Dart compiler for the [Ball programming language](https://ball-lang.dev).

`ball_compiler` translates a Ball `Program` into formatted, idiomatic Dart source code. It builds a structural AST with `package:code_builder` and runs the result through `package:dart_style`, so the output is ready to drop into a pub package.

## Install

```
dart pub add ball_compiler
```

## Quick start

```dart
import 'package:ball_base/ball_base.dart';
import 'package:ball_compiler/compiler.dart';

void main() {
  final program = Program(); // load from .ball.json or build in-memory
  final dartSource = DartCompiler(program).compile();
  print(dartSource);
}
```

## Features

| Feature | Notes |
|---------|-------|
| Whole-program compilation | Each Ball `Module` becomes a Dart library |
| Base-function dispatch | `std.add` -> `a + b`, `std.if` -> Dart `if`, ... |
| Type emission | Reads `typeDefs[]` (preferred) or legacy `types[]` |
| Lazy control flow | `if`, `for`, `while`, `try`, `switch` emitted as real Dart statements |
| Import resolution | `DartCompiler.resolveImports(program, resolver)` inlines imports before compile |
| Raw output mode | `DartCompiler(program, noFormat: true)` skips `dart_style` |
| Metadata preservation | Round-trips encoder metadata (param names, class modifiers, conditional imports) |

## Resolving imports first

Compilers need full type and function signatures up front, so imports must be resolved before `compile()`:

```dart
import 'package:ball_compiler/compiler.dart';
import 'package:ball_resolver/ball_resolver.dart';

Future<String> compile(Program program) async {
  final resolved = await DartCompiler.resolveImports(program, ModuleResolver());
  return DartCompiler(resolved).compile();
}
```

## Design notes

- Expression bodies are emitted as Dart source strings and wrapped in `cb.Code` nodes. `code_builder` handles structural layout; `dart_style` handles indentation.
- Control-flow base functions (`std.if`, `std.for`, ...) are evaluated lazily -- the compiler extracts the `Expression` operands from the `MessageCreation` input and emits real Dart statements instead of eagerly calling helper functions.
- Use `noFormat: true` if your input contains pathologically deep expressions that confuse the formatter.

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
