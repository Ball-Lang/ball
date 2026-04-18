# ball_engine

Tree-walking interpreter for the [Ball programming language](https://ball-lang.dev).

`ball_engine` executes Ball programs directly -- no intermediate code generation. It walks the protobuf expression tree, evaluates each node, and dispatches `std` base functions through a pluggable module-handler system. Every evaluator is `async`, so I/O, timers, and user-defined `await` all suspend through Dart's native `Future` mechanism.

## Install

```
dart pub add ball_engine
```

## Quick start

```dart
import 'package:ball_base/ball_base.dart';
import 'package:ball_engine/engine.dart';

Future<void> main() async {
  final program = Program(); // load from .ball.json or build in-memory
  final engine = BallEngine(program, stdout: (line) => print(line));
  await engine.run();
}
```

## Features

| Feature | Status |
|---------|--------|
| All 73 `std` base functions | Supported |
| `std_collections`, `std_io`, `std_memory`, `dart_std` | Supported |
| Lexical scoping, closures, lambdas | Supported |
| Object-oriented dispatch (getters, setters, operator overloading) | Supported |
| Native `async` / `await` via Dart `Future` | Supported |
| Lazy control flow (`if`, `for`, `while`, `try`, `switch`) | Supported |
| Custom module handlers via `BallModuleHandler` | Supported |
| Lazy import resolution via injected `ModuleResolver` | Supported |

## Constructor options

```dart
BallEngine(
  program,
  stdout: (line) { /* capture output */ },
  stderr: (line) { /* capture errors */ },
  stdinReader: () async => await readLine(),
  args: ['--flag', 'value'],
  moduleHandlers: [StdModuleHandler(), MyCustomHandler()],
  resolver: ModuleResolver(),
  enableProfiling: true,
);
```

## Custom modules

Implement `BallModuleHandler` to expose your own base functions to Ball code:

```dart
class TimeHandler extends BallModuleHandler {
  @override
  String get moduleName => 'time';

  @override
  Future<BallValue> call(String fn, BallValue input, BallCallable engineCall) async {
    if (fn == 'now') return DateTime.now().millisecondsSinceEpoch;
    throw UnimplementedError('time.$fn');
  }
}
```

## Related packages

- [`@ball-lang/engine`](https://www.npmjs.com/package/@ball-lang/engine) -- TypeScript/JavaScript engine (experimental)

## Links

- Website: https://ball-lang.dev
- Repository: https://github.com/ball-lang/ball
- Issue tracker: https://github.com/ball-lang/ball/issues

## License

MIT
