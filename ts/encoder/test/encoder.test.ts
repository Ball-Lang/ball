import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";
import type { Program } from "../src/index.ts";

describe("TsEncoder", () => {
  test("encodes empty function", () => {
    const program = encode(`function main() {}`);
    assert.equal(program.entryModule, "main");
    assert.equal(program.entryFunction, "main");
    const userMod = program.modules.find(m => m.name === "main");
    assert.ok(userMod);
    const mainFn = userMod!.functions.find(f => f.name === "main");
    assert.ok(mainFn);
    assert.ok(mainFn!.body?.block);
  });

  test("encodes numeric literals", () => {
    const program = encode(`function main() { return 42; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    assert.equal(stmts.length, 1);
    const retCall = stmts[0].expression!.call!;
    assert.equal(retCall.function, "return");
  });

  test("encodes binary operations", () => {
    const program = encode(`function main() { const x = 1 + 2; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    assert.equal(stmts.length, 1);
    const letStmt = stmts[0].let!;
    assert.equal(letStmt.name, "x");
    const addCall = letStmt.value!.call!;
    assert.equal(addCall.module, "std");
    assert.equal(addCall.function, "add");
  });

  test("encodes if/else", () => {
    const program = encode(`function main() { if (true) { return 1; } else { return 2; } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const ifExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(ifExpr.call!.function, "if");
  });

  test("encodes for loop", () => {
    const program = encode(`function main() { for (let i = 0; i < 10; i++) { } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const forExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(forExpr.call!.function, "for");
  });

  test("encodes while loop", () => {
    const program = encode(`function main() { while (true) { break; } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const whileExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(whileExpr.call!.function, "while");
  });

  test("encodes arrow functions", () => {
    const program = encode(`function main() { const f = (x: number) => x + 1; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const lambda = mainFn.body!.block!.statements[0].let!.value!.lambda!;
    assert.ok(lambda);
    assert.deepEqual(lambda.metadata?.params, ["x"]);
  });

  test("encodes classes", () => {
    const program = encode(`
      class Point {
        x: number;
        y: number;
        distance(): number { return Math.sqrt(this.x * this.x + this.y * this.y); }
      }
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const typeDef = userMod.typeDefs?.find(t => t.name === "Point");
    assert.ok(typeDef);
    assert.equal(typeDef!.descriptor!.field!.length, 2);
    const distFn = userMod.functions.find(f => f.name === "Point.distance");
    assert.ok(distFn);
  });

  test("encodes interfaces", () => {
    const program = encode(`
      interface Shape { area(): number; width: number; }
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const typeDef = userMod.typeDefs?.find(t => t.name === "Shape");
    assert.ok(typeDef);
    assert.equal(typeDef!.metadata?.kind, "interface");
  });

  test("encodes enums", () => {
    const program = encode(`
      enum Color { Red, Green, Blue }
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const enumDef = userMod.enums?.find(e => e.name === "Color");
    assert.ok(enumDef);
    assert.equal(enumDef!.values.length, 3);
  });

  test("encodes try/catch/finally", () => {
    const program = encode(`
      function main() {
        try { throw new Error("oops"); } catch (e) { } finally { }
      }
    `);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const tryExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(tryExpr.call!.function, "try");
  });

  test("encodes template literals", () => {
    const program = encode("function main() { const s = `hello ${42} world`; }");
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.call);
  });

  test("encodes switch statement", () => {
    const program = encode(`
      function main() {
        switch (x) {
          case 1: break;
          default: break;
        }
      }
    `);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const switchExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(switchExpr.call!.function, "switch");
  });

  test("builds std module with used functions", () => {
    const program = encode(`function main() { const x = 1 + 2; if (x > 0) {} }`);
    const stdMod = program.modules.find(m => m.name === "std");
    assert.ok(stdMod);
    const fnNames = stdMod!.functions.map(f => f.name);
    assert.ok(fnNames.includes("add"));
    assert.ok(fnNames.includes("greater_than"));
    assert.ok(fnNames.includes("if"));
    for (const fn of stdMod!.functions) {
      assert.ok(fn.isBase);
    }
  });

  test("encodes compound assignment", () => {
    const program = encode(`function main() { let x = 10; x += 5; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const assignExpr = mainFn.body!.block!.statements[1].expression!;
    assert.equal(assignExpr.call!.function, "assign");
    const fields = assignExpr.call!.input!.messageCreation!.fields;
    const opField = fields.find(f => f.name === "op");
    assert.equal(opField!.value.literal!.stringValue, "+=");
  });

  test("encodes type aliases", () => {
    const program = encode(`
      type StringOrNumber = string | number;
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const alias = userMod.typeAliases?.find(a => a.name === "StringOrNumber");
    assert.ok(alias);
    assert.equal(alias!.targetType, "string | number");
  });

  test("encodes property access", () => {
    const program = encode(`function main() { const x = obj.field; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.fieldAccess);
    assert.equal(val.fieldAccess!.field, "field");
  });

  test("encodes method calls", () => {
    const program = encode(`function main() { arr.push(1); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const call = mainFn.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "push");
    const selfField = call.input!.messageCreation!.fields.find(f => f.name === "self");
    assert.ok(selfField);
  });

  test("encodes array literals", () => {
    const program = encode(`function main() { const arr = [1, 2, 3]; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.literal?.listValue);
    assert.equal(val.literal!.listValue!.elements.length, 3);
  });

  test("encodes object literals", () => {
    const program = encode(`function main() { const obj = { a: 1, b: "two" }; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.messageCreation);
    assert.equal(val.messageCreation!.fields.length, 2);
  });

  test("encodes object destructuring in variable declaration", () => {
    const program = encode(`function main() { const obj = { a: 1, b: 2 }; const { a, b } = obj; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    // First stmt: const obj = ...
    // Second: const a = obj.a (from destructuring)
    // Third: const b = obj.b (from destructuring)
    assert.equal(stmts.length, 3);
    assert.equal(stmts[1].let!.name, "a");
    assert.ok(stmts[1].let!.value!.fieldAccess);
    assert.equal(stmts[1].let!.value!.fieldAccess!.field, "a");
    assert.equal(stmts[2].let!.name, "b");
    assert.equal(stmts[2].let!.value!.fieldAccess!.field, "b");
  });

  test("encodes array destructuring in variable declaration", () => {
    const program = encode(`function main() { const arr = [1, 2]; const [x, y] = arr; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    assert.equal(stmts.length, 3);
    assert.equal(stmts[1].let!.name, "x");
    assert.equal(stmts[1].let!.value!.call!.function, "index");
    assert.equal(stmts[2].let!.name, "y");
    assert.equal(stmts[2].let!.value!.call!.function, "index");
  });

  test("encodes optional chaining property access", () => {
    const program = encode(`function main() { const x = obj?.prop; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.equal(val.call!.function, "optional_access");
    assert.equal(val.call!.module, "ts_std");
  });

  test("encodes optional chaining method call", () => {
    const program = encode(`function main() { const x = obj?.method(1); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.equal(val.call!.function, "optional_call");
    assert.equal(val.call!.module, "ts_std");
  });

  test("encodes rest parameters", () => {
    const program = encode(`function sum(...nums: number[]): number { return 0; }`);
    const userMod = program.modules.find(m => m.name === "main")!;
    const fn = userMod.functions.find(f => f.name === "sum")!;
    assert.equal(fn.metadata!.rest_param, "nums");
  });

  test("encodes default parameter values", () => {
    const program = encode(`function greet(name: string = "world"): string { return name; }`);
    const userMod = program.modules.find(m => m.name === "main")!;
    const fn = userMod.functions.find(f => f.name === "greet")!;
    assert.ok(fn.metadata!.param_defaults);
    assert.equal((fn.metadata!.param_defaults as Record<string, string>).name, '"world"');
  });

  test("encodes computed property names", () => {
    const program = encode(`function main() { const key = "x"; const obj = { [key]: 42 }; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const objVal = mainFn.body!.block!.statements[1].let!.value!;
    assert.ok(objVal.messageCreation);
    const computedField = objVal.messageCreation!.fields.find(f => f.name === "__computed");
    assert.ok(computedField);
    assert.equal(computedField!.value.call!.function, "computed_property");
    assert.equal(computedField!.value.call!.module, "ts_std");
  });

  test("encodes tagged template literals", () => {
    const program = encode("function main() { const x = tag`hello ${42} world`; }");
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.equal(val.call!.function, "tagged_template");
    assert.equal(val.call!.module, "ts_std");
  });

  test("encodes class field initializers", () => {
    const program = encode(`
      class Foo { x: number = 5; y: string = "hello"; }
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const typeDef = userMod.typeDefs?.find(t => t.name === "Foo")!;
    assert.ok(typeDef.metadata!.field_initializers);
    const inits = typeDef.metadata!.field_initializers as Record<string, string>;
    assert.equal(inits.x, "5");
    assert.equal(inits.y, '"hello"');
  });

  test("encodes static members", () => {
    const program = encode(`
      class Util {
        static count: number = 0;
        static create(): Util { return new Util(); }
      }
      function main() {}
    `);
    const userMod = program.modules.find(m => m.name === "main")!;
    const createFn = userMod.functions.find(f => f.name === "Util.create")!;
    assert.equal(createFn.metadata!.is_static, true);
    // Static field metadata is in the field label (serialized as JSON)
    const typeDef = userMod.typeDefs?.find(t => t.name === "Util")!;
    const countField = typeDef.descriptor!.field!.find(f => f.name === "count")!;
    const fieldMeta = JSON.parse(countField.label!);
    assert.equal(fieldMeta.is_static, true);
  });

  test("encodes async functions", () => {
    const program = encode(`async function fetchData(): Promise<string> { return "data"; }`);
    const userMod = program.modules.find(m => m.name === "main")!;
    const fn = userMod.functions.find(f => f.name === "fetchData")!;
    assert.equal(fn.metadata!.is_async, true);
  });

  test("encodes async arrow functions", () => {
    const program = encode(`function main() { const f = async () => 42; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const lambda = mainFn.body!.block!.statements[0].let!.value!.lambda!;
    assert.equal(lambda.metadata!.is_async, true);
  });

  test("encodes for-in loops as for_in", () => {
    const program = encode(`function main() { for (const key in obj) { } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const forInExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(forInExpr.call!.function, "for_in");
  });

  test("encodes for-of loops as for_each", () => {
    const program = encode(`function main() { for (const item of arr) { } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const forOfExpr = mainFn.body!.block!.statements[0].expression!;
    assert.equal(forOfExpr.call!.function, "for_each");
  });

  test("encodes void expressions as null literal", () => {
    const program = encode(`function main() { const x = void 0; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.literal);
    assert.equal(val.literal!.stringValue, "");
  });

  test("encodes destructuring with defaults", () => {
    const program = encode(`function main() { const { a = 10, b = 20 } = obj; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    assert.equal(stmts.length, 2);
    // Each should use null_coalesce for the default
    assert.equal(stmts[0].let!.name, "a");
    assert.equal(stmts[0].let!.value!.call!.function, "null_coalesce");
    assert.equal(stmts[1].let!.name, "b");
    assert.equal(stmts[1].let!.value!.call!.function, "null_coalesce");
  });

  test("encodes spread in object literals", () => {
    const program = encode(`function main() { const obj = { ...other, x: 1 }; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.messageCreation);
    const spreadField = val.messageCreation!.fields.find(f => f.name === "__spread");
    assert.ok(spreadField);
    assert.equal(spreadField!.value.call!.function, "spread");
  });

  test("encodes lambda rest parameters", () => {
    const program = encode(`function main() { const f = (...args: number[]) => args; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const lambda = mainFn.body!.block!.statements[0].let!.value!.lambda!;
    assert.equal(lambda.metadata!.rest_param, "args");
  });

  test("encodes lambda default parameters", () => {
    const program = encode(`function main() { const f = (x: number = 5) => x; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const lambda = mainFn.body!.block!.statements[0].let!.value!.lambda!;
    assert.ok(lambda.metadata!.param_defaults);
    assert.equal((lambda.metadata!.param_defaults as Record<string, string>).x, "5");
  });

  test("full encode produces valid Program structure", () => {
    const source = `
      function add(a: number, b: number): number {
        return a + b;
      }
      function main() {
        const result = add(3, 4);
      }
    `;
    const program = encode(source);
    assert.ok(program.modules.length >= 2);
    assert.equal(program.entryModule, "main");
    assert.equal(program.entryFunction, "main");
    const stdMod = program.modules.find(m => m.name === "std");
    assert.ok(stdMod);
    for (const fn of stdMod!.functions) {
      assert.ok(fn.isBase, `std function ${fn.name} should be base`);
      assert.ok(!fn.body, `std function ${fn.name} should have no body`);
    }
  });
});
