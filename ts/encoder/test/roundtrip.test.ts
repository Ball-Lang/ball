/**
 * Round-trip tests: TS source -> encode() -> Ball IR -> compile() -> TS source -> execute.
 *
 * Each test defines a TypeScript source string, encodes it to Ball IR,
 * compiles the IR back to TypeScript, then executes both the original
 * and round-tripped versions, asserting identical stdout.
 *
 * Run with:
 *   node --experimental-strip-types --test test/roundtrip.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { execSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encode } from "../src/index.ts";
import { compile } from "../../compiler/src/index.ts";

/**
 * Execute a TypeScript source string via Node's --experimental-transform-types
 * (a superset of --experimental-strip-types that also supports TS-only
 * constructs like `enum`, which strip-only mode rejects) and return trimmed
 * stdout. Uses a temp file to avoid shell escaping issues.
 */
function executeTs(source: string): string {
  const tmpPath = join(
    tmpdir(),
    `ball_roundtrip_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2)}.ts`,
  );
  writeFileSync(tmpPath, source);
  try {
    return execSync(`node --experimental-transform-types "${tmpPath}"`, {
      encoding: "utf8",
      timeout: 10_000,
    }).trim();
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

/**
 * Run the full round-trip: encode source -> compile IR -> execute both,
 * then assert identical output.
 */
function assertRoundTrip(originalSource: string): void {
  const program = encode(originalSource);
  const compiledSource = compile(program);

  const originalOutput = executeTs(originalSource);
  const roundTrippedOutput = executeTs(compiledSource);

  assert.equal(
    roundTrippedOutput,
    originalOutput,
    `Round-tripped output does not match original.\n` +
    `  Original output:     ${JSON.stringify(originalOutput)}\n` +
    `  Round-tripped output: ${JSON.stringify(roundTrippedOutput)}`,
  );
}

describe("encoder -> compiler round-trip", () => {
  test("simple function with arithmetic", () => {
    assertRoundTrip(`
function add(a, b) {
  return a + b;
}
function main() {
  console.log(add(3, 4));
  console.log(add(100, -50));
  console.log(add(0, 0));
}
main();
`);
  });

  test("if/else with string output", () => {
    assertRoundTrip(`
function classify(x) {
  if (x > 0) {
    return "positive";
  } else if (x < 0) {
    return "negative";
  } else {
    return "zero";
  }
}
function main() {
  console.log(classify(42));
  console.log(classify(-7));
  console.log(classify(0));
}
main();
`);
  });

  test("for loop with accumulator", () => {
    assertRoundTrip(`
function main() {
  let sum = 0;
  for (let i = 1; i <= 10; i++) {
    sum = sum + i;
  }
  console.log(sum);
}
main();
`);
  });

  test("nested function calls", () => {
    assertRoundTrip(`
function mul2(x) {
  return x * 2;
}
function addOne(x) {
  return x + 1;
}
function square(x) {
  return x * x;
}
function main() {
  console.log(square(addOne(mul2(3))));
  console.log(mul2(square(4)));
  console.log(addOne(addOne(addOne(0))));
}
main();
`);
  });

  test("while loop with break", () => {
    assertRoundTrip(`
function main() {
  let count = 0;
  let sum = 0;
  while (true) {
    if (count >= 5) {
      break;
    }
    sum = sum + count;
    count = count + 1;
  }
  console.log(count);
  console.log(sum);
}
main();
`);
  });

  test("fibonacci recursive", () => {
    assertRoundTrip(`
function fib(n) {
  if (n <= 1) {
    return n;
  }
  return fib(n - 1) + fib(n - 2);
}
function main() {
  console.log(fib(0));
  console.log(fib(1));
  console.log(fib(5));
  console.log(fib(10));
}
main();
`);
  });

  test("higher-order function with callback", () => {
    assertRoundTrip(`
function apply(fn, x) {
  return fn(x);
}
function main() {
  const triple = (x) => x * 3;
  const negate = (x) => 0 - x;
  console.log(apply(triple, 7));
  console.log(apply(negate, 42));
  console.log(apply((x) => x + 100, 5));
}
main();
`);
  });

  test("enum declaration with member comparisons (#120)", () => {
    // The TS enum encodes to Module.enums[] (EnumDescriptorProto) and the
    // compiler re-materializes it as an enum class with singleton members.
    // The original (numeric enum) and the round-tripped (singleton class)
    // representations agree on member identity, so comparison-driven
    // output must match exactly.
    assertRoundTrip(`
enum Color { red, green, blue }
function label(c) {
  if (c === Color.red) {
    return "stop";
  }
  if (c === Color.green) {
    return "go";
  }
  return "wait";
}
function main() {
  console.log(label(Color.red));
  console.log(label(Color.green));
  console.log(label(Color.blue));
}
main();
`);
  });

  test("string equality and concatenation", () => {
    assertRoundTrip(`
function greet(name) {
  if (name === "world") {
    return "Hello, World!";
  } else {
    return "Hi, " + name + "!";
  }
}
function main() {
  console.log(greet("world"));
  console.log(greet("Alice"));
  console.log(greet("Bob"));
}
main();
`);
  });

  // #249: `this` (field access, bare, in the constructor, in a regular
  // method, and inside an operator method) used to encode to a placeholder
  // literal instead of a real self-reference. Also exercises the
  // constructor-naming fix that #249's own verification uncovered: without
  // it, `constructor(x, y) {}` gets emitted as an ordinary method literally
  // named "constructor" (an illegal return-type annotation, since ordinary
  // methods get one), which fails to even parse — so this test doubles as
  // the proof that a class's real JS constructor round-trips correctly too.
  // Class fields must be declared explicitly (not merely assigned in the
  // constructor) — ts/compiler's self->this heuristic keys off the class's
  // DECLARED field set (currentClassFields), which is empty for a class
  // that only ever assigns `this.x` without a prior `x;` declaration. That
  // is a separate, pre-existing ts/compiler limitation (flagged, not fixed
  // here); ordinary idiomatic TS classes declare their fields, as below.
  test("this.field in a constructor, this.field reads in a method, and bare this", () => {
    assertRoundTrip(`
class Point {
  x;
  y;
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
  addOther(other) {
    return new Point(this.x + other.x, this.y + other.y);
  }
  toStr() {
    return this.x + "," + this.y;
  }
  self() {
    return this;
  }
}
function main() {
  const a = new Point(1, 2);
  const b = new Point(3, 4);
  const c = a.addOther(b);
  console.log(c.toStr());
  console.log(a.self() === a);
}
main();
`);
  });

});
