/**
 * The encoder's TypeChecker must survive a process where a compiled Ball
 * program has shadowed `Map.prototype` (#506).
 *
 * `ts/compiler/src/preamble.ts` re-defines `Map.prototype.entries/keys/values`
 * as Dart-style GETTERS (Dart spells `map.keys`, JS spells `map.keys()`), and
 * that shadowing is process-global. Any library in the same process that calls
 * `map.keys()` then throws `keys is not a function` — and TypeScript's own type
 * checker does exactly that (`createTypeofType` -> `typeofNEFacts.keys()`).
 * Since #506 the encoder builds a real `ts.Program`, so it is now one of those
 * libraries: `@ball-lang/cli` loading `@ball-lang/engine` and then encoding in
 * the same process would have crashed.
 *
 * This file lives on its own because it mutates a global prototype. `node:test`
 * runs each test FILE in its own process, so the shadowing cannot leak into
 * another suite even if a restore were missed.
 *
 * Run with:
 *   node --experimental-strip-types --test test/map_prototype_interop.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { encode } from "../src/index.ts";

const SHADOWED = ["entries", "keys", "values"] as const;

/** Install the preamble's Dart-style getters, exactly as a compiled Ball program does. */
function shadowMapPrototype(): () => void {
  const nativeEntries = Map.prototype.entries;
  const nativeKeys = Map.prototype.keys;
  const nativeValues = Map.prototype.values;
  const saved = SHADOWED.map(
    (name) => [name, Object.getOwnPropertyDescriptor(Map.prototype, name)!] as const,
  );
  Object.defineProperty(Map.prototype, "entries", {
    configurable: true, enumerable: false,
    get(this: Map<unknown, unknown>) {
      return [...nativeEntries.call(this)].map(([key, value]) => ({ key, value }));
    },
  });
  Object.defineProperty(Map.prototype, "keys", {
    configurable: true, enumerable: false,
    get(this: Map<unknown, unknown>) { return [...nativeKeys.call(this)]; },
  });
  Object.defineProperty(Map.prototype, "values", {
    configurable: true, enumerable: false,
    get(this: Map<unknown, unknown>) { return [...nativeValues.call(this)]; },
  });
  return () => {
    for (const [name, descriptor] of saved) Object.defineProperty(Map.prototype, name, descriptor);
  };
}

describe("#506 — checker-backed encoding under a Ball-shadowed Map.prototype", () => {
  test("array/string resolution still works, and the shadowing is put back", () => {
    const restore = shadowMapPrototype();
    try {
      // Sanity: the shadowing really is in effect for this process.
      assert.deepEqual(new Map([["a", 1]]).keys, ["a"]);

      const program = encode(`function main() {
  const a: number[] = [];
  a.slice(1, 3);
  const s: string = "";
  s.slice(1, 3);
}`);
      const main = program.modules
        .find((m) => m.name === "main")!
        .functions.find((f) => f.name === "main")!;
      const calls = main.body!.block!.statements
        .filter((st) => st.expression?.call)
        .map((st) => `${st.expression!.call!.module ?? "std"}.${st.expression!.call!.function}`);
      assert.deepEqual(calls, ["std_collections.list_slice", "std.string_substring"]);

      // The guard must RESTORE the shadowing, not leave the natives in place —
      // a compiled Ball program running after an encode still needs its getters.
      assert.deepEqual(new Map([["b", 2]]).keys, ["b"]);
    } finally {
      restore();
    }
    assert.equal(typeof new Map().keys, "function");
  });
});
