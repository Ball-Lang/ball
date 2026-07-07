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
 * ── Issue #264 additions (deferred coverage cluster from #62/#263) ──
 *   - A bare `throw;` with no value (~3218-3219).
 *   - For-loop init edge cases: a block-style init with a no-value `let`
 *     (a declaration-only C-style init) and a bare non-block/non-string
 *     init expression (~3412-3421).
 *   - Real `std.label`/`std.goto` execution — a labelled loop that
 *     actually restarts via a backward jump (~3462-3491), previously only
 *     proven by the interpreted-engine conformance corpus, not native
 *     TS-codegen.
 *   - `collectHoistedLetNames`'s recursion into a doubly-nested
 *     block-expression-as-statement, and the rename-conflict counter
 *     advancing past `$1` when BOTH `x` and `x$1` are already taken
 *     (~3086-3148).
 *   - A bare `super` reference (not `super.field`) used as a tear-off/call
 *     target inside a class method (~3743-3744).
 *   - The `expr()` "notSet" fallback for a totally-empty `Expression{}`
 *     node with no oneof member populated (~3773).
 *   - `StringBuffer.writeCharCode(code)`'s `self`-field shim (~4290-4292).
 *   - `compileMessageCreation`'s NON-colon-qualified typeName fallbacks: a
 *     bare (unqualified) free-function name, a bare same-class method
 *     name, and a bare user-defined-class name that don't go through the
 *     `"module:ident"` colon branch (~4086-4103).
 *   - The legacy `"module:ClassName.new"` FunctionCall constructor
 *     convention in `compileCall` (~4249-4261) — distinct from
 *     `compileMessageCreation`'s typeName-based constructor detection,
 *     which is the convention both encoders actually emit today.
 *   - Collection-element edge cases: a malformed map entry (missing key or
 *     value) via both `compileMapElements`'s plain fast path and
 *     `emitCollectionElement`'s imperative map branch, and
 *     `renderForInit`'s fallback branches for a non-block / declaration-
 *     only C-style `collection_for` init (~3871-3990).
 *   - `translateInitString`'s fallback for a for-init cosmetic string with
 *     no recognized `var`/`final`/type keyword prefix (~5890-5896).
 *   - `sameRef`'s field-access-chain comparison (used by the in-place
 *     list-mutation optimizer for `this.x = list_concat(list: this.x,
 *     value: y)` inside a class method) and its no-match fallback
 *     (~5810-5816).
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

  test("the map-literal IIFE annotates __r as `any`, never the strip-fragile `Record<string, any>`", () => {
    // Regression guard for the TS-Regression-Gate failure on PR #274: the
    // map-literal/comprehension lowering (compiler.ts compileMapElements) used
    // to emit `const __r: Record<string, any> = {}` on a single long line.
    // Node's `--experimental-strip-types` (Amaro) intermittently mis-strips the
    // two-argument generic `<string, any>` in that position, corrupting the rest
    // of the line and throwing `ERR_INVALID_TYPESCRIPT_SYNTAX: Expression
    // expected` when the ~9800-line compiled engine is loaded under Node 22.23.1.
    // A single-token `any` annotation strips cleanly (like the sibling list
    // emit `__r: any[]`). Assert the fragile form is never re-introduced.
    const mapSpread = call("std", "spread", { value: ref("base") });
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
                  input: { messageCreation: { fields: [{ name: "element", value: mapSpread }] } },
                },
              },
            },
          },
        ],
      },
    };
    const ts = compile(mainProgram(body), { includePreamble: false });
    // The map IIFE must be present with the strip-safe single-token annotation …
    assert.match(ts, /\(\(\) => \{ const __r: any = \{\};/);
    // … and must NOT carry the two-argument generic that trips the type-stripper.
    assert.ok(
      !ts.includes("Record<string, any>"),
      "map-literal emit must not contain the strip-fragile `Record<string, any>` annotation",
    );
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

describe("compiler — a nested block's result in a non-function-body position", () => {
  test("an if-branch that's a block-with-result emits the result as a discarded expression statement, not a return", () => {
    // emitBlock's `block.result` handling has two branches: a function BODY
    // block emits `return <result>;`, but a block used elsewhere (here, an
    // if-statement's `then` branch) is not a function body, so its result
    // is just evaluated as a bare expression statement and discarded.
    const body: Expression = {
      block: {
        statements: [
          {
            expression: std("if", {
              condition: lit(true),
              then: {
                block: {
                  statements: [{ expression: std("print", { message: lit("in-branch") }) }],
                  result: lit(5),
                },
              },
            }),
          },
        ],
      },
    };
    const ts = compile(mainProgram(body), { includePreamble: false });
    // The result (5) is emitted as a bare statement, not wrapped in `return`.
    assert.match(ts, /5;\s*\n\s*\}/);
    assert.doesNotMatch(ts, /return 5;/);
    assert.equal(compileAndRun(mainProgram(body), "block_result_nonfn"), "in-branch");
  });
});

describe("compiler — compileMessageCreation's transparent BallValue wrapper types", () => {
  test("a BallValue wrapper messageCreation with more than one field uses the first field, ignoring the rest", () => {
    // BallMap/BallList/etc. are transparent wrappers in TS (no runtime
    // representation of their own): a single-field wrapper just unwraps to
    // that field's expression. A malformed (unexpected) multi-field wrapper
    // falls back to the SAME single-field behavior rather than erroring.
    const wrapper: Expression = {
      messageCreation: {
        typeName: "BallMap",
        fields: [
          { name: "arg0", value: lit(1) },
          { name: "arg1", value: lit(2) },
        ],
      },
    };
    const body: Expression = { block: { statements: [{ expression: std("print", { message: wrapper }) }] } };
    const ts = compile(mainProgram(body), { includePreamble: false });
    assert.match(ts, /__ball_to_string\(1\)/, "only the first field's expression is used");
    assert.equal(compileAndRun(mainProgram(body), "ballvalue_multi_field"), "1");
  });
});

// ═══════════════════════ Issue #264 additions ═══════════════════════

describe("compiler — a bare `throw;` with no value", () => {
  test("emits `throw null;`", () => {
    const throwStmt: Expression = { call: { module: "std", function: "throw" } };
    const ts = compile(mainProgram({ block: { statements: [{ expression: throwStmt }] } }), { includePreamble: false });
    assert.match(ts, /throw null;/);
  });
});

describe("compiler — for-loop init edge cases", () => {
  test("a block-style init with a declaration-only (no-value) `let` emits a bare `let i`", () => {
    const forStmt: Expression = {
      call: {
        module: "std",
        function: "for",
        input: mc({
          init: { block: { statements: [{ let: { name: "i" } }] } },
          condition: { lambda: { body: std("less_than", { left: ref("i"), right: lit(3) }) } },
          update: { lambda: { body: ref("i") } },
          body: { lambda: { body: std("print", { message: lit("x") }) } },
        }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: forStmt }] } }), { includePreamble: false });
    assert.match(ts, /for \(let i; /, "a declaration-only let init has no `= value` part");
  });

  test("a bare non-block/non-string init expression is compiled directly", () => {
    const forStmt: Expression = {
      call: {
        module: "std",
        function: "for",
        input: mc({
          init: ref("i"),
          condition: { lambda: { body: std("less_than", { left: ref("i"), right: lit(3) }) } },
          update: { lambda: { body: ref("i") } },
          body: { lambda: { body: std("print", { message: lit("x") }) } },
        }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "i", value: lit(0) } }, { expression: forStmt }] } }), { includePreamble: false });
    assert.match(ts, /for \(i; /, "the bare reference init is compiled as-is (no `let`)");
  });

  test("a for-loop with no init clause at all compiles to an empty init slot", () => {
    const forStmt: Expression = {
      call: {
        module: "std",
        function: "for",
        input: mc({
          condition: { lambda: { body: std("less_than", { left: ref("i"), right: lit(3) }) } },
          update: { lambda: { body: ref("i") } },
          body: { lambda: { body: std("print", { message: lit("x") }) } },
        }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "i", value: lit(0) } }, { expression: forStmt }] } }), { includePreamble: false });
    assert.match(ts, /for \(; /, "the empty init slot has nothing before the first `;`");
  });
});

describe("compiler — std.label / std.goto (real labelled-loop execution)", () => {
  test("a backward goto re-enters its enclosing label, actually looping at runtime", () => {
    // `label("loop", { i += 1; if (i < 3) goto("loop"); }); print(i);` compiles
    // to a labelled `while(true)` that `continue`s back to the top on goto and
    // `break`s on natural fall-off — proving the real runtime semantics
    // (previously only exercised by the interpreted-engine conformance
    // corpus, never native TS-codegen).
    const labelBody: Expression = {
      block: {
        statements: [
          {
            expression: std("assign", {
              target: ref("i"),
              value: std("add", { left: ref("i"), right: lit(1) }),
            }),
          },
          {
            expression: std("if", {
              condition: std("less_than", { left: ref("i"), right: lit(3) }),
              then: {
                block: {
                  statements: [{ expression: call("std", "goto", { label: lit("loop") }) }],
                },
              },
            }),
          },
        ],
      },
    };
    const body: Expression = {
      block: {
        statements: [
          { let: { name: "i", value: lit(0) } },
          { expression: call("std", "label", { name: lit("loop"), body: labelBody }) },
          {
            expression: std("print", {
              message: { call: { module: "std", function: "to_string", input: mc({ value: ref("i") }) } },
            }),
          },
        ],
      },
    };
    const program = mainProgram(body);
    (program.modules[0].functions as FunctionDef[]).push(
      { name: "assign", isBase: true },
      { name: "add", isBase: true },
      { name: "less_than", isBase: true },
      { name: "if", isBase: true },
      { name: "to_string", isBase: true },
    );
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /loop: while \(true\)/);
    assert.match(ts, /continue loop;/);
    assert.match(ts, /break loop;/);
    assert.equal(compileAndRun(program, "goto_label"), "3");
  });
});

describe("compiler — collectHoistedLetNames recursion + rename-conflict counter past $1", () => {
  test("a doubly-nested block-statement's `let` is found by recursing into the inner block, and a THIRD same-name declaration skips the already-taken $1 rename", () => {
    // outer `let x = 0` takes "x". A nested block-statement whose OWN single
    // statement is ANOTHER nested block-statement declaring `let x = 1`
    // exercises collectHoistedLetNames' recursive branch and renames to
    // "x$1". A third, sibling block declaring `let x = 2` then conflicts
    // with BOTH "x" and "x$1" (now also in scopeDeclaredVars), so the
    // rename-conflict counter must advance past 1 to produce "x$2".
    const doublyNested: Expression = {
      block: {
        statements: [
          { expression: { block: { statements: [{ let: { name: "x", value: lit(1) } }] } } },
        ],
      },
    };
    const thirdBlock: Expression = { block: { statements: [{ let: { name: "x", value: lit(2) } }] } };
    const body: Expression = {
      block: {
        statements: [
          { let: { name: "x", value: lit(0) } },
          { expression: doublyNested },
          { expression: thirdBlock },
        ],
      },
    };
    const ts = compile(mainProgram(body), { includePreamble: false });
    assert.match(ts, /let x = 0;/);
    assert.match(ts, /let x\$1 = 1;/, "the doubly-nested declaration is renamed via the recursive hoisted-names scan");
    assert.match(ts, /let x\$2 = 2;/, "the third declaration skips the already-taken x$1 and lands on x$2");
  });
});

describe("compiler — a bare `super` reference (tear-off/call target, not `super.field`)", () => {
  test("a `super.method()` call (encoded via the `self` field convention) compiles to real `super.method(...)`", () => {
    const program: Program = {
      name: "bare_super_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Animal.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Animal.speak",
              metadata: { kind: "method" },
              body: { literal: { stringValue: "animal" } },
            },
            { name: "main:Dog.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Dog.speak",
              metadata: { kind: "method" },
              // Dart encoding of `super.speak()`: a call whose input carries
              // a `self` field set to a bare `super` reference.
              body: {
                call: {
                  module: "",
                  function: "speak",
                  input: { messageCreation: { fields: [{ name: "self", value: { reference: { name: "super" } } }] } },
                },
              },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { let: { name: "d", value: { messageCreation: { typeName: "main:Dog", fields: [] } } } },
                    {
                      expression: std("print", {
                        message: {
                          call: {
                            function: "speak",
                            input: { messageCreation: { fields: [{ name: "self", value: ref("d") }] } },
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
            { name: "main:Animal", metadata: { kind: "class" } },
            { name: "main:Dog", metadata: { kind: "class", superclass: "Animal" } },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /super\.speak\(\)/, "the bare `super` reference compiles to the real JS `super` keyword");
    assert.equal(compileAndRun(program, "bare_super"), "animal");
  });
});

describe("compiler — expr()'s notSet fallback for a totally-empty Expression node", () => {
  test("a field value with no oneof member populated compiles to the notSet placeholder", () => {
    const emptyObjectLiteral: Expression = {
      messageCreation: { typeName: "", fields: [{ name: "a", value: {} }] },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: std("print", { message: emptyObjectLiteral }) }] } }), { includePreamble: false });
    assert.match(ts, /null \/\* notSet \*\//);
  });
});

describe("compiler — StringBuffer.writeCharCode(code) self-field shim", () => {
  test("compiles to `self += String.fromCharCode(code)`", () => {
    const writeCharCodeCall: Expression = {
      call: {
        module: "",
        function: "writeCharCode",
        input: mc({ self: ref("buf"), arg0: lit(65) }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: writeCharCodeCall }] } }), { includePreamble: false });
    assert.match(ts, /buf \+= String\.fromCharCode\(65\)/);
  });
});

describe("compiler — compileMessageCreation's bare (non-colon-qualified) typeName fallbacks", () => {
  test("a bare typeName matching a free top-level function's own (unqualified) name compiles to a bare call", () => {
    const program = mainProgram(
      { messageCreation: { typeName: "bareFn", fields: [{ name: "arg0", value: lit(5) }] } },
      [{ name: "bareFn", body: ref("input") }],
    );
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /return bareFn\(5\);/);
  });

  test("a bare typeName matching a sibling method's short name (no colon) resolves via `this.`", () => {
    const program: Program = {
      name: "bare_method_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Calc.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Calc.compute",
              metadata: { kind: "method" },
              body: { literal: { intValue: 42 } },
            },
            {
              name: "main:Calc.run",
              metadata: { kind: "method" },
              // A bare (no-colon) typeName referencing the SIBLING method
              // "compute" directly, distinct from the colon-qualified
              // "module:ident" resolution path.
              body: { messageCreation: { typeName: "compute", fields: [] } },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { let: { name: "c", value: { messageCreation: { typeName: "main:Calc", fields: [] } } } },
                    {
                      expression: std("print", {
                        message: {
                          call: {
                            function: "to_string",
                            module: "std",
                            input: mc({ value: { call: { function: "run", input: { messageCreation: { fields: [{ name: "self", value: ref("c") }] } } } } }),
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
          typeDefs: [{ name: "main:Calc", metadata: { kind: "class" } }],
        },
      ],
    } as any;
    (program.modules[0].functions as FunctionDef[]).push({ name: "to_string", isBase: true });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /this\.compute\(\)/, "the bare typeName resolves to the sibling method via `this.`");
    assert.equal(compileAndRun(program, "bare_method"), "42");
  });

  test("a bare (no module-colon) typeDef name resolves via typeIsUserDefinedClass to `new X(...)`", () => {
    const program: Program = {
      name: "bare_class_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "Foo.new", metadata: { kind: "constructor", params: [{ name: "x", is_this: true }] } },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { expression: std("print", { message: { fieldAccess: { object: { messageCreation: { typeName: "Foo", fields: [{ name: "arg0", value: lit(9) }] } }, field: "x" } } }) },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [{ name: "Foo", metadata: { kind: "class", fields: [{ name: "x", type: "int" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /new Foo\(9\)/, "the bare (unqualified) typeDef name is recognized as a user-defined class");
    assert.equal(compileAndRun(program, "bare_class"), "9");
  });
});

describe("compiler — the legacy `\"module:ClassName.new\"` FunctionCall constructor shape", () => {
  test("compileCall recognizes a FunctionCall whose function ends in a colon-qualified `.new` suffix", () => {
    // Distinct from compileMessageCreation's typeName-based constructor
    // detection (the convention both encoders actually emit today) --
    // this is compileCall's OWN, older constructor-call recognition for a
    // FunctionCall (not a MessageCreation) shaped as "module:ClassName.new".
    const program: Program = {
      name: "legacy_ctor_call_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Foo.new", metadata: { kind: "constructor", params: [{ name: "x", is_this: true }] } },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "f",
                        value: {
                          call: {
                            function: "main:Foo.new",
                            input: { messageCreation: { fields: [{ name: "arg0", value: lit(9) }] } },
                          },
                        },
                      },
                    },
                    {
                      expression: std("print", {
                        message: { call: { function: "to_string", module: "std", input: mc({ value: { fieldAccess: { object: ref("f"), field: "x" } } }) } },
                      }),
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [{ name: "main:Foo", metadata: { kind: "class", fields: [{ name: "x", type: "int" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /new Foo\(9\)/);
    assert.equal(compileAndRun(program, "legacy_ctor_call"), "9");
  });
});

describe("compiler — collection-element edge cases (malformed map entries, renderForInit fallbacks)", () => {
  test("compileMapElements' plain fast path silently drops a malformed entry (missing `value`)", () => {
    const malformedEntry: Expression = { messageCreation: { fields: [{ name: "key", value: lit("k") }] } };
    const mapCreateCall: Expression = {
      call: {
        module: "std",
        function: "map_create",
        input: mc({ entry: malformedEntry }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "m", value: mapCreateCall } }] } }), { includePreamble: false });
    assert.match(ts, /let m = \{\};/, "the malformed entry (no `value`) is silently dropped, leaving an empty object");
  });

  test("emitCollectionElement's map branch silently no-ops a malformed plain element alongside a real control element", () => {
    const spreadEl = call("std", "spread", { value: ref("base") });
    const malformedPlain: Expression = lit(5); // not a key/value messageCreation at all
    const mapCreateCall: Expression = {
      call: {
        module: "std",
        function: "map_create",
        input: { messageCreation: { fields: [{ name: "element", value: spreadEl }, { name: "element", value: malformedPlain }] } },
      },
    };
    const program = mainProgram({ block: { statements: [{ let: { name: "base", value: { messageCreation: { fields: [{ name: "x", value: lit(1) } ] } } } }, { let: { name: "m", value: mapCreateCall } }, { expression: std("print", { message: { call: { module: "std", function: "to_string", input: mc({ value: { fieldAccess: { object: ref("m"), field: "x" } } }) } } }) }] } });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /for \(const __k in __m\)/, "the spread control element still copies base's entries");
    assert.equal(compileAndRun(program, "map_malformed_plain"), "1", "the malformed plain element is a silent no-op, not a crash");
  });

  test("renderForInit falls back to a bare expression when the collection_for init isn't a single-let block", () => {
    const cStyleFor = call("std", "collection_for", {
      init: ref("i"), // not a block at all -> renderForInit's `!block` fallback
      condition: ref("i"),
      update: ref("i"),
      body: ref("i"),
    });
    const listWithFor: Expression = { literal: { listValue: { elements: [cStyleFor] } } };
    const program = mainProgram({
      block: {
        statements: [
          { let: { name: "i", value: lit(0) } },
          { let: { name: "xs", value: listWithFor } },
        ],
      },
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /for \(i; i; i\) \{ __r\.push\(i\); \}/, "the bare reference init compiles via the expr() fallback, not a `let` declaration");
  });

  test("renderForInit emits a bare declaration (no `= value`) for a __no_init__-sentinel let in a collection_for init", () => {
    const cStyleFor = call("std", "collection_for", {
      init: { block: { statements: [{ let: { name: "i", value: ref("__no_init__") } }] } },
      condition: ref("i"),
      update: ref("i"),
      body: ref("i"),
    });
    const listWithFor: Expression = { literal: { listValue: { elements: [cStyleFor] } } };
    const program = mainProgram({ block: { statements: [{ let: { name: "xs", value: listWithFor } }] } });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /for \(let i; i; i\) \{ __r\.push\(i\); \}/, "the __no_init__ sentinel produces a declaration-only `let i`, no `= value`");
  });
});

describe("compiler — compileLiteral's bytes-literal decode (#244)", () => {
  test("a bytesValue literal decodes the actual base64-encoded bytes at compile time", () => {
    // "hi" base64-encoded, matching the raw proto3-JSON convention this
    // compiler's plain-JSON `Literal` DTO carries bytesValue in.
    const bytesLit: Expression = { literal: { bytesValue: Buffer.from("hi").toString("base64") } as any };
    // Asserting on the compiled TS text is sufficient here (no execution
    // needed) -- the runtime behavior of atob/Uint8Array is already proven
    // by std_memory's own executed tests; this isolates compileLiteral's
    // OWN emission for this shape (issue #244: it used to always emit an
    // empty Uint8Array regardless of the source bytes).
    const bytesProgram = mainProgram({ block: { statements: [{ let: { name: "b", value: bytesLit } }] } });
    const ts = compile(bytesProgram, { includePreamble: false });
    assert.match(ts, /Uint8Array\.from\(atob\('aGk='\), c => c\.charCodeAt\(0\)\)/, "the real base64 payload is embedded and decoded, not discarded");
  });
});

describe("compiler — compileMessageCreation's colon-qualified same-class-method + double-match branches", () => {
  test("a colon-qualified typeName (`module:ident`) resolving to a SIBLING method of the class being compiled", () => {
    const program: Program = {
      name: "colon_sibling_method_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Calc.new", metadata: { kind: "constructor", params: [] } },
            { name: "main:Calc.helper2", metadata: { kind: "method" }, body: { literal: { intValue: 7 } } },
            {
              name: "main:Calc.run2",
              metadata: { kind: "method" },
              // Colon-qualified reference to the SIBLING method, distinct
              // from the bare (no-colon) resolution path.
              body: { messageCreation: { typeName: "main:helper2", fields: [] } },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { let: { name: "c", value: { messageCreation: { typeName: "main:Calc", fields: [] } } } },
                    {
                      expression: std("print", {
                        message: {
                          call: {
                            function: "to_string",
                            module: "std",
                            input: mc({ value: { call: { function: "run2", input: { messageCreation: { fields: [{ name: "self", value: ref("c") }] } } } } }),
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
          typeDefs: [{ name: "main:Calc", metadata: { kind: "class" } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /this\.helper2\(\)/);
    assert.equal(compileAndRun(program, "colon_sibling_method"), "7");
  });

  test("a bare typeName that matches BOTH a free top-level function AND a sibling method resolves via `this.`", () => {
    const program: Program = {
      name: "double_match_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "helper", body: { literal: { intValue: 100 } } },
            { name: "main:Calc.new", metadata: { kind: "constructor", params: [] } },
            { name: "main:Calc.helper", metadata: { kind: "method" }, body: { literal: { intValue: 1 } } },
            {
              name: "main:Calc.run",
              metadata: { kind: "method" },
              // Bare "helper" matches BOTH the top-level free function AND
              // this class's own "helper" method -- the class method wins.
              body: { messageCreation: { typeName: "helper", fields: [] } },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { let: { name: "c", value: { messageCreation: { typeName: "main:Calc", fields: [] } } } },
                    {
                      expression: std("print", {
                        message: {
                          call: {
                            function: "to_string",
                            module: "std",
                            input: mc({ value: { call: { function: "run", input: { messageCreation: { fields: [{ name: "self", value: ref("c") }] } } } } }),
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
          typeDefs: [{ name: "main:Calc", metadata: { kind: "class" } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /this\.helper\(\)/);
    assert.equal(compileAndRun(program, "double_match"), "1", "the class method (this.helper()) wins over the bare top-level function");
  });
});

describe("compiler — typeRefMetaToString's nested generic type_args + dartTypeToTs's user-defined generic default", () => {
  test("a nested generic TypeRef (type_args carrying its OWN type_args) stringifies recursively", () => {
    const program: Program = {
      name: "nested_type_args_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Box.new", outputType: "main:Box", metadata: { kind: "constructor", params: [{ name: "value", is_this: true }] } },
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
                            fields: [{ name: "arg0", value: { literal: { listValue: { elements: [] } } } }],
                            metadata: { type_args: [{ name: "List", type_args: [{ name: "int" }] }] },
                          },
                        },
                      },
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [{ name: "main:Box", metadata: { kind: "class", fields: [{ name: "value", type: "Object" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_with_type_args\(new Box\(\[\]\), \["List<int>"\]\)/);
  });

  test("a user-defined generic field type (not List/Map/Set/Future) maps recursively via the default branch", () => {
    const program: Program = {
      name: "user_generic_type_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Box.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
            { name: "main", body: { literal: { intValue: 0 } } },
          ],
          typeDefs: [
            {
              name: "main:Box",
              metadata: { kind: "class", fields: [{ name: "value", type: "Result<int, String>" }] },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /value: Result<number, string>/);
  });
});

describe("compiler — translateInitString's fallback for an unrecognized keyword prefix", () => {
  test("a cosmetic for-init string with no var/final/type keyword prefix is wrapped in `let` as-is", () => {
    const forStmt: Expression = {
      call: {
        module: "std",
        function: "for",
        input: mc({
          init: lit("i = 0"), // no recognized keyword prefix
          condition: { lambda: { body: std("less_than", { left: ref("i"), right: lit(3) }) } },
          update: { lambda: { body: ref("i") } },
          body: { lambda: { body: std("print", { message: lit("x") }) } },
        }),
      },
    };
    const ts = compile(mainProgram({ block: { statements: [{ expression: forStmt }] } }), { includePreamble: false });
    assert.match(ts, /for \(let i = 0; /, "the unrecognized-prefix string is wrapped in `let` verbatim");
  });
});

describe("compiler — std.label/std.goto misuse (defensive error paths)", () => {
  test("std.label with no name or body throws a compile-time error", () => {
    const badLabel: Expression = { call: { module: "std", function: "label", input: mc({}) } };
    assert.throws(() => compile(mainProgram({ block: { statements: [{ expression: badLabel }] } })));
  });

  test("std.goto outside its own label's body throws a compile-time error naming the label", () => {
    const orphanGoto: Expression = { call: { module: "std", function: "goto", input: mc({ label: lit("nope") }) } };
    assert.throws(
      () => compile(mainProgram({ block: { statements: [{ expression: orphanGoto }] } })),
      /is not inside its own std\.label/,
    );
  });
});

describe("compiler — dartTypeToTs's FutureOr<T> mapping", () => {
  test("a class field typed FutureOr<String> maps to `string | Promise<string>`", () => {
    const program: Program = {
      name: "future_or_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Box.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
            { name: "main", body: { literal: { intValue: 0 } } },
          ],
          typeDefs: [
            {
              name: "main:Box",
              metadata: { kind: "class", fields: [{ name: "value", type: "FutureOr<String>" }] },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /value: string \| Promise<string>/);
  });
});

describe("compiler — emitIsCheck's nullable-type branch", () => {
  test("`std.is(value, 'int?')` matches null OR the base type", () => {
    const isCall: Expression = { call: { module: "std", function: "is", input: mc({ value: ref("x"), type: lit("int?") }) } };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "ok", value: isCall } }] } }), { includePreamble: false });
    assert.match(ts, /x == null \|\| \(typeof x === 'number' && Number\.isInteger\(x\)\)/);
  });
});

describe("compiler — typeRefMetaToString's nullable-suffix branch", () => {
  test("a nullable TypeRef in metadata.type_args appends `?` to the stringified type", () => {
    const program: Program = {
      name: "nullable_type_args_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Box.new", outputType: "main:Box", metadata: { kind: "constructor", params: [{ name: "value", is_this: true }] } },
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
                            metadata: { type_args: [{ name: "String", nullable: true }] },
                          },
                        },
                      },
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [{ name: "main:Box", metadata: { kind: "class", fields: [{ name: "value", type: "int" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_with_type_args\(new Box\(5\), \["String\?"\]\)/);
  });
});

describe("compiler — wrapIfNeeded parenthesizes a leading unary-operator expression", () => {
  test("a negated inner expression is wrapped in parens before a chained method call", () => {
    // A negative-int LITERAL compiles to a bare `-5` (compileLiteral emits
    // the sign verbatim) -- unlike `std.negate`, which always wraps in the
    // `__ball_negate(...)` function-call form and so never starts with a
    // bare unary-operator character. This is the shape wrapIfNeeded exists
    // to parenthesize before a chained method call.
    const upperCall: Expression = {
      call: { module: "std", function: "string_to_upper", input: mc({ value: { literal: { intValue: -5 } } }) },
    };
    const ts = compile(mainProgram({ block: { statements: [{ let: { name: "s", value: upperCall } }] } }), { includePreamble: false });
    assert.match(ts, /\(-5\)\.toUpperCase\(\)/);
  });
});

describe("compiler — sameRef's field-access-chain comparison + no-match fallback", () => {
  test("a class method's `this.items = list_concat(list: this.items, value: y)` uses the in-place push optimization", () => {
    const program: Program = {
      name: "in_place_fieldaccess_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "list_concat", isBase: true }, { name: "assign", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Basket.new", metadata: { kind: "constructor", params: [{ name: "items", is_this: true }] } },
            {
              name: "main:Basket.addAll",
              metadata: { kind: "method", params: [{ name: "y" }] },
              body: std("assign", {
                target: { fieldAccess: { object: { reference: { name: "self" } }, field: "items" } },
                value: {
                  call: {
                    module: "std",
                    function: "list_concat",
                    input: mc({
                      list: { fieldAccess: { object: { reference: { name: "self" } }, field: "items" } },
                      value: ref("y"),
                    }),
                  },
                },
              }),
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    { let: { name: "b", value: { messageCreation: { typeName: "main:Basket", fields: [{ name: "arg0", value: { literal: { listValue: { elements: [lit(1)] } } } }] } } } },
                    { expression: { call: { function: "addAll", input: { messageCreation: { fields: [{ name: "self", value: ref("b") }, { name: "arg0", value: { literal: { listValue: { elements: [lit(2)] } } } }] } } } } },
                    {
                      expression: std("print", {
                        message: { call: { module: "std", function: "to_string", input: mc({ value: { fieldAccess: { object: ref("b"), field: "items" } } }) } },
                      }),
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          typeDefs: [{ name: "main:Basket", metadata: { kind: "class", fields: [{ name: "items", type: "List<int>" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_push_all\(this\.items, y\)/);
    assert.equal(compileAndRun(program, "sameref_fieldaccess"), "[1, 2]");
  });

  test("mismatched target/list shapes (reference vs field-access) do NOT trigger the in-place optimization", () => {
    const assignCall: Expression = std("assign", {
      target: ref("y"),
      value: {
        call: {
          module: "std",
          function: "list_concat",
          input: mc({
            list: { fieldAccess: { object: ref("obj"), field: "items" } },
            value: ref("z"),
          }),
        },
      },
    });
    const program = mainProgram({ block: { statements: [{ expression: assignCall }] } });
    (program.modules[0].functions as FunctionDef[]).push({ name: "assign", isBase: true }, { name: "list_concat", isBase: true });
    const ts = compile(program, { includePreamble: false });
    assert.doesNotMatch(ts, /__ball_push_all/, "sameRef falls through to `return false` for mismatched shapes, so the optimization is skipped");
  });
});

describe("compiler — dartInitializerToTs's qualified-constructor + final-fallback branches", () => {
  test("a qualified constructor initializer (`pkg.ClassName()`) compiles to `new pkg.ClassName()`", () => {
    const program: Program = {
      name: "qual_ctor_init_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [{ name: "main:Holder.new", metadata: { kind: "constructor", params: [{ name: "input" }] } }, { name: "main", body: { literal: { intValue: 0 } } }],
          typeDefs: [
            {
              name: "main:Holder",
              metadata: {
                kind: "class",
                fields: [{ name: "rng", type: "Object", initializer: "pkg.SpecialRandom()" }],
              },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /rng: any = new pkg\.SpecialRandom\(\)/);
  });

  test("an unrecognized initializer string with no constructor shape falls back to the type-based default", () => {
    const program: Program = {
      name: "fallback_init_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [{ name: "main:Holder.new", metadata: { kind: "constructor", params: [{ name: "input" }] } }, { name: "main", body: { literal: { intValue: 0 } } }],
          typeDefs: [
            {
              name: "main:Holder",
              metadata: {
                kind: "class",
                fields: [{ name: "count", type: "int", initializer: "somefunc()" }],
              },
            },
          ],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    // "somefunc()" matches neither ctorMatch (must start uppercase/_) nor
    // qualCtorMatch (must contain an uppercase letter) -> defaultInitializer(number) -> "0".
    assert.match(ts, /count: number = 0/);
  });
});

describe("compiler — sanitize()'s legacy single-underscore operator-name convention", () => {
  test("a method name that's a raw operator lexeme (not the canonical __op_x__ form) sanitizes to the legacy __op_x form", () => {
    // Both real encoders (Dart's and TS's) now emit canonical DOUBLE-underscore
    // method names (`__op_add__`) directly as the function name -- this
    // legacy SINGLE-underscore mapping in sanitize() is a defensive fallback
    // for a raw operator lexeme appearing as a bare (unqualified) member
    // name, kept for backward compatibility with older/hand-authored IR.
    const program: Program = {
      name: "legacy_operator_name_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "main:Vec2.new", metadata: { kind: "constructor", params: [{ name: "x", is_this: true }] } },
            {
              name: "main:Vec2.+",
              metadata: { kind: "method", params: [{ name: "other" }] },
              body: { literal: { intValue: 0 } },
            },
            { name: "main", body: { literal: { intValue: 0 } } },
          ],
          typeDefs: [{ name: "main:Vec2", metadata: { kind: "class", fields: [{ name: "x", type: "int" }] } }],
        },
      ],
    } as any;
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__op_add\s*\(/, "the raw '+' member name sanitizes to the legacy single-underscore __op_add");
    assert.doesNotMatch(ts, /__op_add__/, "must not be confused with the canonical double-underscore convention");
  });
});
