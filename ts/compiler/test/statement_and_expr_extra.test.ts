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
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program } from "../src/index.ts";

/** Compile `program`, run it with node, and return trimmed/newline-normalized stdout. */
function compileAndRun(program: Program, tmpNameHint: string): string {
  const ts = compile(program);
  const tmpPath = join(tmpdir(), `ball_${tmpNameHint}_${process.pid}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    let stdout: string;
    try {
      stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (e: any) {
      throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\nTS:\n${ts}`);
    }
    return stdout.replace(/\r\n/g, "\n").trimEnd();
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

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

  test("a for-loop init encoded as a bare cosmetic string (pre-`variable`/`start` convention) is translated to `let`", () => {
    // emitForStmt supports three init shapes: the current `variable`/`start`
    // fields, a `block`-wrapped LetBinding, and this older cosmetic-string
    // fallback (translateInitString) — `"var i = 0"` -> `"let i = 0"`.
    const forStmt: Expression = {
      call: {
        module: "std",
        function: "for",
        input: mc({
          init: lit("var i = 0"),
          condition: { lambda: { body: std("less_than", { left: ref("i"), right: lit(3) }) } },
          update: { lambda: { body: std("post_increment", { value: ref("i") }) } },
          body: {
            lambda: {
              body: std("print", {
                message: { call: { module: "std", function: "to_string", input: mc({ value: ref("i") }) } },
              }),
            },
          },
        }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: forStmt }] } }), { includePreamble: false });
    assert.match(ts, /for \(let i = 0; /, "the cosmetic `var i = 0` string is translated to a `let` declaration");
  });
});

describe("compiler — reified generic type args on class construction (typeRefMetaToString/wrapWithTypeArgs)", () => {
  test("a messageCreation with metadata.type_args wraps the constructor call in __ball_with_type_args", () => {
    // wrapWithTypeArgs is a no-op (returns `expr` unchanged) when type_args is
    // absent/empty — that branch is already covered elsewhere. This exercises
    // the non-trivial branch: type_args present -> typeRefMetaToString stringifies
    // each TypeRef ({name, type_args?, nullable?}) and the call gets wrapped.
    const program: Program = {
      name: "type_args_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            {
              name: "main:Box.new",
              outputType: "main:Box",
              metadata: { kind: "constructor", params: [{ name: "value", is_this: true }] },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "b",
                        value: {
                          messageCreation: {
                            typeName: "main:Box",
                            fields: [{ name: "arg0", value: lit(5) }],
                            metadata: { type_args: [{ name: "int" }] },
                          },
                        },
                        metadata: { keyword: "final", type: "Box" },
                      },
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [
            {
              name: "main:Box",
              descriptor: {
                name: "main:Box",
                field: [{ name: "value", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_INT64" }],
              },
              metadata: { kind: "class", fields: [{ name: "value", type: "int" }] },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_with_type_args\(new Box\(5\), \["int"\]\)/);
  });
});

describe("compiler — inline construction as a call argument (#213)", () => {
  // compileCall's messageCreation-input handling used to ALWAYS flatten a
  // messageCreation argument's fields into positional JS call arguments.
  // That's correct for the universal synthesized-wrapper shape both
  // encoders use (Ball's one-input model bundles every argument into one
  // struct; `map/set/record` literals always route through their own
  // std.map_create/set_create/record CALLS, never a bare messageCreation
  // with real keys), EXCEPT when the messageCreation's `typeName` is set --
  // that always means a genuine class instance value (never a synthesized
  // wrapper, since a wrapper is always anonymous), which Dart's encoder
  // emits BARE (unwrapped) as a single positional argument's entire input
  // (`_setCallInput`). Fixed by checking `typeName` first: non-empty ->
  // compile as ONE value; empty -> always flatten (unchanged from before),
  // which also correctly unwraps a lone `arg0` field (a 1-element flatten
  // is just that element) -- the shape the TS encoder's `encodeCall`
  // ALWAYS produces, even for a single scalar/expression argument.
  //
  // An earlier version of this fix instead kept ANY single non-"arg0"-named
  // field as an object outright (assuming a bare Dart map/record literal
  // could produce that shape) -- but map/record/set literals never do, and
  // this broke a REAL case: a Dart single NAMED argument (`foo(bar: 5)`)
  // wraps as `{fields: [{name: "bar", value: 5}]}` and must ALSO flatten to
  // just `5`, not stay as `{bar: 5}`. Caught by the full ts/compiler suite
  // (dart/self_host/engine.ball.json silently produced empty output) and
  // ts/encoder's round-trip suite before pushing.

  const concatOf = (left: Expression, right: Expression): Expression => std("concat", { left, right });
  const toStringOf = (v: Expression): Expression => ({ call: { module: "std", function: "to_string", input: mc({ value: v }) } });

  test("a class instance constructed inline as a call argument (multi-field messageCreation)", () => {
    // Before the fix: `classify(Pt(3, 4))` compiled to `classify(3, 4)`
    // (Pt's arg0/arg1 constructor fields flattened to positional JS args)
    // instead of `classify(new Pt(3, 4))`.
    const program: Program = {
      name: "inline_ctor_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "concat", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            {
              name: "main:Pt.new",
              outputType: "main:Pt",
              metadata: { kind: "constructor", params: [{ name: "x", is_this: true }, { name: "y", is_this: true }] },
            },
            {
              name: "describe",
              inputType: "main:Pt",
              outputType: "String",
              body: concatOf(
                concatOf(
                  concatOf(lit("x="), toStringOf({ fieldAccess: { object: ref("p"), field: "x" } })),
                  lit(",y="),
                ),
                toStringOf({ fieldAccess: { object: ref("p"), field: "y" } }),
              ),
              metadata: { kind: "function", params: [{ name: "p", type: "Pt" }] },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    {
                      expression: std("print", {
                        message: {
                          call: {
                            function: "describe",
                            input: { messageCreation: { typeName: "main:Pt", fields: [{ name: "arg0", value: lit(3) }, { name: "arg1", value: lit(4) }] } },
                          },
                        },
                      }),
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [
            {
              name: "main:Pt",
              descriptor: {
                name: "main:Pt",
                field: [
                  { name: "x", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_INT64" },
                  { name: "y", number: 2, label: "LABEL_OPTIONAL", type: "TYPE_INT64" },
                ],
              },
              metadata: { kind: "class", fields: [{ name: "x", type: "int" }, { name: "y", type: "int" }] },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /describe\(new Pt\(3, 4\)\)/, "the inline Pt(3, 4) constructs a real Pt instance, not flattened positional args");
    assert.equal(compileAndRun(program, "inline_ctor"), "x=3,y=4");
  });

  test("a lone `arg0`-wrapped scalar argument unwraps to its value, not an object (TS encoder's single-argument convention)", () => {
    // The TS encoder (ts/encoder/src/encoder.ts's encodeCall) wraps EVERY
    // call argument as `{fields: [{name: "arg0", value: <arg>}, ...]}`, even
    // a single scalar/expression argument. Before this fix this was fine
    // (unconditional flatten); the REGRESSION this test guards against is a
    // fix that special-cases "keep as object" too broadly and stops
    // unwrapping this shape -- e.g. `fib(n - 1)` silently became
    // `fib({'arg0': n - 1})`, corrupting every recursive/nested call (was
    // caught via ts/encoder's round-trip suite: fibonacci recursion overflowed
    // the call stack since `{arg0: n-1} <= 1` is always false).
    const doubleBody: Expression = std("multiply", { left: ref("n"), right: lit(2) });
    const program: Program = mainProgram(
      {
        block: {
          statements: [
            {
              expression: std("print", {
                message: {
                  call: {
                    function: "to_string",
                    module: "std",
                    input: mc({
                      value: {
                        call: {
                          function: "double_",
                          input: { messageCreation: { fields: [{ name: "arg0", value: lit(21) }] } },
                        },
                      },
                    }),
                  },
                },
              }),
            },
          ],
        },
      },
      [
        {
          name: "double_",
          inputType: "int",
          outputType: "int",
          body: doubleBody,
          metadata: { kind: "function", params: [{ name: "n", type: "int" }] },
        },
      ],
    );
    (program.modules[0].functions as FunctionDef[]).push(
      { name: "multiply", isBase: true },
      { name: "to_string", isBase: true },
    );
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /double_\(21\)/, "the arg0-wrapped scalar unwraps to a bare `21`, not `{'arg0': 21}`");
    assert.equal(compileAndRun(program, "inline_arg0"), "42");
  });

  test("a Dart single NAMED argument unwraps to its value too (not kept as an object)", () => {
    // Dart's encoder (_encodeArgList/_setCallInput) uses the argument's real
    // name for a NAMED argument (`foo(bar: 5)` -> field "bar", not "arg0")
    // and, since the field name doesn't start with "arg", wraps it in a
    // messageCreation rather than unwrapping bare. This is STILL a
    // synthesized single-argument wrapper (typeName empty) and must flatten
    // to the raw value `5`, not stay as `{'bar': 5}` -- this is exactly the
    // shape an earlier version of the #213 fix mishandled.
    const program: Program = mainProgram(
      {
        block: {
          statements: [
            {
              expression: std("print", {
                message: {
                  call: {
                    function: "to_string",
                    module: "std",
                    input: mc({
                      value: {
                        call: {
                          function: "identity_",
                          input: { messageCreation: { fields: [{ name: "bar", value: lit(5) }] } },
                        },
                      },
                    }),
                  },
                },
              }),
            },
          ],
        },
      },
      [
        {
          name: "identity_",
          inputType: "int",
          outputType: "int",
          body: ref("bar"),
          metadata: { kind: "function", params: [{ name: "bar", type: "int" }] },
        },
      ],
    );
    (program.modules[0].functions as FunctionDef[]).push({ name: "to_string", isBase: true });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /identity_\(5\)/, "the single named-argument wrapper unwraps to a bare `5`, not `{'bar': 5}`");
    assert.equal(compileAndRun(program, "inline_named_arg"), "5");
  });
});
