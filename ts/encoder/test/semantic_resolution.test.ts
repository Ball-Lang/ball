/**
 * Semantic (TypeChecker-backed) std dispatch tests — #506.
 *
 * `slice`, `indexOf` and `includes` exist on BOTH `String.prototype` and
 * `Array.prototype`. Which Ball std function they encode to therefore depends
 * on the RECEIVER'S STATIC TYPE, not on lookup-table order.
 *
 * These tests assert the emitted `{module, function}` pair directly, which is
 * the class of assertion `roundtrip.test.ts` structurally cannot make: a
 * round-trip asserts TS-target OUTPUT EQUIVALENCE, and `std.string_index_of` /
 * `std.string_contains` happen to compile back to JS's receiver-agnostic
 * `.indexOf()` / `.includes()`. A round-trip through ONE target is blind to
 * WHICH std function was chosen, so a portability bug in the IR survives it.
 * Only an IR-shape assertion can see it — hence this file.
 *
 * Run with:
 *   node --experimental-strip-types --test test/semantic_resolution.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode, encodeWithWarnings, EncodeError } from "../src/index.ts";
import type { Expression } from "../src/types.ts";

/** The `main` body's LAST statement, as an expression. */
function lastExpr(source: string): Expression {
  const program = encode(`function main() {\n${source}\n}`);
  const mod = program.modules.find((m) => m.name === "main");
  assert.ok(mod, "the encoded program has a `main` module");
  const main = mod!.functions.find((f) => f.name === "main");
  assert.ok(main, "the encoded module has a `main` function");
  const stmts = main!.body!.block!.statements;
  const last = stmts[stmts.length - 1];
  const expr = last.let ? last.let.value! : last.expression!;
  assert.ok(expr, "the last statement carries an expression");
  return expr;
}

/** The `{module, function}` pair of the std call the last statement emits. */
function stdCallFor(source: string): { module: string; function: string } {
  const call = lastExpr(source).call;
  assert.ok(call, `the last statement of ${JSON.stringify(source)} is a call`);
  return { module: call!.module ?? "std", function: call!.function };
}

/** The AmbiguousStringArrayMethod warnings raised while encoding `source`. */
function ambiguityWarnings(source: string): string[] {
  const { warnings } = encodeWithWarnings(`function main() {\n${source}\n}`);
  return warnings.filter((w) => w.includes("String and Array"));
}

describe("#506 — receiver type, not table order, decides String vs Array dispatch", () => {
  // ── Array receivers: the three names that used to lose to STR_METHODS ──

  test("T2a: `slice` on a number[] receiver -> std_collections.list_slice", () => {
    assert.deepEqual(
      stdCallFor(`const a: number[] = [];\na.slice(1, 3);`),
      { module: "std_collections", function: "list_slice" },
    );
  });

  test("T2b: `indexOf` on a number[] receiver -> std_collections.list_index_of", () => {
    assert.deepEqual(
      stdCallFor(`const a: number[] = [];\na.indexOf(9);`),
      { module: "std_collections", function: "list_index_of" },
    );
  });

  test("T2c: `includes` on a number[] receiver -> std_collections.list_contains", () => {
    assert.deepEqual(
      stdCallFor(`const a: number[] = [];\na.includes(9);`),
      { module: "std_collections", function: "list_contains" },
    );
  });

  test("an array LITERAL receiver resolves the same way (inferred, not annotated)", () => {
    assert.deepEqual(
      stdCallFor(`[1, 2, 3].indexOf(2);`),
      { module: "std_collections", function: "list_index_of" },
    );
  });

  test("a readonly tuple receiver still resolves to the Array mapping", () => {
    assert.deepEqual(
      stdCallFor(`const a: readonly [number, number] = [1, 2];\na.includes(2);`),
      { module: "std_collections", function: "list_contains" },
    );
  });

  // ── String receivers: non-regression guards (green before AND after) ──

  test("T2d: `slice` on a string receiver -> std.string_substring", () => {
    assert.deepEqual(
      stdCallFor(`const s: string = "";\ns.slice(1, 3);`),
      { module: "std", function: "string_substring" },
    );
  });

  test("T2e: `indexOf` on a string receiver -> std.string_index_of", () => {
    assert.deepEqual(
      stdCallFor(`const s: string = "";\ns.indexOf("x");`),
      { module: "std", function: "string_index_of" },
    );
  });

  test("`includes` on a string LITERAL receiver -> std.string_contains", () => {
    assert.deepEqual(
      stdCallFor(`"abc".includes("b");`),
      { module: "std", function: "string_contains" },
    );
  });

  test("an unambiguous String method is untouched by the resolver", () => {
    assert.deepEqual(
      stdCallFor(`const s: string = "";\ns.trim();`),
      { module: "std", function: "string_trim" },
    );
  });

  test("an unambiguous Array method is untouched by the resolver", () => {
    assert.deepEqual(
      stdCallFor(`const a: number[] = [];\na.push(1);`),
      { module: "std_collections", function: "list_push" },
    );
  });

  // ── Warnings: only the receivers the checker cannot type ──

  test("T2f: a typed Array receiver emits NO AmbiguousStringArrayMethod warning", () => {
    assert.deepEqual(ambiguityWarnings(`const a: number[] = [];\na.slice(1, 3);`), []);
  });

  test("a typed String receiver emits NO AmbiguousStringArrayMethod warning", () => {
    assert.deepEqual(ambiguityWarnings(`const s: string = "";\ns.slice(1, 3);`), []);
  });

  test("T2g: an `any` receiver keeps the warn-loud String fallback", () => {
    assert.deepEqual(
      stdCallFor(`const d: any = null;\nd.slice(1, 3);`),
      { module: "std", function: "string_substring" },
    );
    const warnings = ambiguityWarnings(`const d: any = null;\nd.slice(1, 3);`);
    assert.equal(warnings.length, 1, `expected exactly one ambiguity warning, got ${JSON.stringify(warnings)}`);
    assert.match(warnings[0], /\.slice\(/);
  });

  test("T2g: an `any` receiver is still rejected under strictBehaviorAffecting", () => {
    assert.throws(
      () => encodeWithWarnings(
        `function main() { const d: any = null; d.slice(1, 3); }`,
        { strictBehaviorAffecting: true },
      ),
      EncodeError,
      "an inconclusive receiver must stay behaviour-affecting",
    );
  });

  test("an unresolvable (undeclared) receiver keeps the warn-loud fallback", () => {
    assert.deepEqual(
      stdCallFor(`nowhere.includes(1);`),
      { module: "std", function: "string_contains" },
    );
    assert.equal(ambiguityWarnings(`nowhere.includes(1);`).length, 1);
  });

  test("a MIXED string|number[] union receiver stays inconclusive and warns", () => {
    const src = `const u: string | number[] = [] as string | number[];\nu.indexOf(1 as any);`;
    assert.deepEqual(stdCallFor(src), { module: "std", function: "string_index_of" });
    assert.equal(ambiguityWarnings(src).length, 1);
  });

  test("a union whose members all agree on String resolves without warning", () => {
    const src = `const u: "a" | "b" = "a" as "a" | "b";\nu.indexOf("x");`;
    assert.deepEqual(stdCallFor(src), { module: "std", function: "string_index_of" });
    assert.deepEqual(ambiguityWarnings(src), []);
  });

  test("a union whose members all agree on Array resolves to std_collections", () => {
    const src = `const u: number[] | string[] = [] as number[] | string[];\nu.includes(1 as any);`;
    assert.deepEqual(stdCallFor(src), { module: "std_collections", function: "list_contains" });
    assert.deepEqual(ambiguityWarnings(src), []);
  });

  test("a receiver that is NEITHER String nor Array keeps the warn-loud fallback", () => {
    // A user-defined `slice` is not a std construct at all. The checker types
    // the receiver precisely — it is simply neither of the two tables — so the
    // encoder must not claim it resolved anything.
    const src = `class Box { slice(a: number, b: number) { return a + b; } }\n`
      + `const b = new Box();\nb.slice(1, 3);`;
    assert.deepEqual(stdCallFor(src), { module: "std", function: "string_substring" });
    assert.equal(ambiguityWarnings(src).length, 1);
  });

  test("an unresolved generic receiver stays inconclusive and warns", () => {
    const { warnings } = encodeWithWarnings(
      `function pick<T extends string | number[]>(xs: T) { return xs.slice(1, 2); }`,
    );
    assert.equal(
      warnings.filter((w) => w.includes("String and Array")).length,
      1,
      `expected one ambiguity warning, got ${JSON.stringify(warnings)}`,
    );
  });
});
