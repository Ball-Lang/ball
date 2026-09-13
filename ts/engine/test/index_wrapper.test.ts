/**
 * End-to-end tests for the BallEngine compatibility wrapper (src/index.ts)
 * and a couple of production bugs found while writing unit coverage for
 * src/engine_setup.ts:
 *
 * - std.null_check (`x!`) previously failed to throw when `x` was
 *   *explicitly* null at runtime (see engine_setup.ts's `null_check` fix) —
 *   this proves the fix end-to-end through the real engine, not just the
 *   registered-handler unit test.
 * - BallFile envelope unwrapping (ball_file.ts) and options plumbing
 *   (custom stdout/stderr, ball-file `@type` envelopes) are exercised
 *   through the public `BallEngine` API directly, matching engine_test.ts's
 *   style but as node:test cases so they report individually under coverage.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { BallEngine } from "../src/index.ts";

function nullCheckProgram() {
  return {
    modules: [
      { name: "std", functions: [{ name: "print", isBase: true }, { name: "null_check", isBase: true }] },
      {
        name: "main",
        functions: [{
          name: "main",
          body: {
            block: {
              statements: [
                { let: { name: "x", value: { literal: {} } } }, // untyped null literal
                {
                  expression: {
                    call: {
                      module: "std", function: "print",
                      input: {
                        messageCreation: {
                          typeName: "", fields: [{
                            name: "message",
                            value: {
                              call: {
                                module: "std", function: "null_check",
                                input: { messageCreation: { typeName: "", fields: [{ name: "value", value: { reference: { name: "x" } } }] } },
                              },
                            },
                          }],
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        }],
      },
    ],
    entryModule: "main", entryFunction: "main",
  };
}

describe("BallEngine end-to-end: null_check", () => {
  test("std.null_check throws at runtime when the operand is null (not silently pass through)", async () => {
    const engine = new BallEngine(nullCheckProgram());
    await assert.rejects(() => engine.run(), /Null check operator used on a null value/);
  });
});

function listFindProgram(threshold: number) {
  return {
    modules: [
      {
        name: "std",
        functions: [
          { name: "print", isBase: true },
          { name: "to_string", isBase: true },
          { name: "greater_than", isBase: true },
        ],
      },
      { name: "std_collections", functions: [{ name: "list_find", isBase: true }] },
      {
        name: "main",
        functions: [{
          name: "main",
          body: {
            call: {
              module: "std", function: "print",
              input: {
                messageCreation: {
                  typeName: "", fields: [{
                    name: "message",
                    value: {
                      call: {
                        module: "std", function: "to_string",
                        input: {
                          messageCreation: {
                            typeName: "", fields: [{
                              name: "value",
                              value: {
                                call: {
                                  module: "std_collections", function: "list_find",
                                  input: {
                                    messageCreation: {
                                      typeName: "", fields: [
                                        {
                                          name: "list",
                                          value: {
                                            literal: {
                                              listValue: {
                                                elements: [
                                                  { literal: { intValue: "1" } },
                                                  { literal: { intValue: "2" } },
                                                  { literal: { intValue: "3" } },
                                                ],
                                              },
                                            },
                                          },
                                        },
                                        {
                                          name: "callback",
                                          value: {
                                            lambda: {
                                              name: "",
                                              body: {
                                                call: {
                                                  module: "std", function: "greater_than",
                                                  input: {
                                                    messageCreation: {
                                                      typeName: "", fields: [
                                                        { name: "left", value: { reference: { name: "x" } } },
                                                        { name: "right", value: { literal: { intValue: String(threshold) } } },
                                                      ],
                                                    },
                                                  },
                                                },
                                              },
                                              metadata: {
                                                kind: "lambda", expression_body: true, has_return: true,
                                                params: [{ name: "x" }],
                                              },
                                            },
                                          },
                                        },
                                      ],
                                    },
                                  },
                                },
                              },
                            }],
                          },
                        },
                      },
                    },
                  }],
                },
              },
            },
          },
        }],
      },
    ],
    entryModule: "main", entryFunction: "main",
  };
}

describe("BallEngine end-to-end: std_collections.list_find no-match contract (#597)", () => {
  test("a HIT still yields the matching element", async () => {
    const engine = new BallEngine(listFindProgram(2));
    await engine.run();
    assert.deepEqual(engine.getOutput(), ["3"]);
  });

  test("a MISS THROWS a typed StateError — it never yields null", async () => {
    // The hand-written engine_setup.ts override that used to shadow the
    // compiled engine's implementation returned `null` here, so this program
    // printed "null" and exited 0 while the Dart reference engine (and every
    // other self-hosted engine) threw. Uncaught, the throw must propagate out
    // of run(); tests/conformance/463_list_find_no_match pins the caught half.
    const engine = new BallEngine(listFindProgram(100));
    await assert.rejects(
      () => engine.run(),
      (err: any) => {
        assert.equal(err?.__type__, "StateError");
        assert.equal(err?.message, "No element");
        return true;
      },
    );
    assert.deepEqual(engine.getOutput(), []);
  });
});

describe("BallEngine options", () => {
  function helloProgram() {
    return {
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] },
        {
          name: "main",
          functions: [{
            name: "main",
            body: { call: { module: "std", function: "print", input: { messageCreation: { typeName: "", fields: [{ name: "message", value: { literal: { stringValue: "hi" } } }] } } } },
          }],
        },
      ],
      entryModule: "main", entryFunction: "main",
    };
  }

  test("a custom stdout callback receives output instead of getOutput()", async () => {
    const lines: string[] = [];
    const engine = new BallEngine(helloProgram(), { stdout: (msg) => lines.push(msg) });
    await engine.run();
    assert.deepEqual(lines, ["hi"]);
    // getOutput() is only populated by the default stdout collector.
    assert.deepEqual(engine.getOutput(), []);
  });

  test("accepts a self-describing ball-file Program envelope (Any @type)", async () => {
    const wrapped = { "@type": "type.googleapis.com/ball.v1.Program", ...helloProgram() };
    const engine = new BallEngine(wrapped);
    await engine.run();
    assert.deepEqual(engine.getOutput(), ["hi"]);
  });

  test("accepts a JSON string body (not just a parsed object)", async () => {
    const engine = new BallEngine(JSON.stringify(helloProgram()));
    await engine.run();
    assert.deepEqual(engine.getOutput(), ["hi"]);
  });

  test("uses globalThis._patchScopeBindings when present instead of the local patchScopeBindings", async () => {
    // compiled_engine.ts never actually sets this global today, so this
    // branch is otherwise dead in every real run; still part of the public
    // contract (a global escape hatch), so drive it explicitly.
    let called: any = null;
    (globalThis as any)._patchScopeBindings = (scope: any) => { called = scope; };
    try {
      const engine = new BallEngine(helloProgram());
      assert.ok(called, "globalThis._patchScopeBindings was invoked");
      await engine.run();
      assert.deepEqual(engine.getOutput(), ["hi"]);
    } finally {
      delete (globalThis as any)._patchScopeBindings;
    }
  });

  test("respects an explicit maxRecursionDepth by throwing once exceeded", async () => {
    const deep = {
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }, { name: "add", isBase: true }] },
        {
          name: "main",
          functions: [
            {
              name: "recurse",
              body: {
                call: {
                  module: "", function: "recurse",
                  input: { messageCreation: { typeName: "", fields: [] } },
                },
              },
            },
            {
              name: "main",
              body: { call: { module: "", function: "recurse", input: { messageCreation: { typeName: "", fields: [] } } } },
            },
          ],
        },
      ],
      entryModule: "main", entryFunction: "main",
    };
    const engine = new BallEngine(deep, { maxRecursionDepth: 10 });
    await assert.rejects(() => engine.run());
  });
});
