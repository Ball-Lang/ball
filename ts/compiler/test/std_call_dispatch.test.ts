/**
 * Table-driven coverage for `compileStdCall`'s base-function dispatch
 * switch (compiler.ts ~lines 4213-5085) — the single largest uncovered
 * cluster in the compiler (~400 lines across ~150 case branches covering
 * arithmetic/comparison field-name fallbacks, string/list/map/set
 * operations, time/random/JSON/UTF-8/base64 helpers, and a SECOND nested
 * dispatch switch (the `default:` arm, ~4942-5083) for less-common
 * collection/utility operations) plus the adjoining try/catch and
 * assignment special cases (`emitTryStmt`'s single-`catch`-field TS-encoder
 * shape, `~/=`, `typedCatchCondition`'s builtin/Dart-exception/user-type
 * branches).
 *
 * Each case builds a minimal function whose body is a single std call, then
 * asserts a regex against the ONE compiled output (compiled once for the
 * whole file) — matching the string-emission testing style used throughout
 * this test suite (see declarations.test.ts). A final sanity check executes
 * the whole file with node to confirm every branch emits syntactically
 * valid TypeScript, not just a regex-matching fragment.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FieldValuePair, FunctionDef, Program } from "../src/index.ts";

// ── IR builders ──────────────────────────────────────────────────────
const ref = (name: string): Expression => ({ reference: { name } });
const lit = (v: string | number | boolean): Expression =>
  typeof v === "string" ? { literal: { stringValue: v } }
    : typeof v === "boolean" ? { literal: { boolValue: v } }
    : { literal: { intValue: v } };
const listLit = (elements: Expression[]): Expression => ({ literal: { listValue: { elements } } });

function mc(fields: Record<string, Expression>): Expression {
  const pairs: FieldValuePair[] = Object.entries(fields).map(([name, value]) => ({ name, value }));
  return { messageCreation: { fields: pairs } };
}

function call(module: string, fn: string, fields: Record<string, Expression> = {}): Expression {
  return {
    call: {
      module,
      function: fn,
      input: Object.keys(fields).length > 0 ? mc(fields) : undefined,
    },
  };
}

const std = (fn: string, fields: Record<string, Expression> = {}) => call("std", fn, fields);

/** A block body: statements then an implicit `return` on the block result. */
function block(stmts: Array<{ let?: { name: string; value?: Expression }; expression?: Expression }>): Expression {
  return { block: { statements: stmts } };
}

// ── Case table: {name, body, expectRegex[]} ─────────────────────────
interface Case {
  name: string;
  body: Expression;
  expect: RegExp[];
}

const cases: Case[] = [
  // Arithmetic/comparison field-name aliases (arg0/arg1 instead of left/right).
  {
    name: "equalsArgAlias",
    body: std("equals", { arg0: ref("a"), arg1: ref("b") }),
    expect: [/__ball_eq\(a, b\)/],
  },
  {
    name: "notEqualsArgAlias",
    body: std("not_equals", { arg0: ref("a"), arg1: ref("b") }),
    expect: [/!__ball_eq\(a, b\)/],
  },
  {
    name: "integerDivide",
    body: std("integer_divide", { left: ref("a"), right: ref("b") }),
    expect: [/__ball_divide\(a, b\)/],
  },
  // String interpolation: with parts, and with no parts field at all.
  {
    name: "stringInterpolationWithParts",
    body: std("string_interpolation", { parts: listLit([lit("hi "), ref("name")]) }),
    expect: [/\('hi '\) \+ \(name\)/],
  },
  {
    name: "stringInterpolationNoParts",
    body: std("string_interpolation", {}),
    expect: [/return '';/],
  },
  // `is`/`is_not` without an explicit type field (bare null-check fallback).
  {
    name: "isNoType",
    body: std("is", { value: ref("x") }),
    expect: [/x != null/],
  },
  {
    name: "isNotNoType",
    body: std("is_not", { value: ref("x") }),
    expect: [/x == null/],
  },
  // assign `~/=` (integer-division-assign) has no direct JS operator.
  {
    name: "assignIntDivEq",
    body: block([{ expression: std("assign", { target: ref("x"), value: ref("y"), op: lit("~/=") }) }]),
    expect: [/x = Math\.trunc\(x \/ y\)/],
  },
  // In-place list mutation: `x = list_concat(list: x, value: y)` → push.
  {
    name: "assignInPlaceListConcat",
    body: block([{ expression: std("assign", { target: ref("x"), value: std("list_concat", { list: ref("x"), value: ref("y") }) }) }]),
    expect: [/__ball_push_all\(x, y\)/],
  },
  // "return" unwraps to its bare value in expression position.
  {
    name: "returnExprPosition",
    body: block([{ let: { name: "r", value: std("return", { value: lit(5) }) } }]),
    expect: [/let r = 5;/],
  },
  // null_aware_call / null_aware_index / null_aware_access.
  {
    name: "nullAwareCall",
    body: std("null_aware_call", { target: ref("obj"), method: lit("toString") }),
    expect: [/obj\?\.toString\(\)/],
  },
  {
    name: "nullAwareIndex",
    body: std("null_aware_index", { self: ref("obj"), index: lit(0) }),
    expect: [/obj\[0\]/],
  },
  {
    name: "nullAwareAccess",
    body: std("null_aware_access", { target: ref("obj"), field: lit("name") }),
    expect: [/obj\?\.name/],
  },
  // typed_list / typed_map / record shapes.
  {
    name: "typedListLiteral",
    body: std("typed_list", { elements: listLit([lit(1), lit(2)]) }),
    expect: [/\[1, 2\]/],
  },
  {
    name: "typedMapWithEntries",
    body: std("typed_map", { entries: listLit([mc({ key: lit("a"), value: lit(1) })]) }),
    expect: [/new Map\(\[\['a', 1\]\]\)/],
  },
  {
    name: "recordAllNamed",
    body: std("record", { label: lit("x"), value: lit(1) }),
    expect: [/\{ label: 'x', value: 1 \}/],
  },
  {
    name: "recordMixedPositionalNamed",
    body: std("record", { arg0: lit(1), label: lit("x") }),
    expect: [/"0": 1, label: 'x'/],
  },
  // set_create with a single non-list-wrapped element field.
  {
    name: "setCreateSingleField",
    body: std("set_create", { element: lit(1) }),
    expect: [/Set\(\[1\]\)/],
  },
  // yield / yield_each.
  {
    name: "yieldEach",
    body: std("yield_each", { value: ref("items") }),
    expect: [/yield\s*\*\s*items/],
  },
  // cascade with no target (falls back to __ball_cascade helper).
  {
    name: "cascadeNoTarget",
    body: std("cascade", { a: lit(1), b: lit(2) }),
    expect: [/__ball_cascade\(1, 2\)/],
  },
  // null_aware_cascade with a target but no sections.
  {
    name: "nullAwareCascadeNoSections",
    body: std("null_aware_cascade", { target: ref("obj") }),
    expect: [/\bobj\b/],
  },
  // invoke with zero and multiple args; tear_off.
  {
    name: "invokeZeroArgs",
    body: std("invoke", { callee: ref("fn") }),
    expect: [/fn\(\)/],
  },
  {
    name: "invokeMultiArgs",
    body: std("invoke", { callee: ref("fn"), a: lit(1), b: lit(2) }),
    expect: [/fn\(1, 2\)/],
  },
  {
    name: "tearOff",
    body: std("tear_off", { callback: ref("onTap") }),
    expect: [/return onTap;/],
  },
  // list_generate / list_filled.
  {
    name: "listGenerate",
    body: std("list_generate", { count: lit(3), generator: ref("gen") }),
    expect: [/Array\.from\(\{\s*length: 3\s*\},\s*\(_, i\) => \(gen\)\(i\)\)/],
  },
  {
    name: "listFilled",
    body: std("list_filled", { count: lit(3), value: lit(0) }),
    expect: [/Array\(3\)\.fill\(0\)/],
  },
  // to_double / to_int / identical.
  {
    name: "toDouble",
    body: std("to_double", { value: ref("n") }),
    expect: [/new BallDouble\(Number\(n\)\)/],
  },
  {
    name: "identical",
    body: std("identical", { left: ref("a"), right: ref("b") }),
    expect: [/\(a === b\)/],
  },
  // string char/replace/repeat/pad/index ops.
  {
    name: "stringCharCodeAt",
    body: std("string_char_code_at", { value: ref("s"), index: lit(0) }),
    expect: [/s\.charCodeAt\(0\)/],
  },
  {
    name: "stringFromCharCode",
    body: std("string_from_char_code", { value: lit(65) }),
    expect: [/String\.fromCharCode\(65\)/],
  },
  {
    name: "stringCharAt",
    body: std("string_char_at", { value: ref("s"), index: lit(0) }),
    expect: [/s\[0\]/],
  },
  {
    name: "stringReplace",
    body: std("string_replace", { value: ref("s"), from: lit("a"), to: lit("b") }),
    expect: [/s\.replace\('a', 'b'\)/],
  },
  {
    name: "stringReplaceAll",
    body: std("string_replace_all", { value: ref("s"), from: lit("a"), to: lit("b") }),
    expect: [/s\.split\('a'\)\.join\('b'\)/],
  },
  {
    name: "stringRepeat",
    body: std("string_repeat", { value: ref("s"), count: lit(3) }),
    expect: [/s\.repeat\(3\)/],
  },
  {
    name: "stringPadLeft",
    body: std("string_pad_left", { value: ref("s"), width: lit(5) }),
    expect: [/s\.padStart\(5\)/],
  },
  {
    name: "stringPadRight",
    body: std("string_pad_right", { value: ref("s"), width: lit(5), padding: lit("0") }),
    expect: [/s\.padEnd\(5, '0'\)/],
  },
  {
    name: "stringIndexOfWithStart",
    body: std("string_index_of", { value: ref("s"), pattern: lit("a"), start: lit(2) }),
    expect: [/s\.indexOf\('a', 2\)/],
  },
  {
    name: "stringLastIndexOf",
    body: std("string_last_index_of", { value: ref("s"), pattern: lit("a") }),
    expect: [/s\.lastIndexOf\('a'\)/],
  },
  // List ops.
  {
    name: "listPush",
    body: std("list_push", { list: ref("l"), value: lit(1) }),
    expect: [/l\.push\(1\), l/],
  },
  {
    name: "listPop",
    body: std("list_pop", { list: ref("l") }),
    expect: [/l\.pop\(\)/],
  },
  {
    name: "listIsEmpty",
    body: std("list_is_empty", { list: ref("l") }),
    expect: [/\(l\.length === 0\)/],
  },
  {
    name: "listFirst",
    body: std("list_first", { list: ref("l") }),
    expect: [/l\[0\]/],
  },
  {
    name: "listLast",
    body: std("list_last", { list: ref("l") }),
    expect: [/l\[l\.length - 1\]/],
  },
  {
    name: "listContains",
    body: std("list_contains", { list: ref("l"), value: lit(1) }),
    expect: [/l\.includes\(1\)/],
  },
  {
    name: "listSet",
    body: block([{ expression: std("list_set", { list: ref("l"), index: lit(0), value: lit(9) }) }]),
    expect: [/l\[0\] = 9/],
  },
  {
    name: "listIndexOf",
    body: std("list_index_of", { list: ref("l"), value: lit(1) }),
    expect: [/l\.indexOf\(1\)/],
  },
  {
    name: "listReverse",
    body: std("list_reverse", { list: ref("l") }),
    expect: [/\[\.\.\.l\]\.reverse\(\)/],
  },
  {
    name: "listSlice",
    body: std("list_sublist", { list: ref("l"), start: lit(1), end: lit(3) }),
    expect: [/l\.slice\(1, 3\)/],
  },
  // Map ops.
  {
    name: "mapContainsKey",
    body: std("map_contains_key", { map: ref("m"), key: lit("k") }),
    expect: [/\('k' in m\)/],
  },
  {
    name: "mapKeys",
    body: std("map_keys", { map: ref("m") }),
    expect: [/Object\.keys\(m\)/],
  },
  {
    name: "mapValues",
    body: std("map_values", { map: ref("m") }),
    expect: [/Object\.values\(m\)/],
  },
  {
    name: "mapEntries",
    body: std("map_entries", { map: ref("m") }),
    expect: [/Object\.entries\(m\)\.map/],
  },
  {
    name: "mapIsEmpty",
    body: std("map_is_empty", { map: ref("m") }),
    expect: [/Object\.keys\(m\)\.length === 0/],
  },
  {
    name: "mapDelete",
    body: std("map_delete", { map: ref("m"), key: lit("k") }),
    expect: [/delete __m\[__k\]/],
  },
  {
    name: "mapMerge",
    body: std("map_merge", { left: ref("m1"), right: ref("m2") }),
    expect: [/\{\s*\.\.\.m1,\s*\.\.\.m2\s*\}/],
  },
  {
    name: "mapFromEntries",
    body: std("map_from_entries", { entries: ref("es") }),
    expect: [/Object\.fromEntries\(es\.map/],
  },
  {
    name: "stringJoinNoSep",
    body: std("string_join", { list: ref("l") }),
    expect: [/l\.join\(''\)/],
  },
  {
    name: "setStub",
    body: std("set_union", { left: ref("a"), right: ref("b") }),
    expect: [/set_union\(a, b\)/],
  },
  // I/O and misc runtime.
  {
    name: "printError",
    body: std("print_error", { message: lit("oops") }),
    expect: [/console\.error\(__ball_to_string\('oops'\)\)/],
  },
  {
    name: "exitWithCode",
    body: std("exit", { code: lit(1) }),
    expect: [/process\.exit\(1\)/],
  },
  {
    name: "timestampMs",
    body: std("timestamp_ms", {}),
    expect: [/Date\.now\(\)/],
  },
  {
    name: "formatTimestamp",
    body: std("format_timestamp", { value: lit(0) }),
    expect: [/DateTime\.fromMillisecondsSinceEpoch\(0, true\)\.toIso8601String\(\)/],
  },
  {
    name: "timeComponents",
    body: std("time_components", { value: lit(0) }),
    expect: [/getUTCFullYear/],
  },
  {
    name: "randomInt",
    body: std("random_int", { max: lit(10) }),
    expect: [/Math\.floor\(Math\.random\(\) \* 10\)/],
  },
  // JSON / UTF-8 / base64 / symbol.
  {
    name: "jsonEncode",
    body: std("json_encode", { value: ref("obj") }),
    expect: [/JSON\.stringify\(obj\)/],
  },
  {
    name: "jsonDecode",
    body: std("json_decode", { value: ref("s") }),
    expect: [/JSON\.parse\(s\)/],
  },
  {
    name: "utf8Encode",
    body: std("utf8_encode", { value: ref("s") }),
    expect: [/TextEncoder\(\)\.encode\(s\)/],
  },
  {
    name: "utf8Decode",
    body: std("utf8_decode", { value: ref("bytes") }),
    expect: [/TextDecoder\(\)\.decode\(new Uint8Array\(bytes\)\)/],
  },
  {
    name: "base64Encode",
    body: std("base64_encode", { value: ref("bytes") }),
    expect: [/btoa\(String\.fromCharCode/],
  },
  {
    name: "base64Decode",
    body: std("base64_decode", { value: ref("s") }),
    expect: [/atob\(s\)/],
  },
  {
    name: "symbolLiteral",
    body: std("symbol", { value: lit("foo") }),
    expect: [/Symbol\("' \+ __ball_to_string\('foo'\)/],
  },
  {
    name: "typeLiteral",
    body: std("type_literal", { value: lit("int") }),
    expect: [/return 'int';/],
  },
  // ── Second-level dispatch (the `default:` arm's nested switch, ~4942-5083). ──
  {
    name: "mapPutIfAbsent",
    body: std("map_put_if_absent", { map: ref("m"), key: lit("k"), value: ref("supplier") }),
    expect: [/m\['k'\] \?\?= \(supplier\)\(\)/],
  },
  {
    name: "listInsert",
    body: std("list_insert", { list: ref("l"), index: lit(0), value: lit(9) }),
    expect: [/l\.splice\(0, 0, 9\)/],
  },
  {
    name: "listRemoveAt",
    body: std("list_remove_at", { list: ref("l"), index: lit(0) }),
    expect: [/l\.splice\(0, 1\)\[0\]/],
  },
  {
    name: "listClear",
    body: std("list_clear", { list: ref("l") }),
    expect: [/l\.length = 0/],
  },
  {
    name: "listSortNoComparator",
    body: std("list_sort", { list: ref("l") }),
    expect: [/\[\.\.\.l\]\.sort\(\(a, b\) => a < b \? -1 : a > b \? 1 : 0\)/],
  },
  {
    name: "listSortWithComparator",
    body: std("list_sort", { list: ref("l"), comparator: ref("cmp") }),
    expect: [/\[\.\.\.l\]\.sort\(cmp\)/],
  },
  {
    name: "listAny",
    body: std("list_any", { list: ref("l"), function: ref("pred") }),
    expect: [/l\.some\(pred\)/],
  },
  {
    name: "listAll",
    body: std("list_all", { list: ref("l"), function: ref("pred") }),
    expect: [/l\.every\(pred\)/],
  },
  {
    name: "mapForeach",
    body: std("map_foreach", { map: ref("m"), callback: ref("cb") }),
    expect: [/Object\.entries\(m\)\.forEach\(\(\[k, v\]\) => cb\(k, v\)\)/],
  },
  {
    name: "compareTo",
    body: std("compare_to", { value: ref("a"), other: ref("b") }),
    expect: [/a < b \? -1 : a > b \? 1 : 0/],
  },
  {
    name: "toStringAsFixed",
    body: std("to_string_as_fixed", { value: ref("n"), digits: lit(2) }),
    expect: [/\(\+\(n\)\)\.toFixed\(2\)/],
  },
  {
    name: "roundToDouble",
    body: std("round_to_double", { value: ref("n") }),
    expect: [/new BallDouble\(Math\.round\(\+\(n\)\)\)/],
  },
  {
    name: "mathClampNormal",
    body: std("math_clamp", { value: ref("n"), min: lit(0), max: lit(10) }),
    expect: [/Math\.min\(Math\.max\(n, 0\), 10\)/],
  },
  {
    name: "collectionForFallback",
    // A bare collection_for call reached outside a list/set/map literal
    // context (falls through to the imperative-IIFE fallback builder).
    body: std("collection_for", {
      variable: lit("i"),
      iterable: ref("items"),
      element: ref("i"),
    }),
    expect: [/const __r: any\[\] = \[\];/],
  },
  {
    name: "unknownStdFnDefaultFallback",
    // A name matching NEITHER the main switch NOR the nested default
    // switch must fall to the final bare-call default (silent-failure
    // guard tested elsewhere for std_memory; here for plain `std`).
    body: std("__totally_made_up_std_fn__", { value: ref("x") }),
    expect: [/\/\* std\.__totally_made_up_std_fn__ \*\/ __totally_made_up_std_fn__\(x\)/],
  },
];

// ── try/catch + assign special cases (separate program each, since they
// need statement-position bodies and typed catch clauses). ──

function tryProgram(functionsExtra: FunctionDef[]): Program {
  return {
    name: "try_catch_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      { name: "std", functions: [{ name: "print", isBase: true }] },
      { name: "main", functions: [{ name: "main", body: lit(0) }, ...functionsExtra] },
    ],
  };
}

describe("compiler — compileStdCall dispatch table", () => {
  let ts = "";
  before(() => {
    const program: Program = {
      name: "std_call_dispatch_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "add", isBase: true }] },
        {
          name: "main",
          functions: [
            { name: "main", body: lit(0) },
            ...cases.map((c): FunctionDef => ({ name: c.name, body: c.body })),
          ],
        },
      ],
    };
    ts = compile(program, { includePreamble: false });
  });

  for (const c of cases) {
    test(c.name, () => {
      for (const re of c.expect) {
        assert.match(ts, re, `${c.name}: expected output to match ${re}`);
      }
    });
  }

  test("the whole compiled file is syntactically valid TypeScript (executes without a parse error)", () => {
    const tmpPath = join(tmpdir(), `ball_std_dispatch_${process.pid}.ts`);
    // Re-compile WITH the preamble so runtime helpers (__ball_eq, BallDouble,
    // etc.) resolve; none of the generated functions are actually called.
    const full = compile(
      {
        name: "std_call_dispatch_test",
        entryModule: "main",
        entryFunction: "main",
        modules: [
          { name: "std", functions: [{ name: "add", isBase: true }] },
          {
            name: "main",
            functions: [
              { name: "main", body: lit(0) },
              ...cases.map((c): FunctionDef => ({ name: c.name, body: c.body })),
            ],
          },
        ],
      },
    );
    writeFileSync(tmpPath, full);
    try {
      execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

describe("compiler — try/catch special cases", () => {
  test("a single `catch` field (TS-encoder shape) with a finally block", () => {
    const program = tryProgram([
      {
        name: "tryWithSingleCatch",
        body: block([
          {
            expression: std("try", {
              body: block([{ expression: std("print", { message: lit("body") }) }]),
              catch: mc({
                variable: lit("err"),
                body: block([{ expression: std("print", { message: lit("caught") }) }]),
              }),
              finally: block([{ expression: std("print", { message: lit("cleanup") }) }]),
            }),
          },
        ]),
      },
    ]);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /catch \(err\) \{/);
    assert.match(ts, /finally \{/);
  });

  test("typedCatchCondition: a JS builtin exception type (TypeError)", () => {
    const program = tryProgram([
      {
        name: "tryTypedBuiltin",
        body: block([
          {
            expression: std("try", {
              body: block([{ expression: std("print", { message: lit("x") }) }]),
              catches: listLit([
                mc({
                  type: lit("TypeError"),
                  variable: lit("e"),
                  body: block([{ expression: std("print", { message: lit("caught") }) }]),
                }),
              ]),
            }),
          },
        ]),
      },
    ]);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_active_error instanceof TypeError/);
  });

  test("typedCatchCondition: a Dart-only exception type (StateError) checked by message", () => {
    const program = tryProgram([
      {
        name: "tryTypedDartException",
        body: block([
          {
            expression: std("try", {
              body: block([{ expression: std("print", { message: lit("x") }) }]),
              catches: listLit([
                mc({
                  type: lit("StateError"),
                  variable: lit("e"),
                  body: block([{ expression: std("print", { message: lit("caught") }) }]),
                }),
              ]),
            }),
          },
        ]),
      },
    ]);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /__ball_active_error\.message\.includes\('StateError'\)/);
  });

  test("typedCatchCondition: an unrecognized/user type guards `instanceof` with a typeof check", () => {
    const program = tryProgram([
      {
        name: "tryTypedUserType",
        body: block([
          {
            expression: std("try", {
              body: block([{ expression: std("print", { message: lit("x") }) }]),
              catches: listLit([
                mc({
                  type: lit("MyCustomError"),
                  variable: lit("e"),
                  stack_trace: lit("st"),
                  body: block([{ expression: std("print", { message: lit("caught") }) }]),
                }),
              ]),
            }),
          },
        ]),
      },
    ]);
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /typeof MyCustomError !== 'undefined' && __ball_active_error instanceof MyCustomError/);
    // The stack_trace binding must also be emitted.
    assert.match(ts, /const st = \(__ball_active_error instanceof Error/);
  });
});
