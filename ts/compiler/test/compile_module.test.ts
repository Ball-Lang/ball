/**
 * Tests for the public `compileModule` API (library/Module compilation).
 *
 * `compileModule` is the ball_protobuf use case: the input is a Ball Module
 * facade whose `moduleImports[].inline.json` embeds sub-modules, and the output
 * is a single TypeScript ESM library (no main(), all top-level decls exported).
 *
 * These exercise the facade expansion, the cross-module name-dedup/rename pass,
 * the dummy-entry stripping, and the export-rewrite post-processing — all of
 * which are otherwise uncovered by the Program-oriented fixture suites.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { compileModule } from "../src/index.ts";
import type { Module } from "../src/index.ts";

// A trivial std module declaration so referenced base functions resolve.
function stdModule(): Module {
  return {
    name: "std",
    functions: [
      { name: "add", isBase: true },
      { name: "print", isBase: true },
    ],
  };
}

describe("compileModule — facade with no inline sub-modules", () => {
  test("compiles a bare Module and exports its functions", () => {
    const mod: Module = {
      name: "mathlib",
      functions: [
        {
          name: "double",
          body: {
            call: {
              module: "std",
              function: "add",
              input: {
                messageCreation: {
                  typeName: "",
                  fields: [
                    { name: "left", value: { reference: { name: "input" } } },
                    { name: "right", value: { reference: { name: "input" } } },
                  ],
                },
              },
            },
          },
        },
      ],
    };

    const ts = compileModule(mod, { includePreamble: false });
    assert.match(ts, /export (?:async )?function double\b/, "double is exported");
    // No leftover dummy entry main() or top-level invocation.
    assert.doesNotMatch(ts, /__ball_lib_main__/);
    assert.doesNotMatch(ts, /^main\(\);/m);
  });

  test("includePreamble adds the runtime preamble by default", () => {
    const mod: Module = {
      name: "tiny",
      functions: [{ name: "noop", body: { literal: { intValue: 0 } } }],
    };
    const withPreamble = compileModule(mod);
    const withoutPreamble = compileModule(mod, { includePreamble: false });
    assert.ok(
      withPreamble.length > withoutPreamble.length,
      "preamble makes the output longer",
    );
  });

  test("moduleName option is accepted", () => {
    const mod: Module = {
      name: "orig",
      functions: [{ name: "noop", body: { literal: { intValue: 0 } } }],
    };
    const ts = compileModule(mod, { includePreamble: false, moduleName: "renamed" });
    assert.match(ts, /export (?:async )?function noop\b/);
  });
});

describe("compileModule — facade with inline sub-modules", () => {
  test("expands inline.json sub-modules and exports their functions", () => {
    const subA: Module = {
      name: "pkg.a",
      functions: [{ name: "fnA", body: { literal: { intValue: 1 } } }],
    };
    const subB: Module = {
      name: "pkg.b",
      functions: [{ name: "fnB", body: { literal: { intValue: 2 } } }],
    };
    const facade: Module = {
      name: "pkg",
      functions: [],
      moduleImports: [
        { name: "pkg.a", inline: { json: JSON.stringify(subA) } },
        { name: "pkg.b", inline: { json: JSON.stringify(subB) } },
      ],
    };
    const ts = compileModule(facade, { includePreamble: false });
    assert.match(ts, /export (?:async )?function fnA\b/);
    assert.match(ts, /export (?:async )?function fnB\b/);
  });

  test("deduplicates colliding function names across inline modules", () => {
    // Both sub-modules define `helper`; the dedup pass renames them to
    // `_a__helper` / `_b__helper` and rewrites internal references.
    const subA: Module = {
      name: "a",
      functions: [
        { name: "helper", body: { literal: { intValue: 1 } } },
        {
          name: "useHelperA",
          body: {
            call: { module: "", function: "helper", input: { literal: { intValue: 0 } } },
          },
        },
      ],
    };
    const subB: Module = {
      name: "b",
      functions: [{ name: "helper", body: { literal: { intValue: 2 } } }],
    };
    const facade: Module = {
      name: "dup",
      functions: [],
      moduleImports: [
        { name: "a", inline: { json: JSON.stringify(subA) } },
        { name: "b", inline: { json: JSON.stringify(subB) } },
      ],
    };
    const ts = compileModule(facade, { includePreamble: false });
    // The colliding `helper` is renamed per module; no bare `function helper(`
    // should remain unqualified.
    assert.match(ts, /_a__helper\b/, "module a's helper is renamed");
    assert.match(ts, /_b__helper\b/, "module b's helper is renamed");
  });

  test("skips malformed inline json without throwing", () => {
    const good: Module = {
      name: "good",
      functions: [{ name: "ok", body: { literal: { intValue: 1 } } }],
    };
    const facade: Module = {
      name: "mixed",
      functions: [],
      moduleImports: [
        { name: "broken", inline: { json: "{ this is not valid json" } },
        { name: "good", inline: { json: JSON.stringify(good) } },
      ],
    };
    // Should not throw; the broken module is skipped, the good one compiles.
    const ts = compileModule(facade, { includePreamble: false });
    assert.match(ts, /export (?:async )?function ok\b/);
  });

  test("dedup rename also rewrites a BARE reference to a colliding name (e.g. passed as a callback value)", () => {
    // Both sub-modules define `helper`; module a's `usesHelperAsValue`
    // references `helper` as a bare value (not a call) — e.g. passing it as
    // a callback. The rename pass must rewrite this reference too, not just
    // call sites.
    const subA: Module = {
      name: "a",
      functions: [
        { name: "helper", body: { literal: { intValue: 1 } } },
        { name: "usesHelperAsValue", body: { reference: { name: "helper" } } },
      ],
    };
    const subB: Module = {
      name: "b",
      functions: [{ name: "helper", body: { literal: { intValue: 2 } } }],
    };
    const facade: Module = {
      name: "dup2",
      functions: [],
      moduleImports: [
        { name: "a", inline: { json: JSON.stringify(subA) } },
        { name: "b", inline: { json: JSON.stringify(subB) } },
      ],
    };
    const ts = compileModule(facade, { includePreamble: false });
    // usesHelperAsValue's body must reference the RENAMED symbol, not the
    // stale/ambiguous bare "helper".
    const fnMatch = /function usesHelperAsValue\(\)[^{]*\{([\s\S]*?)\n\}/.exec(ts);
    assert.ok(fnMatch, "usesHelperAsValue function found");
    assert.match(fnMatch![1], /_a__helper\b/);
  });
});

describe("compileModule — facade with no non-base functions/typeDefs and no inline modules", () => {
  test("treats the facade itself as the single module (the empty-facade fallback path)", () => {
    // A facade whose only functions are ALL base (or none at all) and with
    // no moduleImports: allModules stays empty after both population loops,
    // so compileModule falls back to pushing the facade module itself.
    const facade: Module = {
      name: "allbase",
      functions: [{ name: "noop", isBase: true }],
    };
    // Must not throw, and must produce a (trivially empty of user code) module.
    const ts = compileModule(facade, { includePreamble: false });
    assert.equal(typeof ts, "string");
  });
});
