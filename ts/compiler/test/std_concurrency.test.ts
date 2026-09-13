/**
 * `std_concurrency` native lowering for the TS compiler (issues #606/#608).
 *
 * The module was absent from `isStd`, so every `std_concurrency` call fell
 * through to the USER-function path and emitted a bare `thread_spawn(...)` —
 * an identifier the generated TypeScript never defines, with no diagnostic.
 * The same defect the Dart compiler had (#606) and the same one #157 fixed for
 * `std_memory` here.
 *
 * The compiler now lowers every declared function
 * (dart/shared/lib/std_concurrency.dart) onto the single-threaded handle tables
 * the preamble installs, mirroring `dart/engine/lib/engine_std.dart`, and
 * throws a COMPILE-time Error for anything it does not implement. The
 * behavioural half — that the emitted program runs and prints the right
 * answers — is conformance fixture `468_std_concurrency_handles`, which this
 * package's `full_e2e.ts` leg executes.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program } from "../src/index.ts";

/** Only the module's PRESENCE matters to `usesStdConcurrency` detection. */
const STD_CONCURRENCY_MODULE = {
  name: "std_concurrency",
  functions: [{ name: "thread_spawn", isBase: true }] as FunctionDef[],
};

function call(fn: string, fields: Record<string, Expression> = {}): Expression {
  return {
    call: {
      module: "std_concurrency",
      function: fn,
      input: Object.keys(fields).length > 0
        ? { messageCreation: { fields: Object.entries(fields).map(([name, value]) => ({ name, value })) } }
        : { messageCreation: { fields: [] } },
    },
  };
}

const intLit = (n: number): Expression => ({ literal: { intValue: n } });
const ref = (name: string): Expression => ({ reference: { name } });

/** `(_) => 0`, the shape every encoder emits for a one-parameter lambda. */
const lambda = (): Expression => ({
  lambda: {
    name: "",
    body: intLit(0),
    metadata: { kind: "lambda", expression_body: true, has_return: true, params: [{ name: "_" }] },
  },
} as unknown as Expression);

function programWith(statements: { expression?: Expression }[]): Program {
  return {
    name: "std_concurrency_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      STD_CONCURRENCY_MODULE,
      {
        name: "main",
        functions: [
          { name: "main", body: { block: { statements, result: { literal: { intValue: 0 } } } } },
        ],
      },
    ],
  } as Program;
}

describe("TS compiler — std_concurrency lowering", () => {
  test("the handle tables are emitted only when std_concurrency is imported", () => {
    const withConc = compile(programWith([]));
    assert.match(withConc, /const _ballThreads: boolean\[\] = \[\];/);
    assert.match(withConc, /const _ballMutexes: boolean\[\] = \[\];/);
    assert.match(withConc, /const _ballAtomics: unknown\[\] = \[\];/);

    const bare = compile({
      name: "no_concurrency",
      entryModule: "main",
      entryFunction: "main",
      modules: [{ name: "main", functions: [{ name: "main", body: intLit(0) }] }],
    } as Program);
    assert.doesNotMatch(bare, /_ballThreads/);
    assert.doesNotMatch(bare, /_ballAtomics/);
  });

  test("every declared function lowers to a helper, never a bare identifier", () => {
    const cases: Array<[string, Record<string, Expression>, RegExp]> = [
      ["thread_spawn", { body: lambda() }, /_ballThreadSpawn\(/],
      ["thread_join", { value: ref("t") }, /_ballThreadJoin\(/],
      ["mutex_create", {}, /_ballMutexCreate\(\)/],
      ["mutex_lock", { value: ref("m") }, /_ballMutexLock\(/],
      ["mutex_unlock", { value: ref("m") }, /_ballMutexUnlock\(/],
      ["scoped_lock", { mutex: ref("m"), body: lambda() }, /_ballScopedLock\(/],
      ["atomic_create", { value: intLit(7) }, /_ballAtomicCreate\(/],
      ["atomic_load", { value: ref("c") }, /_ballAtomicLoad\(/],
      ["atomic_store", { atomic: ref("c"), value: intLit(9) }, /_ballAtomicStore\(/],
      [
        "atomic_compare_exchange",
        { atomic: ref("c"), expected: intLit(9), value: intLit(11) },
        /_ballAtomicCompareExchange\(/,
      ],
    ];
    for (const [fn, fields, expected] of cases) {
      const ts = compile(programWith([{ expression: call(fn, fields) }]), { includePreamble: false });
      assert.match(ts, expected, `${fn} did not lower to its helper`);
      assert.doesNotMatch(
        ts,
        new RegExp(`(^|[^A-Za-z0-9_$])${fn}\\(`),
        `${fn} survived as a bare identifier call`,
      );
    }
  });

  test("a missing required field fails loud at COMPILE time", () => {
    assert.throws(
      () => compile(programWith([{ expression: call("atomic_store", { value: intLit(1) }) }])),
      /atomic_store: required field `atomic`/,
    );
  });

  test("a name no builder declares fails loud at COMPILE time", () => {
    assert.throws(
      () => compile(programWith([{ expression: call("thread_detach", { value: ref("t") }) }])),
      /std_concurrency\.thread_detach is not implemented/,
    );
  });
});
