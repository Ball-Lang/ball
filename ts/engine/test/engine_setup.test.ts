/**
 * Unit tests for the hand-written engine setup helpers in src/engine_setup.ts
 * (createEngineSetup) that the conformance corpus (test/engine_test.ts) does
 * not directly exercise: the Struct-Value shim (`wrapValue`), the Dart-style
 * `toString` formatter (`__bts`), the BallFuture shim + `_isFutureLike`,
 * `_unwrapBallValue`, the JS-native method dispatch table
 * (`MethodDispatchHandler`), the `identical()` global seeded by
 * `seedGlobalScope`, and a broad sample of the std-function overrides
 * registered by `registerExtraStdFunctions`.
 *
 * These are called directly against `createEngineSetup(realCompiledModule)`
 * (the same wiring `src/index.ts` uses) so BallDouble/BallGenerator/_FlowSignal
 * are the real compiled-engine classes, not stand-ins.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createEngineSetup } from "../src/engine_setup.ts";
import * as CompiledEngineModule from "../src/compiled_engine.ts";
import { BallEngine } from "../src/index.ts";

const setup = createEngineSetup(CompiledEngineModule as any);
const { wrapValue, __bts, BallFuture, MethodDispatchHandler, registerExtraStdFunctions,
  seedGlobalScope, _isFutureLike, _unwrapBallValue, protoWrap, patchCompiledEngine } = setup;
const _FlowSignal = (CompiledEngineModule as any)._FlowSignal;

const BallDouble = (globalThis as any).BallDouble;
const BallGenerator = (CompiledEngineModule as any).BallGenerator;

// ── wrapValue (Struct.Value shim used by metadata.fields[...]) ─────────────

describe("wrapValue", () => {
  test("whichKind discriminates every JSON kind", () => {
    assert.equal(wrapValue(null).whichKind(), "nullValue");
    assert.equal(wrapValue(undefined).whichKind(), "nullValue");
    assert.equal(wrapValue("s").whichKind(), "stringValue");
    assert.equal(wrapValue(true).whichKind(), "boolValue");
    assert.equal(wrapValue(42).whichKind(), "numberValue");
    assert.equal(wrapValue([1, 2]).whichKind(), "listValue");
    assert.equal(wrapValue({ a: 1 }).whichKind(), "structValue");
  });

  test("stringValue coerces non-strings and boolValue is truthiness", () => {
    assert.equal(wrapValue("hi").stringValue, "hi");
    assert.equal(wrapValue(42).stringValue, "42");
    assert.equal(wrapValue(null).stringValue, "");
    assert.equal(wrapValue(1).boolValue, true);
    assert.equal(wrapValue(0).boolValue, false);
    assert.equal(wrapValue(7).numberValue, 7);
  });

  test("listValue wraps each element recursively", () => {
    const lv = wrapValue([1, "two"]).listValue;
    assert.equal(lv.values.length, 2);
    assert.equal(lv.values[0].numberValue, 1);
    assert.equal(lv.values[1].stringValue, "two");
    // Non-array raw falls back to an empty list.
    assert.deepEqual(wrapValue("x").listValue.values, []);
  });

  test("structValue wraps each field recursively", () => {
    const sv = wrapValue({ k: 1, j: "v" }).structValue;
    assert.equal(sv.fields.k.numberValue, 1);
    assert.equal(sv.fields.j.stringValue, "v");
    // Non-object raw falls back to an empty struct.
    assert.deepEqual(wrapValue(5).structValue.fields, {});
  });

  test("has* predicates match exactly one kind each", () => {
    const v = wrapValue("s");
    assert.equal(v.hasStringValue(), true);
    assert.equal(v.hasBoolValue(), false);
    assert.equal(v.hasNumberValue(), false);
    assert.equal(v.hasListValue(), false);
    assert.equal(v.hasStructValue(), false);
    assert.equal(v.hasNullValue(), false);

    assert.equal(wrapValue(true).hasBoolValue(), true);
    assert.equal(wrapValue(1).hasNumberValue(), true);
    assert.equal(wrapValue([]).hasListValue(), true);
    assert.equal(wrapValue({}).hasStructValue(), true);
    assert.equal(wrapValue(null).hasNullValue(), true);
    assert.equal(wrapValue(undefined).hasNullValue(), true);
  });

  test("toString/valueOf expose the raw value", () => {
    assert.equal(wrapValue(42).toString(), "42");
    assert.equal(wrapValue(42).valueOf(), 42);
    assert.equal(String(wrapValue("x")), "x");
  });

  test("whichKind falls back to nullValue for a type with no proto3-JSON representation (bigint)", () => {
    // bigint is not string/boolean/number/array/object, so it falls through
    // every branch to the final `return 'nullValue'` — proto3 JSON (and this
    // Struct.Value shim) has no representation for it.
    assert.equal(wrapValue(10n).whichKind(), "nullValue");
  });
});

// ── __bts (Dart-style toString formatter) ───────────────────────────────────

describe("__bts", () => {
  test("null/undefined/booleans", () => {
    assert.equal(__bts(null), "null");
    assert.equal(__bts(undefined), "null");
    assert.equal(__bts(true), "true");
    assert.equal(__bts(false), "false");
  });

  test("bigint prints without a decimal", () => {
    assert.equal(__bts(10n), "10");
    assert.equal(__bts(-5n), "-5");
  });

  test("number formatting: NaN, Infinity, -0, integers, decimals", () => {
    assert.equal(__bts(NaN), "NaN");
    assert.equal(__bts(Infinity), "Infinity");
    assert.equal(__bts(-Infinity), "-Infinity");
    assert.equal(__bts(-0), "-0.0");
    assert.equal(__bts(5), "5");
    assert.equal(__bts(5.5), "5.5");
  });

  test("BallDouble delegates to its own patched toString (handles -0.0)", () => {
    const bd = new BallDouble(5);
    assert.equal(__bts(bd), bd.toString());
    assert.equal(__bts(new BallDouble(-0)), "-0.0");
  });

  test("strings pass through unchanged", () => {
    assert.equal(__bts("hello"), "hello");
  });

  test("arrays format recursively with Dart list syntax", () => {
    assert.equal(__bts([1, "a", true]), "[1, a, true]");
    assert.equal(__bts([]), "[]");
  });

  test("Map formats as Dart map syntax", () => {
    const m = new Map<any, any>([["a", 1], ["b", 2]]);
    assert.equal(__bts(m), "{a: 1, b: 2}");
  });

  test("Set formats as Dart set syntax", () => {
    const s = new Set([1, 2, 3]);
    assert.equal(__bts(s), "{1, 2, 3}");
  });

  test("BallFuture-like values unwrap to their .value", () => {
    const fut = new BallFuture(42);
    assert.equal(__bts(fut), "42");
    // Plain-object future marker (what the real compiled engine produces).
    assert.equal(__bts({ __ball_future__: true, value: "x" }), "x");
  });

  test("BallGenerator-like values unwrap to their .values list", () => {
    const gen = new BallGenerator();
    gen.values.push(1, 2);
    assert.equal(__bts(gen), "[1, 2]");
    assert.equal(__bts({ __ball_generator__: true, values: [7] }), "[7]");
  });

  test("objects with a string __buffer__ (StringBuffer) print the buffer", () => {
    assert.equal(__bts({ __type__: "x", __buffer__: "hello" }), "hello");
  });

  test("objects with an array __buffer__ join the parts", () => {
    assert.equal(__bts({ __buffer__: ["a", "b", "c"] }), "abc");
  });

  test("a __type__ ending in :StringBuffer with no buffer yet prints empty", () => {
    assert.equal(__bts({ __type__: "main:StringBuffer" }), "");
    assert.equal(__bts({ __type__: "StringBuffer" }), "");
  });

  test("objects with a custom toString use it", () => {
    const custom = { toString: () => "custom!" };
    assert.equal(__bts(custom), "custom!");
  });

  test("plain objects format as Dart map-literal syntax, skipping __-prefixed keys", () => {
    assert.equal(__bts({ a: 1, __hidden: 2 }), "{a: 1}");
    assert.equal(__bts({ __hidden: 1 }), "{}");
  });

  test("a value with no matching case at all (function) falls back to String(v)", () => {
    // A function is not null/boolean/BallDouble/bigint/number/string/future/
    // generator/array/Map/Set/plain-object — it falls through every branch to
    // the final `return String(v)`.
    function namedFn() {}
    assert.equal(__bts(namedFn), String(namedFn));
  });
});

// ── protoWrap: return-statement normalization ───────────────────────────────

describe("protoWrap", () => {
  test("normalizes a `return` statement with a value into a std.return call expression", () => {
    const wrapped = protoWrap({ return: { value: { literal: { intValue: "5" } } } });
    assert.equal(wrapped.expression.call.module, "std");
    assert.equal(wrapped.expression.call.function, "return");
    const fields = wrapped.expression.call.input.messageCreation.fields;
    assert.equal(fields.length, 1);
    assert.equal(fields[0].name, "value");
    assert.equal(fields[0].value.literal.intValue, "5");
  });

  test("a bare (non-`.value`-wrapped) return payload is used directly as the value", () => {
    const wrapped = protoWrap({ return: { literal: { intValue: "9" } } });
    const fields = wrapped.expression.call.input.messageCreation.fields;
    assert.equal(fields[0].value.literal.intValue, "9");
  });

  test("a null return payload normalizes to an empty-fields messageCreation (bare `return;`)", () => {
    const wrapped = protoWrap({ return: null });
    assert.deepEqual(wrapped.expression.call.input.messageCreation.fields, []);
  });

  test("does not re-wrap a statement that already has `expression` or `let`", () => {
    const exprStmt = { expression: { literal: { intValue: "1" } }, return: "ignored" };
    const passthrough = protoWrap(exprStmt);
    assert.equal(passthrough.call, undefined);
    assert.equal(passthrough.expression.literal.intValue, "1");
  });
});

// ── BallFuture shim / _isFutureLike / _unwrapBallValue ──────────────────────

describe("BallFuture shim + helpers", () => {
  test("_isFutureLike recognizes the shim and duck-typed markers, rejects plain values", () => {
    assert.equal(_isFutureLike(new BallFuture(1)), true);
    assert.equal(_isFutureLike({ __ball_future__: true }), true);
    assert.equal(_isFutureLike(42), false);
    assert.equal(_isFutureLike(null), false);
    assert.equal(_isFutureLike({}), false);
  });

  test("BallFuture stores value/completed and marks itself", () => {
    const fut = new BallFuture("done", true);
    assert.equal(fut.value, "done");
    assert.equal(fut.completed, true);
    assert.equal(fut.__ball_future__, true);
  });

  test("_unwrapBallValue unwraps futures and generators, passes through everything else", () => {
    assert.equal(_unwrapBallValue(new BallFuture(9)), 9);
    const gen = new BallGenerator();
    gen.values.push(1, 2, 3);
    assert.deepEqual(_unwrapBallValue(gen), [1, 2, 3]);
    assert.deepEqual(_unwrapBallValue({ __ball_future__: true, value: "v" }), "v");
    assert.deepEqual(_unwrapBallValue({ __ball_generator__: true, values: [4] }), [4]);
    assert.equal(_unwrapBallValue(5), 5);
    assert.equal(_unwrapBallValue("plain"), "plain");
  });
});

// ── MethodDispatchHandler (JS-native method-style dispatch) ────────────────

describe("MethodDispatchHandler", () => {
  const handler = new MethodDispatchHandler();

  test("handles() matches only the empty/absent module (method-style calls)", () => {
    assert.equal(handler.handles(""), true);
    assert.equal(handler.handles(null), true);
    assert.equal(handler.handles(undefined), true);
    assert.equal(handler.handles("std"), false);
    assert.equal(handler.handles("std_collections"), false);
  });

  test("call() returns undefined for non-object input or a missing self", () => {
    assert.equal(handler.call("add", null, null), undefined);
    assert.equal(handler.call("add", "not an object", null), undefined);
    assert.equal(handler.call("anything", {}, null), undefined);
  });

  test("call() returns undefined when self matches no known type (null/boolean)", () => {
    assert.equal(handler.call("anything", { self: null }, null), undefined);
    assert.equal(handler.call("anything", { self: true }, null), undefined);
  });

  describe("array methods", () => {
    test("mutating methods", () => {
      const arr = [1, 2, 3];
      assert.equal(handler.call("add", { self: arr, arg0: 4 }, null), null);
      assert.deepEqual(arr, [1, 2, 3, 4]);
      assert.equal(handler.call("removeLast", { self: arr }, null), 4);
      assert.equal(handler.call("removeAt", { self: arr, arg0: 0 }, null), 1);
      assert.deepEqual(arr, [2, 3]);
      assert.equal(handler.call("insert", { self: arr, arg0: 0, arg1: 9 }, null), null);
      assert.deepEqual(arr, [9, 2, 3]);
      assert.equal(handler.call("clear", { self: arr }, null), null);
      assert.deepEqual(arr, []);
    });

    test("query methods", () => {
      const arr = [10, 20, 30];
      assert.equal(handler.call("contains", { self: arr, arg0: 20 }, null), true);
      assert.equal(handler.call("indexOf", { self: arr, arg0: 20 }, null), 1);
      assert.equal(handler.call("join", { self: arr, arg0: "-" }, null), "10-20-30");
      assert.equal(handler.call("join", { self: arr }, null), "10,20,30");
      assert.deepEqual(handler.call("sublist", { self: arr, arg0: 1, arg1: 2 }, null), [20]);
      assert.equal(handler.call("length", { self: arr }, null), 3);
      assert.equal(handler.call("isEmpty", { self: arr }, null), false);
      assert.equal(handler.call("isNotEmpty", { self: arr }, null), true);
      assert.equal(handler.call("first", { self: arr }, null), 10);
      assert.equal(handler.call("last", { self: arr }, null), 30);
      assert.deepEqual(handler.call("toList", { self: arr }, null), [10, 20, 30]);
      assert.equal(handler.call("toString", { self: arr }, null), "[10, 20, 30]");
    });

    test("sort / reversed / filled (static-ish helpers via a list receiver)", () => {
      const arr = [3, 1, 2];
      assert.equal(handler.call("sort", { self: arr }, null), null);
      assert.deepEqual(arr, [1, 2, 3]);
      assert.deepEqual(handler.call("reversed", { self: [1, 2, 3] }, null), [3, 2, 1]);
      assert.deepEqual(handler.call("filled", { self: [], arg0: 3, arg1: "x" }, null), ["x", "x", "x"]);
    });
  });

  describe("string methods", () => {
    const s = "Hello World";
    test("query methods", () => {
      assert.equal(handler.call("contains", { self: s, arg0: "World" }, null), true);
      assert.equal(handler.call("substring", { self: s, arg0: 0, arg1: 5 }, null), "Hello");
      assert.equal(handler.call("indexOf", { self: s, arg0: "World" }, null), 6);
      assert.deepEqual(handler.call("split", { self: s, arg0: " " }, null), ["Hello", "World"]);
      assert.equal(handler.call("trim", { self: "  x  " }, null), "x");
      assert.equal(handler.call("toUpperCase", { self: s }, null), "HELLO WORLD");
      assert.equal(handler.call("toLowerCase", { self: s }, null), "hello world");
      assert.equal(handler.call("replaceAll", { self: "aXaXa", arg0: "X", arg1: "-" }, null), "a-a-a");
      assert.equal(handler.call("startsWith", { self: s, arg0: "Hello" }, null), true);
      assert.equal(handler.call("endsWith", { self: s, arg0: "World" }, null), true);
      assert.equal(handler.call("padLeft", { self: "5", arg0: 3, arg1: "0" }, null), "005");
      assert.equal(handler.call("padRight", { self: "5", arg0: 3, arg1: "0" }, null), "500");
      assert.equal(handler.call("length", { self: s }, null), 11);
      assert.equal(handler.call("isEmpty", { self: "" }, null), true);
      assert.equal(handler.call("isNotEmpty", { self: s }, null), true);
      assert.equal(handler.call("toString", { self: s }, null), s);
      assert.equal(handler.call("codeUnitAt", { self: "A", arg0: 0 }, null), 65);
      assert.equal(handler.call("compareTo", { self: "a", arg0: "b" }, null), -1);
      assert.equal(handler.call("compareTo", { self: "b", arg0: "a" }, null), 1);
      assert.equal(handler.call("compareTo", { self: "a", arg0: "a" }, null), 0);
      assert.equal(handler.call("replaceFirst", { self: "aXaXa", arg0: "X", arg1: "-" }, null), "a-aXa");
    });
  });

  describe("number methods", () => {
    test("conversions and predicates", () => {
      assert.equal(handler.call("toDouble", { self: 5 }, null), 5);
      assert.equal(handler.call("toInt", { self: 5.9 }, null), 5);
      assert.equal(handler.call("toString", { self: 5 }, null), "5");
      assert.equal(handler.call("toStringAsFixed", { self: 3.14159, arg0: 2 }, null), "3.14");
      assert.equal(handler.call("abs", { self: -5 }, null), 5);
      assert.equal(handler.call("round", { self: 5.5 }, null), 6);
      assert.equal(handler.call("floor", { self: 5.9 }, null), 5);
      assert.equal(handler.call("ceil", { self: 5.1 }, null), 6);
      assert.equal(handler.call("compareTo", { self: 1, arg0: 2 }, null), -1);
      assert.equal(handler.call("compareTo", { self: 2, arg0: 1 }, null), 1);
      assert.equal(handler.call("compareTo", { self: 1, arg0: 1 }, null), 0);
      assert.equal(handler.call("clamp", { self: 15, arg0: 0, arg1: 10 }, null), 10);
      assert.equal(handler.call("remainder", { self: 7, arg0: 3 }, null), 1);
    });

    test("remainder on a BallDouble receiver routes through the BallDouble branch", () => {
      const bd = new BallDouble(7.5);
      const result = handler.call("remainder", { self: bd, arg0: 2 }, null);
      assert.ok(result instanceof BallDouble);
      assert.equal(result.value, 1.5);
    });
  });

  describe("StringBuffer-like objects (has __type__)", () => {
    test("write/writeCharCode accumulate into __buffer__, toString reads it", () => {
      const buf: any = { __type__: "x:StringBuffer" };
      assert.equal(handler.call("write", { self: buf, arg0: "ab" }, null), null);
      assert.equal(handler.call("writeCharCode", { self: buf, arg0: 99 }, null), null);
      assert.deepEqual(buf.__buffer__, ["ab", "c"]);
      assert.equal(handler.call("toString", { self: buf }, null), "abc");
    });

    test("a __type__ object with no matching case falls through to the generic map switch", () => {
      // fn='containsKey' matches neither write/writeCharCode/toString, nor Set,
      // so it must fall through to the final generic-object switch below.
      const obj: any = { __type__: "x", k: 1 };
      assert.equal(handler.call("containsKey", { self: obj, arg0: "k" }, null), true);
    });

    test("toString on a __type__ object with no __buffer__ falls through to the generic map toString", () => {
      // Unlike list/set toString, the generic-object toString case does not
      // filter __-prefixed keys, so a __type__ marker shows up verbatim.
      const obj: any = { __type__: "x", a: 1 };
      assert.equal(handler.call("toString", { self: obj }, null), "{__type__: x, a: 1}");
    });
  });

  describe("Set methods", () => {
    test("set algebra + membership + mutation", () => {
      const a = new Set([1, 2, 3]);
      const b = new Set([2, 3, 4]);
      assert.deepEqual(handler.call("union", { self: a, arg0: b }, null), new Set([1, 2, 3, 4]));
      assert.deepEqual(handler.call("intersection", { self: a, arg0: b }, null), new Set([2, 3]));
      assert.deepEqual(handler.call("difference", { self: a, arg0: b }, null), new Set([1]));
      assert.equal(handler.call("contains", { self: a, arg0: 2 }, null), true);
      const s = new Set([1]);
      assert.equal(handler.call("add", { self: s, arg0: 2 }, null), null);
      assert.equal(s.has(2), true);
      assert.equal(handler.call("remove", { self: s, arg0: 1 }, null), true);
      assert.equal(handler.call("length", { self: s }, null), 1);
      assert.equal(handler.call("isEmpty", { self: new Set() }, null), true);
      assert.equal(handler.call("isNotEmpty", { self: s }, null), true);
      assert.deepEqual(handler.call("toList", { self: new Set([1, 2]) }, null), [1, 2]);
      assert.equal(handler.call("toString", { self: new Set([1, 2]) }, null), "{1, 2}");
    });
  });

  describe("generic object (map-like) methods", () => {
    test("key/value/entry operations", () => {
      const map: any = { a: 1, b: 2 };
      assert.equal(handler.call("containsKey", { self: map, arg0: "a" }, null), true);
      assert.equal(handler.call("containsValue", { self: map, arg0: 2 }, null), true);
      assert.equal(handler.call("remove", { self: map, arg0: "a" }, null), 1);
      assert.deepEqual(map, { b: 2 });
      assert.equal(handler.call("length", { self: map }, null), 1);
      assert.equal(handler.call("isEmpty", { self: {} }, null), true);
      assert.equal(handler.call("isNotEmpty", { self: map }, null), true);
      assert.deepEqual(handler.call("keys", { self: { x: 1, y: 2 } }, null), ["x", "y"]);
      assert.deepEqual(handler.call("values", { self: { x: 1, y: 2 } }, null), [1, 2]);
      assert.deepEqual(
        handler.call("entries", { self: { x: 1 } }, null),
        [{ key: "x", value: 1 }],
      );
      const putMap: any = { x: 1 };
      assert.equal(handler.call("putIfAbsent", { self: putMap, arg0: "x", arg1: 99 }, null), 1);
      assert.equal(handler.call("putIfAbsent", { self: putMap, arg0: "y", arg1: 99 }, null), 99);
      assert.equal(putMap.y, 99);
      assert.equal(handler.call("toString", { self: { a: 1, b: 2 } }, null), "{a: 1, b: 2}");
    });
  });
});

// ── seedGlobalScope: `identical` global ─────────────────────────────────────

describe("seedGlobalScope", () => {
  test("binds List/Map/Set/RegExp/DateTime/Duration class refs and identical()", () => {
    const bindings: Record<string, any> = {};
    const fakeScope = { bind: (name: string, value: any) => { bindings[name] = value; } };
    const fakeEngine = { _globalScope: fakeScope } as any;
    seedGlobalScope(fakeEngine);
    assert.equal(bindings["List"]?.__class_ref__, "List");
    assert.equal(bindings["Map"]?.__class_ref__, "Map");
    assert.equal(bindings["Set"]?.__class_ref__, "Set");
    assert.equal(bindings["RegExp"]?.__class_ref__, "RegExp");
    assert.equal(bindings["DateTime"]?.__class_ref__, "DateTime");
    assert.equal(bindings["Duration"]?.__class_ref__, "Duration");

    const identical = bindings["identical"];
    assert.equal(typeof identical, "function");
    const obj = {};
    assert.equal(identical({ arg0: obj, arg1: obj }), true);
    assert.equal(identical({ arg0: {}, arg1: {} }), false);
    assert.equal(identical({ left: 1, right: 1 }), true);
    assert.equal(identical({ a: 1, b: 2 }), false);
    // Non-object / array input takes the `false` fallback branch.
    assert.equal(identical(null), false);
    assert.equal(identical([1, 2]), false);
  });

  test("is a no-op when the engine has no bindable global scope", () => {
    assert.doesNotThrow(() => seedGlobalScope({} as any));
    assert.doesNotThrow(() => seedGlobalScope({ _globalScope: {} } as any));
  });
});

// ── registerExtraStdFunctions: a broad sample of the JS std overrides ──────

/** Minimal stdHandler stand-in: register() stores by name, call() invokes it. */
class FakeStdHandler {
  private dispatch = new Map<string, (...args: any[]) => any>();
  register(name: string, fn: (...args: any[]) => any): void {
    this.dispatch.set(name, fn);
  }
  async call(name: string, input?: any): Promise<any> {
    const fn = this.dispatch.get(name);
    assert.ok(fn, `no handler registered for std.${name}`);
    return await fn(input);
  }
}

function makeStdHandler(): FakeStdHandler {
  const h = new FakeStdHandler();
  const fakeEngine = { _trackMemoryAllocation: (_bytes: number) => {} };
  registerExtraStdFunctions(h as any, fakeEngine as any);
  return h;
}

describe("registerExtraStdFunctions: list_*", () => {
  const h = makeStdHandler();

  test("higher-order list functions over an array", async () => {
    const doubled: any[] = [];
    await h.call("list_foreach", { list: [1, 2, 3], function: (x: number) => doubled.push(x * 2) });
    assert.deepEqual(doubled, [2, 4, 6]);

    assert.deepEqual(await h.call("list_map", { list: [1, 2], function: (x: number) => x + 1 }), [2, 3]);
    assert.deepEqual(await h.call("list_filter", { list: [1, 2, 3, 4], function: (x: number) => x % 2 === 0 }), [2, 4]);
    assert.deepEqual(await h.call("list_where", { list: [1, 2, 3, 4], function: (x: number) => x > 2 }), [3, 4]);
    assert.equal(
      await h.call("list_reduce", { list: [1, 2, 3], function: (i: any) => i.arg0 + i.arg1, initial: 0 }),
      6,
    );
    assert.equal(await h.call("list_any", { list: [1, 2, 3], function: (x: number) => x === 2 }), true);
    assert.equal(await h.call("list_every", { list: [1, 2, 3], function: (x: number) => x > 0 }), true);
    assert.equal(await h.call("list_find", { list: [1, 2, 3], function: (x: number) => x === 2 }), 2);
    assert.deepEqual(await h.call("list_expand", { list: [1, 2], function: (x: number) => [x, x] }), [1, 1, 2, 2]);
  });

  test("list_find returns null when no element satisfies the predicate", async () => {
    assert.equal(await h.call("list_find", { list: [1, 2, 3], function: (x: number) => x === 99 }), null);
  });

  test("list_foreach also iterates a Set and a plain-object map", async () => {
    const seen: any[] = [];
    await h.call("list_foreach", { list: new Set([1, 2]), function: (x: any) => seen.push(x) });
    assert.deepEqual(seen, [1, 2]);

    const pairs: any[] = [];
    await h.call("list_foreach", { list: { a: 1, b: 2 }, function: (i: any) => pairs.push([i.key, i.value]) });
    assert.deepEqual(pairs, [["a", 1], ["b", 2]]);
  });

  test("list_sort with a custom async comparator (merge sort path) and the default path", async () => {
    // list_sort returns a NEW sorted array — it does not mutate its input
    // (unlike the plain 'sort' registered for MethodDispatchHandler).
    const arr = [3, 1, 2];
    const sorted = await h.call("list_sort", { list: arr, compare: async (i: any) => i.arg0 - i.arg1 });
    assert.deepEqual(sorted, [1, 2, 3]);
    assert.deepEqual(arr, [3, 1, 2], "original array left untouched");

    const arr2 = ["b", "a", "c"];
    const sorted2 = await h.call("list_sort", { list: arr2 });
    assert.deepEqual(sorted2, ["a", "b", "c"]);
  });

  test("length/reversed/sublist/index_of over arrays and index_of over a string", async () => {
    assert.equal(await h.call("list_length", { list: [1, 2, 3] }), 3);
    assert.equal(await h.call("list_length", "abc"), 3);
    assert.deepEqual(await h.call("list_reversed", { list: [1, 2, 3] }), [3, 2, 1]);
    assert.deepEqual(await h.call("list_sublist", { list: [1, 2, 3, 4], start: 1, end: 3 }), [2, 3]);
    assert.equal(await h.call("list_index_of", { list: [1, 2, 3], value: 2 }), 1);
    assert.equal(await h.call("list_index_of", { list: "abc", value: "b" }), 1);
  });

  test("mutation helpers: add/add_all/remove_at/insert/clear/contains/remove/remove_last", async () => {
    const l = [1, 2];
    assert.equal(await h.call("list_add", { list: l, value: 3 }), null);
    assert.deepEqual(l, [1, 2, 3]);
    await h.call("list_add_all", { list: l, other: [4, 5] });
    assert.deepEqual(l, [1, 2, 3, 4, 5]);
    assert.equal(await h.call("list_remove_at", { list: l, index: 0 }), 1);
    assert.deepEqual(l, [2, 3, 4, 5]);
    await h.call("list_insert", { list: l, index: 0, value: 99 });
    assert.deepEqual(l, [99, 2, 3, 4, 5]);
    assert.equal(await h.call("list_contains", { list: l, value: 99 }), true);
    assert.equal(await h.call("list_contains", { list: "abc", value: "b" }), true);
    assert.equal(await h.call("list_remove", { list: l, value: 99 }), true);
    assert.equal(await h.call("list_remove", { list: l, value: 12345 }), false);
    assert.deepEqual(l, [2, 3, 4, 5]);
    assert.equal(await h.call("list_remove_last", { list: l }), 5);
    assert.deepEqual(l, [2, 3, 4]);
    await h.call("list_clear", { list: l });
    assert.deepEqual(l, []);
  });

  test("list_contains on a Set coerces between numeric and string forms", async () => {
    const s = new Set([1, 2, 3]);
    assert.equal(await h.call("list_contains", { list: s, value: 2 }), true);
    assert.equal(await h.call("list_contains", { list: s, value: "2" }), true);
    const sStr = new Set(["1", "2"]);
    assert.equal(await h.call("list_contains", { list: sStr, value: 1 }), true);
    assert.equal(await h.call("list_contains", { list: sStr, value: 99 }), false);
  });

  test("to_list/join/push/pop/peek/take/skip/first/last/set/slice/of/from", async () => {
    assert.deepEqual(await h.call("list_to_list", { list: [1, 2] }), [1, 2]);
    assert.deepEqual(await h.call("list_to_list", { list: new Set([1, 2]) }), [1, 2]);
    assert.equal(await h.call("list_join", { list: [1, null, "x"], separator: "," }), "1,null,x");
    const pushArr = [1];
    await h.call("list_push", { list: pushArr, value: 2 });
    assert.deepEqual(pushArr, [1, 2]);
    const pushSet = new Set([1]);
    await h.call("list_push", { list: pushSet, value: 2 });
    assert.equal(pushSet.has(2), true);
    assert.equal(await h.call("list_pop", { list: [1, 2, 3] }), 3);
    assert.equal(await h.call("list_pop", { list: [] }), null);
    assert.equal(await h.call("list_peek", { list: [1, 2, 3] }), 3);
    assert.deepEqual(await h.call("list_take", { list: [1, 2, 3, 4], count: 2 }), [1, 2]);
    assert.deepEqual(await h.call("list_skip", { list: [1, 2, 3, 4], count: 2 }), [3, 4]);
    assert.equal(await h.call("list_first", { list: [1, 2] }), 1);
    assert.equal(await h.call("list_last", { list: [1, 2] }), 2);
    const setArr = [1, 2, 3];
    await h.call("list_set", { list: setArr, index: 1, value: 99 });
    assert.deepEqual(setArr, [1, 99, 3]);
    assert.deepEqual(await h.call("list_slice", { list: [1, 2, 3, 4], start: 1, end: 3 }), [2, 3]);
    assert.deepEqual(await h.call("list_slice", { list: [1, 2, 3, 4], value: [1, 3] }), [2, 3]);
    assert.deepEqual(await h.call("list_slice", { list: [1, 2, 3, 4], arg0: 2 }), [3, 4]);
    assert.deepEqual(await h.call("list_slice", { list: [1, 2, 3, 4], value: 2 }), [3, 4]);
    assert.deepEqual(await h.call("list_slice", { list: [1, 2, 3, 4] }), [1, 2, 3, 4]);
    assert.deepEqual(await h.call("list_of", { list: [1, 2] }), [1, 2]);
    assert.deepEqual(await h.call("list_of", { list: new Set([1, 2]) }), [1, 2]);
    assert.deepEqual(await h.call("list_from", { list: [1, 2] }), [1, 2]);
  });

  test("generate/filled/list_generate honor a memory-tracking engine", async () => {
    assert.deepEqual(await h.call("generate", { count: 3, generator: (i: number) => i * i }), [0, 1, 4]);
    assert.deepEqual(await h.call("generate", { count: 2 }), [null, null]);
    assert.deepEqual(await h.call("filled", { count: 2, value: "x" }), ["x", "x"]);
    assert.deepEqual(await h.call("list_generate", { count: 3, function: (i: number) => i * 2 }), [0, 2, 4]);
    assert.deepEqual(await h.call("list_generate", { count: 2 }), []);
    assert.deepEqual(await h.call("dart_list_generate", { count: 2, generator: (i: number) => i }), [0, 1]);
    assert.deepEqual(await h.call("dart_list_filled", { count: 2, value: 0 }), [0, 0]);
    assert.deepEqual(await h.call("list_filled", { count: 2, value: 1 }), [1, 1]);
  });

  test("length override handles string/array/Set/object/other", async () => {
    assert.equal(await h.call("length", { value: "abc" }), 3);
    assert.equal(await h.call("length", { value: [1, 2] }), 2);
    assert.equal(await h.call("length", { value: new Set([1, 2, 3]) }), 3);
    assert.equal(await h.call("length", { value: { a: 1 } }), 1);
    assert.equal(await h.call("length", { value: 5 }), 0);
  });
});

describe("registerExtraStdFunctions: map_*", () => {
  const h = makeStdHandler();

  test("map_from_entries / map_fromEntries / fromEntries all build a map from entry records", async () => {
    const entries = [{ key: "a", value: 1 }, { arg0: "b", arg1: 2 }];
    assert.deepEqual(await h.call("map_from_entries", { entries }), { a: 1, b: 2 });
    assert.deepEqual(await h.call("map_fromEntries", { entries }), { a: 1, b: 2 });
    assert.deepEqual(await h.call("fromEntries", { entries }), { a: 1, b: 2 });
  });

  test("containsKey/length/keys/values/entries (override versions)", async () => {
    const map = { a: 1, b: 2 };
    assert.equal(await h.call("map_containsKey", { map, key: "a" }), true);
    assert.equal(await h.call("map_contains_key", { map, key: "z" }), false);
    assert.equal(await h.call("map_length", { map }), 2);
    assert.deepEqual(await h.call("map_keys", { map }), ["a", "b"]);
    assert.deepEqual(await h.call("map_values", { map }), [1, 2]);
    assert.deepEqual(await h.call("map_entries", { map }), [{ key: "a", value: 1 }, { key: "b", value: 2 }]);
  });

  test("remove/put_if_absent/for_each/map/create/update/clear/add_all", async () => {
    const map: any = { a: 1 };
    assert.equal(await h.call("map_remove", { map, key: "a" }), 1);
    assert.deepEqual(map, {});

    const put: any = { x: 1 };
    assert.equal(await h.call("map_put_if_absent", { map: put, key: "x", value: 2 }), 1);
    assert.equal(await h.call("map_put_if_absent", { map: put, key: "y", ifAbsent: () => 99 }), 99);

    const seen: any[] = [];
    await h.call("map_for_each", { map: { a: 1 }, function: (i: any) => seen.push([i.key, i.value]) });
    assert.deepEqual(seen, [["a", 1]]);

    const mapped = await h.call("map_map", { map: { a: 1 }, function: (i: any) => ({ key: i.key, value: i.value * 10 }) });
    assert.deepEqual(mapped, { a: 10 });

    const created = await h.call("map_create", { entry: [{ key: "a", value: 1 }] });
    assert.deepEqual(created, { a: 1 });

    // A single entry (not wrapped in an array) — the non-array `entries`/`entry` branch.
    const createdSingle = await h.call("map_create", { entry: { key: "b", value: 2 } });
    assert.deepEqual(createdSingle, { b: 2 });

    const upd: any = { a: 1 };
    assert.equal(await h.call("map_update", { map: upd, key: "a", update: (v: number) => v + 1 }), 2);
    assert.equal(await h.call("map_update", { map: upd, key: "b", ifAbsent: () => 5 }), 5);

    const cl: any = { a: 1, b: 2 };
    await h.call("map_clear", { map: cl });
    assert.deepEqual(cl, {});

    const dst: any = { a: 1 };
    await h.call("map_add_all", { map: dst, other: { b: 2 } });
    assert.deepEqual(dst, { a: 1, b: 2 });
  });
});

describe("registerExtraStdFunctions: set_*", () => {
  const h = makeStdHandler();

  test("set algebra, membership, conversion, mutation", async () => {
    const a = new Set([1, 2]);
    const b = new Set([2, 3]);
    assert.deepEqual(await h.call("set_union", { set: a, other: b }), new Set([1, 2, 3]));
    assert.deepEqual(await h.call("set_intersection", { set: a, other: b }), new Set([2]));
    assert.deepEqual(await h.call("set_difference", { set: a, other: b }), new Set([1]));
    assert.equal(await h.call("set_contains", { set: a, value: 1 }), true);
    assert.deepEqual(await h.call("set_to_list", { set: new Set([1, 2]) }), [1, 2]);
    assert.equal(await h.call("set_length", { set: new Set([1, 2, 3]) }), 3);
    assert.deepEqual(await h.call("set_from", { list: [1, 1, 2] }), new Set([1, 2]));
    assert.deepEqual(await h.call("set_create", {}), new Set());
    const s = new Set([1]);
    assert.equal(await h.call("set_add", { set: s, value: 2 }), true);
    assert.equal(await h.call("set_remove", { set: s, value: 1 }), true);
    await h.call("set_add_all", { set: s, other: [3, 4] });
    assert.deepEqual(s, new Set([2, 3, 4]));
  });

  test("generic union/intersection/difference aliases via self/arg0", async () => {
    const a = new Set([1, 2]);
    const b = new Set([2, 3]);
    assert.deepEqual(await h.call("union", { self: a, arg0: b }), new Set([1, 2, 3]));
    assert.deepEqual(await h.call("intersection", { self: a, arg0: b }), new Set([2]));
    assert.deepEqual(await h.call("difference", { self: a, arg0: b }), new Set([1]));
  });
});

describe("registerExtraStdFunctions: string_*", () => {
  const h = makeStdHandler();

  test("character/substring/replace/split/trim/case/pad operations", async () => {
    assert.equal(await h.call("string_code_unit_at", { value: "A", index: 0 }), 65);
    assert.equal(await h.call("string_char_code_at", { value: "A", index: 0 }), 65);
    assert.equal(await h.call("string_from_char_code", { value: 65 }), "A");
    assert.equal(await h.call("string_from_char_codes", { codes: [72, 73] }), "HI");
    assert.equal(await h.call("string_replace", { value: "abc", from: "b", to: "X" }), "aXc");
    assert.equal(await h.call("string_replace_all", { value: "aXaXa", from: "X", to: "-" }), "a-a-a");
    assert.equal(await h.call("string_repeat", { value: "ab", count: 2 }), "abab");
    assert.deepEqual(await h.call("string_split", { value: "a,b", separator: "," }), ["a", "b"]);
    assert.equal(await h.call("string_substring", { value: "hello", start: 1, end: 3 }), "el");
    assert.equal(await h.call("string_contains", { value: "hello", substring: "ell" }), true);
    assert.equal(await h.call("string_length", { value: "hello" }), 5);
    assert.equal(await h.call("string_index_of", { value: "hello", substring: "l" }), 2);
    assert.equal(await h.call("string_to_upper_case", { value: "abc" }), "ABC");
    assert.equal(await h.call("string_to_lower_case", { value: "ABC" }), "abc");
    assert.equal(await h.call("string_trim", { value: "  x  " }), "x");
    assert.equal(await h.call("string_starts_with", { value: "hello", prefix: "he" }), true);
    assert.equal(await h.call("string_ends_with", { value: "hello", suffix: "lo" }), true);
    assert.equal(await h.call("string_pad_left", { value: "5", width: 3, padding: "0" }), "005");
    assert.equal(await h.call("string_pad_right", { value: "5", width: 3, padding: "0" }), "500");
    assert.equal(await h.call("string_char_at", { value: "abc", index: 1 }), "b");
  });

  test("string_to_int parses digit strings and throws FormatException on invalid input", async () => {
    assert.equal(await h.call("string_to_int", { value: "42" }), 42);
    assert.equal(await h.call("string_to_int", { value: "-7" }), -7);
    await assert.rejects(() => h.call("string_to_int", { value: "abc" }), /FormatException/);
  });

  test("write/writeCharCode accumulate into self.__buffer__", async () => {
    const self: any = {};
    await h.call("write", { self, arg0: "ab" });
    await h.call("writeCharCode", { self, arg0: 99 });
    assert.equal(self.__buffer__, "abc");
  });
});

describe("registerExtraStdFunctions: conversion / equality / math / async", () => {
  const h = makeStdHandler();

  test("to_double / to_int / int_to_double / double_to_int", async () => {
    assert.equal((await h.call("to_double", { value: 5 })).value, 5);
    assert.equal(await h.call("to_int", { value: 5.9 }), 5);
    assert.equal((await h.call("int_to_double", { value: 5 })).value, 5);
    assert.equal(await h.call("double_to_int", { value: new BallDouble(5.9) }), 5);
  });

  test("to_string peels a single-field {value} wrapper and formats via __bts", async () => {
    assert.equal(await h.call("to_string", { value: 42 }), "42");
    assert.equal(await h.call("to_string", { value: { value: "nested" } }), "nested");
    assert.equal(await h.call("to_string", 7), "7");
  });

  test("equals / not_equals treat NaN as unequal and unwrap BallDouble", async () => {
    assert.equal(await h.call("equals", { left: 1, right: 1 }), true);
    assert.equal(await h.call("equals", { left: NaN, right: NaN }), false);
    assert.equal(await h.call("not_equals", { left: NaN, right: NaN }), true);
    assert.equal(await h.call("equals", { left: new BallDouble(1), right: 1 }), true);
    assert.equal(await h.call("equals", { left: "a", right: "a" }), true);
    assert.equal(await h.call("not_equals", { left: "a", right: "b" }), true);
  });

  test("not_equals falls back to true when one side is null/undefined (can't __bts-compare)", async () => {
    // Neither the number path nor `av === bv` nor the "both non-null" __bts
    // comparison applies when exactly one side is null — the function falls
    // through to its final `return true`.
    assert.equal(await h.call("not_equals", { left: null, right: 5 }), true);
    assert.equal(await h.call("not_equals", { left: 5, right: undefined }), true);
  });

  test("concat / null_check / compare_to / divide_double", async () => {
    assert.equal(await h.call("concat", { left: "a", right: "b" }), "ab");
    assert.equal(await h.call("null_check", { value: 5 }), 5);
    await assert.rejects(() => h.call("null_check", { value: null }), /Null check operator/);
    // No `value` key at all: falls back to the whole (non-null) input map,
    // matching every other unary helper's `?? i` convention.
    assert.equal(await h.call("null_check", 5), 5);
    assert.equal(await h.call("compare_to", { left: "a", right: "b" }), -1);
    assert.equal(await h.call("compare_to", { left: 5, right: 3 }), 1);
    assert.equal((await h.call("divide_double", { left: 5, right: 2 })).value, 2.5);
  });

  test("math_* helpers", async () => {
    assert.equal(await h.call("math_abs", { value: -5 }), 5);
    assert.equal(await h.call("math_max", { left: 3, right: 7 }), 7);
    assert.equal(await h.call("math_min", { left: 3, right: 7 }), 3);
    assert.equal(await h.call("math_sqrt", { value: 9 }), 3);
    assert.equal(await h.call("math_pow", { base: 2, exponent: 3 }), 8);
    assert.equal(await h.call("math_sign", { value: -5 }), -1);
    assert.equal(await h.call("math_is_infinite", { value: Infinity }), true);
    assert.equal(await h.call("math_is_infinite", { value: 5 }), false);
  });

  test("await unwraps real Promises, BallFuture shims, and plain future markers", async () => {
    assert.equal(await h.call("await", { value: Promise.resolve(9) }), 9);
    assert.equal(await h.call("await", { value: new BallFuture(9) }), 9);
    assert.equal(await h.call("await", { value: { __ball_future__: true, value: 9 } }), 9);
    assert.equal(await h.call("await", { value: 9 }), 9);
  });

  test("yield / yield_each pass through their value", async () => {
    assert.equal(await h.call("yield", { value: 5 }), 5);
    assert.deepEqual(await h.call("yield_each", { value: [1, 2] }), [1, 2]);
    assert.equal(await h.call("yield_each", { value: "x" }), "x");
  });
});

describe("registerExtraStdFunctions: std_time / std_convert", () => {
  const h = makeStdHandler();

  test("std_time helpers return plausible values", async () => {
    assert.equal(typeof (await h.call("now")), "number");
    assert.equal(typeof (await h.call("now_micros")), "number");
    assert.equal(typeof (await h.call("timestamp_ms")), "number");
    assert.equal(typeof (await h.call("timestamp_micros")), "number");
    assert.equal(typeof (await h.call("format_timestamp", { timestamp_ms: 0 })), "string");
    assert.equal(await h.call("parse_timestamp", { value: new Date(0).toISOString() }), 0);
    assert.equal(await h.call("duration_add", { left: 1, right: 2 }), 3);
    assert.equal(await h.call("duration_subtract", { left: 5, right: 2 }), 3);
    for (const fn of ["year", "month", "day", "hour", "minute", "second"]) {
      assert.equal(typeof (await h.call(fn)), "number");
    }
  });

  test("std_convert: json + utf8 + base64 round-trip", async () => {
    assert.equal(await h.call("json_encode", { value: { a: 1 } }), '{"a":1}');
    assert.deepEqual(await h.call("json_decode", { value: '{"a":1}' }), { a: 1 });
    const bytes = await h.call("utf8_encode", { value: "hi" });
    assert.deepEqual(bytes, [104, 105]);
    assert.equal(await h.call("utf8_decode", { value: bytes }), "hi");
    const b64 = await h.call("base64_encode", { value: [104, 105] });
    assert.equal(typeof b64, "string");
    assert.deepEqual(await h.call("base64_decode", { value: b64 }), [104, 105]);
  });

  test("base64_encode/decode fall back to btoa/atob when Buffer is unavailable (browser-like environment)", async () => {
    const realBuffer = (globalThis as any).Buffer;
    // @ts-expect-error deliberately simulating a non-Node (Buffer-less) host.
    delete (globalThis as any).Buffer;
    try {
      const encoded = await h.call("base64_encode", { value: [104, 105] });
      assert.equal(encoded, btoa("hi"));
      const decoded = await h.call("base64_decode", { value: encoded });
      assert.deepEqual(decoded, [104, 105]);
    } finally {
      (globalThis as any).Buffer = realBuffer;
    }
  });
});

// ── typed_list ───────────────────────────────────────────────────────────

describe("registerExtraStdFunctions: typed_list", () => {
  test("returns the element array verbatim (type argument is erased)", async () => {
    const h = makeStdHandler();
    assert.deepEqual(await h.call("typed_list", { elements: [1, 2, 3] }), [1, 2, 3]);
    assert.deepEqual(await h.call("typed_list", {}), []);
  });
});

// ── registerExtraStdFunctions: 'sort' (std-registered, distinct from the
// MethodDispatchHandler's array `sort` case tested above) ──────────────────

describe("registerExtraStdFunctions: sort (std base function)", () => {
  const h = makeStdHandler();

  test("returns null without mutating a non-array `self`", async () => {
    assert.equal(await h.call("sort", { self: "not an array" }), null);
  });

  test("with no comparator, sorts the array in place using the default (<, >) ordering", async () => {
    const arr = [3, 1, 2];
    assert.equal(await h.call("sort", { self: arr }), null);
    assert.deepEqual(arr, [1, 2, 3]);
  });

  test("with an async comparator, merge-sorts the array in place (accepts `list` as well as `self`)", async () => {
    const arr = [3, 1, 2];
    assert.equal(await h.call("sort", { list: arr, compare: async (i: any) => i.arg0 - i.arg1 }), null);
    assert.deepEqual(arr, [1, 2, 3]);
  });
});

// ── Numeric coercion helpers: _extractNumericArg / _toIntValue / ───────────
// _toDoubleValue / _coerceInt / _coerceNum (private — exercised indirectly
// through the std functions that route through them) ───────────────────────

describe("registerExtraStdFunctions: numeric coercion edge cases", () => {
  const h = makeStdHandler();

  test("to_int/double_to_int clamp a raw bigint outside the int64 range", async () => {
    const tooBig = 10n ** 30n;
    const tooSmall = -(10n ** 30n);
    assert.equal(await h.call("to_int", { value: tooBig }), 9223372036854775807n);
    assert.equal(await h.call("to_int", { value: tooSmall }), -9223372036854775808n);
    assert.equal(await h.call("double_to_int", { value: tooBig }), 9223372036854775807n);
  });

  test("to_int keeps a within-int64-but-unsafe-magnitude bigint as a bigint (not a lossy Number)", async () => {
    // 2^53 + 1 : within int64 range but not exactly representable as a
    // JS Number, so `_toIntValue` must return it as a bigint verbatim.
    const unsafe = 9007199254740993n;
    assert.equal(await h.call("to_int", { value: unsafe }), unsafe);
  });

  test("to_double/int_to_double extract a nested numeric raw value from an object shape", async () => {
    // The outer std-function registration already extracts `i.value`, so
    // nesting a plain object one level deeper as that extracted value drives
    // `_extractNumericArg`'s own object-unwrapping branch.
    assert.equal((await h.call("to_double", { value: { value: 7 } })).value, 7);
    assert.equal((await h.call("to_double", { value: { arg0: 7 } })).value, 7);
  });

  test("to_double unwraps a BallDouble nested inside an object's value/arg0 field", async () => {
    assert.equal((await h.call("to_double", { value: { value: new BallDouble(3.5) } })).value, 3.5);
  });

  test("to_double coerces a non-numeric nested raw value via Number(raw)", async () => {
    assert.equal((await h.call("to_double", { value: { value: "42" } })).value, 42);
  });

  test("to_double falls back to 0 when the value cannot be parsed as a number at all", async () => {
    assert.equal((await h.call("to_double", { value: "not a number" })).value, 0);
  });

  test("to_double falls back to a plain number (not a BallDouble) when BallDouble is unavailable", async () => {
    const real = (globalThis as any).BallDouble;
    delete (globalThis as any).BallDouble;
    try {
      assert.equal(await h.call("to_double", { value: 5 }), 5);
    } finally {
      (globalThis as any).BallDouble = real;
    }
  });

  test("math_abs coerces a digit string via _coerceInt's string branch", async () => {
    assert.equal(await h.call("math_abs", { value: "-5" }), 5);
  });

  test("math_abs coerces a huge digit string (beyond safe-integer magnitude, within int64) to a bigint result", async () => {
    assert.equal(await h.call("math_abs", { value: "-9223372036854775000" }), 9223372036854775000n);
  });

  test("math_abs falls back to 0 for a non-digit string (parseInt fails)", async () => {
    assert.equal(await h.call("math_abs", { value: "not-a-number" }), 0);
  });

  test("math_abs coerces booleans (true=1, false=0)", async () => {
    assert.equal(await h.call("math_abs", { value: true }), 1);
    assert.equal(await h.call("math_abs", { value: false }), 0);
  });

  test("math_abs falls back to 0 for a value _coerceInt has no case for (array/object)", async () => {
    assert.equal(await h.call("math_abs", { value: [1, 2] }), 0);
  });

  test("compare_to coerces a digit string against a number via _coerceNum's string branch", async () => {
    assert.equal(await h.call("compare_to", { left: "5", right: 3 }), 1);
    assert.equal(await h.call("compare_to", { left: "2", right: 3 }), -1);
  });

  test("compare_to coerces a huge digit string (beyond safe-integer magnitude) via _toIntValue", async () => {
    assert.equal(await h.call("compare_to", { left: "9007199254740993", right: 0 }), 1);
  });

  test("compare_to coerces a decimal (non-digit-regex) string via Number(s)", async () => {
    assert.equal(await h.call("compare_to", { left: "5.5", right: 3 }), 1);
    assert.equal(await h.call("compare_to", { left: "not-a-number", right: 0 }), 0);
  });

  test("compare_to coerces booleans and falls back to 0 for a value with no numeric case", async () => {
    assert.equal(await h.call("compare_to", { left: true, right: 0 }), 1);
    assert.equal(await h.call("compare_to", { left: [1, 2], right: 0 }), 0);
  });
});

// ── patchCompiledEngine: internals only reachable through a real, patched ──
// compiled-engine instance (constructed the same way src/index.ts's
// `BallEngine` does) ─────────────────────────────────────────────────────────

describe("patchCompiledEngine (via a real BallEngine instance)", () => {
  function makeEngine(): any {
    return (new BallEngine({}) as any)._compiledEngine;
  }

  test("_matchesTypePattern covers the num/List/Map/Set/Object/dynamic/Null/null cases", () => {
    const ce = makeEngine();
    assert.equal(ce._matchesTypePattern(5, "num"), true);
    assert.equal(ce._matchesTypePattern(5n, "num"), true);
    assert.equal(ce._matchesTypePattern("x", "num"), false);
    assert.equal(ce._matchesTypePattern([1, 2], "List"), true);
    assert.equal(ce._matchesTypePattern({ a: 1 }, "Map"), true);
    assert.equal(ce._matchesTypePattern(new Set(), "Map"), false);
    assert.equal(ce._matchesTypePattern(new Set([1]), "Set"), true);
    assert.equal(ce._matchesTypePattern(null, "Object"), false);
    assert.equal(ce._matchesTypePattern(5, "Object"), true);
    assert.equal(ce._matchesTypePattern("anything", "dynamic"), true);
    assert.equal(ce._matchesTypePattern(null, "null"), true);
    assert.equal(ce._matchesTypePattern(null, "Null"), true);
  });

  test("_stdMapCreate ingests a single (non-array) entries object", () => {
    const ce = makeEngine();
    assert.deepEqual(ce._stdMapCreate({ entries: { key: "x", value: 5 } }), { x: 5 });
  });

  test("_callFunction's async-metadata getBool reads a raw (non-Value-wrapped) boolean field", async () => {
    // Real Ball IR wraps metadata booleans in a Struct Value (`{boolValue: true}`);
    // this drives the `typeof v === 'object'` check false so `getBool` falls
    // through to its raw-truthiness `return !!v` branch instead.
    const ce = makeEngine();
    const func = {
      name: "asyncRaw", isBase: false, inputType: "", metadata: { fields: { is_async: true } },
      body: { literal: { intValue: "42" } },
    };
    const result = await ce._callFunction("main", func, {}, ce._globalScope);
    // Whatever the native engine's own async handling produces, it must be
    // future-like (proves `is_async` was actually detected as true).
    assert.equal(_isFutureLike(result), true);
  });

  test("_callFunction unwraps a FlowSignal('return', ...) result and re-wraps a non-future result in BallFuture", async () => {
    // The native compiled engine's own async handling already wraps ordinary
    // results in a future marker before our patch ever sees them (verified
    // empirically), so these two defensive branches in the patch's own
    // decision logic are unit-tested here directly: stub the *native*
    // `_callFunction` (captured as `origCallFunction` by a second
    // `patchCompiledEngine` application) to hand back exactly the shapes the
    // patch is defending against.
    const ce = makeEngine();
    let call = 0;
    ce._callFunction = async (_moduleName: string, _func: any, _input: any, _parentScope: any) => {
      call++;
      if (call === 1) return new _FlowSignal("return", { value: 777 });
      return 55; // a plain, non-future value
    };
    patchCompiledEngine(ce);

    const asyncFunc = { name: "f", isBase: false, body: {}, metadata: { fields: { is_async: true } } };
    const viaFlowSignal = await ce._callFunction("main", asyncFunc, {}, ce._globalScope);
    assert.equal(_isFutureLike(viaFlowSignal), true);
    assert.equal(_unwrapBallValue(viaFlowSignal), 777);

    const viaPlainFallback = await ce._callFunction("main", asyncFunc, {}, ce._globalScope);
    assert.equal(_isFutureLike(viaPlainFallback), true);
    assert.equal(_unwrapBallValue(viaPlainFallback), 55);
  });

  test("_evalCall auto-unwraps a BallFuture-like result from the native call evaluator", async () => {
    const ce = makeEngine();
    ce._evalCall = async (_call: any, _scope: any) => ({ __ball_future__: true, value: 321, completed: true });
    patchCompiledEngine(ce);
    assert.equal(await ce._evalCall({}, ce._globalScope), 321);
  });

  test("_callBaseFunction('yield'/'yield_each') push into the current generator when one is active", () => {
    const ce = makeEngine();
    const BallGenerator = (CompiledEngineModule as any).BallGenerator;

    // No active generator: returns the (unwrapped) value without pushing anywhere.
    ce._currentGenerator = null;
    assert.equal(ce._callBaseFunction("std", "yield", { value: 5 }), 5);

    // An active generator: the value is pushed into it.
    ce._currentGenerator = new BallGenerator();
    assert.equal(ce._callBaseFunction("std", "yield", { value: 7 }), 7);
    assert.deepEqual(ce._currentGenerator.values, [7]);

    // yield_each with a plain array iterable.
    ce._currentGenerator = new BallGenerator();
    ce._callBaseFunction("std", "yield_each", { value: [1, 2] });
    assert.deepEqual(ce._currentGenerator.values, [1, 2]);

    // yield_each with a BallGenerator iterable (spreads its .values).
    const inner = new BallGenerator();
    inner.values.push(9, 10);
    ce._currentGenerator = new BallGenerator();
    ce._callBaseFunction("std", "yield_each", { value: inner });
    assert.deepEqual(ce._currentGenerator.values, [9, 10]);
  });

  test("_evalMessageCreation merges duplicate Object.prototype-polluted field names into an array", async () => {
    const ce = makeEngine();
    const msg = {
      typeName: "",
      fields: [
        { name: "length", value: { literal: { intValue: "1" } } },
        { name: "length", value: { literal: { intValue: "2" } } },
        { name: "length", value: { literal: { intValue: "3" } } },
      ],
    };
    const result = await ce._evalMessageCreation(msg, ce._globalScope);
    assert.deepEqual(result.length, [1, 2, 3]);
  });

  test("BallGenerator.prototype.yieldAll appends from any iterable, not just arrays", () => {
    makeEngine(); // ensures patchCompiledEngine has run at least once
    const BallGenerator = (CompiledEngineModule as any).BallGenerator;
    const gen = new BallGenerator();
    gen.values.push(1);
    gen.yieldAll(new Set([2, 3]));
    assert.deepEqual(gen.values, [1, 2, 3]);
  });

  test("wraps a pre-existing globalThis.__bts to unwrap BallFuture/BallGenerator before delegating", () => {
    // compiled_engine.ts never actually sets globalThis.__bts today (grepped:
    // zero occurrences), so in every real run `origBts` is undefined and this
    // wrapping is skipped — same "otherwise-dead escape hatch" shape as the
    // globalThis._patchScopeBindings test in index_wrapper.test.ts. Drive it
    // explicitly by pre-seeding the global before construction.
    const calls: any[] = [];
    const mockOrig = (v: any) => { calls.push(v); return "ORIG:" + String(v); };
    (globalThis as any).__bts = mockOrig;
    try {
      makeEngine();
      const patched = (globalThis as any).__bts;
      assert.notEqual(patched, mockOrig);
      assert.equal(patched(42), "ORIG:42");
      const fut = new BallFuture(7);
      assert.equal(patched(fut), "ORIG:7");
      assert.deepEqual(calls, [42, 7]);
    } finally {
      delete (globalThis as any).__bts;
    }
  });
});
