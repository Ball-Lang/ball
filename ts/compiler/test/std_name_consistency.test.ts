/**
 * Encoder/compiler std-vocabulary consistency gate (issues #489, #490).
 *
 * The TS encoder and the TS compiler are two halves of one pipeline, but they
 * were developed against separate test suites: `ts/encoder`'s unit tests assert
 * the encoder's OWN spelling of each std base function, and `ts/compiler`'s
 * `std_call_dispatch.test.ts` hand-builds IR using the COMPILER's spelling.
 * Neither could ever see that the two vocabularies had drifted apart — which is
 * exactly what happened: the encoder emitted `list_add`, `optional_access`,
 * `contains_key`, `string_replace_first`, `string_to_upper_case`, ... none of
 * which `compileStdCall` recognises, so real TS code hit
 * "TS compiler: std.X is not implemented (compileStdCall)".
 *
 * This test closes that hole mechanically:
 *   1. Statically enumerate every std/std_collections base-function name that
 *      `ts/encoder/src/encoder.ts` can emit (its `stdCall()` call sites plus the
 *      BINARY_OPS / STR_METHODS / ARR_METHODS lookup tables), via the TypeScript
 *      AST rather than a regex.
 *   2. Feed each one through the REAL `compile()` and assert the compiler never
 *      answers with its not-implemented error.
 *
 * A name the encoder can emit but the compiler cannot compile is a build
 * failure, not a latent trap for whoever writes the first program that uses it.
 *
 * Run with:
 *   node --experimental-strip-types --test test/std_name_consistency.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import ts from "typescript";
import { compile } from "../src/index.ts";
import type { Program, Expression, FieldValuePair } from "../src/types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ENCODER_SRC = join(HERE, "..", "..", "encoder", "src", "encoder.ts");

/**
 * Names the encoder can emit that the TS compiler deliberately does NOT
 * implement. Every entry is an ACCEPTED, DOCUMENTED gap — adding one requires
 * editing this table, which is the point: a silent new gap is impossible.
 *
 * Keep in sync with `ts/encoder/ENCODER_CARVEOUTS.md`.
 */
const KNOWN_GAPS: Record<string, string> = {
  // #489: JS `typeof` has no universal std equivalent. Implementing it means a
  // genuinely new base function (dart/shared/lib/std.dart + gen_std.dart + the
  // Dart compiler/engine + every target) — deliberately NOT folded into the
  // vocabulary-alignment fix. The encoder keeps emitting it so the failure is
  // loud and named rather than silently mis-encoded.
  type_of: "#489: needs a new universal std base function across every target",
  // A computed object-literal key (`{ [k]: v }`) has no Ball representation:
  // MessageCreation field names are static strings. Encoded loudly so the
  // compiler names the construct instead of emitting a wrong object.
  computed_property: "computed object keys have no Ball MessageCreation shape",
  // Tagged templates need the raw/cooked strings array JS exposes to the tag
  // function; Ball has no equivalent value.
  tagged_template: "tagged templates need JS's raw/cooked strings array",
};

/** Extract every (module, function) pair `encoder.ts` can emit. */
function encoderEmittableNames(): Map<string, Set<string>> {
  const source = readFileSync(ENCODER_SRC, "utf8");
  const sf = ts.createSourceFile(
    ENCODER_SRC, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS,
  );
  const found = new Map<string, Set<string>>();
  const add = (name: string, mod: string) => {
    if (!found.has(name)) found.set(name, new Set());
    found.get(name)!.add(mod);
  };

  const visit = (node: ts.Node): void => {
    // `this.stdCall("name", [...], "module")` — module defaults to "std".
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === "stdCall"
    ) {
      const nameArg = node.arguments[0];
      const modArg = node.arguments[2];
      if (nameArg && ts.isStringLiteral(nameArg)) {
        add(nameArg.text, modArg && ts.isStringLiteral(modArg) ? modArg.text : "std");
      }
    }
    // The operator/method lookup tables.
    if (
      ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) &&
      /^(BINARY_OPS|STR_METHODS|ARR_METHODS)$/.test(node.name.text) &&
      node.initializer && ts.isObjectLiteralExpression(node.initializer)
    ) {
      for (const prop of node.initializer.properties) {
        if (!ts.isPropertyAssignment(prop)) continue;
        const init = prop.initializer;
        if (ts.isStringLiteral(init)) { add(init.text, "std"); continue; }
        if (!ts.isObjectLiteralExpression(init)) continue;
        let fn: string | undefined;
        let mod = "std";
        for (const entry of init.properties) {
          if (!ts.isPropertyAssignment(entry) || !ts.isIdentifier(entry.name)) continue;
          if (!ts.isStringLiteral(entry.initializer)) continue;
          if (entry.name.text === "fn" || entry.name.text === "function") fn = entry.initializer.text;
          if (entry.name.text === "mod" || entry.name.text === "module") mod = entry.initializer.text;
        }
        if (fn) add(fn, mod);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  return found;
}

/**
 * A generous superset of the field names the compiler's cases look for. The
 * probe only asserts that the DISPATCH recognises the name; a case that then
 * rejects a nonsensical field combination is fine and not what is under test.
 */
function probeFields(): FieldValuePair[] {
  const str = (s: string): Expression => ({ literal: { stringValue: s } });
  const num = (n: string): Expression => ({ literal: { intValue: n } });
  const ref = (n: string): Expression => ({ reference: { name: n } });
  const names: [string, Expression][] = [
    ["value", ref("v")], ["left", ref("a")], ["right", ref("b")],
    ["target", ref("t")], ["list", ref("l")], ["map", ref("m")],
    ["key", str("k")], ["field", str("f")], ["index", num("0")],
    ["object", ref("o")], ["other", ref("b")], ["start", num("0")],
    ["end", num("1")], ["from", str("x")], ["to", str("y")],
    ["pattern", str("p")], ["separator", str(",")], ["count", num("2")],
    ["width", num("3")], ["padding", str(" ")], ["method", str("m")],
    ["function", ref("cb")], ["condition", ref("c")], ["iterable", ref("l")],
    ["variable", str("it")], ["body", ref("v")], ["message", str("m")],
    ["type", str("int")], ["callee", ref("cb")], ["label", str("L")],
    ["tag", ref("tag")], ["strings", { literal: { listValue: { elements: [] } } }],
    ["expressions", { literal: { listValue: { elements: [] } } }],
    ["cases", { literal: { listValue: { elements: [] } } }],
    ["subject", ref("s")], ["catches", { literal: { listValue: { elements: [] } } }],
  ];
  return names.map(([name, v]) => ({ name, value: v }));
}

/**
 * Build a one-function Program that calls `<module>.<fn>(...)`, either as the
 * function's tail expression or as a statement inside a block. Both positions
 * matter: `break`/`continue`/`labeled` are dispatched by the compiler's
 * statement-level control-flow router, never by `compileStdCall`.
 */
function programCalling(fn: string, module: string, position: "expression" | "statement"): Program {
  const call: Expression = {
    call: {
      module,
      function: fn,
      input: { messageCreation: { typeName: "", fields: probeFields() } },
    },
  };
  return {
    name: "probe",
    version: "1.0.0",
    entryModule: "probe",
    entryFunction: "main",
    modules: [
      { name: module, functions: [{ name: fn, isBase: true }] },
      {
        name: "probe",
        functions: [{
          name: "main",
          body: position === "expression"
            ? call
            : { block: { statements: [{ expression: call }] } },
        }],
      },
    ],
  } as Program;
}

const NOT_IMPLEMENTED = /is not implemented \(compileStdCall\)/;

/**
 * True when the compiler refuses the name in BOTH positions with its
 * not-implemented error. Any other error (a case rejecting the synthetic field
 * soup) means the dispatch DID recognise the name, which is all this gate
 * asserts.
 */
function compilerRejectsName(fn: string, module: string): string | undefined {
  let lastMessage: string | undefined;
  for (const position of ["expression", "statement"] as const) {
    try {
      compile(programCalling(fn, module, position));
      return undefined;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!NOT_IMPLEMENTED.test(msg)) return undefined;
      lastMessage = msg;
    }
  }
  return lastMessage;
}

describe("encoder/compiler std vocabulary consistency (#489)", () => {
  const emittable = encoderEmittableNames();

  test("the extractor finds a realistic number of encoder-emittable names", () => {
    // Positive floor: a broken extractor that finds nothing must fail here
    // rather than read as a green "no drift" result.
    assert.ok(
      emittable.size >= 60,
      `expected the encoder to emit at least 60 distinct std names, found ${emittable.size}`,
    );
    // Spot-check a few canonical names the encoder is known to emit, so a
    // regression that guts the tables (rather than the extractor) also fails.
    for (const anchor of ["add", "if", "for_each", "for_in", "list_push", "map_contains_key"]) {
      assert.ok(emittable.has(anchor), `extractor should have found "${anchor}"`);
    }
  });

  test("every std name the encoder can emit is implemented by the compiler", () => {
    const missing: string[] = [];
    let probed = 0;
    for (const [fn, modules] of emittable) {
      if (Object.prototype.hasOwnProperty.call(KNOWN_GAPS, fn)) continue;
      for (const module of modules) {
        probed++;
        const rejection = compilerRejectsName(fn, module);
        if (rejection) missing.push(`${module}.${fn}: ${rejection}`);
      }
    }
    assert.ok(probed >= 60, `expected to probe at least 60 names, probed ${probed}`);
    assert.deepEqual(
      missing,
      [],
      `The TS encoder can emit std names the TS compiler does not implement.\n` +
      `Either rename the encoder to the compiler's canonical name, implement the\n` +
      `case in compileStdCall, or add a documented entry to KNOWN_GAPS.\n` +
      missing.join("\n"),
    );
  });

  test("every documented gap is still a real gap (no stale carve-outs)", () => {
    for (const [fn, reason] of Object.entries(KNOWN_GAPS)) {
      assert.ok(reason.length > 0, `${fn} needs a documented reason`);
      assert.ok(
        emittable.has(fn),
        `KNOWN_GAPS lists "${fn}" but the encoder no longer emits it — delete the entry`,
      );
      let rejected = false;
      for (const module of emittable.get(fn)!) {
        if (compilerRejectsName(fn, module)) rejected = true;
      }
      assert.ok(
        rejected,
        `KNOWN_GAPS lists "${fn}" but the compiler now implements it — delete the entry`,
      );
    }
  });
});
