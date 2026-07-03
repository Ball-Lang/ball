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
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";
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
