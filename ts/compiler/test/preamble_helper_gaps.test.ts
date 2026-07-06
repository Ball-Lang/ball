/**
 * Preamble runtime-helper reachability audit (#62 Phase-2a).
 *
 * preamble.ts is one big `String.raw` template (see compiler.ts's
 * TS_RUNTIME_PREAMBLE import) — c8 only ever sees "one big string
 * assignment", so it always reports 100% regardless of whether any of the
 * ~40 runtime helpers embedded inside it are ever actually exercised. The
 * #62 Phase-1 gap-map's real-coverage proxy (grep every helper's triggering
 * Dart construct against tests/conformance/src/*.dart) found exactly one
 * helper with NO exercising fixture: __ball_math_lcm. Every other helper's
 * triggering construct (arithmetic/comparison operators, is-checks with
 * type args, cascades, addAll, .gcd(), etc.) already has fixture coverage,
 * confirmed via the same grep method — this file only needs to close the
 * one real gap it found, following bigint_hardening.test.ts's pattern
 * (executed test, not a fixture — fixtures test end-to-end Dart behavior,
 * not "does this exact preamble helper fire").
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
import type { Expression, FieldValuePair, Program } from "../src/index.ts";

// ── IR builders (mirrors bigint_hardening.test.ts's convention) ────────
const lit = (v: number): Expression => ({ literal: { intValue: v } });

function mc(fields: Record<string, Expression>): Expression {
  const pairs: FieldValuePair[] = Object.entries(fields).map(([name, value]) => ({ name, value }));
  return { messageCreation: { fields: pairs } };
}

function std(fn: string, fields: Record<string, Expression> = {}): Expression {
  return { call: { module: "std", function: fn, input: mc(fields) } };
}

function printCall(value: Expression): Expression {
  return std("print", { message: value }); // print's own codegen wraps with __ball_to_string
}

type Stmt = { expression?: Expression };

function program(statements: Stmt[]): Program {
  return {
    name: "preamble_helper_gaps_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      { name: "main", functions: [{ name: "main", body: { block: { statements } } }] },
    ],
  };
}

describe("TS compiler — preamble helper reachability (#62 Phase-2a)", () => {
  test("__ball_math_lcm (num.lcm()) — no conformance fixture calls the built-in method (144_lcm_computation.dart defines its own user-level lcm(), never the built-in)", () => {
    const statements: Stmt[] = [
      { expression: printCall(std("math_lcm", { left: lit(4), right: lit(6) }) as Expression) },   // 12
      { expression: printCall(std("math_lcm", { left: lit(12), right: lit(18) }) as Expression) }, // 36
      { expression: printCall(std("math_lcm", { left: lit(7), right: lit(5) }) as Expression) },   // 35
      { expression: printCall(std("math_lcm", { left: lit(0), right: lit(5) }) as Expression) },   // 0 (zero-operand guard)
    ];

    const ts = compile(program(statements));
    const tmpPath = join(tmpdir(), `ball_preamble_gaps_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e: any) {
        throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\n---compiled---\n${ts}`);
      }
      const lines = stdout.replace(/\r\n/g, "\n").trimEnd().split("\n");
      assert.deepEqual(lines, ["12", "36", "35", "0"]);
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});
