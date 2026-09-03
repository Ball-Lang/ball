/**
 * Parity lock for `src/compiled_engine.ts` — the ONE committed, generated
 * self-hosted engine artifact in the repo (every other target regenerates its
 * compiled engine from source on each CI run, so only this one can silently go
 * stale in git).
 *
 * The conformance corpus (test/engine_test.ts) is generated from Dart by the
 * Dart encoder, so it only ever emits the Ball shapes that encoder produces. A
 * semantic change to `dart/engine/lib/engine_eval.dart` that the corpus does
 * not happen to exercise therefore leaves the whole sweep green even when the
 * committed artifact was built from a stale `dart/self_host/engine.ball.json` —
 * exactly what happened to the `_isBareSelfConstruction` guard (#499): the
 * corpus stayed at 371/371 while this engine answered a hand-built program with
 * "Maximum recursion depth exceeded: 100000" where the Dart reference engine
 * returned normally.
 *
 * The `Assert compiled TS engine is up to date` step in ci.yml's Ball Artifact
 * Freshness job is the primary gate (it regenerates and diffs the artifact);
 * this test is the behavioural half — it names the semantics that drifted, so a
 * failure says WHAT the stale engine gets wrong, not merely that bytes differ.
 *
 * The expectation below is the verbatim output of the Dart reference engine
 * (`cd dart/cli && dart run bin/ball.dart run <program>`) on the same program;
 * the mirrored Dart-side unit test lives in `dart/engine/test/engine_test.dart`
 * beside the "is on class instance" / #499 group.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { BallEngine } from "../src/index.ts";

/**
 * class Foo { var _x = 5; Foo(); }  main() { print(Foo().__type__); }
 *
 * `Foo.new`'s body is the constructor's own self-reference carrying the class's
 * inline field initializers — field names that are neither positional (`argN`)
 * nor declared constructor parameters. It must resolve to the instance under
 * construction; treating it as a real construction re-enters `Foo.new` forever.
 */
function fieldInitializerSelfRefProgram() {
  return {
    entryModule: "main",
    entryFunction: "main",
    modules: [
      { name: "std", functions: [{ name: "print", isBase: true }] },
      {
        name: "main",
        functions: [
          {
            name: "Foo.new",
            metadata: { kind: "constructor", class: "Foo" },
            body: {
              messageCreation: {
                typeName: "Foo",
                fields: [{ name: "_x", value: { literal: { numberValue: 5 } } }],
              },
            },
          },
          {
            name: "main",
            body: {
              block: {
                statements: [
                  {
                    let: {
                      name: "f",
                      value: { messageCreation: { typeName: "Foo", fields: [] } },
                    },
                  },
                  {
                    expression: {
                      call: {
                        module: "std",
                        function: "print",
                        input: {
                          messageCreation: {
                            typeName: "",
                            fields: [
                              {
                                name: "message",
                                value: {
                                  fieldAccess: {
                                    object: { reference: { name: "f" } },
                                    field: "__type__",
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
}

describe("compiled_engine.ts is in sync with dart/engine (constructor self-reference, #499)", () => {
  test("a self-reference carrying only non-parameter fields resolves to self", async () => {
    // Dart reference engine on the same program prints exactly `Foo`. A
    // compiled_engine.ts built before the final `_isBareSelfConstruction` rule
    // landed instead throws "Maximum recursion depth exceeded: 100000".
    const engine = new BallEngine(fieldInitializerSelfRefProgram());
    assert.deepEqual(await engine.run(), ["Foo"]);
  });
});
