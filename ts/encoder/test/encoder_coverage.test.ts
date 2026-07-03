/**
 * Supplementary encoder coverage tests.
 *
 * Targets hand-written branches in src/encoder.ts that the primary suites do
 * not yet exercise: class heritage (extends/implements), static members,
 * constructors, the string/array std method mappings (replace, slice,
 * toString), and tagged templates that contain substitution spans.
 *
 * All assertions go through the public `encode` API and inspect the resulting
 * Ball IR, mirroring the style of encoder.test.ts.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";
import type { Module, TypeDefinition, FunctionDef } from "../src/types.ts";

function userModule(program: { modules: Module[] }, name = "main"): Module {
  const mod = program.modules.find((m) => m.name === name);
  assert.ok(mod, `module ${name} exists`);
  return mod!;
}

describe("encoder class heritage + members", () => {
  test("extends sets superclass metadata", () => {
    const program = encode(`class Dog extends Animal {}`);
    const mod = userModule(program);
    const td = mod.typeDefs?.find((t) => t.name === "Dog") as TypeDefinition;
    assert.ok(td);
    assert.equal(td.metadata?.["superclass"], "Animal");
  });

  test("implements sets interfaces metadata", () => {
    const program = encode(`class Box implements Container, Sized {}`);
    const mod = userModule(program);
    const td = mod.typeDefs?.find((t) => t.name === "Box") as TypeDefinition;
    assert.ok(td);
    assert.deepEqual(td.metadata?.["interfaces"], ["Container", "Sized"]);
  });

  test("static field is flagged in field label, static method in fn metadata", () => {
    const program = encode(
      `class Counter { static total: number = 0; instance: number = 1; static reset() { } tick() { } }`,
    );
    const mod = userModule(program);
    const td = mod.typeDefs?.find((t) => t.name === "Counter") as TypeDefinition;
    assert.ok(td);
    const totalField = td.descriptor?.field?.find((f) => f.name === "total");
    assert.ok(totalField);
    assert.ok(
      typeof totalField!.label === "string" &&
        totalField!.label.includes("is_static"),
      "static field label carries is_static",
    );

    const resetFn = mod.functions.find((f) => f.name === "Counter.reset");
    assert.ok(resetFn, "static method emitted with class-qualified name");
    assert.equal((resetFn as FunctionDef).metadata?.["is_static"], true);

    const tickFn = mod.functions.find((f) => f.name === "Counter.tick");
    assert.ok(tickFn, "instance method emitted");
  });

  test("constructor is emitted as <Class>.constructor", () => {
    const program = encode(`class Point { constructor(x: number) { } }`);
    const mod = userModule(program);
    const ctor = mod.functions.find((f) => f.name === "Point.constructor");
    assert.ok(ctor, "constructor function emitted");
  });
});

describe("encoder std method mappings", () => {
  function callFnFor(src: string): string {
    const program = encode(`function main() { ${src} }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const stmt = main.body!.block!.statements[0];
    const expr = stmt.let ? stmt.let.value! : stmt.expression!;
    return expr.call!.function;
  }

  test("String.replace maps to string_replace_first", () => {
    assert.equal(callFnFor(`const r = "ab".replace("a", "x");`), "string_replace_first");
  });

  test("String.slice maps to string_substring", () => {
    assert.equal(callFnFor(`const r = "abc".slice(1);`), "string_substring");
  });

  test("toString maps through the to_string mapping (self under 'value')", () => {
    // Exercises mapMethodToStd's `toString` branch (selfName: "value"). Fixed
    // bug: `method in STR_METHODS`/`ARR_METHODS` (a plain-object dict) matched
    // "toString" via the *inherited* Object.prototype.toString before ever
    // reaching this dedicated branch, silently returning the native JS
    // Function itself as `fn` instead of falling through — producing a
    // corrupt (non-string) call.function. Now hasOwnProperty-gated (see
    // encoder.ts), so `.toString()` reaches this branch and call.function is
    // the real "to_string" string.
    const program = encode(`function main() { const r = (42).toString(); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.module, "std");
    assert.equal(call.function, "to_string");
    assert.equal(typeof call.function, "string");
    const selfField = call.input!.messageCreation!.fields.find((f) => f.name === "value");
    assert.ok(selfField, "to_string mapping puts the receiver under 'value'");
    assert.equal(selfField!.value.literal!.intValue, "42");
  });

  test("Array.toString also reaches the to_string mapping (not the inherited-toString ARR_METHODS collision)", () => {
    const program = encode(`function main() { const r = [1, 2].toString(); }`);
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const call = main.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "to_string");
    assert.equal(typeof call.function, "string");
  });

  test("Array.reverse maps to list_reversed", () => {
    assert.equal(callFnFor(`const r = [1, 2, 3].reverse();`), "list_reversed");
  });
});

describe("encoder tagged templates", () => {
  test("tagged template with substitution spans collects strings + expressions", () => {
    const program = encode(
      "function main() { const x = 1; const r = tag`a${x}b${x}c`; }",
    );
    const mod = userModule(program);
    const main = mod.functions.find((f) => f.name === "main")!;
    const letR = main.body!.block!.statements.find((s) => s.let?.name === "r");
    assert.ok(letR);
    const call = letR!.let!.value!.call!;
    assert.equal(call.function, "tagged_template");
    const fields = call.input!.messageCreation!.fields;
    const strings = fields.find((f) => f.name === "strings")!;
    const expressions = fields.find((f) => f.name === "expressions")!;
    // head + 2 middle/tail string parts = 3 string literals; 2 substitutions.
    assert.equal(strings.value.literal!.listValue!.elements.length, 3);
    assert.equal(expressions.value.literal!.listValue!.elements.length, 2);
  });
});
