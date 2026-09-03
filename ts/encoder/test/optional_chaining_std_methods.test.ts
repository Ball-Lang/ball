/**
 * IR-shape tests for `?.` in front of a method the encoder maps onto a std
 * base function (#504).
 *
 * `encodeCall`'s property-access branch used to consult `mapMethodToStd`
 * BEFORE it looked at `questionDotToken`, so the `null_aware_call` branch was
 * unreachable for every name in `STR_METHODS`/`ARR_METHODS` and `arr?.push(1)`
 * encoded to a bare, unguarded `std_collections.list_push` — the `?.`
 * short-circuit silently vanished, with no warning.
 *
 * These assert on the emitted IR rather than on stdout: the round-trip fixture
 * in `roundtrip.test.ts` proves the behaviour, and this file pins the SHAPE so
 * a future refactor cannot quietly drop the guard again.
 *
 * Run with:
 *   node --experimental-strip-types --test test/optional_chaining_std_methods.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";
import type { Expression, FunctionCall } from "../src/index.ts";

/** The single statement of `function f(...) { <stmt> }`. */
function soleStatementOf(source: string): Expression {
  const program = encode(source);
  const mod = program.modules.find(m => m.name === "main");
  assert.ok(mod, "expected a `main` module");
  const fn = mod!.functions.find(f => f.name === "f");
  assert.ok(fn, "expected a function named `f`");
  const stmts = fn!.body!.block!.statements;
  assert.equal(stmts.length, 1, "expected exactly one statement");
  const expr = stmts[0].expression;
  assert.ok(expr, "expected an expression statement");
  return expr!;
}

/** Every `call` node anywhere in an expression tree. */
function allCalls(expr: Expression | undefined): FunctionCall[] {
  if (!expr) return [];
  const out: FunctionCall[] = [];
  if (expr.call) {
    out.push(expr.call);
    for (const f of expr.call.input?.messageCreation?.fields ?? []) {
      out.push(...allCalls(f.value));
    }
  }
  if (expr.block) {
    for (const s of expr.block.statements ?? []) {
      out.push(...allCalls(s.let?.value));
      out.push(...allCalls(s.expression));
    }
    out.push(...allCalls(expr.block.result));
  }
  if (expr.lambda?.body) out.push(...allCalls(expr.lambda.body));
  if (expr.fieldAccess?.object) out.push(...allCalls(expr.fieldAccess.object));
  for (const f of expr.messageCreation?.fields ?? []) out.push(...allCalls(f.value));
  return out;
}

/** Field lookup by canonical name, matching how every compiler reads inputs. */
function fieldOf(call: FunctionCall, name: string): Expression {
  const f = (call.input?.messageCreation?.fields ?? []).find(x => x.name === name);
  assert.ok(f, `expected field "${name}" on ${call.module}.${call.function}`);
  return f!.value!;
}

/**
 * Assert the canonical guarded shape:
 *
 *   block {
 *     let __ball_recv_N = <receiver>
 *     result: std.if(
 *       condition: std.not_equals(left: ref(__ball_recv_N), right: null),
 *       then:      <module>.<fn>(<self>: ref(__ball_recv_N), ...),
 *       else:      null,
 *     )
 *   }
 *
 * Only primitives every target compiler already implements are used — the
 * pre-existing `null_aware_call` node is deliberately NOT reused, because both
 * `ts/compiler` and `dart/compiler` emit its `method` field VERBATIM as
 * `target?.<method>(...)` in the target language, so a JS spelling like `push`
 * would compile to a nonexistent `List.push` in Dart.
 */
function assertGuardedStdCall(
  expr: Expression,
  expected: { module: string; fn: string; selfField: string },
): FunctionCall {
  assert.ok(expr.block, "expected a block that binds the receiver exactly once");
  const stmts = expr.block!.statements ?? [];
  assert.equal(stmts.length, 1, "expected exactly one `let` statement");
  const binding = stmts[0].let;
  assert.ok(binding, "expected the receiver to be bound to a temporary");
  assert.match(
    binding!.name,
    /^__ball_recv_\d+$/,
    "the receiver temp must carry a per-call-site counter so nested chains do not shadow",
  );
  const temp = binding!.name;

  const ifCall = expr.block!.result?.call;
  assert.ok(ifCall, "expected the block result to be a call");
  assert.equal(ifCall!.module, "std");
  assert.equal(ifCall!.function, "if");

  const cond = fieldOf(ifCall!, "condition").call;
  assert.ok(cond, "expected the condition to be a call");
  assert.equal(cond!.module, "std");
  assert.equal(cond!.function, "not_equals");
  assert.equal(fieldOf(cond!, "left").reference?.name, temp);
  assert.deepEqual(
    fieldOf(cond!, "right"),
    { literal: {} },
    "the right operand must be the canonical Ball null literal",
  );

  const thenCall = fieldOf(ifCall!, "then").call;
  assert.ok(thenCall, "expected the `then` branch to be the std call");
  assert.equal(thenCall!.module, expected.module);
  assert.equal(thenCall!.function, expected.fn);
  assert.equal(
    fieldOf(thenCall!, expected.selfField).reference?.name,
    temp,
    "the std call must receive the TEMP, not a second evaluation of the receiver",
  );

  assert.deepEqual(
    fieldOf(ifCall!, "else"),
    { literal: {} },
    "the short-circuit result must be the canonical Ball null literal",
  );
  return thenCall!;
}

describe("optional chaining on a std-mapped builtin method (#504)", () => {
  test("arr?.push(1) guards the receiver instead of emitting a bare list_push", () => {
    const expr = soleStatementOf(`function f(arr) { arr?.push(1); }`);
    const push = assertGuardedStdCall(expr, {
      module: "std_collections",
      fn: "list_push",
      selfField: "list",
    });
    assert.deepEqual(fieldOf(push, "value"), { literal: { intValue: "1" } });

    // The regression this pins: no list_push may be reachable as the whole
    // statement, i.e. without the guard in front of it.
    assert.equal(
      expr.call?.function,
      undefined,
      "the statement must not be a bare std call any more",
    );
  });

  test("str?.trim() guards the receiver instead of emitting a bare string_trim", () => {
    const expr = soleStatementOf(`function f(s) { s?.trim(); }`);
    assertGuardedStdCall(expr, {
      module: "std",
      fn: "string_trim",
      selfField: "value",
    });
  });

  test("a nested optional chain uses distinct receiver temporaries", () => {
    const expr = soleStatementOf(`function f(a, b) { a?.push(b?.trim()); }`);
    const temps = new Set<string>();
    const collect = (e: Expression | undefined): void => {
      if (!e) return;
      for (const s of e.block?.statements ?? []) {
        if (s.let?.name?.startsWith("__ball_recv_")) temps.add(s.let.name);
        collect(s.let?.value);
        collect(s.expression);
      }
      collect(e.block?.result);
      for (const f of e.call?.input?.messageCreation?.fields ?? []) collect(f.value);
    };
    collect(expr);
    assert.equal(temps.size, 2, `expected two distinct receiver temps, got ${[...temps]}`);
  });

  test("a NON-optional std-mapped call still emits the bare std call", () => {
    const expr = soleStatementOf(`function f(arr) { arr.push(1); }`);
    assert.ok(expr.call, "expected a bare call, not a guarded block");
    assert.equal(expr.call!.module, "std_collections");
    assert.equal(expr.call!.function, "list_push");
    assert.equal(fieldOf(expr.call!, "list").reference?.name, "arr");
  });

  test("the guard does not re-route through null_aware_call", () => {
    // `null_aware_call` emits its `method` field verbatim as
    // `target?.<method>(...)` in the TARGET language, so a JS spelling like
    // `push` would compile to a nonexistent `List.push` in Dart.
    const expr = soleStatementOf(`function f(arr) { arr?.push(1); }`);
    const names = allCalls(expr).map(c => c.function);
    assert.ok(
      !names.includes("null_aware_call"),
      `std-mapped builtins must not route through null_aware_call, got ${names.join(", ")}`,
    );
  });

  test("?. on a USER-defined method still routes through null_aware_call", () => {
    const expr = soleStatementOf(`function f(o) { o?.greet(); }`);
    assert.equal(expr.call?.module, "std");
    assert.equal(expr.call?.function, "null_aware_call");
  });
});
