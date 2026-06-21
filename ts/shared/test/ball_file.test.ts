/**
 * Tests for the self-describing ball-file envelope helpers in src/ball_file.ts.
 *
 * Exercises the JSON + binary encode/decode round-trips for both Program and
 * Module envelopes, the plain proto3-JSON unwrap, and every BallFileFormatError
 * error path. These are pure functions over the @bufbuild/protobuf runtime, so
 * the tests are deterministic and need no engine/compiler.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { create } from "@bufbuild/protobuf";
import {
  ProgramSchema,
  ModuleSchema,
  FunctionDefinitionSchema,
  ExpressionSchema,
  LiteralSchema,
  type Program,
  type Module,
} from "../gen/ball/v1/ball_pb.js";
import {
  PROGRAM_TYPE_URL,
  MODULE_TYPE_URL,
  BallFileFormatError,
  unwrapBallFileJson,
  decodeBallFileJson,
  decodeProgramJson,
  decodeModuleJson,
  decodeBallFileBinary,
  decodeProgramBinary,
  decodeModuleBinary,
  encodeProgramJson,
  encodeModuleJson,
  encodeProgramBinary,
  encodeModuleBinary,
} from "../src/ball_file.ts";

// ── Fixtures ────────────────────────────────────────────────────────────────

function makeProgram(): Program {
  return create(ProgramSchema, {
    name: "demo",
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
                  value: { case: "stringValue", value: "hi" },
                }),
              },
            }),
          }),
        ],
      }),
    ],
  });
}

function makeModule(): Module {
  return create(ModuleSchema, {
    name: "mymod",
    functions: [
      create(FunctionDefinitionSchema, { name: "noop", isBase: true }),
    ],
  });
}

// ── Constants ─────────────────────────────────────────────────────────────

describe("ball_file type URL constants", () => {
  test("PROGRAM_TYPE_URL / MODULE_TYPE_URL", () => {
    assert.equal(PROGRAM_TYPE_URL, "type.googleapis.com/ball.v1.Program");
    assert.equal(MODULE_TYPE_URL, "type.googleapis.com/ball.v1.Module");
  });
});

// ── BallFileFormatError ─────────────────────────────────────────────────────

describe("BallFileFormatError", () => {
  test("is an Error with the right name", () => {
    const e = new BallFileFormatError("boom");
    assert.ok(e instanceof Error);
    assert.ok(e instanceof BallFileFormatError);
    assert.equal(e.name, "BallFileFormatError");
    assert.equal(e.message, "boom");
  });
});

// ── JSON encode → decode round-trips ────────────────────────────────────────

describe("JSON encode/decode round-trips", () => {
  test("Program JSON round-trip via encodeProgramJson + decodeProgramJson", () => {
    const program = makeProgram();
    const json = encodeProgramJson(program);
    assert.equal(json["@type"], PROGRAM_TYPE_URL);
    assert.equal(json["name"], "demo");

    const decoded = decodeProgramJson(json);
    assert.equal(decoded.name, "demo");
    assert.equal(decoded.entryModule, "main");
    assert.equal(decoded.modules[0].functions[0].name, "run");
  });

  test("Module JSON round-trip via encodeModuleJson + decodeModuleJson", () => {
    const mod = makeModule();
    const json = encodeModuleJson(mod);
    assert.equal(json["@type"], MODULE_TYPE_URL);
    assert.equal(json["name"], "mymod");

    const decoded = decodeModuleJson(json);
    assert.equal(decoded.name, "mymod");
    assert.equal(decoded.functions[0].name, "noop");
    assert.equal(decoded.functions[0].isBase, true);
  });

  test("decodeBallFileJson discriminates Program vs Module", () => {
    const programFile = decodeBallFileJson(encodeProgramJson(makeProgram()));
    assert.equal(programFile.kind, "program");
    if (programFile.kind === "program") {
      assert.equal(programFile.program.name, "demo");
    }

    const moduleFile = decodeBallFileJson(encodeModuleJson(makeModule()));
    assert.equal(moduleFile.kind, "module");
    if (moduleFile.kind === "module") {
      assert.equal(moduleFile.module.name, "mymod");
    }
  });
});

// ── unwrapBallFileJson ──────────────────────────────────────────────────────

describe("unwrapBallFileJson", () => {
  test("strips @type and keeps the body for a Program envelope", () => {
    const body = unwrapBallFileJson(encodeProgramJson(makeProgram()));
    assert.equal((body as Record<string, unknown>)["@type"], undefined);
    assert.equal((body as Record<string, unknown>)["name"], "demo");
  });

  test("accepts a Module envelope", () => {
    const body = unwrapBallFileJson(encodeModuleJson(makeModule()));
    assert.equal((body as Record<string, unknown>)["@type"], undefined);
    assert.equal((body as Record<string, unknown>)["name"], "mymod");
  });

  test("throws on non-object input", () => {
    assert.throws(() => unwrapBallFileJson(null), BallFileFormatError);
    assert.throws(() => unwrapBallFileJson(42 as unknown), BallFileFormatError);
    assert.throws(() => unwrapBallFileJson([1, 2] as unknown), BallFileFormatError);
  });

  test("throws when @type is missing", () => {
    assert.throws(
      () => unwrapBallFileJson({ name: "x" }),
      /not self-describing/,
    );
  });

  test("throws when @type is not a string", () => {
    assert.throws(
      () => unwrapBallFileJson({ "@type": 7 }),
      /not self-describing/,
    );
  });

  test("throws on unknown @type URL", () => {
    assert.throws(
      () => unwrapBallFileJson({ "@type": "type.googleapis.com/ball.v1.Widget" }),
      /unknown ball file @type/,
    );
  });
});

// ── decode JSON error paths ─────────────────────────────────────────────────

describe("decode JSON error paths", () => {
  test("decodeBallFileJson rejects non-object", () => {
    assert.throws(() => decodeBallFileJson(null), BallFileFormatError);
    assert.throws(() => decodeBallFileJson("nope" as unknown), BallFileFormatError);
    assert.throws(() => decodeBallFileJson([] as unknown), BallFileFormatError);
  });

  test("decodeBallFileJson rejects missing @type", () => {
    assert.throws(() => decodeBallFileJson({ name: "x" }), /not self-describing/);
  });

  test("decodeProgramJson rejects a Module envelope", () => {
    assert.throws(
      () => decodeProgramJson(encodeModuleJson(makeModule())),
      /expected a Program/,
    );
  });

  test("decodeModuleJson rejects a Program envelope", () => {
    assert.throws(
      () => decodeModuleJson(encodeProgramJson(makeProgram())),
      /expected a Module/,
    );
  });
});

// ── Binary encode → decode round-trips ──────────────────────────────────────

describe("binary encode/decode round-trips", () => {
  test("Program binary round-trip", () => {
    const bytes = encodeProgramBinary(makeProgram());
    assert.ok(bytes instanceof Uint8Array);
    assert.ok(bytes.length > 0);

    const file = decodeBallFileBinary(bytes);
    assert.equal(file.kind, "program");

    const program = decodeProgramBinary(bytes);
    assert.equal(program.name, "demo");
    assert.equal(program.modules[0].functions[0].name, "run");
  });

  test("Module binary round-trip", () => {
    const bytes = encodeModuleBinary(makeModule());
    assert.ok(bytes instanceof Uint8Array);

    const file = decodeBallFileBinary(bytes);
    assert.equal(file.kind, "module");

    const mod = decodeModuleBinary(bytes);
    assert.equal(mod.name, "mymod");
  });

  test("decodeProgramBinary rejects a Module binary", () => {
    const bytes = encodeModuleBinary(makeModule());
    assert.throws(() => decodeProgramBinary(bytes), /expected a Program/);
  });

  test("decodeModuleBinary rejects a Program binary", () => {
    const bytes = encodeProgramBinary(makeProgram());
    assert.throws(() => decodeModuleBinary(bytes), /expected a Module/);
  });

  test("decodeBallFileBinary rejects an unknown type URL", () => {
    // A google.protobuf.Any with an unrecognized type_url. Field 1 (type_url)
    // is a string; encode "x" as the URL so neither Program nor Module matches.
    // tag for field 1, wire type 2 (length-delimited) = 0x0A, len 1, 'x' = 0x78.
    const bytes = new Uint8Array([0x0a, 0x01, 0x78]);
    assert.throws(() => decodeBallFileBinary(bytes), /unknown ball file type URL/);
  });
});
