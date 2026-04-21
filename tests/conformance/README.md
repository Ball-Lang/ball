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
| 21 | typed_catch | Try/catch with typed exception matching |
| 22 | rethrow_preserves | Rethrow preserves original exception |
| 23 | labeled_break | Break out of labeled nested loops |
| 24 | throw_value | Throw and catch arbitrary values |
| 25 | closures | Closure captures enclosing scope |
| 26 | string_ops | String operations (concat, length, compare) |
| 27 | list_ops | List operations (create, access, iterate) |
| 28 | fibonacci | Iterative fibonacci with for loop |
| 29 | nested_functions | Functions calling functions |
| 30 | math_utils | Math utility functions (abs, max, min) |
| 31 | arithmetic_basic | Basic arithmetic: add, subtract, multiply, divide, modulo |
| 32 | arithmetic_negative | Arithmetic with negative numbers |
| 33 | comparison_chain | All comparison operators (<, >, <=, >=, ==, !=) |
| 34 | boolean_logic | Boolean AND, OR, NOT combinations |
| 35 | short_circuit | Short-circuit evaluation of && and \|\| |
| 36 | string_interpolation | String interpolation with variables and expressions |
| 37 | string_concat | String concatenation via interpolation |
| 38 | string_length | String length property |
| 39 | compound_assign | Compound assignment operators (+=, -=, *=, ~/=, %=) |
| 40 | increment_decrement | Pre/post increment and decrement |
| 41 | for_sum | For loop summing 1 to 100 |
| 42 | nested_functions | Multiple user-defined functions composed |
| 43 | countdown | While loop countdown by 2 |
| 44 | for_loop_basic | Basic for loop 0 to 4 |
| 45 | for_in_loop | For-in loop over list |
| 46 | while_loop | While loop 1 to 5 |
| 47 | do_while | Do-while countdown from 5 |
| 48 | break_continue | Break and continue in for loop |
| 49 | nested_loops | Nested for loops (multiplication table 3x3) |
| 50 | if_else_chain | If/else-if/else chain |
| 51 | nested_if | Nested if statements |
| 52 | max_of_three | Function finding max of three values |
| 53 | try_catch_finally | Try/catch/finally with string throw |
| 54 | abs_value | Absolute value function |
| 55 | scope_variable | Block scoping and variable shadowing |
| 56 | closure_capture | Closure capturing and mutating variable |
| 57 | recursion_factorial | Recursive factorial |
| 58 | mutual_recursion | Mutually recursive isEven/isOdd |
| 59 | deep_recursion | Deep recursion sum(100) |
| 60 | collatz | Collatz conjecture step counting |
| 61 | bitwise_ops | Bitwise AND, OR, XOR, NOT, shifts |
| 62 | ternary | Ternary conditional expressions |
| 63 | is_prime | Primality test with trial division |
| 64 | multiple_functions | Composing square, cube, add |
| 65 | higher_order | Higher-order functions (passing lambdas) |
| 66 | digit_sum | Sum digits of a number |
| 67 | reverse_number | Reverse digits of a number |
| 68 | triangle_pattern | Print triangle pattern with nested loops |
| 69 | early_return | Early return from function |
| 70 | accumulator | Accumulator pattern in for loop |
| 71 | fizzbuzz | FizzBuzz 1 to 15 |
| 72 | gcd | Euclidean GCD algorithm |
| 73 | power | Iterative exponentiation |
| 74 | fibonacci_sequence | Fibonacci sequence (first 10 terms) |
| 75 | sum_of_squares | Sum of squares and cubes |

## Adding a New Test

1. Write a Dart source in `src/NN_name.dart` (use only std-compatible features)
2. Run `cd dart/encoder && dart run bin/generate_conformance.dart` to generate `.ball.json` and `.expected_output.txt`
3. Verify with `cd dart/engine && dart test test/conformance_test.dart`
4. Add to the table above
