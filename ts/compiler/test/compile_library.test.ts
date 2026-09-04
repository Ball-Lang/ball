/**
 * Tests for the public `compileLibrary` API — Ball Program → TypeScript
 * LIBRARY (issue #536).
 *
 * `compileLibrary` is the TS sibling of `rust/compiler`'s `compile_library`,
 * `go/compiler`'s `CompileLibrary`, `python/compiler`'s `compile_library`,
 * C#'s entry-optional `Compile` and Dart's `DartCompiler.compileModule`: it
 * compiles a whole already-loaded Program with NO assumed entry point and NO
 * synthesized invocation, and exports every top-level declaration.
 *
 * WHY IT EXISTS (and what the two pre-existing entry points do instead):
 *
 *  - `compile()` looks the entry function up by NAME and unconditionally
 *    appends a zero-arg `main();`. `@ball-lang/encoder` defaults
 *    `entryFunction` to `"main"` for every file it encodes, whether or not the
 *    source ever meant one to run, so a real library file that happens to
 *    declare `main(argv: string[])` gets a wrong-arity call appended and
 *    `argv.length` throws at runtime.
 *  - `compileModule()` is scoped by its own docblock to "the ball_protobuf use
 *    case": it synthesizes an `__ball_lib_entry__`/`__ball_lib_main__` dummy
 *    pair and removes it again with NON-GLOBAL regexes matched against the
 *    compiler's formatted output text. When a real user function
 *    `main(): number { return 0; }` is present, the raw output contains TWO
 *    `function main()` declarations (the user's plus the renamed dummy) and the
 *    non-global strip removes the FIRST — the user's. It reads as correct only
 *    because both bodies happen to be byte-identical.
 *
 * So every structural assertion below is made by PARSING the emitted
 * TypeScript with ts-morph and querying declarations — never by re-matching
 * the same fragile text patterns the primitive exists to escape.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Project } from "ts-morph";
import { compile, compileLibrary } from "../src/index.ts";
import type { Program } from "../src/index.ts";

// ── structural inspection helpers ───────────────────────────────────────────

/** Parse emitted TypeScript and hand back a queryable source file. */
function parsed(source: string) {
  const project = new Project({
    useInMemoryFileSystem: true,
    compilerOptions: { target: 99 /* ESNext */ },
  });
  return project.createSourceFile("emitted.ts", source, { overwrite: true });
}

/** Every top-level `function` declaration, by name. */
function functionsNamed(source: string, name: string) {
  return parsed(source).getFunctions().filter((f) => f.getName() === name);
}

/**
 * Every top-level statement that is a bare call `<name>(...)` (with or without
 * `await`) — i.e. a synthesized entry invocation. Queried from the AST, so an
 * invocation hidden inside a function body or a comment cannot produce a false
 * positive and a reformat cannot produce a false negative.
 */
function topLevelCallsTo(source: string, name: string): string[] {
  const found: string[] = [];
  for (const stmt of parsed(source).getStatements()) {
    const text = stmt.getText();
    // ExpressionStatement kind === 244 in the TS AST; match by shape instead of
    // importing SyntaxKind so this stays readable.
    const call = /^(?:await\s+)?([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*;?$/.exec(text.trim());
    if (call && call[1] === name) found.push(text.trim());
  }
  return found;
}

// ── program builders ────────────────────────────────────────────────────────

/** A std module declaring only the base functions the fixtures below call. */
function stdModule() {
  return {
    name: "std",
    functions: [
      { name: "return", isBase: true },
      { name: "multiply", isBase: true },
      { name: "add", isBase: true },
    ],
  };
}

/**
 * `export function main(argv: string[]) { console.log(argv.length); return 0; }`
 * as `@ball-lang/encoder` encodes it: a plain module function, plus the
 * `entryFunction: "main"` default the encoder stamps on EVERY file.
 */
function entryNameCollisionProgram(): Program {
  return {
    name: "libmain",
    version: "1.0.0",
    modules: [
      stdModule(),
      {
        name: "main",
        functions: [
          {
            name: "twice",
            body: {
              call: {
                module: "std",
                function: "multiply",
                input: {
                  messageCreation: {
                    typeName: "",
                    fields: [
                      { name: "left", value: { reference: { name: "x" } } },
                      { name: "right", value: { literal: { intValue: "2" } } },
                    ],
                  },
                },
              },
            },
            metadata: { params: [{ name: "x" }] },
          },
          {
            name: "main",
            body: { literal: { intValue: "0" } },
            metadata: { params: [{ name: "argv" }] },
          },
        ],
      },
    ],
    entryModule: "main",
    entryFunction: "main",
  } as Program;
}

/**
 * `export function main(): number { return 0; }` — byte-for-byte the IR
 * `@ball-lang/encoder` produces for that source, and exactly the shape
 * `compileModule`'s synthetic `__ball_lib_main__` stub compiles to.
 */
function dummyShapeCollisionProgram(intValue: string): Program {
  return {
    name: "main",
    version: "1.0.0",
    modules: [
      { name: "std", functions: [{ name: "return", isBase: true }] },
      {
        name: "main",
        functions: [
          {
            name: "main",
            body: {
              block: {
                statements: [
                  {
                    expression: {
                      call: {
                        module: "std",
                        function: "return",
                        input: {
                          messageCreation: {
                            typeName: "",
                            fields: [
                              { name: "value", value: { literal: { intValue } } },
                            ],
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
            metadata: { returnType: "number" },
            outputType: "number",
          },
        ],
      },
    ],
    entryModule: "main",
    entryFunction: "main",
  } as Program;
}

// ── the entry-name collision (the defect this primitive exists to avoid) ────

describe("compileLibrary — the entry function is not special", () => {
  test("emits no invocation for a declaration that shares the entry name", () => {
    const ts = compileLibrary(entryNameCollisionProgram(), {
      includePreamble: false,
    });

    assert.deepEqual(
      topLevelCallsTo(ts, "main"),
      [],
      "a library must never be given a synthesized entry invocation",
    );

    const mains = functionsNamed(ts, "main");
    assert.equal(mains.length, 1, "exactly one main declaration");
    const params = mains[0].getParameters().map((p) => p.getName());
    assert.deepEqual(
      params,
      ["argv"],
      "the real 1-arg signature is preserved, not rewritten to zero-arg",
    );
  });

  test("compile() by contrast REQUIRES an entry point; compileLibrary does not", () => {
    const program = entryNameCollisionProgram();
    program.entryModule = "no_such_module";

    // Documented, intentional behaviour of the whole-program compiler.
    assert.throws(
      () => compile(program, { includePreamble: false }),
      /Entry module "no_such_module" not found/,
    );

    // "No entry" is not an error for a library — it is the normal case.
    const ts = compileLibrary(program, { includePreamble: false });
    assert.equal(functionsNamed(ts, "twice").length, 1);
    assert.equal(functionsNamed(ts, "main").length, 1);
  });

  test("exports every top-level function structurally", () => {
    const ts = compileLibrary(entryNameCollisionProgram(), {
      includePreamble: false,
    });
    for (const name of ["twice", "main"]) {
      const [fn] = functionsNamed(ts, name);
      assert.ok(fn, `${name} is declared`);
      assert.equal(
        fn.isExported(),
        true,
        `${name} is exported (asserted via the AST, not a text match)`,
      );
    }
  });
});

// ── the dummy-shape collision ───────────────────────────────────────────────

describe("compileLibrary — no dummy-entry machinery to leak", () => {
  for (const [label, intValue] of [
    ["identical to compileModule's synthetic stub (`return 0`)", "0"],
    ["distinguishable from it (`return 42`)", "42"],
  ] as const) {
    test(`exactly one real main survives when its body is ${label}`, () => {
      const ts = compileLibrary(dummyShapeCollisionProgram(intValue), {
        includePreamble: false,
      });

      const mains = functionsNamed(ts, "main");
      assert.equal(mains.length, 1, "exactly one main declaration survives");
      assert.equal(mains[0].isExported(), true);
      assert.equal(mains[0].getParameters().length, 0);
      assert.match(
        mains[0].getBodyText() ?? "",
        new RegExp(`return ${intValue};`),
        "the surviving declaration is the USER's, body intact",
      );

      // Nothing synthetic may reach the output at all.
      assert.doesNotMatch(ts, /__ball_lib_(?:entry|main)__/);
      assert.deepEqual(topLevelCallsTo(ts, "main"), []);
    });
  }
});

// ── declaration-only, empty and multi-module programs ───────────────────────

describe("compileLibrary — declaration-only and empty programs", () => {
  test("emits classes, enums and type aliases with no functions at all", () => {
    const program: Program = {
      name: "types_only",
      version: "1.0.0",
      modules: [
        {
          name: "main",
          typeAliases: [{ name: "Id", targetType: "string" }],
          enums: [
            {
              name: "Color",
              value: [
                { name: "red", number: 0 },
                { name: "blue", number: 1 },
              ],
            },
          ],
          typeDefs: [{ name: "Box", metadata: { fields: [{ name: "size", type: "int" }] } }],
        },
      ],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    const ts = compileLibrary(program, { includePreamble: false });
    const sf = parsed(ts);

    const alias = sf.getTypeAlias("Id");
    assert.ok(alias, "type alias Id emitted");
    assert.equal(alias.isExported(), true);

    for (const name of ["Color", "Box"]) {
      const cls = sf.getClass(name);
      assert.ok(cls, `class ${name} emitted`);
      assert.equal(cls.isExported(), true);
    }
    assert.equal(sf.getFunctions().length, 0, "no functions were invented");
  });

  test("an empty module compiles to empty output, without throwing", () => {
    const program: Program = {
      name: "empty",
      version: "1.0.0",
      modules: [{ name: "main" }],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    const ts = compileLibrary(program, { includePreamble: false });
    assert.equal(ts.trim(), "");
  });

  test("a program with no modules at all compiles to empty output", () => {
    const program: Program = {
      name: "nothing",
      version: "1.0.0",
      modules: [],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    assert.equal(compileLibrary(program, { includePreamble: false }).trim(), "");
  });
});

describe("compileLibrary — whole-Program context", () => {
  test("a cross-module call still resolves to a bare function reference", () => {
    const program: Program = {
      name: "multi",
      version: "1.0.0",
      modules: [
        stdModule(),
        {
          name: "helper",
          functions: [{ name: "twice", body: { reference: { name: "input" } } }],
        },
        {
          name: "main",
          functions: [
            {
              name: "doubled",
              body: {
                call: {
                  module: "helper",
                  function: "twice",
                  input: { reference: { name: "value" } },
                },
              },
              metadata: { params: [{ name: "value" }] },
            },
          ],
        },
      ],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    const ts = compileLibrary(program, { includePreamble: false });
    // BOTH modules were compiled — the library-mode compiler does not stop at
    // the entry module — and the cross-module call resolved to the sibling.
    assert.equal(functionsNamed(ts, "twice").length, 1);
    const [doubled] = functionsNamed(ts, "doubled");
    assert.ok(doubled);
    assert.match(doubled.getBodyText() ?? "", /twice\(/);
  });

  test("top-level variables are emitted and exported", () => {
    const program: Program = {
      name: "vars",
      version: "1.0.0",
      modules: [
        {
          name: "main",
          functions: [
            {
              name: "PI",
              body: { literal: { doubleValue: 3.14 } },
              metadata: { kind: "top_level_variable" },
            },
          ],
        },
      ],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    const ts = compileLibrary(program, { includePreamble: false });
    const [decl] = parsed(ts).getVariableStatements();
    assert.ok(decl, "a top-level variable statement was emitted");
    assert.equal(decl.isExported(), true);
    assert.match(decl.getText(), /PI/);
    assert.match(decl.getText(), /3\.14/);
  });

  test("the linear-memory runtime is injected when std_memory is imported", () => {
    const program: Program = {
      name: "mem",
      version: "1.0.0",
      modules: [
        { name: "std_memory", functions: [{ name: "memory_alloc", isBase: true }] },
        {
          name: "main",
          functions: [{ name: "noop", body: { literal: { intValue: "0" } } }],
        },
      ],
      entryModule: "main",
      entryFunction: "main",
    } as Program;

    const ts = compileLibrary(program, { includePreamble: false });
    assert.match(ts, /const _ballMemory = new ByteData\(65536\)/);
  });
});

// ── options ─────────────────────────────────────────────────────────────────

describe("compileLibrary — options", () => {
  test("includePreamble defaults to true and can be turned off", () => {
    const program = dummyShapeCollisionProgram("0");
    const withPreamble = compileLibrary(program);
    const withoutPreamble = compileLibrary(program, { includePreamble: false });

    assert.ok(
      withPreamble.length > withoutPreamble.length,
      "the default output carries the runtime preamble",
    );
    assert.ok(withPreamble.endsWith(withoutPreamble));
    assert.equal(functionsNamed(withPreamble, "main").length, 1);
  });

  test("does not emit the engine post-processing helper", () => {
    // compile() prepends `__isUnknownFnError` (a helper only its own
    // engine-specific post-processing passes call). A library compile of
    // third-party code must not gain a declaration its source never had —
    // that alone would break the coverage study's fixpoint stage.
    const program = dummyShapeCollisionProgram("0");
    assert.match(compile(program, { includePreamble: false }), /__isUnknownFnError/);
    assert.doesNotMatch(
      compileLibrary(program, { includePreamble: false }),
      /__isUnknownFnError/,
    );
  });
});
