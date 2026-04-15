---
name: ball-engine
description: >
  Build, modify, debug, or extend a Ball runtime engine/interpreter. USE FOR: implementing base
  function execution, fixing runtime behavior, adding control flow interpretation, debugging
  scope/variable issues, or creating a new target language engine. DO NOT USE FOR: compiler/code
  generation work, encoder/parser work, or proto schema changes. The Dart engine is the reference
  implementation.
---

# Ball Engine Skill

## What is a Ball Engine?

A Ball engine interprets and executes Ball programs directly at runtime, without generating source code. The Dart engine (`dart/engine/lib/engine.dart`) is the reference implementation.

## Architecture

```
Program (protobuf)
  → Build lookup tables (types, functions by name)
  → Register module handlers (std, dart_std, custom)
  → Create root scope
  → Find entry function (entryModule.entryFunction)
  → Evaluate entry function body
  → Return captured output
```

## Expression Evaluation

| Expression | Evaluation Strategy |
|------------|-------------------|
| `literal` | Return native value directly |
| `reference` | Look up variable in scope chain |
| `fieldAccess` | Evaluate object, extract field (support virtual properties) |
| `messageCreation` | Evaluate all field values, return as map |
| `call` (user function) | Create new scope, bind input, evaluate body |
| `call` (base function) | Dispatch to module handler |
| `block` | Create child scope, evaluate statements sequentially, return result |
| `lambda` | Capture current scope, return callable |

## Scope Management

- Lexical scoping via linked chain: `Scope { bindings, parent? }`
- `lookup(name)` — walk up parent chain until found
- `bind(name, value)` — add to current scope
- `set(name, value)` — find existing binding and update (anywhere in chain)
- `"input"` — always bound to function parameter in function scope

## Control Flow — Lazy Evaluation

These base functions must NOT eagerly evaluate all input fields:

| Function | Strategy |
|----------|----------|
| `if` | Eval condition → eval then OR else (not both) |
| `for` | Eval init → loop: eval condition → eval body → eval update |
| `while` | Loop: eval condition → eval body |
| `and` | Eval left → if false, return false (don't eval right) |
| `or` | Eval left → if true, return true (don't eval right) |
| `switch` | Eval value → match against cases → eval matched body |
| `try` | Eval body → on exception, eval catch → always eval finally |

## Flow Signals

Break/continue/return propagate as special signal objects:

```
FlowSignal { kind: "break"|"continue"|"return", label?: string, value?: any }
```

- `return` — unwind to nearest function boundary, carry return value
- `break` — unwind to nearest loop (or labeled statement)
- `continue` — skip to loop update/condition

## Virtual Properties

Built-in properties on native types (no base function call needed):

| Type | Properties |
|------|-----------|
| String | `length`, `isEmpty`, `isNotEmpty` |
| List | `length`, `isEmpty`, `isNotEmpty`, `first`, `last`, `single`, `reversed` |
| Map | `length`, `isEmpty`, `isNotEmpty`, `keys`, `values`, `entries` |
| double/num | `isNaN`, `isFinite`, `isInfinite`, `isNegative`, `sign`, `abs` |
| All | `runtimeType` |

## Custom Module Handlers

Extend the engine with custom base modules:

```dart
class MyHandler extends BallModuleHandler {
  String get moduleName => 'my_module';
  BallValue call(String function, BallValue input, BallCallable callable) {
    switch (function) {
      case 'my_func': return doSomething(input);
      default: throw 'Unknown function: $function';
    }
  }
}
```

## Testing Pattern

```dart
final program = buildProgram(
  name: 'test',
  functions: [mainFunc(body: printCall('Hello'))],
);
final output = runAndCapture(program);
expect(output, ['Hello']);
```

## Common Mistakes

1. Evaluating control flow eagerly (see lazy evaluation section)
2. Not propagating FlowSignals through nested expressions
3. Forgetting to create child scopes for blocks and function calls
4. Not handling `"input"` reference specially
5. Not supporting virtual properties on built-in types
