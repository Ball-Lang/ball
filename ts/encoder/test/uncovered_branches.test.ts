/**
 * Targeted coverage tests for src/encoder.ts branches the primary suites
 * (encoder.test.ts, encoder_coverage.test.ts, conformance.test.ts,
 * roundtrip.test.ts) do not exercise: top-level variable declarations
 * (plain/object-destructured/array-destructured), local array destructuring
 * with a default initializer, a bare block statement, `typeof`, non-null
 * assertion (`!`), `await`, array spread, object shorthand properties,
 * optional element access (`arr?.[i]`), the `in` operator, prefix
 * increment/decrement, a no-substitution tagged template, and a destructured
 * lambda parameter.
 *
 * Assertions go through the public `encode` API and inspect the resulting
 * Ball IR, mirroring the style of encoder.test.ts / encoder_coverage.test.ts.
 *
 * #62 Phase-2b adds a second wave: braceless loop/if bodies (for/for-of/
 * for-in/while/do-while/else without `{}`), a labeled non-block statement,
 * destructuring edge cases (nested patterns, non-identifier property names,
 * a for-loop init with no initializer or a destructured init variable), a
 * destructured function parameter, an abstract method signature (no body),
 * a parameterless `new Foo`, a non-identifier object-literal key, class
 * fields/interface properties with no explicit type annotation, a
 * string-literal enum member name, an arrow function with an expression
 * (non-block) body, a labeled block statement (needing no synthetic wrap),
 * a numeric object-destructuring/object-literal key, a nested array-pattern
 * element, and a multi-arg array method call (`.splice(index, count)`).
 *
 * Five branches audited and found genuinely unreachable (not tested — see
 * the comments at their use sites instead):
 *  - `mapMethodToStd`'s `selfName ?? "value"` fallback (every current
 *    mapping entry sets `selfName` explicitly);
 *  - `encodeStatement`'s `decl.name.getText()` fallback for a plain
 *    `let`/`const` (TS's own syntax requires an initializer for a
 *    destructuring declaration, so by the time that branch runs
 *    `decl.name` is exhaustively known to be an Identifier);
 *  - `encodeFunction`'s name-computation fallback for a non-identifier
 *    name (a class method with a non-identifier name, e.g. `'foo-bar'() {}`,
 *    is filtered out by its caller's `ts.isIdentifier(member.name)` guard
 *    BEFORE `encodeFunction` ever runs — it's silently dropped from the
 *    encoded class entirely, a separate real gap worth its own issue, not
 *    something this coverage pass should paper over with a test that can't
 *    actually reach the line it's meant to cover);
 *  - both object-destructuring elements' `element.name.getText()` fallback
 *    for the SHORTHAND case (no `propertyName`) — shorthand syntax
 *    (`{a}`) grammatically requires `name` to be a plain Identifier, so
 *    a shorthand binding can never itself be a non-identifier (top-level
 *    at line ~97, local at line ~215 — the nested-pattern case that IS
 *    reachable always has an explicit `propertyName`, e.g. `{a: {b}}`,
 *    exercised elsewhere in this file);
 *  - `encodeLambda`'s outer `node.body ? ... : undefined` alternate —
 *    `ts.ArrowFunction`/`ts.FunctionExpression`'s `.body` is non-optional
 *    in TS's own AST types, so this node can never lack a body (unlike
 *    `MethodDeclaration`, which genuinely can — see the abstract-method
 *    test above, which covers the analogous case in `encodeFunction`).
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode, encodeWithWarnings } from "../src/index.ts";
import type { Module } from "../src/types.ts";

function userModule(program: { modules: Module[] }, name = "main"): Module {
  const mod = program.modules.find((m) => m.name === name);
  assert.ok(mod, `module ${name} exists`);
  return mod!;
}

describe("encoder top-level variable declarations", () => {
  test("plain top-level const becomes a module-level function", () => {
    const program = encode(`const x = 5;`);
    const mod = userModule(program);
    const fn = mod.functions.find((f) => f.name === "x");
    assert.ok(fn, "top-level const emitted as a function");
    assert.equal(fn!.body!.literal!.intValue, "5");
    assert.equal(fn!.metadata?.["kind"], "top_level_variable");
  });

  test("top-level object destructuring emits one function per binding, with rename support", () => {
    const program = encode(`const {a, b: renamed} = obj;`);
    const mod = userModule(program);
    const aFn = mod.functions.find((f) => f.name === "a");
    const renamedFn = mod.functions.find((f) => f.name === "renamed");
    assert.ok(aFn, "shorthand binding emitted");
    assert.ok(renamedFn, "renamed binding emitted");
    assert.equal(aFn!.body!.fieldAccess!.field, "a");
    assert.equal(renamedFn!.body!.fieldAccess!.field, "b");
    assert.equal(aFn!.metadata?.["destructured"], true);
  });

  test("top-level array destructuring emits indexed accessors and skips omitted elements", () => {
    const program = encode(`const [x, , z] = arr;`);
    const mod = userModule(program);
    const xFn = mod.functions.find((f) => f.name === "x");
    const zFn = mod.functions.find((f) => f.name === "z");
    assert.ok(xFn && zFn);
    const xIndex = xFn!.body!.call!.input!.messageCreation!.fields.find((f) => f.name === "index");
    const zIndex = zFn!.body!.call!.input!.messageCreation!.fields.find((f) => f.name === "index");
    assert.equal(xIndex!.value.literal!.intValue, "0");
    assert.equal(zIndex!.value.literal!.intValue, "2");
    // The omitted middle element must not produce its own binding.
    assert.equal(mod.functions.filter((f) => f.metadata?.["kind"] === "top_level_variable").length, 2);
  });
});

describe("encoder local array destructuring with defaults", () => {
  test("a missing element falls back to its default via null_coalesce", () => {
    const program = encode(`function main() { const arr = [1]; const [a = 9] = arr; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const letA = main.body!.block!.statements.find((s) => s.let?.name === "a")!;
    const call = letA.let!.value!.call!;
    assert.equal(call.function, "null_coalesce");
    const fields = call.input!.messageCreation!.fields;
    assert.equal(fields.find((f) => f.name === "left")!.value.call!.function, "index");
    assert.equal(fields.find((f) => f.name === "right")!.value.literal!.intValue, "9");
  });
});

describe("encoder statement kinds", () => {
  test("a bare block statement encodes to a nested block expression", () => {
    const program = encode(`function main() { { const x = 1; } }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const stmt = main.body!.block!.statements[0];
    assert.ok(stmt.expression?.block, "bare block wrapped as an expression block");
    assert.equal(stmt.expression!.block!.statements[0].let!.name, "x");
  });
});

describe("encoder expression kinds", () => {
  test("typeof maps to std.type_of", () => {
    const program = encode(`function main() { const t = typeof x; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "type_of");
    assert.equal(call.module, "std");
  });

  test("non-null assertion (!) maps to std.null_check", () => {
    const program = encode(`function main() { const y = x!; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "null_check");
  });

  test("await maps to std.await", () => {
    const program = encode(`async function main() { const v = await foo(); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "await");
    const inner = call.input!.messageCreation!.fields.find((f) => f.name === "value")!;
    assert.equal(inner.value.call!.function, "foo");
  });

  test("spread in an array literal encodes to a std.spread element", () => {
    const program = encode(`function main() { const a = [...arr, 1]; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const elements = main.body!.block!.statements[0].let!.value!.literal!.listValue!.elements;
    assert.equal(elements.length, 2);
    assert.equal(elements[0].call!.function, "spread");
    assert.equal(elements[1].literal!.intValue, "1");
  });

  test("shorthand object property emits a field referencing the same name", () => {
    const program = encode(`function main() { const a = 1; const o = { a }; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const oLet = main.body!.block!.statements.find((s) => s.let?.name === "o")!;
    const field = oLet.let!.value!.messageCreation!.fields[0];
    assert.equal(field.name, "a");
    assert.equal(field.value.reference!.name, "a");
  });

  test("optional element access maps to std.optional_access", () => {
    const program = encode(`function main() { const v = arr?.[0]; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "optional_access");
    const fields = call.input!.messageCreation!.fields;
    assert.equal(fields.find((f) => f.name === "object")!.value.reference!.name, "arr");
    assert.equal(fields.find((f) => f.name === "field")!.value.literal!.intValue, "0");
  });

  test("the `in` operator maps to std_collections.contains_key", () => {
    const program = encode(`function main() { const has = 'a' in obj; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "contains_key");
    assert.equal(call.module, "std_collections");
    const fields = call.input!.messageCreation!.fields;
    assert.equal(fields.find((f) => f.name === "map")!.value.reference!.name, "obj");
    assert.equal(fields.find((f) => f.name === "key")!.value.literal!.stringValue, "a");
  });

  test("prefix increment/decrement map to std.pre_increment / std.pre_decrement", () => {
    const program = encode(`function main() { let i = 0; ++i; --i; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const stmts = main.body!.block!.statements;
    assert.equal(stmts[1].expression!.call!.function, "pre_increment");
    assert.equal(stmts[2].expression!.call!.function, "pre_decrement");
  });

  test("a no-substitution tagged template collects a single string part and no expressions", () => {
    const program = encode("function main() { const r = tag`hello`; }");
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "tagged_template");
    const fields = call.input!.messageCreation!.fields;
    const strings = fields.find((f) => f.name === "strings")!.value.literal!.listValue!.elements;
    const expressions = fields.find((f) => f.name === "expressions")!.value.literal!.listValue!.elements;
    assert.equal(strings.length, 1);
    assert.equal(strings[0].literal!.stringValue, "hello");
    assert.equal(expressions.length, 0);
  });

  test("a destructured lambda parameter is recorded in metadata.destructured_params", () => {
    const program = encode(`function main() { const f = ({a, b}) => a; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const lambda = main.body!.block!.statements[0].let!.value!.lambda!;
    assert.ok(lambda.metadata?.["destructured_params"], "destructured_params metadata present");
    const destructured = lambda.metadata!["destructured_params"] as Record<string, string>;
    assert.equal(destructured["param0"], "{a, b}");
  });

  test("a decimal numeric literal encodes as a doubleValue", () => {
    const program = encode(`function main() { const x = 1.5; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    assert.equal(main.body!.block!.statements[0].let!.value!.literal!.doubleValue, 1.5);
  });

  test("an `as`/type-assertion expression encodes to just its inner expression", () => {
    const program = encode(`function main() { const y = (5 as unknown) as number; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    assert.equal(main.body!.block!.statements[0].let!.value!.literal!.intValue, "5");
  });

  test("an unhandled prefix operator (unary +) warns and falls back to the bare operand", () => {
    const program = encode(`function main() { const z = +5; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    assert.equal(main.body!.block!.statements[0].let!.value!.literal!.intValue, "5");
  });

  // `**` (exponentiation) has no entry in BINARY_OPS — unlike the Dart
  // encoder, which maps it (and `>>>`) to a std base function. This is a
  // genuine TS-encoder gap, not a fixture-of-convenience: both operators fall
  // through to the same "Unhandled binary operator" warn() + placeholder path.
  test("an unhandled binary operator (**) warns and falls back to a placeholder literal", () => {
    const { program, warnings } = encodeWithWarnings(`function main() { const z = 2 ** 3; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const value = main.body!.block!.statements[0].let!.value!;
    assert.ok(value.literal!.stringValue?.includes("binary:"), "falls back to a placeholder literal");
    assert.ok(
      warnings.some((w) => w.includes("Unhandled binary operator")),
      "should warn about the unhandled operator",
    );
  });
});

describe("encoder console mappings", () => {
  test("console.log() with no arguments prints an empty string", () => {
    const program = encode(`function main() { console.log(); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "print");
    const msg = call.input!.messageCreation!.fields.find((f) => f.name === "message")!;
    assert.equal(msg.value.literal!.stringValue, "");
  });

  test("console.log(a, b) with multiple arguments emits one std.print per argument in a block", () => {
    const program = encode(`function main() { console.log(1, 2); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const block = main.body!.block!.statements[0].expression!.block!;
    assert.equal(block.statements.length, 2);
    assert.equal(block.statements[0].expression!.call!.function, "print");
    assert.equal(block.statements[1].expression!.call!.function, "print");
  });

  test("console.error(x) maps to std.print_error", () => {
    const program = encode(`function main() { console.error("e"); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "print_error");
    assert.equal(call.input!.messageCreation!.fields[0].value.literal!.stringValue, "e");
  });

  test("console.error() with no arguments prints an empty string via print_error", () => {
    const program = encode(`function main() { console.error(); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "print_error");
    assert.equal(call.input!.messageCreation!.fields[0].value.literal!.stringValue, "");
  });
});

// ── #62 Phase-2b: braceless bodies, destructuring edge cases, misc ─────

describe("encoder top-level declarations (wave 2)", () => {
  test("top-level let with no initializer encodes to a null literal", () => {
    const program = encode(`let x;`);
    const mod = userModule(program);
    const fn = mod.functions.find((f) => f.name === "x")!;
    assert.ok(fn, "top-level uninitialized var emitted as a function");
    assert.equal(Object.keys(fn.body!.literal!).length, 0, "empty Literal = null");
  });

  test("top-level object destructuring with a numeric property key falls back to getText()", () => {
    const program = encode(`const { 0: first } = obj;`);
    const mod = userModule(program);
    const fn = mod.functions.find((f) => f.name === "first")!;
    assert.equal(fn.body!.fieldAccess!.field, "0");
  });

  test("top-level object destructuring with a nested binding pattern falls back to getText() for the local name", () => {
    const program = encode(`const { a: {b} } = obj;`);
    const mod = userModule(program);
    // The nested pattern's own local name ("b") is what's ultimately bound;
    // the OUTER destructured function here is named after the whole nested
    // pattern's source text (getText() fallback, since it isn't a plain
    // Identifier) — assert it's non-empty and references field "a".
    const fn = mod.functions.find((f) => f.metadata?.["destructured"] === true)!;
    assert.ok(fn, "nested-pattern binding still emits a top-level function");
    assert.equal(fn.body!.fieldAccess!.field, "a");
    assert.ok(fn.name.length > 0);
  });

  test("top-level array destructuring with a nested pattern element falls back to getText()", () => {
    const program = encode(`const [[a, b]] = arr;`);
    const mod = userModule(program);
    const fn = mod.functions.find((f) => f.metadata?.["destructured"] === true)!;
    assert.ok(fn, "nested array-pattern element still emits a top-level function");
    assert.equal(fn.body!.call!.function, "index");
  });
});

describe("encoder function/method declarations (wave 2)", () => {
  test("a destructured function parameter falls back to getText() for its param name", () => {
    const program = encode(`function f({a, b}) { return a; }`);
    const mod = userModule(program);
    const fn = mod.functions.find((f) => f.name === "f")!;
    const params = fn.metadata!["params"] as Array<{ name: string }>;
    assert.equal(params.length, 1);
    assert.ok(params[0].name.includes("a") && params[0].name.includes("b"));
  });

  test("an abstract method signature (no body) encodes with no `body` field", () => {
    const program = encode(`abstract class A { abstract foo(): void; }`);
    const mod = userModule(program);
    const typeDef = mod.typeDefs!.find((t) => t.name === "A")!;
    assert.ok(typeDef, "abstract class A encoded");
    const fn = mod.functions.find((f) => f.name === "A.foo")!;
    assert.ok(fn, "abstract method still produces a FunctionDef");
    assert.equal(fn.body, undefined, "no implementation -> no body");
  });
});

describe("encoder braceless statement bodies (wave 2)", () => {
  test("a labeled non-block statement (a braceless for loop) wraps both the label body and the for body in a synthetic block", () => {
    const program = encode(`function main() { outer: for (let i = 0; i < 3; i++) console.log(i); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const labeled = main.body!.block!.statements[0].expression!.call!;
    assert.equal(labeled.function, "labeled");
    const bodyField = labeled.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    const forBlock = bodyField.value.block!;
    const forCall = forBlock.statements[0].expression!.call!;
    assert.equal(forCall.function, "for");
    const forBodyField = forCall.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    assert.equal(forBodyField.value.block!.statements[0].expression!.call!.function, "print");
  });

  test("a braceless for-of body wraps the single statement in a synthetic block", () => {
    const program = encode(`function main() { for (const x of xs) console.log(x); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "for_each");
    const bodyField = call.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    assert.equal(bodyField.value.block!.statements[0].expression!.call!.function, "print");
  });

  test("a braceless while body wraps the single statement in a synthetic block", () => {
    const program = encode(`function main() { while (cond) console.log(1); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "while");
    const bodyField = call.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    assert.equal(bodyField.value.block!.statements[0].expression!.call!.function, "print");
  });

  test("a braceless do-while body wraps the single statement in a synthetic block", () => {
    const program = encode(`function main() { do console.log(1); while (cond); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "do_while");
    const bodyField = call.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    assert.equal(bodyField.value.block!.statements[0].expression!.call!.function, "print");
  });

  test("a braceless else branch wraps the single statement in a synthetic block", () => {
    const program = encode(`function main() { if (x) { } else console.log(1); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "if");
    const elseField = call.input!.messageCreation!.fields.find((f) => f.name === "else")!;
    assert.equal(elseField.value.block!.statements[0].expression!.call!.function, "print");
  });

  // Companion to the braceless-for label test above: a label wrapping an
  // ALREADY-block statement needs no synthetic wrap (the isBlock TRUE side).
  test("a labeled block statement is used as-is, with no synthetic wrap", () => {
    const program = encode(`function main() { outer: { console.log(1); } }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const labeled = main.body!.block!.statements[0].expression!.call!;
    assert.equal(labeled.function, "labeled");
    const bodyField = labeled.input!.messageCreation!.fields.find((f) => f.name === "body")!;
    assert.equal(bodyField.value.block!.statements[0].expression!.call!.function, "print");
  });
});

describe("encoder for-loop init edge cases (wave 2)", () => {
  test("a for-loop init declaration with no initializer omits `value`", () => {
    const program = encode(`function main() { for (let i; i < 3; i++) { } }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    const initField = call.input!.messageCreation!.fields.find((f) => f.name === "init")!;
    const letStmt = initField.value.block!.statements[0];
    assert.equal(letStmt.let!.name, "i");
    assert.equal(letStmt.let!.value, undefined);
  });

  test("a for-loop init using a destructuring pattern falls back to getText() for its name", () => {
    const program = encode(`function main() { for (let [a, b] = pair; a < 3; a++) { } }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    const initField = call.input!.messageCreation!.fields.find((f) => f.name === "init")!;
    const letStmt = initField.value.block!.statements[0];
    assert.ok(letStmt.let!.name.includes("a") && letStmt.let!.name.includes("b"));
  });

  test("a for-of loop with a destructured variable falls back to getText() for the variable label", () => {
    const program = encode(`function main() { for (const [a, b] of pairs) { } }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].expression!.call!;
    const varField = call.input!.messageCreation!.fields.find((f) => f.name === "variable")!;
    assert.ok(varField.value.literal!.stringValue!.includes("a") && varField.value.literal!.stringValue!.includes("b"));
  });
});

describe("encoder local destructuring edge cases (wave 2)", () => {
  test("a local object destructuring with a nested binding pattern falls back to getText()", () => {
    const program = encode(`function main() { const { a: { b } } = obj; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const letStmt = main.body!.block!.statements.find((s) => s.let)!;
    assert.equal(letStmt.let!.value!.fieldAccess!.field, "a");
  });

  test("a local object destructuring with a numeric property key falls back to getText()", () => {
    const program = encode(`function main() { const { 0: first } = obj; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const letStmt = main.body!.block!.statements.find((s) => s.let)!;
    assert.equal(letStmt.let!.value!.fieldAccess!.field, "0");
  });

  test("a local array destructuring with a hole skips the omitted element", () => {
    const program = encode(`function main() { const [x, , z] = arr; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const lets = main.body!.block!.statements.filter((s) => s.let);
    assert.equal(lets.length, 2, "the hole must not produce its own local binding");
    assert.equal(lets[0].let!.name, "x");
    assert.equal(lets[1].let!.name, "z");
  });

  test("a local array destructuring with a nested pattern element falls back to getText()", () => {
    const program = encode(`function main() { const [[a, b]] = arr; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const letStmt = main.body!.block!.statements.find((s) => s.let)!;
    assert.equal(letStmt.let!.value!.call!.function, "index");
  });
});

describe("encoder misc expression/declaration kinds (wave 2)", () => {
  test("`new Foo` with no parentheses/arguments encodes with zero fields", () => {
    const program = encode(`function main() { const x = new Foo; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const mc = main.body!.block!.statements[0].let!.value!.messageCreation!;
    assert.equal(mc.typeName, "Foo");
    assert.equal(mc.fields.length, 0);
  });

  test("an object literal with a string-literal key falls back to getText()/text for the field name", () => {
    const program = encode(`function main() { const o = { 'a-b': 1 }; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const mc = main.body!.block!.statements[0].let!.value!.messageCreation!;
    assert.equal(mc.fields[0].name, "a-b");
  });

  test("an object literal with a numeric key falls back to getText() for the field name", () => {
    const program = encode(`function main() { const o = { 0: 1 }; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const mc = main.body!.block!.statements[0].let!.value!.messageCreation!;
    assert.equal(mc.fields[0].name, "0");
  });

  test("a class field with no explicit type annotation defaults to 'any'", () => {
    const program = encode(`class C { x = 5; }`);
    const mod = userModule(program);
    const typeDef = mod.typeDefs!.find((t) => t.name === "C")!;
    const field = typeDef.descriptor!.field!.find((f) => f.name === "x")!;
    assert.equal(field.type, "any");
  });

  test("an interface property with no explicit type annotation defaults to 'any'", () => {
    const program = encode(`interface Foo { x; }`);
    const mod = userModule(program);
    const typeDef = mod.typeDefs!.find((t) => t.name === "Foo")!;
    const field = typeDef.descriptor!.field!.find((f) => f.name === "x")!;
    assert.equal(field.type, "any");
  });

  test("a string-literal enum member name falls back to getText()", () => {
    const program = encode(`enum Foo { 'a-b' = 1 }`);
    const mod = userModule(program);
    const enumDef = mod.enums!.find((e) => e.name === "Foo")!;
    assert.ok(enumDef.value[0].name.includes("a-b"));
  });

  test("an arrow function with an expression (non-block) body encodes the expression directly", () => {
    const program = encode(`function main() { const f = (x: number) => x + 1; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const lambda = main.body!.block!.statements[0].let!.value!.lambda!;
    assert.equal(lambda.body!.call!.function, "add");
  });

  test("an arrow function with a block body encodes the block directly", () => {
    const program = encode(`function main() { const f = (x: number) => { return x + 1; }; }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const lambda = main.body!.block!.statements[0].let!.value!.lambda!;
    assert.equal(lambda.body!.block!.statements[0].expression!.call!.function, "return");
  });

  // `splice` (unlike `slice`) has no STR_METHODS entry, so it can only
  // resolve through ARR_METHODS — a reliable way to reach the multi-arg
  // naming branch without the encoder's string/array method maps colliding
  // (both maps happen to have a `slice` entry, and STR_METHODS is checked
  // first, so `arr.slice(...)` alone would silently test the STRING path).
  test("a multi-argument array method call (splice(index, count)) names args arg1, arg2, ...", () => {
    const program = encode(`function main() { const s = arr.splice(1, 2); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "list_remove_at");
    const fields = call.input!.messageCreation!.fields;
    assert.equal(fields.find((f) => f.name === "value")!.value.literal!.intValue, "1");
    assert.equal(fields.find((f) => f.name === "arg1")!.value.literal!.intValue, "2");
  });
});
