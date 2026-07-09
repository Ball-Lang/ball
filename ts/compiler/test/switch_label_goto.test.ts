/**
 * Compiler test for the goto-via-switch lowering
 * (`emitGotoSwitchStmt`/`parseSwitchCases`, compiler.ts). A Ball `switch`
 * whose cases carry labels is Dart's goto-via-switch:
 *
 *   switch (s) { case 0: …; continue one; one: case 1: …; break; default: … }
 *
 * where `continue <caseLabel>` transfers control to that case's body with NO
 * subject re-check, then runs onward per normal switch rules. TS has no
 * labelled switch cases, so the earlier if/else-chain lowering emitted a bare
 * `continue one;` referencing a non-existent JS label — a hard runtime
 * SyntaxError (the `400_switch_continue_label` compiled-leg regression,
 * follow-up to #337). The fix lowers it to a `<loopLabel>: while (…) switch
 * (<stateVar>) { … }` state machine; this test pins both the emitted SHAPE and
 * the runtime behavior across the four control paths of `400`.
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
import type { Expression, FunctionDef, Program, Statement } from "../src/index.ts";

const strLit = (s: string): Expression => ({ literal: { stringValue: s } });
const intLit = (n: number): Expression => ({ literal: { intValue: n } });

function callStmt(fn: string, fields: Array<{ name: string; value: Expression }>): Statement {
  return { expression: { call: { module: "std", function: fn, input: { messageCreation: { fields } } } } };
}
const printOf = (msg: Expression): Statement => callStmt("print", [{ name: "message", value: msg }]);
const continueTo = (label: string): Statement => callStmt("continue", [{ name: "label", value: strLit(label) }]);
const breakStmt = (): Statement => callStmt("break", []);

/** A switch case: `pattern` text (or `is_default`), optional goto `label`,
 *  and a body block. */
function caseOf(opts: {
  pattern?: string;
  label?: string;
  isDefault?: boolean;
  body: Statement[];
}): Expression {
  const fields: Array<{ name: string; value: Expression }> = [];
  if (opts.label) fields.push({ name: "label", value: strLit(opts.label) });
  if (opts.isDefault) fields.push({ name: "is_default", value: { literal: { boolValue: true } } });
  else if (opts.pattern !== undefined) fields.push({ name: "pattern", value: strLit(opts.pattern) });
  fields.push({ name: "body", value: { block: { statements: opts.body } } });
  return { messageCreation: { fields } };
}

/** A `walk(int)` function whose body is a labelled switch on its input, plus a
 *  `main` that calls it for each of the four control paths. */
function gotoSwitchProgram(): Program {
  const cases: Expression[] = [
    // case 0: print('0'); continue one;
    caseOf({ pattern: "0", body: [printOf(strLit("0")), continueTo("one")] }),
    // one: case 1: print('1'); continue two;
    caseOf({ pattern: "1", label: "one", body: [printOf(strLit("1")), continueTo("two")] }),
    // two: case 2: print('2'); break;
    caseOf({ pattern: "2", label: "two", body: [printOf(strLit("2")), breakStmt()] }),
    // default: print('9');
    caseOf({ isDefault: true, body: [printOf(strLit("9"))] }),
  ];
  const walkSwitch: Statement = {
    expression: {
      call: {
        module: "std",
        function: "switch",
        input: {
          messageCreation: {
            fields: [
              { name: "subject", value: { reference: { name: "input" } } },
              { name: "cases", value: { literal: { listValue: { elements: cases } } } },
            ],
          },
        },
      },
    },
  };
  // A direct call to the user function `walk`.
  const walkCall = (n: number): Statement => ({
    expression: { call: { module: "main", function: "walk", input: intLit(n) } },
  });
  return {
    name: "goto_switch_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      {
        name: "std",
        functions: [
          { name: "switch", isBase: true },
          { name: "print", isBase: true },
          { name: "continue", isBase: true },
          { name: "break", isBase: true },
        ] as FunctionDef[],
      },
      {
        name: "main",
        functions: [
          {
            name: "walk",
            inputType: "int",
            outputType: "void",
            metadata: { params: ["input"] },
            body: { block: { statements: [walkSwitch] } },
          },
          {
            name: "main",
            body: { block: { statements: [walkCall(0), walkCall(1), walkCall(2), walkCall(9)] } },
          },
        ],
      },
    ],
  };
}

function runTs(ts: string): string {
  const tmpPath = join(tmpdir(), `ball_goto_switch_${process.pid}_${Math.random().toString(36).slice(2)}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    return execSync(`node --experimental-strip-types "${tmpPath}"`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).replace(/\r\n/g, "\n").trimEnd();
  } catch (e: any) {
    throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\nTS:\n${ts}`);
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

describe("compiler — goto-via-switch (labelled cases, `continue <label>`)", () => {
  const ts = compile(gotoSwitchProgram());

  test("lowers to a labelled while/switch state machine, not a bare labelled continue", () => {
    // The bug emitted `continue one;` / `continue two;` targeting non-existent
    // JS labels. The fix must NOT emit those, and MUST emit the state machine.
    assert.doesNotMatch(ts, /continue one;/, "must not emit a bare labelled continue to a case label");
    assert.doesNotMatch(ts, /continue two;/, "must not emit a bare labelled continue to a case label");
    assert.match(ts, /__swl\d+: while \(/, "must emit a labelled state-machine loop");
    assert.match(ts, /switch \(__swst\d+\)/, "must switch on the state variable");
    // A `continue <caseLabel>` becomes a state assignment + loop continue.
    assert.match(ts, /__swst\d+ = 1; continue __swl\d+;/, "continue one → jump to arm 1");
    assert.match(ts, /__swst\d+ = 2; continue __swl\d+;/, "continue two → jump to arm 2");
  });

  test("runs all four control paths (goto chain, mid-entry, direct, default)", () => {
    // walk(0): 0→one→two ; walk(1): one→two ; walk(2): two ; walk(9): default.
    assert.equal(runTs(ts), ["0", "1", "2", "1", "2", "2", "9"].join("\n"));
  });
});
