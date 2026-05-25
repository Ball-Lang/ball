import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode, encodeWithWarnings, EncodeError } from "../src/index.ts";
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
    // Null is an EMPTY literal (matches the Dart encoder), not stringValue "".
    assert.equal(val.literal!.stringValue, undefined);
    assert.equal(val.literal!.intValue, undefined);
    assert.equal(val.literal!.boolValue, undefined);
  });

  test("encodes null/undefined as empty literal (matches Dart encoder)", () => {
    const program = encode(`function main() { const a = null; const b = undefined; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const stmts = mainFn.body!.block!.statements;
    for (const idx of [0, 1]) {
      const val = stmts[idx].let!.value!;
      assert.ok(val.literal, `stmt ${idx} should be a literal`);
      // Empty oneof: no value field set => engine reads it as null.
      assert.equal(val.literal!.stringValue, undefined);
      assert.equal(val.literal!.reference, undefined);
    }
    // `undefined` must NOT round-trip to an unbound reference.
    assert.equal(stmts[1].let!.value!.reference, undefined);
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

  test("encodes call of a non-identifier callee as __invoke", () => {
    // The callee is a call expression result, so neither identifier nor
    // property-access — must route through __invoke with a `callee` field.
    const program = encode(`function main() { getFn()(1, 2); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const call = mainFn.body!.block!.statements[0].expression!.call!;
    assert.equal(call.function, "__invoke");
    const fields = call.input!.messageCreation!.fields;
    const callee = fields.find(f => f.name === "callee");
    assert.ok(callee, "should carry callee field");
    assert.equal(callee!.value.call!.function, "getFn");
    assert.ok(fields.find(f => f.name === "arg0"));
    assert.ok(fields.find(f => f.name === "arg1"));
  });

  test("encodes C-style for loop with init/condition/update", () => {
    const program = encode(`function main() { for (let i = 0; i < 10; i++) { x(); } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const forCall = mainFn.body!.block!.statements[0].expression!.call!;
    assert.equal(forCall.function, "for");
    const fields = forCall.input!.messageCreation!.fields;
    assert.equal(fields.find(f => f.name === "variable")!.value.literal!.stringValue, "i");
    assert.ok(fields.find(f => f.name === "start"));
    // condition/update/body are lazily-evaluated lambdas.
    assert.ok(fields.find(f => f.name === "condition")!.value.lambda);
    assert.ok(fields.find(f => f.name === "update")!.value.lambda);
    assert.ok(fields.find(f => f.name === "body")!.value.lambda);
  });

  test("encodes C-style for loop with expression initializer (non-decl)", () => {
    const program = encode(`function main() { let i; for (i = 0; i < 3; i++) {} }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const forCall = mainFn.body!.block!.statements[1].expression!.call!;
    assert.equal(forCall.function, "for");
    const fields = forCall.input!.messageCreation!.fields;
    // No variable declaration => `init` lambda instead of `variable`/`start`.
    assert.ok(fields.find(f => f.name === "init")!.value.lambda);
  });

  test("encodes do/while loop as do_while with lazy condition", () => {
    const program = encode(`function main() { do { x(); } while (cond); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const doCall = mainFn.body!.block!.statements[0].expression!.call!;
    assert.equal(doCall.function, "do_while");
    const fields = doCall.input!.messageCreation!.fields;
    assert.ok(fields.find(f => f.name === "condition")!.value.lambda, "condition is lazy");
    assert.ok(fields.find(f => f.name === "body")!.value.lambda);
  });

  test("encodes labeled break and continue", () => {
    const program = encode(`
      function main() {
        outer: for (const a of xs) {
          for (const b of ys) {
            if (a) break outer;
            if (b) continue outer;
          }
        }
      }
    `);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const labeled = mainFn.body!.block!.statements[0].expression!.call!;
    assert.equal(labeled.function, "labeled");
    const labFields = labeled.input!.messageCreation!.fields;
    assert.equal(labFields.find(f => f.name === "label")!.value.literal!.stringValue, "outer");
    // Find the break/continue deeper in the tree by serializing.
    const json = JSON.stringify(program);
    assert.ok(json.includes('"break"'));
    assert.ok(json.includes('"continue"'));
    // The labeled break/continue carry a `label` literal of "outer".
    const labelCount = (json.match(/"outer"/g) ?? []).length;
    assert.ok(labelCount >= 3, `expected outer label on the labeled stmt + break + continue, got ${labelCount}`);
  });

  test("encodes plain break/continue without a label field", () => {
    const program = encode(`function main() { while (true) { break; } for (const x of xs) { continue; } }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    // break is the result of the while body's block.
    const json = JSON.stringify(program);
    assert.ok(json.includes('"break"'));
    assert.ok(json.includes('"continue"'));
  });

  test("encodes new Foo(args) as messageCreation", () => {
    const program = encode(`function main() { const p = new Point(1, 2); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.messageCreation);
    assert.equal(val.messageCreation!.typeName, "Point");
    assert.equal(val.messageCreation!.fields.length, 2);
    assert.equal(val.messageCreation!.fields[0].name, "arg0");
    assert.equal(val.messageCreation!.fields[1].name, "arg1");
  });

  test("encodes new Foo() with no args", () => {
    const program = encode(`function main() { const p = new Empty(); }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const val = mainFn.body!.block!.statements[0].let!.value!;
    assert.ok(val.messageCreation);
    assert.equal(val.messageCreation!.typeName, "Empty");
    assert.equal(val.messageCreation!.fields.length, 0);
  });

  test("does not emit numeric add for provably-string concat (literal)", () => {
    const program = encode(`function main() { const s = "a" + b; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const call = mainFn.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "concat");
  });

  test("emits polymorphic add for string-var + string-var (engine coerces)", () => {
    // Neither operand is provably a string => fall through to std.add, which
    // the engine resolves polymorphically. Must NOT guess concat or numeric.
    const program = encode(`function main() { const s = a + b; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const call = mainFn.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "add");
    assert.equal(call.module, "std");
  });

  test("nested provable concat propagates: (a + 'x') + b", () => {
    const program = encode(`function main() { const s = (a + "x") + b; }`);
    const mainFn = program.modules.find(m => m.name === "main")!.functions.find(f => f.name === "main")!;
    const call = mainFn.body!.block!.statements[0].let!.value!.call!;
    assert.equal(call.function, "concat");
  });

  test("strict mode throws EncodeError on unhandled construct", () => {
    // A `with` statement has no Ball mapping => warn() => throws in strict.
    assert.throws(
      () => encode(`function main() { with (obj) { x; } }`, { strict: true }),
      (err: unknown) => {
        assert.ok(err instanceof EncodeError);
        assert.ok((err as EncodeError).warnings.length > 0);
        return true;
      },
    );
  });

  test("non-strict mode collects warnings without throwing", () => {
    const { program, warnings } = encodeWithWarnings(`function main() { with (obj) { x; } }`);
    assert.ok(program.modules.length >= 1);
    assert.ok(warnings.length > 0, "should accumulate warnings for unhandled `with`");
  });

  test("clean source produces no warnings", () => {
    const { warnings } = encodeWithWarnings(`function main() { const x = 1 + 2; return x; }`);
    assert.equal(warnings.length, 0);
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
