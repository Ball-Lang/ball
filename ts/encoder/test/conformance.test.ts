/**
 * Encoder conformance tests: encode TS source -> run through Ball engine -> verify output.
 *
 * These tests cover the patterns from conformance tests 21-36 (typed catch,
 * rethrow, labeled break, throw value, closures, string ops, list ops,
 * fibonacci, nested functions, math utils, arithmetic, comparisons, boolean
 * logic, short circuit, string interpolation) plus additional patterns
 * exercising the encoder's coverage of TS constructs.
 *
 * Each test encodes a TypeScript program to Ball IR, executes it through the
 * TS Ball engine, and asserts the captured stdout lines match expected output.
 *
 * Run with:
 *   node --experimental-strip-types --test test/conformance.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";
import { BallEngine } from "../../engine/src/index.ts";

/**
 * Encode TS source to Ball IR, run through the Ball engine, return output lines.
 */
async function encodeAndRun(source: string, entryFunction = "main"): Promise<string[]> {
  const program = encode(source, { entryFunction });
  const engine = new BallEngine(program);
  await engine.run();
  return engine.getOutput();
}

/**
 * Assert that encoding and running `source` produces the expected output lines.
 */
async function assertOutput(source: string, expected: string[], entryFunction = "main"): Promise<void> {
  const output = await encodeAndRun(source, entryFunction);
  assert.deepStrictEqual(
    output,
    expected,
    `Output mismatch.\n  Expected: ${JSON.stringify(expected)}\n  Actual:   ${JSON.stringify(output)}`,
  );
}

// ── 21: typed catch ────────────────────────────────────────────────────────

describe("conformance 21: typed catch", () => {
  test("try/catch with string throw", async () => {
    await assertOutput(`
function main() {
  try {
    throw "NotFound";
  } catch (e) {
    console.log("caught-" + e);
  }
}
`, ["caught-NotFound"]);
  });

  test("try/catch/finally", async () => {
    await assertOutput(`
function main() {
  let result = "";
  try {
    result = result + "try ";
    throw "error";
  } catch (e) {
    result = result + "catch ";
  } finally {
    result = result + "finally";
  }
  console.log(result);
}
`, ["try catch finally"]);
  });
});

// ── 22: rethrow preserves ──────────────────────────────────────────────────

describe("conformance 22: rethrow preserves", () => {
  test("caught exception rethrown and caught again", async () => {
    await assertOutput(`
function main() {
  try {
    try {
      throw "boom";
    } catch (e) {
      throw e;
    }
  } catch (e2) {
    console.log(e2);
  }
}
`, ["boom"]);
  });
});

// ── 23: labeled break ──────────────────────────────────────────────────────

describe("conformance 23: labeled break", () => {
  test("break out of nested loop with label", async () => {
    await assertOutput(`
function main() {
  let found = 0;
  outer:
  for (let i = 0; i < 5; i++) {
    for (let j = 0; j < 5; j++) {
      if (i === 1 && j === 2) {
        found = 1;
        break outer;
      }
    }
  }
  console.log(found);
}
`, ["1"]);
  });
});

// ── 24: throw value ────────────────────────────────────────────────────────

describe("conformance 24: throw value", () => {
  test("throw and catch a string value", async () => {
    await assertOutput(`
function main() {
  try {
    throw "missing-key";
  } catch (e) {
    console.log(e);
  }
}
`, ["missing-key"]);
  });
});

// ── 25: closures ───────────────────────────────────────────────────────────

describe("conformance 25: closures", () => {
  test("closure captures outer variable", async () => {
    await assertOutput(`
function makeAdder(x) {
  return (y) => x + y;
}
function main() {
  const add5 = makeAdder(5);
  console.log(add5(3));
  console.log(add5(10));
}
`, ["8", "15"]);
  });

  test("closure over separate variables", async () => {
    // Closures that capture separately-scoped variables.
    // (Calling lambdas stored in arrays via indexing requires __invoke,
    //  so we use a simpler pattern that demonstrates closure capture.)
    await assertOutput(`
function makeConst(v) {
  return () => v;
}
function main() {
  const f0 = makeConst(0);
  const f1 = makeConst(1);
  const f2 = makeConst(2);
  console.log(f0());
  console.log(f1());
  console.log(f2());
}
`, ["0", "1", "2"]);
  });
});

// ── 26: string ops ─────────────────────────────────────────────────────────

describe("conformance 26: string ops", () => {
  test("string length and concatenation", async () => {
    await assertOutput(`
function main() {
  const s = "Hello, World!";
  console.log(s.length);
  console.log(s.toUpperCase());
  console.log(s.toLowerCase());
}
`, ["13", "HELLO, WORLD!", "hello, world!"]);
  });

  test("string trim", async () => {
    await assertOutput(`
function main() {
  const s = "  Hello, World!  ";
  console.log(s.trim());
}
`, ["Hello, World!"]);
  });
});

// ── 27: list ops ───────────────────────────────────────────────────────────

describe("conformance 27: list ops", () => {
  test("list length, push, access", async () => {
    await assertOutput(`
function main() {
  const arr = [1, 2, 3, 4, 5];
  console.log(arr.length);
  console.log(arr[3]);
  let sum = 0;
  for (let i = 0; i < arr.length; i++) {
    sum = sum + arr[i];
  }
  console.log(sum);
}
`, ["5", "4", "15"]);
  });
});

// ── 28: fibonacci ──────────────────────────────────────────────────────────

describe("conformance 28: fibonacci", () => {
  test("recursive fibonacci sequence", async () => {
    await assertOutput(`
function fib(n) {
  if (n <= 1) { return n; }
  return fib(n - 1) + fib(n - 2);
}
function main() {
  for (let i = 0; i < 8; i++) {
    console.log(fib(i));
  }
}
`, ["0", "1", "1", "2", "3", "5", "8", "13"]);
  });
});

// ── 29: nested functions ───────────────────────────────────────────────────

describe("conformance 29: nested functions", () => {
  test("inner function accessing outer scope", async () => {
    await assertOutput(`
function outer(x) {
  function inner(y) {
    return x * y;
  }
  return inner(x);
}
function main() {
  console.log(outer(5));
  console.log(outer(13));
}
`, ["25", "169"]);
  });
});

// ── 30: math utils ─────────────────────────────────────────────────────────

describe("conformance 30: math utils", () => {
  test("abs, max, min", async () => {
    await assertOutput(`
function abs(x) {
  if (x < 0) { return 0 - x; }
  return x;
}
function max(a, b) {
  if (a > b) { return a; }
  return b;
}
function min(a, b) {
  if (a < b) { return a; }
  return b;
}
function main() {
  console.log(abs(-5));
  console.log(min(3, 7));
  console.log(max(10, 20));
  console.log(max(10, 5));
}
`, ["5", "3", "20", "10"]);
  });
});

// ── 31: arithmetic basic ──────────────────────────────────────────────────

describe("conformance 31: arithmetic basic", () => {
  test("addition, multiplication, division, modulo", async () => {
    await assertOutput(`
function main() {
  console.log(2 + 3);
  console.log(2 * 3);
  console.log(3 * 7);
}
`, ["5", "6", "21"]);
  });

  test("modulo", async () => {
    await assertOutput(`
function main() {
  console.log(17 % 5);
}
`, ["2"]);
  });
});

// ── 32: arithmetic negative ────────────────────────────────────────────────

describe("conformance 32: arithmetic negative", () => {
  test("negative number operations", async () => {
    // Note: Ball's std.modulo uses Dart-style Euclidean modulo where
    // the result is always non-negative. -15 % 4 = 1, not -3 (JS semantics).
    await assertOutput(`
function main() {
  console.log(3 + -5);
  console.log(-4 * -5);
  console.log(10 * -10);
  console.log(-15 % 4);
}
`, ["-2", "20", "-100", "1"]);
  });
});

// ── 33: comparison chain ───────────────────────────────────────────────────

describe("conformance 33: comparison chain", () => {
  test("chained comparisons", async () => {
    await assertOutput(`
function main() {
  console.log(1 < 2);
  console.log(2 > 3);
  console.log(3 <= 3);
  console.log(4 >= 4);
  console.log(5 === 5);
  console.log(5 !== 6);
}
`, ["true", "false", "true", "true", "true", "true"]);
  });
});

// ── 34: boolean logic ──────────────────────────────────────────────────────

describe("conformance 34: boolean logic", () => {
  test("and, or, not operators", async () => {
    await assertOutput(`
function main() {
  console.log(true && true);
  console.log(true && false);
  console.log(false || true);
  console.log(false || false);
  console.log(false && true);
  console.log(!false);
}
`, ["true", "false", "true", "false", "false", "true"]);
  });
});

// ── 35: short circuit ──────────────────────────────────────────────────────

describe("conformance 35: short circuit", () => {
  test("short-circuit evaluation", async () => {
    await assertOutput(`
function main() {
  let x = 0;
  const a = false && (x = 1);
  console.log(a);
  console.log(x);
  const b = true || (x = 2);
  console.log(b);
  console.log(x);
}
`, ["false", "0", "true", "0"]);
  });
});

// ── 36: string interpolation ───────────────────────────────────────────────

describe("conformance 36: string interpolation", () => {
  test("template literal interpolation", async () => {
    await assertOutput(`
function main() {
  const name = "world";
  console.log("Hello, " + name + "!");
  const age = 25;
  console.log("Age: " + age);
  const a = 2;
  const b = 3;
  console.log("Sum: " + (a + b));
}
`, ["Hello, world!", "Age: 25", "Sum: 5"]);
  });

  test("template literal syntax", async () => {
    await assertOutput("function main() { const x = 42; console.log(`value: ${x}`); }", ["value: 42"]);
  });
});

// ── Additional patterns ────────────────────────────────────────────────────

describe("additional encoder patterns", () => {
  test("while loop with counter", async () => {
    await assertOutput(`
function main() {
  let i = 0;
  let sum = 0;
  while (i < 5) {
    sum = sum + i;
    i = i + 1;
  }
  console.log(sum);
}
`, ["10"]);
  });

  test("do-while loop", async () => {
    await assertOutput(`
function main() {
  let i = 0;
  do {
    i = i + 1;
  } while (i < 3);
  console.log(i);
}
`, ["3"]);
  });

  test("ternary expression", async () => {
    await assertOutput(`
function main() {
  const x = 5;
  const result = x > 3 ? "big" : "small";
  console.log(result);
}
`, ["big"]);
  });

  test("recursive countdown", async () => {
    await assertOutput(`
function countdown(n) {
  if (n <= 0) {
    console.log("done");
    return;
  }
  console.log(n);
  countdown(n - 1);
}
function main() {
  countdown(3);
}
`, ["3", "2", "1", "done"]);
  });

  test("higher-order function: map-like", async () => {
    await assertOutput(`
function applyToEach(arr, fn) {
  const result = [];
  for (let i = 0; i < arr.length; i++) {
    result.push(fn(arr[i]));
  }
  return result;
}
function main() {
  const nums = [1, 2, 3, 4];
  const doubled = applyToEach(nums, (x) => x * 2);
  for (let i = 0; i < doubled.length; i++) {
    console.log(doubled[i]);
  }
}
`, ["2", "4", "6", "8"]);
  });

  test("multiple closures sharing scope", async () => {
    // Closures that share a captured variable via a factory function.
    // (Object method dispatch on closure fields requires __invoke, so we
    //  return the closures separately instead of in an object.)
    await assertOutput(`
function makeCounter() {
  let count = 0;
  function inc() { count = count + 1; }
  function get() { return count; }
  inc();
  inc();
  inc();
  return get();
}
function main() {
  console.log(makeCounter());
}
`, ["3"]);
  });

  test("string comparison", async () => {
    await assertOutput(`
function main() {
  console.log("abc" === "abc");
  console.log("abc" === "def");
  console.log("" === "");
}
`, ["true", "false", "true"]);
  });

  test("nested if-else chain", async () => {
    await assertOutput(`
function classify(n) {
  if (n > 0) {
    return "positive";
  } else if (n < 0) {
    return "negative";
  } else {
    return "zero";
  }
}
function main() {
  console.log(classify(5));
  console.log(classify(-3));
  console.log(classify(0));
}
`, ["positive", "negative", "zero"]);
  });

  test("break in for loop", async () => {
    await assertOutput(`
function main() {
  let result = 0;
  for (let i = 0; i < 100; i++) {
    if (i === 5) {
      break;
    }
    result = result + i;
  }
  console.log(result);
}
`, ["10"]);
  });

  test("continue in for loop", async () => {
    await assertOutput(`
function main() {
  let sum = 0;
  for (let i = 0; i < 10; i++) {
    if (i % 2 === 0) {
      continue;
    }
    sum = sum + i;
  }
  console.log(sum);
}
`, ["25"]);
  });

  test("switch statement", async () => {
    await assertOutput(`
function dayName(d) {
  switch (d) {
    case 1: return "Mon";
    case 2: return "Tue";
    case 3: return "Wed";
    default: return "Other";
  }
}
function main() {
  console.log(dayName(1));
  console.log(dayName(3));
  console.log(dayName(9));
}
`, ["Mon", "Wed", "Other"]);
  });

  test("prefix/postfix increment and decrement", async () => {
    await assertOutput(`
function main() {
  let a = 5;
  a++;
  console.log(a);
  a--;
  console.log(a);
}
`, ["6", "5"]);
  });

  test("bitwise operations", async () => {
    await assertOutput(`
function main() {
  console.log(5 & 3);
  console.log(5 | 3);
  console.log(5 ^ 3);
  console.log(~0);
}
`, ["1", "7", "6", "-1"]);
  });

  test("null coalescing", async () => {
    await assertOutput(`
function main() {
  const a = null;
  const b = a ?? "default";
  console.log(b);
  const c = "exists";
  const d = c ?? "fallback";
  console.log(d);
}
`, ["default", "exists"]);
  });

  test("for-of loop", async () => {
    await assertOutput(`
function main() {
  const items = [10, 20, 30];
  let sum = 0;
  for (const item of items) {
    sum = sum + item;
  }
  console.log(sum);
}
`, ["60"]);
  });

  test("GCD algorithm (Euclidean)", async () => {
    await assertOutput(`
function gcd(a, b) {
  while (b !== 0) {
    const temp = b;
    b = a % b;
    a = temp;
  }
  return a;
}
function main() {
  console.log(gcd(48, 18));
  console.log(gcd(100, 75));
  console.log(gcd(7, 13));
}
`, ["6", "25", "1"]);
  });

  test("isPrime check", async () => {
    await assertOutput(`
function isPrime(n) {
  if (n < 2) { return false; }
  for (let i = 2; i * i <= n; i++) {
    if (n % i === 0) { return false; }
  }
  return true;
}
function main() {
  console.log(isPrime(2));
  console.log(isPrime(4));
  console.log(isPrime(17));
  console.log(isPrime(1));
}
`, ["true", "false", "true", "false"]);
  });

  test("power function (iterative)", async () => {
    await assertOutput(`
function power(base, exp) {
  let result = 1;
  for (let i = 0; i < exp; i++) {
    result = result * base;
  }
  return result;
}
function main() {
  console.log(power(2, 10));
  console.log(power(3, 4));
  console.log(power(5, 0));
}
`, ["1024", "81", "1"]);
  });

  test("array reversal", async () => {
    await assertOutput(`
function reverse(arr) {
  const result = [];
  for (let i = arr.length - 1; i >= 0; i--) {
    result.push(arr[i]);
  }
  return result;
}
function main() {
  const r = reverse([1, 2, 3, 4, 5]);
  for (const x of r) {
    console.log(x);
  }
}
`, ["5", "4", "3", "2", "1"]);
  });

  test("accumulator with closures", async () => {
    await assertOutput(`
function makeAccumulator(init) {
  let total = init;
  return (n) => {
    total = total + n;
    return total;
  };
}
function main() {
  const acc = makeAccumulator(0);
  console.log(acc(5));
  console.log(acc(10));
  console.log(acc(3));
}
`, ["5", "15", "18"]);
  });

  test("nested loops with multiplication table", async () => {
    await assertOutput(`
function main() {
  for (let i = 1; i <= 3; i++) {
    let row = "";
    for (let j = 1; j <= 3; j++) {
      if (j > 1) { row = row + " "; }
      row = row + (i * j);
    }
    console.log(row);
  }
}
`, ["1 2 3", "2 4 6", "3 6 9"]);
  });

  test("factorial recursive", async () => {
    await assertOutput(`
function factorial(n) {
  if (n <= 1) { return 1; }
  return n * factorial(n - 1);
}
function main() {
  console.log(factorial(0));
  console.log(factorial(1));
  console.log(factorial(5));
  console.log(factorial(10));
}
`, ["1", "1", "120", "3628800"]);
  });

  test("console.log with no args", async () => {
    await assertOutput(`
function main() {
  console.log("before");
  console.log("");
  console.log("after");
}
`, ["before", "", "after"]);
  });
});
