/**
 * Tests for the generated protobuf-es bindings from ball.proto.
 *
 * Verifies that the @bufbuild/protobuf runtime provides the API surface
 * needed by the Ball TS engine and tools:
 *
 *   Dart protobuf API          ->  protobuf-es v2 equivalent
 *   ─────────────────────────────────────────────────────────
 *   expression.whichExpr()     ->  expression.expr.case
 *   literal.whichValue()       ->  literal.value.case
 *   statement.whichStmt()      ->  statement.stmt.case
 *   func.hasBody()             ->  func.body !== undefined
 *   func.hasMetadata()         ->  func.metadata !== undefined
 *   metadata.fields['key']     ->  metadata?.['key']  (JsonObject)
 *   val.whichKind()            ->  typeof metadata?.['key']
 *   program.writeToBuffer()    ->  toBinary(ProgramSchema, program)
 *   Program.fromBuffer(bytes)  ->  fromBinary(ProgramSchema, bytes)
 *   Program.fromJson(json)     ->  fromJson(ProgramSchema, json)
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  create,
  fromJson,
  toJson,
  toBinary,
  fromBinary,
} from "@bufbuild/protobuf";
import {
  ProgramSchema,
  ModuleSchema,
  FunctionDefinitionSchema,
  ExpressionSchema,
  LiteralSchema,
  FunctionCallSchema,
  BlockSchema,
  StatementSchema,
  LetBindingSchema,
  ReferenceSchema,
  FieldAccessSchema,
  MessageCreationSchema,
  FieldValuePairSchema,
  ListLiteralSchema,
} from "../gen/ball/v1/ball_pb.js";
import type {
  Program,
  Module,
  FunctionDefinition,
  Expression,
  Literal,
  FunctionCall,
  Block,
  Statement,
} from "../gen/ball/v1/ball_pb.js";

function findRepoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    if (existsSync(resolve(dir, "proto", "ball", "v1", "ball.proto")))
      return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error("repo root not found");
    dir = parent;
  }
}

describe("protobuf-es generated bindings", () => {
  // ── Message creation ────────────────────────────────────────────
  test("create messages with defaults", () => {
    const fn = create(FunctionDefinitionSchema);
    assert.equal(fn.name, "");
    assert.equal(fn.inputType, "");
    assert.equal(fn.outputType, "");
    assert.equal(fn.isBase, false);
    assert.equal(fn.body, undefined);
    assert.equal(fn.metadata, undefined);
    assert.equal(fn.description, "");
  });

  test("create messages with initial values", () => {
    const fn = create(FunctionDefinitionSchema, {
      name: "print",
      isBase: true,
      inputType: "PrintInput",
    });
    assert.equal(fn.name, "print");
    assert.equal(fn.isBase, true);
    assert.equal(fn.inputType, "PrintInput");
    assert.equal(fn.body, undefined);
  });

  // ── Oneof discriminated unions ──────────────────────────────────
  test("Expression oneof - call", () => {
    const expr = create(ExpressionSchema, {
      expr: {
        case: "call",
        value: create(FunctionCallSchema, {
          module: "std",
          function: "print",
        }),
      },
    });
    assert.equal(expr.expr.case, "call");
    assert.equal(expr.expr.value?.module, "std");
    assert.equal(expr.expr.value?.function, "print");
  });

  test("Expression oneof - literal", () => {
    const expr = create(ExpressionSchema, {
      expr: {
        case: "literal",
        value: create(LiteralSchema, {
          value: { case: "stringValue", value: "hello" },
        }),
      },
    });
    assert.equal(expr.expr.case, "literal");
    assert.equal(expr.expr.value?.value.case, "stringValue");
    assert.equal(expr.expr.value?.value.value, "hello");
  });

  test("Expression oneof - reference", () => {
    const expr = create(ExpressionSchema, {
      expr: {
        case: "reference",
        value: create(ReferenceSchema, { name: "input" }),
      },
    });
    assert.equal(expr.expr.case, "reference");
    assert.equal(expr.expr.value?.name, "input");
  });

  test("Expression oneof - block", () => {
    const expr = create(ExpressionSchema, {
      expr: {
        case: "block",
        value: create(BlockSchema, {
          statements: [
            create(StatementSchema, {
              stmt: {
                case: "let",
                value: create(LetBindingSchema, {
                  name: "x",
                  value: create(ExpressionSchema, {
                    expr: {
                      case: "literal",
                      value: create(LiteralSchema, {
                        value: { case: "intValue", value: 42n },
                      }),
                    },
                  }),
                }),
              },
            }),
          ],
          result: create(ExpressionSchema, {
            expr: {
              case: "reference",
              value: create(ReferenceSchema, { name: "x" }),
            },
          }),
        }),
      },
    });
    assert.equal(expr.expr.case, "block");
    const block = expr.expr.value!;
    assert.equal(block.statements.length, 1);
    assert.equal(block.statements[0].stmt.case, "let");
    assert.equal(block.result?.expr.case, "reference");
  });

  test("Expression oneof - not set", () => {
    const expr = create(ExpressionSchema);
    assert.equal(expr.expr.case, undefined);
    assert.equal(expr.expr.value, undefined);
  });

  test("Literal oneof variants", () => {
    const intLit = create(LiteralSchema, {
      value: { case: "intValue", value: 42n },
    });
    assert.equal(intLit.value.case, "intValue");
    assert.equal(intLit.value.value, 42n);

    const doubleLit = create(LiteralSchema, {
      value: { case: "doubleValue", value: 3.14 },
    });
    assert.equal(doubleLit.value.case, "doubleValue");
    assert.equal(doubleLit.value.value, 3.14);

    const boolLit = create(LiteralSchema, {
      value: { case: "boolValue", value: true },
    });
    assert.equal(boolLit.value.case, "boolValue");
    assert.equal(boolLit.value.value, true);
  });

  test("Statement oneof", () => {
    const letStmt = create(StatementSchema, {
      stmt: {
        case: "let",
        value: create(LetBindingSchema, { name: "x" }),
      },
    });
    assert.equal(letStmt.stmt.case, "let");

    const exprStmt = create(StatementSchema, {
      stmt: {
        case: "expression",
        value: create(ExpressionSchema),
      },
    });
    assert.equal(exprStmt.stmt.case, "expression");
  });

  // ── Presence checking ───────────────────────────────────────────
  test("presence checks for optional message fields", () => {
    const withBody = create(FunctionDefinitionSchema, {
      name: "test",
      body: create(ExpressionSchema),
    });
    assert.notEqual(withBody.body, undefined);

    const withoutBody = create(FunctionDefinitionSchema, {
      name: "test",
      isBase: true,
    });
    assert.equal(withoutBody.body, undefined);
  });

  test("metadata presence", () => {
    const withMeta = create(FunctionDefinitionSchema, {
      name: "test",
      metadata: { kind: "method" },
    });
    assert.notEqual(withMeta.metadata, undefined);
    assert.equal(withMeta.metadata?.["kind"], "method");

    const withoutMeta = create(FunctionDefinitionSchema, { name: "test" });
    assert.equal(withoutMeta.metadata, undefined);
  });

  // ── Metadata (google.protobuf.Struct) access ────────────────────
  test("metadata fields access (replaces Dart .fields[key].whichKind())", () => {
    const fn = create(FunctionDefinitionSchema, {
      name: "test",
      metadata: {
        kind: "method",
        params: ["a", "b"],
        isAsync: true,
        count: 42,
        nested: { inner: "value" },
      },
    });

    // Direct access (replaces fn.metadata.fields['key'].stringValue)
    assert.equal(fn.metadata?.["kind"], "method");
    assert.deepEqual(fn.metadata?.["params"], ["a", "b"]);
    assert.equal(fn.metadata?.["isAsync"], true);
    assert.equal(fn.metadata?.["count"], 42);
    assert.deepEqual(fn.metadata?.["nested"], { inner: "value" });

    // Type checking (replaces .whichKind())
    assert.equal(typeof fn.metadata?.["kind"], "string");
    assert.equal(typeof fn.metadata?.["isAsync"], "boolean");
    assert.equal(typeof fn.metadata?.["count"], "number");
    assert.equal(Array.isArray(fn.metadata?.["params"]), true);
    assert.equal(typeof fn.metadata?.["nested"], "object");

    // Missing key returns undefined (replaces Dart null)
    assert.equal(fn.metadata?.["nonexistent"], undefined);
  });

  // ── Repeated fields ─────────────────────────────────────────────
  test("repeated fields default to empty array", () => {
    const mod = create(ModuleSchema);
    assert.equal(mod.functions.length, 0);
    assert.equal(mod.typeDefs.length, 0);
    assert.equal(mod.enums.length, 0);
    assert.equal(mod.moduleImports.length, 0);
    assert.equal(mod.typeAliases.length, 0);
    assert.equal(mod.moduleConstants.length, 0);
  });

  // ── JSON serialization ──────────────────────────────────────────
  test("fromJson / toJson roundtrip", () => {
    const json = {
      name: "test",
      entryModule: "main",
      entryFunction: "run",
      modules: [
        {
          name: "main",
          functions: [
            {
              name: "run",
              body: {
                call: {
                  module: "std",
                  function: "print",
                  input: { literal: { stringValue: "hello" } },
                },
              },
            },
          ],
        },
      ],
    };

    const program = fromJson(ProgramSchema, json);
    assert.equal(program.name, "test");
    assert.equal(program.modules[0].name, "main");
    assert.equal(program.modules[0].functions[0].body?.expr.case, "call");
    const call = program.modules[0].functions[0].body?.expr.value as FunctionCall;
    assert.equal(call.module, "std");
    assert.equal(call.function, "print");

    const roundtripped = toJson(ProgramSchema, program);
    const program2 = fromJson(ProgramSchema, roundtripped);
    assert.equal(program2.name, "test");
    assert.equal(program2.modules[0].functions[0].body?.expr.case, "call");
  });

  // ── Binary serialization ────────────────────────────────────────
  test("toBinary / fromBinary roundtrip", () => {
    const program = create(ProgramSchema, {
      name: "test",
      entryModule: "main",
      entryFunction: "run",
      modules: [
        create(ModuleSchema, {
          name: "main",
          functions: [
            create(FunctionDefinitionSchema, {
              name: "run",
              body: create(ExpressionSchema, {
                expr: {
                  case: "literal",
                  value: create(LiteralSchema, {
                    value: { case: "intValue", value: 42n },
                  }),
                },
              }),
            }),
          ],
        }),
      ],
    });

    const bytes = toBinary(ProgramSchema, program);
    assert.ok(bytes instanceof Uint8Array);
    assert.ok(bytes.length > 0);

    const restored = fromBinary(ProgramSchema, bytes);
    assert.equal(restored.name, "test");
    assert.equal(restored.modules[0].functions[0].body?.expr.case, "literal");
    assert.equal(
      (restored.modules[0].functions[0].body?.expr.value as Literal)?.value
        .value,
      42n,
    );
  });

  // ── Load real conformance test programs ─────────────────────────
  test("load conformance test programs via fromJson", () => {
    const root = findRepoRoot();
    const conformanceDir = resolve(root, "tests/conformance");
    if (!existsSync(conformanceDir)) {
      console.log("  skipped: conformance dir not found");
      return;
    }

    const files = readdirSync(conformanceDir)
      .filter((f) => f.endsWith(".ball.json"))
      .sort();

    let loaded = 0;
    for (const file of files) {
      const raw = JSON.parse(
        readFileSync(resolve(conformanceDir, file), "utf8"),
      );
      const program = fromJson(ProgramSchema, raw);

      // Basic structural checks
      assert.ok(program.modules.length > 0, `${file}: has modules`);
      assert.ok(program.entryModule.length > 0, `${file}: has entryModule`);
      assert.ok(
        program.entryFunction.length > 0,
        `${file}: has entryFunction`,
      );

      // Find entry function
      const entryMod = program.modules.find(
        (m) => m.name === program.entryModule,
      );
      assert.ok(entryMod, `${file}: entry module exists`);
      const entryFn = entryMod!.functions.find(
        (f) => f.name === program.entryFunction,
      );
      assert.ok(entryFn, `${file}: entry function exists`);
      assert.notEqual(
        entryFn!.body,
        undefined,
        `${file}: entry function has body`,
      );

      loaded++;
    }

    console.log(`  loaded ${loaded} conformance programs successfully`);
  });
});
