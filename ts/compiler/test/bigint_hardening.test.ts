/**
 * TS-BigInt hardening (#132) — executed end-to-end runtime behavior for the
 * preamble's 64-bit BigInt helpers, which the codegen-shape tests in
 * std_call_dispatch.test.ts don't reach (they regex-match compiled TEXT;
 * these values only differ at RUNTIME).
 *
 * Covers:
 *  - The 32-bit AND/OR/XOR/NOT fast path (__fits32) at the signed-32
 *    boundary and with negative operands, proven identical to the full
 *    64-bit BigInt path (values pre-computed independently via
 *    BigInt.asIntN(64, ...) — see the comment above each expected value).
 *  - __to_bigint defaulting a null/undefined operand to 0, matching the
 *    reference Dart engine's _toInt (engine_std.dart) fallback.
 *  - BigInt.prototype.toJSON emitting the exact decimal digits as an
 *    UNQUOTED JSON number (via JSON.rawJSON) for an int64 beyond
 *    Number.MAX_SAFE_INTEGER — matching Dart's dart:convert and the C++
 *    self-host's _ball_json_encode (std::to_string on int64_t), NOT the
 *    unrelated proto3-JSON convention (which quotes int64 as a string;
 *    that's for .ball.json program files, not user-program jsonEncode).
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FieldValuePair, Program } from "../src/index.ts";

// ── IR builders (mirrors std_call_dispatch.test.ts's convention) ───────
const ref = (name: string): Expression => ({ reference: { name } });
const lit = (v: number): Expression => ({ literal: { intValue: v } });
// A literal beyond Number.MAX_SAFE_INTEGER must be given as a STRING here —
// a bare JS number literal rounds to the nearest double the instant it's
// parsed by THIS test file (e.g. 9223372036854775807 becomes
// 9223372036854776000 in the .ts source itself, before the compiler ever
// sees it), independent of anything under test.
const bigLit = (v: string): Expression => ({ literal: { intValue: v } });

function mc(fields: Record<string, Expression>): Expression {
  const pairs: FieldValuePair[] = Object.entries(fields).map(([name, value]) => ({ name, value }));
  return { messageCreation: { fields: pairs } };
}

function std(fn: string, fields: Record<string, Expression> = {}): Expression {
  return {
    call: {
      module: fn === "json_encode" ? "std_convert" : "std",
      function: fn,
      input: Object.keys(fields).length > 0 ? mc(fields) : undefined,
    },
  };
}

function printCall(value: Expression): Expression {
  return std("print", { message: value }); // print's own codegen wraps with __ball_to_string
}

type Stmt = { let?: { name: string; value?: Expression }; expression?: Expression };

function program(statements: Stmt[]): Program {
  return {
    name: "bigint_hardening_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      { name: "main", functions: [{ name: "main", body: { block: { statements } } }] },
    ],
  };
}

describe("TS compiler — BigInt hardening (#132) executed end-to-end", () => {
  test("32-bit fast path, __to_bigint null-safety, and BigInt.toJSON all match expected values", () => {
    const INT32_MAX = 2147483647;
    const INT32_MIN = -2147483648;

    const statements: Stmt[] = [
      // 32-bit fast path: boundary values + negative operands. Each expected
      // value below was independently computed via
      // BigInt.asIntN(64, BigInt(a) <op> BigInt(b)) — the full 64-bit path —
      // to prove the 32-bit fast path is behavior-identical, not just
      // internally self-consistent.
      { expression: printCall(std("bitwise_and", { left: lit(INT32_MAX), right: lit(-1) })) }, // 2147483647
      { expression: printCall(std("bitwise_and", { left: lit(INT32_MIN), right: lit(-1) })) }, // -2147483648
      { expression: printCall(std("bitwise_or", { left: lit(-5), right: lit(3) })) },          // -5
      { expression: printCall(std("bitwise_xor", { left: lit(-1), right: lit(INT32_MAX) })) }, // -2147483648
      { expression: printCall(std("bitwise_not", { value: lit(INT32_MAX) })) },                // -2147483648
      { expression: printCall(std("bitwise_not", { value: lit(INT32_MIN) })) },                // 2147483647

      // __to_bigint null-safety: an uninitialized variable used as a
      // bitwise operand must default to 0 (matching the reference Dart
      // engine's _toInt fallback), not throw or silently misbehave. OR
      // (rather than AND) is the differentiator: if the null operand
      // contributed anything other than exactly 0, the result would not
      // be exactly 5.
      { let: { name: "x" } },
      { expression: printCall(std("bitwise_or", { left: ref("x"), right: lit(5) })) }, // 5

      // BigInt.prototype.toJSON: an int64 past Number.MAX_SAFE_INTEGER
      // (compiled as a genuine `bigint`, see compileLiteral) must serialize
      // as the exact digit string, UNQUOTED (a raw JSON number token, not a
      // proto3-JSON-style quoted string).
      { expression: std("print", { message: std("json_encode", { value: bigLit("9223372036854775807") }) }) },
    ];

    const ts = compile(program(statements));
    const tmpPath = join(tmpdir(), `ball_bigint_hardening_${process.pid}.ts`);
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
      assert.deepEqual(lines, [
        "2147483647",
        "-2147483648",
        "-5",
        "-2147483648",
        "-2147483648",
        "2147483647",
        "5",
        "9223372036854775807",
      ]);
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});
