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
  // A "type_args" field (the encoder's current TypeRef-migration marker for
  // cosmetic type arguments) must be excluded like the older
  // "__type_args__" — otherwise it gets pushed in as a bogus named field,
  // identical in kind to the `<int>{}` -> `new Set(['int'])` bug #219 fixed
  // for set_create (#236).
  {
    name: "recordTypeArgsExcluded",
    body: std("record", { label: lit("x"), value: lit(1), type_args: lit("int") }),
    expect: [/\{ label: 'x', value: 1 \}/],
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
    // Wrapped in __ball_require_map so a List/primitive fails loud instead
    // of `in` silently checking array-index membership or throwing an
    // unhelpful native error (#257).
    expect: [/\('k' in __ball_require_map\(m, 'map_contains_key'\)\)/],
  },
  {
    name: "mapKeys",
    body: std("map_keys", { map: ref("m") }),
    // Routes through __ball_map_keys (not a bare Object.keys) so a non-Map
    // receiver fails loud instead of silently returning [] (#218).
    expect: [/__ball_map_keys\(m\)/],
  },
  {
    name: "mapValues",
    body: std("map_values", { map: ref("m") }),
    expect: [/__ball_map_values\(m\)/],
  },
  {
    name: "mapEntries",
    body: std("map_entries", { map: ref("m") }),
    // Routes through __ball_map_entries (not a bare Object.entries) so a
    // non-Map receiver fails loud instead of silently returning [] (#218).
    expect: [/__ball_map_entries\(m\)/],
  },
  {
    name: "mapIsEmpty",
    body: std("map_is_empty", { map: ref("m") }),
    expect: [/Object\.keys\(__ball_require_map\(m, 'map_is_empty'\)\)\.length === 0/],
  },
  {
    name: "mapDelete",
    body: std("map_delete", { map: ref("m"), key: lit("k") }),
    expect: [/delete __m\[__k\]/],
  },
  {
    name: "mapMerge",
    body: std("map_merge", { left: ref("m1"), right: ref("m2") }),
    expect: [/\{\s*\.\.\.__ball_require_map\(m1, 'map_merge'\),\s*\.\.\.__ball_require_map\(m2, 'map_merge'\)\s*\}/],
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
  { name: "stringJoinMissing", body: std("string_join", {}), expect: [/return '';/] },
  // set_union (and its set_* siblings) used to compile to a stub bare-
  // identifier call here; now a compile-time throw (#257, see the dedicated
  // "set_* is confirmed-dead codegen" describe block below) — removed from
  // this shared-compile table since a throwing case would fail the ONE
  // combined compile() this table's before() hook does for every case.
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
  // ── Missing-field fallbacks (the encoder always provides the primary
  // field name in practice, so these "graceful degradation" branches are
  // otherwise unreachable by any conformance fixture). ──
  { name: "identicalMissing", body: std("identical", { left: ref("a") }), expect: [/return "false";|return false;|\bfalse\b/] },
  { name: "stringCharCodeAtMissing", body: std("string_char_code_at", { value: ref("s") }), expect: [/return "0";|return 0;/] },
  { name: "stringCharAtMissing", body: std("string_char_at", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringReplaceMissing", body: std("string_replace", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringReplaceAllMissing", body: std("string_replace_all", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringRepeatMissing", body: std("string_repeat", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringPadLeftMissing", body: std("string_pad_left", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringPadRightMissing", body: std("string_pad_right", { value: ref("s") }), expect: [/return "";|return '';/] },
  { name: "stringIndexOfNoStart", body: std("string_index_of", { value: ref("s"), pattern: lit("a") }), expect: [/s\.indexOf\('a'\)(?!, )/] },
  { name: "stringIndexOfMissing", body: std("string_index_of", { value: ref("s") }), expect: [/return -1;|return "-1";/] },
  { name: "stringLastIndexOfMissing", body: std("string_last_index_of", { value: ref("s") }), expect: [/return -1;|return "-1";/] },
  { name: "listPushMissing", body: std("list_push", { list: ref("l") }), expect: [/return \[\];/] },
  { name: "listLengthOfList", body: std("list_length", { list: ref("l") }), expect: [/l\.length/] },
  { name: "listLengthMissing", body: std("list_length", {}), expect: [/return 0;|return "0";/] },
  { name: "listContainsMissing", body: std("list_contains", { list: ref("l") }), expect: [/return false;|return "false";/] },
  { name: "listGet", body: std("list_get", { list: ref("l"), index: lit(0) }), expect: [/l\[0\]/] },
  { name: "listGetMissing", body: std("list_get", { list: ref("l") }), expect: [/return undefined;/] },
  { name: "listSetMissing", body: block([{ expression: std("list_set", { list: ref("l"), index: lit(0) }) }]), expect: [/return undefined;/] },
  { name: "listIndexOfMissing", body: std("list_index_of", { list: ref("l") }), expect: [/return -1;|return "-1";/] },
  // list_concat's OWN dispatch case (as opposed to the "assign" in-place-
  // mutation shortcut, which intercepts the common `x = list_concat(x, y)`
  // shape before it ever reaches this switch).
  { name: "listConcatDirect", body: std("list_concat", { left: ref("a"), right: ref("b") }), expect: [/__ball_concat\(a, b\)/] },
  // "list" (unlike "left") isn't touched by any of the right-side aliases
  // (right/other/value → arg0/left), so this genuinely leaves `r` unresolved.
  { name: "listConcatMissing", body: std("list_concat", { list: ref("a") }), expect: [/return \[\];/] },
  { name: "listSliceMissing", body: std("list_sublist", { start: lit(0) }), expect: [/return \[\];/] },
  { name: "mapGet", body: std("map_get", { map: ref("m"), key: lit("k") }), expect: [/m\['k'\]/] },
  { name: "mapGetMissing", body: std("map_get", { map: ref("m") }), expect: [/return undefined;/] },
  { name: "mapSet", body: block([{ expression: std("map_set", { map: ref("m"), key: lit("k"), value: lit(1) }) }]), expect: [/__ball_require_map\(m, 'map_set'\)\['k'\] = 1/] },
  { name: "mapSetMissing", body: block([{ expression: std("map_set", { map: ref("m") }) }]), expect: [/return undefined;/] },
  { name: "mapContainsKeyMissing", body: std("map_contains_key", { map: ref("m") }), expect: [/return false;|return "false";/] },
  { name: "mapLength", body: std("map_length", { map: ref("m") }), expect: [/Object\.keys\(__ball_require_map\(m, 'map_length'\)\)\.length/] },
  { name: "mapLengthMissing", body: std("map_length", {}), expect: [/return 0;|return "0";/] },
  { name: "mapDeleteMissing", body: std("map_delete", { map: ref("m") }), expect: [/return undefined;/] },
  { name: "mapMergeMissing", body: std("map_merge", { left: ref("a") }), expect: [/return \{\};/] },
  { name: "mapFromEntriesMissing", body: std("map_from_entries", {}), expect: [/return \{\};/] },
  { name: "listGenerateMissing", body: std("list_generate", { count: lit(3) }), expect: [/return \[\];/] },
  { name: "listFilledMissing", body: std("list_filled", { count: lit(3) }), expect: [/return \[\];/] },
  { name: "sleepMsMissing", body: std("sleep_ms", {}), expect: [/return undefined;/] },
  { name: "parseTimestampMissing", body: std("parse_timestamp", {}), expect: [/return 0;|return "0";/] },
  { name: "intToDoubleMissing", body: std("int_to_double", {}), expect: [/new BallDouble\(0\)/] },
  { name: "typedListNonListElements", body: std("typed_list", { elements: ref("xs") }), expect: [/\bxs\b/] },
  { name: "typedListMissing", body: std("typed_list", {}), expect: [/return \[\];/] },
  // set_create: a field name that's neither "elements"/"element" nor one of
  // the type-args cosmetic markers falls through to the generic
  // push-as-element branch (#219's regression guard).
  {
    name: "setCreateExtraFieldAsElement",
    body: std("set_create", { extra: lit(5) }),
    expect: [/Set\(\[5\]\)/],
  },
  // null_spread with a value present (the existing table only covers the
  // no-value fallback via cascade-style tests elsewhere).
  { name: "nullSpreadWithValue", body: std("null_spread", { value: ref("xs") }), expect: [/\(xs \?\? \[\]\)/] },
  { name: "invokeNoCallee", body: std("invoke", {}), expect: [/return null;/] },
  // cascade / null_aware_cascade with a target AND sections, both as a
  // list-literal (multiple sections) and as a single non-list expression.
  {
    name: "cascadeTargetWithSectionsList",
    body: std("cascade", { target: ref("obj"), sections: listLit([ref("a"), ref("b")]) }),
    expect: [/__cascade_self__\) => \{ a; b; return __cascade_self__; \}\)\(obj\)/],
  },
  {
    name: "cascadeTargetWithSectionsExpr",
    body: std("cascade", { target: ref("obj"), sections: ref("single") }),
    expect: [/__cascade_self__\) => \{ single; return __cascade_self__; \}\)\(obj\)/],
  },
  {
    name: "cascadeTargetNoSections",
    body: std("cascade", { target: ref("obj") }),
    expect: [/\bobj\b/],
  },
  {
    name: "nullAwareCascadeTargetWithSectionsList",
    body: std("null_aware_cascade", { target: ref("obj"), sections: listLit([ref("a")]) }),
    expect: [/if \(__cascade_self__ == null\) return null; a; return __cascade_self__;/],
  },
  {
    name: "nullAwareCascadeTargetWithSectionsExpr",
    body: std("null_aware_cascade", { target: ref("obj"), sections: ref("single") }),
    expect: [/if \(__cascade_self__ == null\) return null; single; return __cascade_self__;/],
  },
  // `for`/`do_while`/`assign` used in EXPRESSION position (e.g. as a `let`
  // binding's value) route through compileStdCall's own IIFE-wrapping
  // cases — a DIFFERENT path than the same functions appearing as a bare
  // statement, which emitControlFlowStatement/emitAssignStmt handle directly.
  {
    name: "forExprPosition",
    body: block([{ let: { name: "r", value: std("for", {
      variable: lit("i"), start: lit(0), condition: ref("cond"), update: ref("upd"), body: ref("noop"),
    }) } }]),
    expect: [/for \(let i = 0; cond; upd\)/],
  },
  {
    name: "doWhileExprPosition",
    body: block([{ let: { name: "r", value: std("do_while", { condition: ref("cond"), body: ref("noop") }) } }]),
    expect: [/do \{[\s\S]*\} while \(cond\);/],
  },
  {
    name: "assignIntDivEqExprPosition",
    body: block([{ let: { name: "r", value: std("assign", { target: ref("x"), value: ref("y"), op: lit("~/=") }) } }]),
    expect: [/x = Math\.trunc\(x \/ y\)/],
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
    expect: [/Object\.entries\(__ball_require_map\(m, 'map_foreach'\)\)\.forEach\(\(\[k, v\]\) => cb\(k, v\)\)/],
  },
  {
    name: "compareTo",
    body: std("compare_to", { value: ref("a"), other: ref("b") }),
    expect: [/a < b \? -1 : a > b \? 1 : 0/],
  },
  {
    name: "toStringAsFixed",
    body: std("to_string_as_fixed", { value: ref("n"), digits: lit(2) }),
    expect: [/__ball_to_fixed\(n, 2\)/],
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
  // "unknownStdFnDefaultFallback" (a name matching neither the main switch
  // nor the nested default switch) used to fall to a bare-call fallback
  // here; compileStdCall's default now throws a compile-time Error naming
  // the unimplemented function instead (#257, see the dedicated describe
  // block below) — removed from this shared-compile table for the same
  // reason as set_union above.
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

describe("compiler — compileStdCall: fg() helper's own missing-field fallback", () => {
  test("an arithmetic op with none of its expected fields throws (fg() returns undefined, then the non-null-asserted expr(undefined) fails loud)", () => {
    // Every fg() call site immediately non-null-asserts its result, so a
    // genuinely-missing field is never silently tolerated — matching
    // CLAUDE.md's "fail loud" invariant instead of emitting `undefined`.
    const program: Program = {
      name: "fg_missing_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "main", functions: [
          { name: "main", body: lit(0) },
          { name: "addMissingFields", body: std("add", {}) },
        ] },
      ],
    };
    assert.throws(() => compile(program, { includePreamble: false }));
  });
});

describe("compiler — compileStdCall: math_clamp static-method-call shift", () => {
  test("MathUtils.clamp(v, lo, hi) encodes 'value' as a class reference and shifts args", () => {
    // The encoder maps a static call like MathUtils.clamp(5, 0, 10) to
    // math_clamp(value: MathUtils, min: 5, max: 0, arg2: 10) — 'value'
    // being a reference to the class itself (not the actual clamped value)
    // is the signal to shift min/max/arg2 into the real (value, lo, hi).
    const program: Program = {
      name: "math_clamp_shift_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [{ name: "main:MathUtils", metadata: { kind: "class" } }],
          functions: [
            { name: "main", body: lit(0) },
            {
              name: "clampViaStaticCall",
              body: std("math_clamp", {
                value: ref("MathUtils"),
                min: lit(5),
                max: lit(0),
                arg2: lit(10),
              }),
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /Math\.min\(Math\.max\(5, 0\), 10\)/);
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

describe("compiler — std.map_keys/std.map_values/std.map_entries fail loud on a non-Map receiver (#218)", () => {
  test("map_keys/map_values/map_entries on a real Map succeed; on a non-Map they throw (caught by std.try)", () => {
    // This exercises the DIRECT base-function-call form (module: "std",
    // function: "map_keys"/"map_values"/"map_entries") — a different
    // compileStdCall case than the `.keys`/`.values`/`.entries`
    // DART-GETTER-STYLE property access, which preamble.ts's defDartGetter
    // block already guards. Before #218, all three cases emitted a bare
    // `Object.keys(...)`/`Object.values(...)`/`Object.entries(...)` with no
    // Map check, silently returning garbage for a non-Map instead of
    // throwing — the class of silent-degradation bug that hid issue #55.
    // (.entries's OWN getter had the same gap too — fixed alongside.)
    const tryMapFn = (fn: string, mapExpr: Expression) => std("try", {
      body: block([{ expression: std("print", { message: std(fn, { map: mapExpr }) }) }]),
      catch: mc({
        variable: lit("e"),
        body: block([{ expression: std("print", { message: lit("threw") }) }]),
      }),
    });
    const program: Program = {
      name: "map_keys_values_entries_fail_loud_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] },
        {
          name: "main",
          functions: [
            {
              name: "main",
              body: block([
                { let: { name: "m", value: std("map_create", { entry: mc({ key: lit("a"), value: lit(1) }) }) } },
                { expression: std("print", { message: std("map_keys", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_values", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_entries", { map: ref("m") }) }) },
                { expression: tryMapFn("map_keys", lit(42)) },
                { expression: tryMapFn("map_values", lit("hi")) },
                { expression: tryMapFn("map_entries", lit(7)) },
              ]),
            },
          ],
        },
      ],
    };
    const tmpPath = join(tmpdir(), `ball_map_fail_loud_${process.pid}.ts`);
    writeFileSync(tmpPath, compile(program));
    try {
      const out = execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8" }).trim();
      assert.equal(out, "[a]\n[1]\n[{key: a, value: 1}]\nthrew\nthrew\nthrew");
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

describe("compiler — remaining map_* base functions fail loud on a non-Map receiver (#257)", () => {
  test("map_get/map_set/map_contains_key/map_length/map_is_empty/map_delete/map_merge/map_contains_value/map_foreach: real Map succeeds, non-Map throws", () => {
    // The #218 fix (PR #256) only covered map_keys/map_values/map_entries.
    // These nine siblings had the identical unguarded gap: bare bracket
    // access (map_get/map_set), `key in map` (map_contains_key — throws
    // for primitives already via JS's own `in`, but NOT for a List, which
    // silently checks array-index membership instead), Object.keys/values/
    // entries with no guard (map_length/map_is_empty/map_contains_value/
    // map_foreach), delete map[key] (map_delete, silent no-op on a
    // primitive), and {...l, ...r} (map_merge, silently produces {} for a
    // non-object). All now route through the shared __ball_require_map
    // guard added in preamble.ts.
    const tryMapFn = (fn: string, fields: Record<string, Expression>) => std("try", {
      body: block([{ expression: std("print", { message: std(fn, fields) }) }]),
      catch: mc({
        variable: lit("e"),
        body: block([{ expression: std("print", { message: lit("threw") }) }]),
      }),
    });
    const program: Program = {
      name: "map_ops_fail_loud_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] },
        {
          name: "main",
          functions: [
            {
              name: "main",
              body: block([
                { let: { name: "m", value: std("map_create", { entry: mc({ key: lit("a"), value: lit(1) }) }) } },
                // Real-Map success, one representative case per function.
                { expression: std("print", { message: std("map_get", { map: ref("m"), key: lit("a") }) }) },
                { expression: std("map_set", { map: ref("m"), key: lit("b"), value: lit(2) }) },
                { expression: std("print", { message: std("map_contains_key", { map: ref("m"), key: lit("a") }) }) },
                { expression: std("print", { message: std("map_length", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_is_empty", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_delete", { map: ref("m"), key: lit("b") }) }) },
                { expression: std("print", { message: std("map_merge", { left: ref("m"), right: std("map_create", { entry: mc({ key: lit("c"), value: lit(3) }) }) }) }) },
                { expression: std("print", { message: std("map_contains_value", { map: ref("m"), value: lit(1) }) }) },
                { expression: std("print", { message: std("map_foreach", { map: ref("m"), function: { lambda: { body: std("print", { message: ref("k") }), metadata: { params: ["k", "v"] } } } }) }) },
                // Non-Map: every op throws, caught by std.try.
                { expression: tryMapFn("map_get", { map: lit(42), key: lit("a") }) },
                { expression: tryMapFn("map_set", { map: lit("hi"), key: lit("a"), value: lit(1) }) },
                { expression: tryMapFn("map_contains_key", { map: { literal: { listValue: { elements: [lit(1)] } } }, key: lit(0) }) },
                { expression: tryMapFn("map_length", { map: lit(7) }) },
                { expression: tryMapFn("map_is_empty", { map: lit(true) }) },
                { expression: tryMapFn("map_delete", { map: lit(42), key: lit("a") }) },
                { expression: tryMapFn("map_merge", { left: lit(42), right: ref("m") }) },
                { expression: tryMapFn("map_contains_value", { map: lit(42), value: lit(1) }) },
                { expression: tryMapFn("map_foreach", { map: lit(42), function: { lambda: { body: lit(0), metadata: { params: ["k", "v"] } } } }) },
              ]),
            },
          ],
        },
      ],
    };
    const tmpPath = join(tmpdir(), `ball_map_ops_fail_loud_${process.pid}.ts`);
    writeFileSync(tmpPath, compile(program));
    try {
      const out = execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8" }).trim();
      const lines = out.split("\n");
      // Real-Map successes (9 lines) then 9 "threw" lines for the non-Map cases.
      assert.equal(lines.length, 18, `expected 18 output lines, got:\n${out}`);
      assert.deepEqual(lines.slice(9), Array(9).fill("threw"));
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

describe("compiler — printing/reading a real Map doesn't hit the Map.prototype getter shadow (#259)", () => {
  test("typed_map builds a genuine Map; print + map_keys/map_values/map_entries all succeed with real output", () => {
    // preamble.ts shadows Map.prototype.entries/keys/values with GETTERS so
    // Dart's property-style `map.entries` access works. That shadow broke
    // every INTERNAL call site that still invoked them as METHODS on a real
    // Map (`x.entries()` first evaluates the getter -- returning an array --
    // then tries to call THAT as a function): __ball_to_string's Map
    // printer, the Map-like addAll copy sites, and __ball_map_keys/values/
    // entries itself (the very helpers #256/#257 added to fix #218 — their
    // non-Map-throws branch was already fixed, but their real-Map SUCCESS
    // branch was silently broken by this pre-existing, unrelated shadow).
    // typed_map (unlike map_create, which emits a plain object) is what
    // exercises a genuine `new Map(...)`.
    const program: Program = {
      name: "map_proto_shadow_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] },
        {
          name: "main",
          functions: [
            {
              name: "main",
              body: block([
                {
                  let: {
                    name: "m",
                    value: std("typed_map", {
                      entries: listLit([
                        mc({ key: lit("a"), value: lit(1) }),
                        mc({ key: lit("b"), value: lit(2) }),
                      ]),
                    }),
                  },
                },
                { expression: std("print", { message: ref("m") }) },
                { expression: std("print", { message: std("map_keys", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_values", { map: ref("m") }) }) },
                { expression: std("print", { message: std("map_entries", { map: ref("m") }) }) },
              ]),
            },
          ],
        },
      ],
    };
    const tmpPath = join(tmpdir(), `ball_map_proto_shadow_${process.pid}.ts`);
    writeFileSync(tmpPath, compile(program));
    try {
      const out = execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8" }).trim();
      const lines = out.split("\n");
      assert.deepEqual(lines, [
        "{a: 1, b: 2}",
        "[a, b]",
        "[1, 2]",
        "[{key: a, value: 1}, {key: b, value: 2}]",
      ]);
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

describe("compiler — compileStdCall default fallback throws at compile time (#257)", () => {
  test("an unknown std function name throws a compile-time Error naming it, instead of a bare-identifier call", () => {
    // Used to silently emit `/* std.foo */ foo(args)` -- a call on a
    // nonexistent identifier, deferring the failure to a confusing runtime
    // ReferenceError. Now matches compileMemoryCall's own documented policy:
    // fail loud at compile time, naming the actual unimplemented function.
    const program: Program = {
      name: "unknown_std_fn_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [{ name: "main", functions: [
        { name: "main", body: std("__totally_made_up_std_fn__", { value: ref("x") }) },
      ] }],
    };
    assert.throws(
      () => compile(program, { includePreamble: false }),
      /std\.__totally_made_up_std_fn__ is not implemented/,
    );
  });
});

describe("compiler — set_* base functions are confirmed-dead codegen, now a compile-time throw (#257)", () => {
  test("std.set_union (and its set_* siblings) throws instead of compiling to a nonexistent bare identifier", () => {
    // Neither dart/encoder nor ts/encoder ever emits a direct
    // `std.set_union`/etc. base-function call -- a Set method call
    // (mySet.union(other)) routes through compileCall's generic
    // "self"-field method dispatch onto native JS Set.prototype methods
    // instead, so this case is never actually reached by any real encoder
    // output. It used to compile to a call on a nonexistent bare
    // identifier (`set_union(a, b)`, a ReferenceError if it WERE ever
    // hit); now a clean compile-time throw instead.
    const program: Program = {
      name: "set_union_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [{ name: "main", functions: [
        { name: "main", body: std("set_union", { left: ref("a"), right: ref("b") }) },
      ] }],
    };
    assert.throws(
      () => compile(program, { includePreamble: false }),
      /std\.set_union is not implemented/,
    );
  });
});

describe("compiler — null_aware_call/index/access throw at compile time on a missing field (#257)", () => {
  test("null_aware_call/null_aware_index/null_aware_access each throw a descriptive Error when their required fields are absent", () => {
    // A bare `/* ... */` comment used to stand in for the missing field --
    // context-dependent behavior (silently `undefined` in return position,
    // a hard-to-diagnose SyntaxError mid-expression) instead of a clear
    // compile-time error naming the malformed call.
    const mkProgram = (body: Expression): Program => ({
      name: "null_aware_missing_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [{ name: "main", functions: [{ name: "main", body }] }],
    });
    assert.throws(
      () => compile(mkProgram(std("null_aware_call", { target: ref("obj") })), { includePreamble: false }),
      /null_aware_call requires/,
    );
    assert.throws(
      () => compile(mkProgram(std("null_aware_index", { self: ref("obj") })), { includePreamble: false }),
      /null_aware_index requires/,
    );
    assert.throws(
      () => compile(mkProgram(std("null_aware_access", { target: ref("obj") })), { includePreamble: false }),
      /null_aware_access requires/,
    );
  });
});

describe("compiler — typed_map throws on a malformed entry instead of silently dropping it (#257)", () => {
  test("an entry missing key or value throws instead of vanishing from the resulting Map", () => {
    const program: Program = {
      name: "typed_map_malformed_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [{ name: "main", functions: [
        { name: "main", body: std("typed_map", { entries: listLit([mc({ key: lit("a") })]) }) },
      ] }],
    };
    assert.throws(
      () => compile(program, { includePreamble: false }),
      /typed_map entry is missing "key" or "value"/,
    );
  });
});
