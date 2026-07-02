/**
 * Compiler tests for top-level Ball declarations that the Program fixture
 * suites don't exercise directly: type aliases and top-level variables.
 *
 * The IR shapes here mirror what the TS encoder emits (verified against
 * `@ball-lang/encoder` output) so the compiler's declaration-emit paths run.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";

function programWith(mod: Partial<Program["modules"][number]>): Program {
  return {
    name: "decls",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      {
        name: "main",
        functions: [
          { name: "main", body: { literal: { intValue: 1 } } },
          ...(mod.functions ?? []),
        ],
        typeAliases: mod.typeAliases,
        enums: mod.enums,
        typeDefs: mod.typeDefs,
      },
    ],
  };
}

describe("compiler — type aliases", () => {
  test("emits a type alias declaration", () => {
    const program = programWith({
      typeAliases: [{ name: "Id", targetType: "string" }],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /type Id = string/);
  });
});

describe("compiler — enums (Module.enums[], #120)", () => {
  test("emits an enum class from an EnumDescriptorProto entry", () => {
    const program = programWith({
      enums: [
        {
          name: "Color",
          value: [
            { name: "red", number: 0 },
            { name: "green", number: 1 },
            { name: "blue", number: 2 },
          ],
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /class Color/);
    assert.match(ts, /static readonly red = new Color\(0, 'red'\)/);
    assert.match(ts, /static readonly blue = new Color\(2, 'blue'\)/);
    assert.match(ts, /static readonly values: Color\[\] = \[Color\.red, Color\.green, Color\.blue\]/);
  });

  test("strips the module qualifier from Dart-encoder enum names", () => {
    const program = programWith({
      enums: [
        { name: "main:Status", value: [{ name: "ok", number: 0 }] },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /class Status/);
    assert.match(ts, /static readonly ok = new Status\(0, 'ok'\)/);
  });

  test("does not duplicate a typeDef class of the same name", () => {
    const program = programWith({
      typeDefs: [{ name: "Color", metadata: { kind: "enum", values: ["red"] } }],
      enums: [{ name: "Color", value: [{ name: "red", number: 0 }] }],
    });
    const ts = compile(program, { includePreamble: false });
    const matches = ts.match(/class Color/g) ?? [];
    assert.equal(matches.length, 1, "Color must be declared exactly once");
  });
});

describe("compiler — top-level variables", () => {
  test("emits a top_level_variable as an initialized const/let", () => {
    const program = programWith({
      functions: [
        {
          name: "PI",
          body: { literal: { doubleValue: 3.14 } },
          metadata: { kind: "top_level_variable" },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /PI/);
    assert.match(ts, /3\.14/);
  });
});
