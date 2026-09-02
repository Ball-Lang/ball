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

  // ─────────────────────────────────────────────────────────────────────
  // #489 / #490 regression fixtures.
  //
  // This file is the ONLY leg that runs encode() -> compile() -> execute and
  // diffs stdout. Before these fixtures existed, the encoder could invent a
  // std name (list_add, optional_access, string_replace_first, ...) or emit
  // the right name with the wrong FIELD names, and nothing in CI noticed:
  // encoder.test.ts asserted the encoder's own spelling as correct, and
  // conformance.test.ts routes through ts/engine, which had been separately
  // hand-patched with matching ad hoc aliases. One fixture per construct is
  // what makes a future drift of this class fail the build.
  // ─────────────────────────────────────────────────────────────────────

  // The `?? "none"` guards are deliberate: JS distinguishes `undefined` from
  // `null`, Ball has a single null, so a bare short-circuit prints "undefined"
  // on one side and "null" on the other. Coalescing compares the branch that
  // actually matters — did the access short-circuit, and did it yield the right
  // value when it did not.
  test("optional chaining property access, null and non-null (#489)", () => {
    assertRoundTrip(`
function nameOf(o) {
  return o?.name ?? "none";
}
function main() {
  console.log(nameOf({ name: "ada" }));
  console.log(nameOf(null));
}
main();
`);
  });

  test("optional element access a?.[i] (#489)", () => {
    assertRoundTrip(`
function at(a, i) {
  return a?.[i] ?? -1;
}
function main() {
  console.log(at([10, 20, 30], 1));
  console.log(at(null, 1));
}
main();
`);
  });

  test("optional chaining method call o?.m() (#489)", () => {
    assertRoundTrip(`
function main() {
  const o = { greet: () => "hi" };
  const missing = null;
  console.log(o?.greet() ?? "none");
  console.log(missing?.greet() ?? "none");
}
main();
`);
  });

  test("Array.push mutates and is observable (#489)", () => {
    assertRoundTrip(`
function main() {
  const xs = [1, 2];
  xs.push(3);
  xs.push(4);
  console.log(xs.length);
  console.log(xs[2]);
  console.log(xs[3]);
}
main();
`);
  });

  test("Array.pop / indexOf / includes / join / reverse (#489)", () => {
    assertRoundTrip(`
function main() {
  const xs = [1, 2, 3];
  console.log(xs.pop());
  console.log(xs.length);
  console.log([4, 5, 6].indexOf(5));
  console.log([4, 5, 6].includes(6));
  console.log(["a", "b"].join("-"));
  console.log([1, 2, 3].reverse().join(","));
}
main();
`);
  });

  // NOTE: `slice`, `indexOf`, `includes` and `concat` exist on BOTH String and
  // Array, and the encoder is syntax-only (no type checker), so the STRING
  // mapping wins for all four — see ts/encoder/ENCODER_CARVEOUTS.md. That is
  // survivable in the TS target for indexOf/includes (JS Array has both under
  // the same spelling), so the fixture below exercises those, while array
  // `slice`/`concat` stay a documented, type-checker-shaped gap.
  test("Array.splice(i, 1) removes one element (#489)", () => {
    assertRoundTrip(`
function main() {
  const xs = [1, 2, 3];
  xs.splice(1, 1);
  console.log(xs.join(","));
  console.log(xs.length);
}
main();
`);
  });

  test("Array.map / filter / reduce / find / every / some (#489)", () => {
    assertRoundTrip(`
function main() {
  const xs = [1, 2, 3, 4];
  console.log(xs.map((x) => x * 2).join(","));
  console.log(xs.filter((x) => x > 2).join(","));
  console.log(xs.reduce((a, b) => a + b));
  console.log(xs.find((x) => x > 2));
  console.log(xs.every((x) => x > 0));
  console.log(xs.some((x) => x > 3));
}
main();
`);
  });

  test("Array.forEach desugars to native iteration (#489)", () => {
    assertRoundTrip(`
function main() {
  const xs = [1, 2, 3];
  xs.forEach((x) => console.log(x));
  let total = 0;
  xs.forEach((x) => {
    total = total + x;
  });
  console.log(total);
}
main();
`);
  });

  test("the `in` operator on an object (#489)", () => {
    assertRoundTrip(`
function main() {
  const o = { a: 1, b: 2 };
  console.log("a" in o);
  console.log("zz" in o);
}
main();
`);
  });

  test("String.replace replaces only the first occurrence (#489)", () => {
    assertRoundTrip(`
function main() {
  console.log("a-b-c".replace("-", "+"));
  console.log("a-b-c".replaceAll("-", "+"));
}
main();
`);
  });

  test("String.toUpperCase / toLowerCase through the COMPILER (#489)", () => {
    // conformance.test.ts proves these only via ts/engine, which carried its
    // own ad hoc alias for the encoder's non-canonical spelling.
    assertRoundTrip(`
function main() {
  console.log("MiXeD".toUpperCase());
  console.log("MiXeD".toLowerCase());
}
main();
`);
  });

  test("String indexOf / substring / slice / padStart / repeat / charAt (#489)", () => {
    assertRoundTrip(`
function main() {
  console.log("hello".indexOf("l"));
  console.log("hello".substring(1, 3));
  console.log("hello".slice(2));
  console.log("7".padStart(3, "0"));
  console.log("ab".repeat(3));
  console.log("abc".charAt(1));
  console.log("abc".charCodeAt(0));
  console.log("  pad  ".trim() + "|");
  console.log("  pad  ".trimStart() + "|");
  console.log("  pad  ".trimEnd() + "|");
  console.log("a,b,c".split(",").join("/"));
}
main();
`);
  });

  test("super.method() in a subclass (#490)", () => {
    assertRoundTrip(`
class Base {
  greet() {
    return "a";
  }
}
class Child extends Base {
  greet() {
    return super.greet() + "b";
  }
}
function main() {
  console.log(new Child().greet());
}
main();
`);
  });

  test("delete obj.prop and delete obj[key] (#490)", () => {
    assertRoundTrip(`
function main() {
  const o = { a: 1, b: 2 };
  delete o.a;
  console.log("a" in o);
  console.log("b" in o);
  const p = { x: 1 };
  const k = "x";
  delete p[k];
  console.log("x" in p);
}
main();
`);
  });

  test("exponentiation ** and **= (#490)", () => {
    assertRoundTrip(`
function main() {
  console.log(2 ** 3);
  console.log(2 ** 0);
  let n = 3;
  n **= 2;
  console.log(n);
}
main();
`);
  });

  test("regex literal driving test / exec / match / replace (#490)", () => {
    assertRoundTrip(`
function main() {
  console.log(/^[a-z]+$/.test("abc"));
  console.log(/^[a-z]+$/.test("Abc"));
  console.log("a1b2".replace(/[0-9]/, "#"));
  console.log("a1b2".replaceAll(/[0-9]/g, "#"));
  console.log("a1b2".replace(/[0-9]/g, "#"));
  console.log("a1b2".match(/[0-9]/g).join(","));
}
main();
`);
  });
});
