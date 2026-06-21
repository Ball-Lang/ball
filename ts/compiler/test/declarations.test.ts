/**
 * Compiler tests for top-level Ball declarations that the Program fixture
 * suites don't exercise directly: type aliases and top-level variables.
 *
 * The IR shapes here mirror what the TS encoder emits (verified against
 * `@ball-lang/encoder` output) so the compiler's declaration-emit paths run.
 *
 * NOTE: enum compilation is intentionally not asserted here — the TS compiler
 * currently emits nothing for a Module's `enums[]` (a known gap; see PR
 * description). Enums encode fine but are dropped at compile time.
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
