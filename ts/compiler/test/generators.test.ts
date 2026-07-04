/**
 * Compiler tests for Dart-style `sync*`/`async*` generator compilation
 * (compiler.ts `emitFreeFunction`'s generator branch, ~lines 2340-2371),
 * `wrapIIFE` (~lines 2378-2386, wraps a captured statement block emitted
 * in EXPRESSION position — a Ball control-flow function like `for`/`while`/
 * `try` used as a value rather than a statement — choosing `yield*`/`await`/
 * bare IIFE based on which bare keyword the captured body contains), and
 * `bodyReferencesAny` (~lines 2389-2407, used to detect whether `main`
 * transitively calls an async user function so the emitted `main()` itself
 * becomes `async function main()`).
 *
 * Dart's `sync*`/`async*` produce RE-ITERABLE Iterables (`.length`, `.first`,
 * repeated iteration all work); JS `function*` produces a single-use
 * iterator. The compiler bridges this by emitting a plain function that
 * materializes the generator's output into a real array
 * (`return [...(function* () { ... })()];`).
 *
 * None of `tests/conformance/{162,163,174,175,176,209}_generator_*` were
 * previously exercised through the native TS-codegen path (only via the
 * interpreted-engine conformance corpus) — this was a completely untested
 * real feature on the compiler side.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  readFileSync,
  writeFileSync,
  unlinkSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program } from "../src/index.ts";
import { unwrapBallFile } from "./ball_file.ts";

function findRepoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    if (existsSync(join(dir, "proto", "ball", "v1", "ball.proto"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error("repo root not found");
    dir = parent;
  }
}

const root = findRepoRoot();
const conformanceDir = resolve(root, "tests/conformance");

const GENERATOR_FIXTURES = [
  "162_generator_sync",
  "163_generator_async",
  "174_generator_yield_star",
  "175_generator_empty_return",
  "176_generator_early_return",
  "209_generator_filtered_state",
];

describe("compiler — sync*/async* generators (real fixtures, native codegen)", () => {
  for (const name of GENERATOR_FIXTURES) {
    test(`native fixture — ${name}`, () => {
      const program: Program = unwrapBallFile(
        JSON.parse(readFileSync(join(conformanceDir, `${name}.ball.json`), "utf8")),
      );
      const ts = compile(program);
      const tmpPath = join(tmpdir(), `ball_gen_${name}_${process.pid}.ts`);
      writeFileSync(tmpPath, ts);
      try {
        let stdout: string;
        try {
          stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          });
        } catch (e: any) {
          throw new Error(`Node failed for ${name}:\nstderr:\n${e.stderr}`);
        }
        const expected = readFileSync(
          join(conformanceDir, `${name}.expected_output.txt`),
          "utf8",
        );
        const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
        assert.equal(norm(stdout), norm(expected), `Stdout mismatch for ${name}`);
      } finally {
        try { unlinkSync(tmpPath); } catch { /* ignore */ }
      }
    });
  }

  test("a sync* function materializes into a plain array-returning function, not a JS generator", () => {
    const program: Program = unwrapBallFile(
      JSON.parse(readFileSync(join(conformanceDir, "162_generator_sync.ball.json"), "utf8")),
    );
    const ts = compile(program, { includePreamble: false });
    // Must NOT declare a real `function*` for the generator — it must be a
    // regular function wrapping an internal IIFE'd generator materialized
    // via spread into an array (Dart re-iterable Iterable semantics).
    assert.match(ts, /return \[\.\.\.\(function\*\s*\(\)\s*\{/);
  });
});

describe("compiler — wrapIIFE (control-flow calls used as expressions)", () => {
  const stdModule = () => ({
    name: "std",
    functions: [
      { name: "for_in", isBase: true },
      { name: "while", isBase: true },
      { name: "try", isBase: true },
      { name: "yield", isBase: true },
      { name: "await", isBase: true },
      { name: "print", isBase: true },
    ] as FunctionDef[],
  });

  function programWithMainLet(letValue: Expression): Program {
    return {
      name: "wrapiife_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        stdModule(),
        {
          name: "main",
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [{ let: { name: "result", value: letValue } }],
                },
              },
            },
          ],
        },
      ],
    };
  }

  test("a for_in loop used as an expression value wraps in a yield* IIFE when its body yields", () => {
    // `let result = for_in(item in items) { yield item; }` — used as a
    // VALUE (not a statement), so compileStdCall's "for_in" case captures
    // the loop body and wrapIIFE must detect the bare `yield` inside it.
    const forInAsExpr: Expression = {
      call: {
        module: "std",
        function: "for_in",
        input: {
          messageCreation: {
            fields: [
              { name: "variable", value: { literal: { stringValue: "item" } } },
              { name: "iterable", value: { reference: { name: "items" } } },
              {
                name: "body",
                value: {
                  block: {
                    statements: [
                      {
                        expression: {
                          call: {
                            module: "std",
                            function: "yield",
                            input: {
                              messageCreation: {
                                fields: [{ name: "value", value: { reference: { name: "item" } } }],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
      },
    };
    const program = programWithMainLet(forInAsExpr);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /yield\s*\*\s*\(function\*\s*\(\)\s*\{/, "wraps in a yield* generator IIFE");
  });

  test("a while loop used as an expression value wraps in an async IIFE when its body awaits", () => {
    const whileAsExpr: Expression = {
      call: {
        module: "std",
        function: "while",
        input: {
          messageCreation: {
            fields: [
              { name: "condition", value: { literal: { boolValue: false } } },
              {
                name: "body",
                value: {
                  block: {
                    statements: [
                      {
                        expression: {
                          call: {
                            module: "std",
                            function: "await",
                            input: {
                              messageCreation: {
                                fields: [{ name: "value", value: { reference: { name: "items" } } }],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
      },
    };
    const program = programWithMainLet(whileAsExpr);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /await\s*\(async \(\) => \{/, "wraps in an async IIFE");
  });

  test("a try block used as an expression value with neither yield nor await wraps in a bare IIFE", () => {
    const tryAsExpr: Expression = {
      call: {
        module: "std",
        function: "try",
        input: {
          messageCreation: {
            fields: [
              {
                name: "body",
                value: {
                  block: {
                    statements: [
                      {
                        expression: {
                          call: {
                            module: "std",
                            function: "print",
                            input: {
                              messageCreation: {
                                fields: [{ name: "message", value: { literal: { stringValue: "ok" } } }],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            ],
          },
        },
      },
    };
    const program = programWithMainLet(tryAsExpr);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /let result = \(\(\) => \{/, "wraps in a bare arrow IIFE (no yield/await keyword)");
  });
});

describe("compiler — bodyReferencesAny (main() async auto-detection)", () => {
  test("main() becomes async when it references an async user function nested inside a call argument", () => {
    // `doWork` is async; `main`'s body doesn't call it directly at the top
    // level — the reference is nested inside a `print(...)` call's message
    // field, which only `bodyReferencesAny`'s recursive messageCreation-field
    // walk (not a shallow top-level scan) can find.
    const program: Program = {
      name: "async_detect_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "std",
          functions: [
            { name: "print", isBase: true },
            { name: "to_string", isBase: true },
          ],
        },
        {
          name: "main",
          functions: [
            {
              name: "doWork",
              metadata: { is_async: true },
              body: { literal: { intValue: 1 } },
            },
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      expression: {
                        call: {
                          module: "std",
                          function: "print",
                          input: {
                            messageCreation: {
                              fields: [
                                {
                                  name: "message",
                                  value: {
                                    call: {
                                      module: "std",
                                      function: "to_string",
                                      input: {
                                        messageCreation: {
                                          fields: [
                                            {
                                              name: "value",
                                              value: { call: { module: "", function: "doWork" } },
                                            },
                                          ],
                                        },
                                      },
                                    },
                                  },
                                },
                              ],
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /async function main\s*\(/, "main() is emitted as async");
    assert.match(ts, /await main\(\);/, "the top-level invocation awaits main()");
  });
});
