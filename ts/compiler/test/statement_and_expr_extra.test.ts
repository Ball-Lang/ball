/**
 * Coverage for remaining statement/expression-emission gaps in compiler.ts:
 *   - Block-expression-as-statement hoisting with shadow-rename on name
 *     collision (emitStatement/collectHoistedLetNames, ~3059-3130).
 *   - Collection-literal control elements: collection_if's else arm, a map
 *     spread element, and a C-style collection_for (~3792-3901).
 *   - compileMessageCreation's module-qualified identifier resolution
 *     (`"module:ident"` typeName routed to a free function or a same-class
 *     method rather than an inert tagged object), and the empty-typeName
 *     plain-object-literal path (~3938-4005).
 *   - compileCall's `self`-field routing special cases used by the
 *     StringBuffer shim (`write`/`writeCharCode`) and `Map.fromEntries`
 *     (~4190-4210).
 *   - Control-flow text fallbacks: a malformed switch (missing subject/
 *     cases) and a labeled statement (~3163-3206).
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program } from "../src/index.ts";

const ref = (name: string): Expression => ({ reference: { name } });
const lit = (v: string | number | boolean): Expression =>
  typeof v === "string" ? { literal: { stringValue: v } }
    : typeof v === "boolean" ? { literal: { boolValue: v } }
    : { literal: { intValue: v } };

function mc(fields: Record<string, Expression>): Expression {
  return { messageCreation: { fields: Object.entries(fields).map(([name, value]) => ({ name, value })) } };
}
function call(module: string, fn: string, fields: Record<string, Expression> = {}): Expression {
  return { call: { module, function: fn, input: Object.keys(fields).length > 0 ? mc(fields) : undefined } };
}
const std = (fn: string, fields: Record<string, Expression> = {}) => call("std", fn, fields);

function mainProgram(body: Expression, extraFunctions: FunctionDef[] = []): Program {
  return {
    name: "extra_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      { name: "std", functions: [{ name: "print", isBase: true }] },
      { name: "main", functions: [{ name: "main", body }, ...extraFunctions] },
    ],
  };
}

describe("compiler — block-expression-as-statement hoisting + shadow rename", () => {
  test("a nested block re-declaring the same `let` name is renamed to avoid a redeclaration conflict", () => {
    // main's body: two nested (block-expression-as-statement, no result)
    // blocks, each declaring `let x` — the second must be renamed (x$1) so
    // the hoisted-flat function body doesn't redeclare `x`.
    const nestedBlockA: Expression = { block: { statements: [{ let: { name: "x", value: lit(1) } }] } };
    const nestedBlockB: Expression = { block: { statements: [{ let: { name: "x", value: lit(2) } }] } };
    const body: Expression = {
      block: {
        statements: [
          { expression: nestedBlockA },
          { expression: nestedBlockB },
        ],
      },
    };
    const ts = compile(mainProgram(body), { includePreamble: false });
    assert.match(ts, /let x = 1;/);
    assert.match(ts, /let x\$1 = 2;/, "the second declaration is shadow-renamed to avoid a redeclaration");
  });
});

describe("compiler — collection literal control elements", () => {
  test("collection_if with an else arm inside a list literal", () => {
    const listWithIf: Expression = {
      literal: {
        listValue: {
          elements: [
            call("std", "collection_if", {
              condition: ref("flag"),
              then: lit(1),
              else: lit(2),
            }),
          ],
        },
      },
    };
    const program = mainProgram({
      block: { statements: [{ let: { name: "xs", value: listWithIf } }] },
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /if \(flag\) \{ __r\.push\(1\); \} else \{ __r\.push\(2\); \}/);
  });

  test("a map spread element inside a map literal copies the source map's entries", () => {
    const mapWithSpread: Expression = {
      literal: {
        listValue: {
          elements: [
            call("std", "spread", { value: ref("base") }),
          ],
        },
      },
    };
    // Route through map_create so it's treated as map elements, not list.
    const body: Expression = {
      block: {
        statements: [
          {
            let: {
              name: "merged",
              value: {
                call: {
                  module: "std",
                  function: "map_create",
                  input: { messageCreation: { fields: [{ name: "element", value: mapWithSpread.literal!.listValue!.elements[0] }] } },
                },
              },
            },
          },
        ],
      },
    };
    const ts = compile(mainProgram(body), { includePreamble: false });
    assert.match(ts, /for \(const __k in __m\) \{ __r\[__k\] = __m\[__k\]; \}/);
  });

  test("a C-style collection_for inside a list literal renders init/condition/update", () => {
    const cStyleFor = call("std", "collection_for", {
      init: { block: { statements: [{ let: { name: "i", value: lit(0) } }] } },
      condition: { reference: { name: "i" } }, // simplified; real IR wraps in lambda but bare works too
      update: { reference: { name: "i" } },
      body: ref("i"),
    });
    const listWithFor: Expression = { literal: { listValue: { elements: [cStyleFor] } } };
    const program = mainProgram({
      block: { statements: [{ let: { name: "xs", value: listWithFor } }] },
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /for \(let i = 0; i; i\) \{ __r\.push\(i\); \}/);
  });
});

describe("compiler — compileMessageCreation module-qualified dispatch", () => {
  test("a module-qualified typeName resolving to a free top-level function compiles to a bare call", () => {
    const program = mainProgram(
      { messageCreation: { typeName: "main:helperFn", fields: [{ name: "arg0", value: lit(5) }] } },
      [{ name: "helperFn", body: ref("input") }],
    );
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /return helperFn\(5\);/);
  });

  test("an empty-typeName messageCreation used directly as an expression compiles to a plain object literal", () => {
    const program = mainProgram({
      messageCreation: { typeName: "", fields: [{ name: "a", value: lit(1) }, { name: "b", value: lit(2) }] },
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /return \{\s*'a': 1, 'b': 2\s*\};/);
  });
});

describe("compiler — compileCall self-field routing (StringBuffer / Map.fromEntries shims)", () => {
  test("StringBuffer.write(text) compiles to `self += text`", () => {
    const writeCall: Expression = {
      call: {
        module: "",
        function: "write",
        input: mc({ self: ref("buf"), arg0: lit("hi") }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: writeCall }] } }), { includePreamble: false });
    assert.match(ts, /buf \+= 'hi'/);
  });

  test("Map.fromEntries(list) compiles to Object.fromEntries with arg0/arg1 or key/value fallback", () => {
    const fromEntriesCall: Expression = {
      call: {
        module: "",
        function: "fromEntries",
        input: mc({ self: { reference: { name: "Map" } }, arg0: ref("pairs") }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "m", value: fromEntriesCall } }] } }), { includePreamble: false });
    assert.match(ts, /Object\.fromEntries\(\(pairs\)\.map\(\(e: any\) => \[e\.arg0 \?\? e\.key, e\.arg1 \?\? e\.value\]\)\)/);
  });
});

describe("compiler — control-flow text fallbacks", () => {
  test("a malformed switch (missing subject/cases) emits a comment instead of throwing", () => {
    const malformedSwitch: Expression = {
      call: { module: "std", function: "switch", input: mc({}) },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: malformedSwitch }] } }), { includePreamble: false });
    assert.match(ts, /\/\* malformed switch \*\//);
  });

  test("a labeled statement emits a JS label followed by its body", () => {
    const labeled: Expression = {
      call: {
        module: "std",
        function: "labeled",
        input: mc({ label: lit("outer"), body: { block: { statements: [{ expression: std("print", { message: lit("x") }) }] } } }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: labeled }] } }), { includePreamble: false });
    assert.match(ts, /outer:/);
  });
});
