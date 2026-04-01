# Dart Implementation Agents

When working in the Dart packages:

## Testing

- Tests live in `dart/engine/test/engine_test.dart`
- Run with: `cd dart/engine && dart test`
- Use `buildProgram()` to create test programs inline
- Use `runAndCapture()` to execute and verify output
- Use `loadProgram()` for .ball.json file tests

## Package Dependencies

All packages use workspace resolution. Run `dart pub get` from `dart/` root.

## Generated Files

NEVER edit files in:
- `dart/shared/lib/gen/` — protobuf generated
- `dart/shared/std.json` — run `dart run bin/gen_std.dart` in `dart/shared/`
- `dart/shared/std.bin` — generated alongside std.json

## Code Style

- Dart 3.9+ features (records, patterns, sealed classes are fine)
- Follow `lints` package rules
- No unnecessary null-safety annotations on non-nullable types
