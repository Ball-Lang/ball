# Conformance Test Suite

Cross-language test suite for Ball implementations. Each test is a `.ball.json` program with a matching `.expected_output.txt` file containing the exact expected stdout.

## Running Tests

### Dart Engine

```bash
cd dart/engine
dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance
```

### C++ Engine

```bash
cd cpp/build
for f in ../../tests/conformance/*.ball.json; do
  name=$(basename "$f" .ball.json)
  expected="../../tests/conformance/${name}.expected_output.txt"
  actual=$(./engine/ball_cpp_runner "$f")
  if [ "$actual" = "$(cat "$expected")" ]; then
    echo "  PASS $name"
  else
    echo "  FAIL $name"
  fi
done
```

## Test Programs

| # | Test | Feature |
|---|------|---------|
| 01 | hello_world | Print string literal |
| 02 | arithmetic | `add`, `multiply` (2 + 3*4 = 14) |
| 03 | string_concat | `string_concat` chaining |
| 04 | boolean_logic | `and`, `or`, `not` |
| 05 | variables | Let bindings, variable references |
| 06 | if_else | `if` with condition, then, else |
| 07 | while_loop | `while` loop with mutation |
| 08 | for_loop | `for` loop with increment |
| 09 | function_call | User-defined function (square) |
| 10 | fibonacci | Recursive fibonacci(10) = 55 |
| 11 | nested_if | Nested if-else |
| 12 | string_length | `string_length` |
| 13 | comparison_ops | `equals`, `not_equals`, `less_than`, `gte` |
| 14 | modulo | `modulo` for even/odd check |
| 15 | multiple_functions | Composing user functions |
| 16 | block_scope | Block expressions with scoping |
| 17 | recursion_sum | Recursive sum(1..10) = 55 |
| 18 | double_math | Double-precision arithmetic |
| 19 | string_substring | `string_substring` extraction |
| 20 | nested_loops | Nested for loops (multiplication table) |

## Adding a New Test

1. Create `NN_name.ball.json` with the Ball program
2. Create `NN_name.expected_output.txt` with exact expected stdout (include trailing newline)
3. Add to the table above
