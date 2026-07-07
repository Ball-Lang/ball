/**
 * Compiler tests for STRUCTURED pattern-matching compilation
 * (`compileStructuredPattern`, compiler.ts ~lines 5900-6145) reached from
 * both `switch` used as a STATEMENT (`emitControlFlowStatement`'s
 * if/else-chain compilation) and `switch` used as an EXPRESSION
 * (`compileSwitchExpr`'s ternary-chain compilation).
 *
 * `pattern_expr` carries a structured messageCreation (typeName = the
 * pattern kind: ListPattern/RecordPattern/CastPattern/etc.) alongside a
 * cosmetic legacy `pattern` string. `compileStructuredPattern` is the
 * modern path; unknown kinds fall back to the legacy text parser. This
 * is a currently HOT area (recent fix: "MapPattern must exclude portable
 * Set value across compiler + engines", #178) — see the notes below.
 *
 * None of these real fixtures (`tests/conformance/{238,239,252,302,303,
 * 305,306}_*.ball.json`) were previously exercised through the native
 * TS-codegen path (only via the interpreted-engine conformance corpus).
 *
 * FIXED (#206, #207): `KNOWN_PATTERN_KINDS` (compiler.ts ~line 5869) used
 * to omit "MapPattern", "LogicalAndPattern", "ObjectPattern", and
 * "RelationalPattern", so a structured MapPattern/LogicalAndPattern ALWAYS
 * fell back to the legacy text pattern. That fallback (`parseMapPattern`,
 * ~line 5751) only recognized `var`-bound entries (`{'k': var v}`); the
 * real encoder also emits `final`-bound entries (`{'k': final v}`), which
 * the parser rejected and fell through to a bogus default condition that
 * embedded raw Dart pattern syntax into the emitted TS — a hard
 * `SyntaxError` at runtime, not just wrong output. All four kinds are now
 * in `KNOWN_PATTERN_KINDS` with structured cases in
 * `compileStructuredPattern`; the `final`-bound-entry regression is
 * pinned by `394_mappattern_excludes_set` and `258_logical_and_pattern`
 * in native_conformance.test.ts.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  readFileSync,
  writeFileSync,
  unlinkSync,
  existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Expression, FunctionDef, Program, Statement } from "../src/index.ts";
import { unwrapBallFile } from "./ball_file.ts";

function findRepoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    if (existsSync(join(dir, "proto", "ball", "v1", "ball.proto"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error("repo root not found");
    dir = parent;
  }
}

const root = findRepoRoot();
const conformanceDir = resolve(root, "tests/conformance");

const PATTERN_FIXTURES = [
  // ListPattern with a rest sub-pattern ([first, ...rest, last]).
  "252_list_rest_pattern",
  // CastPattern: `pat as T` asserts (throws on mismatch), does not refute.
  "302_cast_patterns",
  // LogicalOrPattern over typed alternatives (`case bool _ || double _:`).
  "303_or_typed_patterns",
  // Structured LogicalOrPattern with plain const alternatives.
  "238_switch_or_patterns",
  // RelationalPattern: now routed through the structured path (#207 audit);
  // previously fell back to the legacy text path (also correct there).
  "239_switch_expr_relational",
  // RecordPattern: positional-only and mixed positional+named shapes.
  "305_record_patterns",
  // Nullable VarPattern/WildcardPattern types (`int?`, `double? _`).
  "306_nullable_type_patterns",
  // MapPattern (var-bound entries): now routed through the structured
  // MapPattern case (#206). The `final`-bound-entry variant that used to
  // crash with ERR_INVALID_TYPESCRIPT_SYNTAX is pinned by
  // 394_mappattern_excludes_set in native_conformance.test.ts.
  "237_map_pattern_switch",
];

describe("compiler — structured pattern matching (real fixtures, native codegen)", () => {
  for (const name of PATTERN_FIXTURES) {
    test(`native fixture — ${name}`, () => {
      const program: Program = unwrapBallFile(
        JSON.parse(readFileSync(join(conformanceDir, `${name}.ball.json`), "utf8")),
      );
      const ts = compile(program);
      const tmpPath = join(tmpdir(), `ball_pattern_${name}_${process.pid}.ts`);
      writeFileSync(tmpPath, ts);
      try {
        let stdout: string;
        try {
          stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          });
        } catch (e: any) {
          throw new Error(`Node failed for ${name}:\nstderr:\n${e.stderr}`);
        }
        const expected = readFileSync(
          join(conformanceDir, `${name}.expected_output.txt`),
          "utf8",
        );
        const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
        assert.equal(norm(stdout), norm(expected), `Stdout mismatch for ${name}`);
      } finally {
        try { unlinkSync(tmpPath); } catch { /* ignore */ }
      }
    });
  }
});

// ── Direct-IR unit tests for structural details the real fixtures above
// don't isolate on their own (guard-clause binding hoisting in both the
// statement and expression switch forms, NullCheckPattern in isolation). ──

const stdModule = () => ({
  name: "std",
  functions: [
    { name: "switch", isBase: true },
    { name: "switch_expr", isBase: true },
    { name: "print", isBase: true },
  ] as FunctionDef[],
});

function switchStmtProgram(subject: Expression, cases: Expression[]): Program {
  return {
    name: "pattern_guard_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      stdModule(),
      {
        name: "main",
        functions: [
          {
            name: "main",
            body: {
              block: {
                statements: [
                  {
                    expression: {
                      call: {
                        module: "std",
                        function: "switch",
                        input: {
                          messageCreation: {
                            fields: [
                              { name: "subject", value: subject },
                              { name: "cases", value: { literal: { listValue: { elements: cases } } } },
                            ],
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        ],
      },
    ],
  };
}

function varPatternCase(
  varName: string,
  typeName: string | undefined,
  guard: Expression | undefined,
  body: Expression,
): Expression {
  const patternExprFields: Expression[] = [];
  const fields: any[] = [{ name: "name", value: { literal: { stringValue: varName } } }];
  if (typeName) fields.push({ name: "type", value: { literal: { stringValue: typeName } } });
  const caseFields: any[] = [
    { name: "pattern_expr", value: { messageCreation: { typeName: "VarPattern", fields } } },
    { name: "body", value: body },
  ];
  if (guard) caseFields.push({ name: "guard", value: guard });
  return { messageCreation: { fields: caseFields } };
}

/** A raw `pattern_expr`-carrying switch case, for structured-pattern kinds
 *  that {@link varPatternCase} doesn't model directly. */
function patternExprCase(patternExpr: Expression, body: Expression, guard?: Expression): Expression {
  const caseFields: any[] = [
    { name: "pattern_expr", value: patternExpr },
    { name: "body", value: body },
  ];
  if (guard) caseFields.push({ name: "guard", value: guard });
  return { messageCreation: { fields: caseFields } };
}

const strLit = (s: string): Expression => ({ literal: { stringValue: s } });
const intLit = (n: number): Expression => ({ literal: { intValue: n } });

/** `VarPattern{name, type?}` pattern_expr builder (bare Expression, not a case). */
function varPatternExpr(varName: string | undefined, typeName?: string): Expression {
  const fields: any[] = [];
  if (varName) fields.push({ name: "name", value: strLit(varName) });
  if (typeName) fields.push({ name: "type", value: strLit(typeName) });
  return { messageCreation: { typeName: "VarPattern", fields } };
}

function returnValue(v: Expression): Expression {
  return { call: { module: "std", function: "return", input: { messageCreation: { fields: [{ name: "value", value: v }] } } } };
}
/** A print CALL as a bare Expression (for use as a switch-case `body`, or
 *  anywhere an Expression is expected, e.g. `returnValue`'s value). */
function printExpr(msg: Expression): Expression {
  return { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: msg }] } } } };
}
/** A print call wrapped as a Statement (for use inside `block.statements`). */
function printOf(msg: Expression): Statement {
  return { expression: printExpr(msg) };
}
function toStringOf(v: Expression): Expression {
  return { call: { module: "std", function: "to_string", input: { messageCreation: { fields: [{ name: "value", value: v }] } } } };
}

function switchExprProgram(subject: Expression, cases: Expression[], extraFns: FunctionDef[] = []): Program {
  return {
    name: "switch_expr_extra_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      {
        name: "std",
        functions: [
          { name: "switch_expr", isBase: true },
          { name: "print", isBase: true },
          { name: "to_string", isBase: true },
          ...extraFns,
        ] as FunctionDef[],
      },
      {
        name: "main",
        functions: [
          {
            name: "main",
            body: {
              block: {
                statements: [
                  {
                    let: {
                      name: "result",
                      value: {
                        call: {
                          module: "std",
                          function: "switch_expr",
                          input: {
                            messageCreation: {
                              fields: [
                                { name: "subject", value: subject },
                                { name: "cases", value: { literal: { listValue: { elements: cases } } } },
                              ],
                            },
                          },
                        },
                      },
                    },
                  },
                  printOf(toStringOf({ reference: { name: "result" } })),
                ],
              },
            },
          },
        ],
      },
    ],
  };
}

function compileAndRunProgram(program: Program, hint: string): string {
  const ts = compile(program);
  const tmpPath = join(tmpdir(), `ball_${hint}_${process.pid}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    let stdout: string;
    try {
      stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e: any) {
      throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\nTS:\n${ts}`);
    }
    return stdout.replace(/\r\n/g, "\n").trimEnd();
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

describe("compiler — structured pattern guard clauses (`when`)", () => {
  test("switch STATEMENT: a guarded VarPattern binding is hoisted so the guard can read it", () => {
    // `switch (x) { case int n when n > 0: print('positive'); }`
    const program = switchStmtProgram(
      { reference: { name: "x" } },
      [
        varPatternCase(
          "n",
          "int",
          {
            call: {
              module: "std",
              function: "gte",
              input: {
                messageCreation: {
                  fields: [
                    { name: "left", value: { reference: { name: "n" } } },
                    { name: "right", value: { literal: { intValue: 1 } } },
                  ],
                },
              },
            },
          },
          {
            call: {
              module: "std",
              function: "print",
              input: {
                messageCreation: {
                  fields: [{ name: "message", value: { literal: { stringValue: "positive" } } }],
                },
              },
            },
          },
        ),
      ],
    );
    const ts = compile(program, { includePreamble: false });
    // The bound `n` must be usable inside the guard IIFE, gated by the
    // type-check condition.
    assert.match(ts, /\(\(n\) => \(/, "guard is evaluated in an IIFE parameterized by the pattern binding");
    assert.match(ts, /Number\.isInteger/, "the VarPattern's int type check is present");
  });

  test("switch EXPRESSION: a false guard falls through to the next branch (does not short-circuit the whole switch)", () => {
    // `x = switch (n) { int v when v > 10 => 'big', int v => 'small' }`
    // A structured catch-all VarPattern (no type→ 'true' condition) with a
    // guard must NOT terminate the branch chain — it must still fall
    // through to later cases when the guard is false (foldSwitchBranch).
    const caseHighGuard: Expression = {
      messageCreation: {
        fields: [
          {
            name: "pattern_expr",
            value: {
              messageCreation: {
                typeName: "VarPattern",
                fields: [{ name: "name", value: { literal: { stringValue: "v" } } }],
              },
            },
          },
          {
            name: "guard",
            value: {
              call: {
                module: "std",
                function: "gte",
                input: {
                  messageCreation: {
                    fields: [
                      { name: "left", value: { reference: { name: "v" } } },
                      { name: "right", value: { literal: { intValue: 10 } } },
                    ],
                  },
                },
              },
            },
          },
          { name: "body", value: { literal: { stringValue: "big" } } },
        ],
      },
    };
    const caseFallback: Expression = {
      messageCreation: {
        fields: [
          {
            name: "pattern_expr",
            value: { messageCreation: { typeName: "WildcardPattern", fields: [] } },
          },
          { name: "body", value: { literal: { stringValue: "small" } } },
        ],
      },
    };
    const program: Program = {
      name: "switch_expr_guard_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        stdModule(),
        {
          name: "main",
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "result",
                        value: {
                          call: {
                            module: "std",
                            function: "switch_expr",
                            input: {
                              messageCreation: {
                                fields: [
                                  { name: "subject", value: { reference: { name: "n" } } },
                                  {
                                    name: "cases",
                                    value: { literal: { listValue: { elements: [caseHighGuard, caseFallback] } } },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    // Ternary chain: guarded branch's false path must fall through to the
    // 'small' branch, not to `undefined`.
    assert.match(ts, /'small'/);
    assert.match(ts, /'big'/);
    // The guard's ternary must reference a fallthrough, i.e. the 'small'
    // branch's condition appears textually AFTER the guarded IIFE.
    const bigIdx = ts.indexOf("'big'");
    const smallIdx = ts.indexOf("'small'");
    assert.ok(bigIdx >= 0 && smallIdx >= 0 && bigIdx < smallIdx);
  });
});

// ── ObjectPattern: also missing from KNOWN_PATTERN_KINDS (found by the
// #207 audit alongside MapPattern/LogicalAndPattern/RelationalPattern), but
// with no real conformance fixture exercising `Type(field: pattern)`. This
// direct-IR test compiles AND executes a switch_expr over ObjectPattern so
// the fix is proven end-to-end, not just structurally plausible. ──

describe("compiler — ObjectPattern (audit-discovered gap, #207)", () => {
  test("Type(field: pattern) type-gates by class and matches a named field's getter", () => {
    const program: Program = {
      name: "object_pattern_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "std",
          functions: [
            { name: "switch_expr", isBase: true },
            { name: "concat", isBase: true },
            { name: "to_string", isBase: true },
            { name: "print", isBase: true },
          ] as FunctionDef[],
        },
        {
          name: "main",
          functions: [
            {
              name: "main:Pt.new",
              outputType: "main:Pt",
              metadata: {
                kind: "constructor",
                params: [
                  { name: "x", is_this: true },
                  { name: "y", is_this: true },
                ],
              },
            },
            {
              name: "classify",
              inputType: "Object",
              outputType: "String",
              body: {
                call: {
                  module: "std",
                  function: "switch_expr",
                  input: {
                    messageCreation: {
                      fields: [
                        { name: "subject", value: { reference: { name: "obj" } } },
                        {
                          name: "cases",
                          value: {
                            literal: {
                              listValue: {
                                elements: [
                                  {
                                    messageCreation: {
                                      fields: [
                                        {
                                          name: "body",
                                          value: {
                                            call: {
                                              module: "std",
                                              function: "concat",
                                              input: {
                                                messageCreation: {
                                                  fields: [
                                                    { name: "left", value: { literal: { stringValue: "x=" } } },
                                                    {
                                                      name: "right",
                                                      value: {
                                                        call: {
                                                          module: "std",
                                                          function: "to_string",
                                                          input: {
                                                            messageCreation: {
                                                              fields: [{ name: "value", value: { reference: { name: "px" } } }],
                                                            },
                                                          },
                                                        },
                                                      },
                                                    },
                                                  ],
                                                },
                                              },
                                            },
                                          },
                                        },
                                        {
                                          name: "pattern_expr",
                                          value: {
                                            messageCreation: {
                                              typeName: "ObjectPattern",
                                              fields: [
                                                { name: "type", value: { literal: { stringValue: "Pt" } } },
                                                {
                                                  name: "fields",
                                                  value: {
                                                    literal: {
                                                      listValue: {
                                                        elements: [
                                                          {
                                                            messageCreation: {
                                                              fields: [
                                                                { name: "name", value: { literal: { stringValue: "x" } } },
                                                                {
                                                                  name: "pattern",
                                                                  value: {
                                                                    messageCreation: {
                                                                      typeName: "VarPattern",
                                                                      fields: [{ name: "name", value: { literal: { stringValue: "px" } } }],
                                                                    },
                                                                  },
                                                                },
                                                              ],
                                                            },
                                                          },
                                                        ],
                                                      },
                                                    },
                                                  },
                                                },
                                              ],
                                            },
                                          },
                                        },
                                      ],
                                    },
                                  },
                                  {
                                    messageCreation: {
                                      fields: [
                                        { name: "is_default", value: { literal: { boolValue: true } } },
                                        { name: "body", value: { literal: { stringValue: "not-pt" } } },
                                      ],
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
              metadata: { kind: "function", params: [{ name: "obj", type: "Object" }] },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    // Construct via an intermediate `let` (matching every real
                    // fixture's convention) rather than inline in the call's
                    // input — inline construction as a call argument hits a
                    // SEPARATE, pre-existing compiler bug where a messageCreation's
                    // arg0/arg1 fields get flattened into positional JS call
                    // arguments instead of `new Pt(3, 4)` being recognized and
                    // passed as one argument. Out of scope for #205-#207; flagged
                    // to the team separately.
                    {
                      let: {
                        name: "p",
                        value: {
                          messageCreation: {
                            typeName: "main:Pt",
                            fields: [
                              { name: "arg0", value: { literal: { intValue: "3" } } },
                              { name: "arg1", value: { literal: { intValue: "4" } } },
                            ],
                          },
                        },
                        metadata: { keyword: "final", type: "Pt" },
                      },
                    },
                    {
                      expression: {
                        call: {
                          module: "std",
                          function: "print",
                          input: {
                            messageCreation: {
                              typeName: "PrintInput",
                              fields: [
                                {
                                  name: "message",
                                  value: {
                                    call: {
                                      function: "classify",
                                      input: { reference: { name: "p" } },
                                    },
                                  },
                                },
                              ],
                            },
                          },
                        },
                      },
                    },
                    {
                      expression: {
                        call: {
                          module: "std",
                          function: "print",
                          input: {
                            messageCreation: {
                              typeName: "PrintInput",
                              fields: [
                                {
                                  name: "message",
                                  value: {
                                    call: {
                                      function: "classify",
                                      input: { literal: { stringValue: "hi" } },
                                    },
                                  },
                                },
                              ],
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          moduleImports: [{ name: "std" }],
          typeDefs: [
            {
              name: "main:Pt",
              descriptor: {
                name: "main:Pt",
                field: [
                  { name: "x", number: 1, label: "LABEL_OPTIONAL", type: "TYPE_INT64" },
                  { name: "y", number: 2, label: "LABEL_OPTIONAL", type: "TYPE_INT64" },
                ],
              },
              metadata: {
                kind: "class",
                fields: [
                  { name: "x", type: "int" },
                  { name: "y", type: "int" },
                ],
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_object_pattern_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e: any) {
        throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\nTS:\n${ts}`);
      }
      const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
      assert.equal(norm(stdout), "x=3\nnot-pt");
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

// ── Legacy cosmetic-TEXT pattern fallback (patternLiteralText/
// parseTypeTestPattern/parseMapPattern/patternBindings/patternToTsCondition/
// splitTopLevel). Before #206/#207, 237_map_pattern_switch and
// 239_switch_expr_relational were this fallback's ONLY real-fixture callers
// (their pattern_expr kinds — MapPattern, RelationalPattern — fell out of
// KNOWN_PATTERN_KINDS into the text parser). Now that those kinds are
// structured, both fixtures route through compileStructuredPattern instead,
// which orphaned the text-fallback functions from any test. This direct-IR
// test exercises a case with a cosmetic `pattern` string and NO `pattern_expr`
// field at all — the shape the text fallback exists for (older/hand-authored
// Ball JSON without structured pattern_expr nodes) — so the fallback stays a
// tested, working code path in its own right. ──

describe("compiler — legacy cosmetic-text pattern fallback (no pattern_expr field)", () => {
  test("a switch STATEMENT with only cosmetic `pattern` strings dispatches via the text parser", () => {
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: {
        fields: [
          { name: "pattern", value: { literal: { stringValue: patternText } } },
          { name: "body", value: body },
        ],
      },
    });
    const returnValue = (v: Expression): Expression => ({
      call: { module: "std", function: "return", input: { messageCreation: { fields: [{ name: "value", value: v }] } } },
    });
    const concatOf = (left: Expression, right: Expression): Expression => ({
      call: { module: "std", function: "concat", input: { messageCreation: { fields: [{ name: "left", value: left }, { name: "right", value: right }] } } },
    });
    const toStringOf = (v: Expression): Expression => ({
      call: { module: "std", function: "to_string", input: { messageCreation: { fields: [{ name: "value", value: v }] } } },
    });
    const strLit = (s: string): Expression => ({ literal: { stringValue: s } });
    const printClassifyOf = (arg: Expression) => ({
      expression: {
        call: {
          module: "std",
          function: "print",
          input: {
            messageCreation: {
              typeName: "PrintInput",
              fields: [{ name: "message", value: { call: { function: "classify", input: arg } } }],
            },
          },
        },
      },
    });

    const program: Program = {
      name: "legacy_text_pattern_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "std",
          functions: [
            { name: "switch", isBase: true },
            { name: "return", isBase: true },
            { name: "concat", isBase: true },
            { name: "to_string", isBase: true },
            { name: "print", isBase: true },
          ] as FunctionDef[],
        },
        {
          name: "main",
          functions: [
            {
              name: "classify",
              inputType: "Object",
              outputType: "String",
              body: {
                block: {
                  statements: [
                    {
                      expression: {
                        call: {
                          module: "std",
                          function: "switch",
                          input: {
                            messageCreation: {
                              fields: [
                                { name: "subject", value: { reference: { name: "obj" } } },
                                {
                                  name: "cases",
                                  value: {
                                    literal: {
                                      listValue: {
                                        elements: [
                                          // parseTypeTestPattern + patternBindings' type-test branch.
                                          textCase("int n", returnValue(concatOf(strLit("int:"), toStringOf({ reference: { name: "n" } })))),
                                          // parseMapPattern (var-bound) + patternBindings' map branch.
                                          textCase("{'x': var v}", returnValue(concatOf(strLit("map:"), toStringOf({ reference: { name: "v" } })))),
                                          // patternToTsCondition's `||` branch -> splitTopLevel.
                                          textCase("'a' || 'b'", returnValue(strLit("or:matched"))),
                                          textCase("_", returnValue(strLit("other"))),
                                        ],
                                      },
                                    },
                                  },
                                },
                              ],
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
              metadata: { kind: "function", params: [{ name: "obj", type: "Object" }] },
            },
            {
              name: "main",
              outputType: "void",
              body: {
                block: {
                  statements: [
                    // The map literal is built via an intermediate `let` (matching
                    // every real fixture's convention), not inline in the call's
                    // input — inline construction as a call argument hits a
                    // SEPARATE, pre-existing compiler bug (#213) where a
                    // single-field messageCreation gets unwrapped to just that
                    // field's value instead of the `{'x': 99}` object literal.
                    {
                      let: {
                        name: "m",
                        value: { messageCreation: { fields: [{ name: "x", value: { literal: { intValue: "99" } } }] } },
                        metadata: { keyword: "final", type: "Object" },
                      },
                    },
                    printClassifyOf({ literal: { intValue: "42" } }),
                    printClassifyOf({ reference: { name: "m" } }),
                    printClassifyOf({ literal: { stringValue: "a" } }),
                    printClassifyOf({ literal: { boolValue: true } }),
                  ],
                },
              },
              metadata: { kind: "function" },
            },
          ],
          moduleImports: [{ name: "std" }],
        },
      ],
    };

    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_legacy_text_pattern_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (e: any) {
        throw new Error(`Node failed:\nstderr:\n${e.stderr}\n\nTS:\n${ts}`);
      }
      const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
      assert.equal(norm(stdout), "int:42\nmap:99\nor:matched\nother");
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });
});

// ═══════════════════════ Issue #264 additions ═══════════════════════
// compileStructuredPattern's combinator/edge branches (LogicalOr/And
// falling back to the legacy parser when a sub-pattern isn't itself
// structured, CastPattern with no type, ListPattern's post-rest binding,
// RecordPattern's mixed positional+named check, NullCheckPattern actually
// exercised, a standalone RestPattern, patternExprKind's `__pattern_kind__`
// fallback, and ConstPattern/VarPattern's no-value/no-name edge cases) plus
// the switch-fallthrough+guard combinations and legacy-text-pattern
// branches (true/false/null literals, relational patterns, and the
// switch_expr form of the legacy-text fallback) deferred from #62/#263.

describe("compiler — patternExprKind's __pattern_kind__ fallback (no typeName)", () => {
  test("a pattern_expr with NO typeName but a __pattern_kind__ field resolves via the fallback", () => {
    const noTypeNameWildcard: Expression = {
      messageCreation: { fields: [{ name: "__pattern_kind__", value: strLit("WildcardPattern") }] },
    };
    const program = switchStmtProgram(
      intLit(7),
      [patternExprCase(noTypeNameWildcard, printExpr(strLit("matched")))],
    );
    const ts = compile(program, { includePreamble: false });
    assert.equal(compileAndRunProgram(program, "pattern_kind_fallback"), "matched");
  });

  test("a pattern_expr with neither typeName nor __pattern_kind__ falls through to the legacy text parser", () => {
    const bareMessageCreation: Expression = {
      messageCreation: { fields: [{ name: "irrelevant", value: intLit(1) }] },
    };
    const caseFields: any[] = [
      { name: "pattern_expr", value: bareMessageCreation },
      { name: "pattern", value: strLit("_") },
      { name: "body", value: printExpr(strLit("fell-through")) },
    ];
    const program = switchStmtProgram(intLit(7), [{ messageCreation: { fields: caseFields } }]);
    assert.equal(compileAndRunProgram(program, "pattern_kind_empty"), "fell-through");
  });
});

describe("compiler — ConstPattern/VarPattern edge cases", () => {
  test("a ConstPattern with no `value` field is an unconditional catch-all", () => {
    const noValueConst: Expression = { messageCreation: { typeName: "ConstPattern", fields: [] } };
    const program = switchStmtProgram(intLit(99), [patternExprCase(noValueConst, printExpr(strLit("any-const")))]);
    assert.equal(compileAndRunProgram(program, "const_no_value"), "any-const");
  });

  test("a VarPattern with a type but no `name` is a typed catch-all with no binding", () => {
    const typedNoName = varPatternExpr(undefined, "int");
    const program = switchStmtProgram(intLit(5), [patternExprCase(typedNoName, printExpr(strLit("typed-no-bind")))]);
    assert.equal(compileAndRunProgram(program, "var_no_name"), "typed-no-bind");
  });
});

describe("compiler — LogicalOrPattern/LogicalAndPattern fall back to the legacy parser when a sub-pattern isn't structured", () => {
  test("LogicalOrPattern with one unstructured-kind operand returns undefined (falls to the cosmetic-text case)", () => {
    const orWithUnknownOperand: Expression = {
      messageCreation: {
        typeName: "LogicalOrPattern",
        fields: [
          { name: "left", value: { messageCreation: { typeName: "ConstPattern", fields: [{ name: "value", value: intLit(1) }] } } },
          { name: "right", value: { messageCreation: { typeName: "SomeUnknownPatternKind", fields: [] } } },
        ],
      },
    };
    const caseFields: any[] = [
      { name: "pattern_expr", value: orWithUnknownOperand },
      { name: "pattern", value: strLit("1") },
      { name: "body", value: printExpr(strLit("matched-one")) },
    ];
    const program = switchStmtProgram(intLit(1), [{ messageCreation: { fields: caseFields } }]);
    assert.equal(compileAndRunProgram(program, "logical_or_fallback"), "matched-one");
  });

  test("LogicalAndPattern with one unstructured-kind operand returns undefined (falls to the cosmetic-text case)", () => {
    const andWithUnknownOperand: Expression = {
      messageCreation: {
        typeName: "LogicalAndPattern",
        fields: [
          { name: "left", value: { messageCreation: { typeName: "ConstPattern", fields: [{ name: "value", value: intLit(2) }] } } },
          { name: "right", value: { messageCreation: { typeName: "SomeUnknownPatternKind", fields: [] } } },
        ],
      },
    };
    const caseFields: any[] = [
      { name: "pattern_expr", value: andWithUnknownOperand },
      { name: "pattern", value: strLit("2") },
      { name: "body", value: printExpr(strLit("matched-two")) },
    ];
    const program = switchStmtProgram(intLit(2), [{ messageCreation: { fields: caseFields } }]);
    assert.equal(compileAndRunProgram(program, "logical_and_fallback"), "matched-two");
  });
});

describe("compiler — CastPattern with no `type` field", () => {
  test("returns the bare sub-pattern result unchanged (no cast assertion)", () => {
    const castNoType: Expression = {
      messageCreation: { typeName: "CastPattern", fields: [{ name: "pattern", value: varPatternExpr("v") }] },
    };
    const program = switchExprProgram(intLit(3), [patternExprCase(castNoType, toStringOf({ reference: { name: "v" } }))]);
    assert.equal(compileAndRunProgram(program, "cast_no_type"), "3");
  });
});

describe("compiler — ListPattern's post-rest-element binding", () => {
  test("`[first, ...rest, last]` binds elements both before AND after a NAMED rest sub-pattern", () => {
    const restWithBinding: Expression = {
      messageCreation: { typeName: "RestPattern", fields: [{ name: "subpattern", value: varPatternExpr("rest") }] },
    };
    const listPattern: Expression = {
      messageCreation: {
        typeName: "ListPattern",
        fields: [
          {
            name: "elements",
            value: {
              literal: {
                listValue: {
                  elements: [varPatternExpr("first"), restWithBinding, varPatternExpr("last")],
                },
              },
            },
          },
        ],
      },
    };
    const body = toStringOf(
      std5("concat", {
        left: std5("concat", {
          left: toStringOf({ reference: { name: "first" } }),
          right: strLit(","),
        }),
        right: std5("concat", {
          left: toStringOf({ reference: { name: "rest" } }),
          right: std5("concat", { left: strLit(","), right: toStringOf({ reference: { name: "last" } }) }),
        }),
      }),
    );
    const program = switchExprProgram(
      { literal: { listValue: { elements: [intLit(1), intLit(2), intLit(3), intLit(4)] } } },
      [patternExprCase(listPattern, body)],
      [{ name: "concat", isBase: true }],
    );
    assert.equal(compileAndRunProgram(program, "list_rest_binding"), "1,[2, 3],4");
  });
});

describe("compiler — RecordPattern's mixed positional+named exact-key-set check", () => {
  test("a record pattern with BOTH a positional and a named sub-pattern binds both", () => {
    const mixedRecordPattern: Expression = {
      messageCreation: {
        typeName: "RecordPattern",
        fields: [
          {
            name: "fields",
            value: {
              literal: {
                listValue: {
                  elements: [
                    { messageCreation: { fields: [{ name: "pattern", value: varPatternExpr("a") }] } },
                    { messageCreation: { fields: [{ name: "name", value: strLit("label") }, { name: "pattern", value: varPatternExpr("n") }] } },
                  ],
                },
              },
            },
          },
        ],
      },
    };
    const body = toStringOf(
      std5("concat", { left: toStringOf({ reference: { name: "a" } }), right: std5("concat", { left: strLit(","), right: { reference: { name: "n" } } }) }),
    );
    const recordValue: Expression = { messageCreation: { fields: [{ name: "arg0", value: intLit(7) }, { name: "label", value: strLit("hi") }] } };
    const program = switchExprProgram(recordValue, [patternExprCase(mixedRecordPattern, body)], [{ name: "concat", isBase: true }, { name: "record", isBase: true }]);
    // Build the record value via the real `record` base function so it
    // matches the compiler's actual record materialization (mixed ->
    // object with "0"/"1"-style positional keys + named keys), rather than
    // a hand-shaped object that happens to look similar.
    const recordCall: Expression = {
      call: {
        module: "std",
        function: "record",
        input: { messageCreation: { fields: [{ name: "$0", value: intLit(7) }, { name: "label", value: strLit("hi") }] } },
      },
    };
    program.modules[1].functions[0].body = {
      block: {
        statements: [
          { let: { name: "rec", value: recordCall } },
          {
            let: {
              name: "result",
              value: {
                call: {
                  module: "std",
                  function: "switch_expr",
                  input: {
                    messageCreation: {
                      fields: [
                        { name: "subject", value: { reference: { name: "rec" } } },
                        { name: "cases", value: { literal: { listValue: { elements: [patternExprCase(mixedRecordPattern, body)] } } } },
                      ],
                    },
                  },
                },
              },
            },
          },
          printOf(toStringOf({ reference: { name: "result" } })),
        ],
      },
    };
    assert.equal(compileAndRunProgram(program, "record_mixed_pattern"), "7,hi");
  });
});

describe("compiler — NullCheckPattern/NullAssertPattern actually exercised", () => {
  test("`var v?` (NullCheckPattern) matches a non-null subject and binds it", () => {
    const nullCheck: Expression = {
      messageCreation: { typeName: "NullCheckPattern", fields: [{ name: "pattern", value: varPatternExpr("v") }] },
    };
    const program = switchExprProgram(intLit(9), [patternExprCase(nullCheck, toStringOf({ reference: { name: "v" } }))]);
    assert.equal(compileAndRunProgram(program, "null_check_pattern"), "9");
  });

  test("`var v!` (NullAssertPattern) also matches a non-null subject and binds it", () => {
    const nullAssert: Expression = {
      messageCreation: { typeName: "NullAssertPattern", fields: [{ name: "pattern", value: varPatternExpr("v") }] },
    };
    const program = switchExprProgram(intLit(11), [patternExprCase(nullAssert, toStringOf({ reference: { name: "v" } }))]);
    assert.equal(compileAndRunProgram(program, "null_assert_pattern"), "11");
  });
});

describe("compiler — a standalone RestPattern used directly as a case's pattern (defensive path)", () => {
  test("delegates entirely to its subpattern when used outside a ListPattern", () => {
    const standaloneRest: Expression = {
      messageCreation: { typeName: "RestPattern", fields: [{ name: "subpattern", value: varPatternExpr("v") }] },
    };
    const program = switchExprProgram(intLit(13), [patternExprCase(standaloneRest, toStringOf({ reference: { name: "v" } }))]);
    assert.equal(compileAndRunProgram(program, "standalone_rest"), "13");
  });
});

describe("compiler — legacy cosmetic-text pattern: true/false/null literals and relational patterns", () => {
  test("switch STATEMENT: `true`/`false`/`null` text patterns match by literal equality", () => {
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "pattern", value: strLit(patternText) }, { name: "body", value: body }] },
    });
    const program = switchStmtProgram(
      { reference: { name: "b" } },
      [
        textCase("true", returnValue(strLit("was-true"))),
        textCase("false", returnValue(strLit("was-false"))),
        textCase("null", returnValue(strLit("was-null"))),
        textCase("_", returnValue(strLit("other"))),
      ],
    );
    (program.modules[0].functions as FunctionDef[]).push({ name: "return", isBase: true });
    // Wrap main's body: classify three values, printing each result.
    program.modules[1].functions = [
      {
        name: "classify",
        body: program.modules[1].functions[0].body,
        metadata: { kind: "function", params: [{ name: "b" }] },
      },
      {
        name: "main",
        body: {
          block: {
            statements: [
              printOf({ call: { function: "classify", input: { literal: { boolValue: true } } } }),
              printOf({ call: { function: "classify", input: { literal: { boolValue: false } } } }),
              printOf({ call: { function: "classify", input: { literal: {} } } }),
            ],
          },
        },
      },
    ];
    assert.equal(compileAndRunProgram(program, "legacy_bool_null_text"), "was-true\nwas-false\nwas-null");
  });

  test("switch EXPRESSION: a relational text pattern (`> 5`) matches numerically", () => {
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "pattern", value: strLit(patternText) }, { name: "body", value: body }] },
    });
    const program = switchExprProgram(intLit(10), [
      textCase("> 5", strLit("big")),
      textCase("_", strLit("small")),
    ]);
    assert.equal(compileAndRunProgram(program, "legacy_relational_text"), "big");
  });
});

describe("compiler — switch_expr's legacy cosmetic-text pattern fallback (no pattern_expr field)", () => {
  test("a switch EXPRESSION with only cosmetic `pattern`/`value` strings dispatches via the text parser", () => {
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "pattern", value: strLit(patternText) }, { name: "body", value: body }] },
    });
    const valueCase = (value: Expression, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "value", value }, { name: "body", value: body }] },
    });
    const program = switchExprProgram(intLit(2), [
      textCase("int n", strLit("int-branch")),
      valueCase(intLit(2), strLit("value-branch")),
      textCase("_", strLit("other")),
    ]);
    // Subject is an int (2), so the FIRST case ("int n", a type-test text
    // pattern with no literal condition) matches first.
    assert.equal(compileAndRunProgram(program, "switch_expr_legacy_text"), "int-branch");
  });

  test("switch EXPRESSION: the `value` field matcher (patText undefined) compiles to a strict-equality condition", () => {
    const valueCase = (value: Expression, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "value", value }, { name: "body", value: body }] },
    });
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "pattern", value: strLit(patternText) }, { name: "body", value: body }] },
    });
    const program = switchExprProgram(intLit(5), [
      valueCase(intLit(5), strLit("matched-by-value")),
      textCase("_", strLit("other")),
    ]);
    assert.equal(compileAndRunProgram(program, "switch_expr_value_field"), "matched-by-value");
  });
});

describe("compiler — switch fallthrough + guard with TEXT-based (non-structured) patterns", () => {
  test("switch STATEMENT: two adjacent empty-body text-pattern cases accumulate into one fallthrough condition", () => {
    const textCase = (patternText: string, body?: Expression): Expression => {
      const fields: any[] = [{ name: "pattern", value: strLit(patternText) }];
      if (body) fields.push({ name: "body", value: body });
      return { messageCreation: { fields } };
    };
    const program = switchStmtProgram(
      { reference: { name: "n" } },
      [
        textCase("1"), // empty body -> accumulates
        textCase("2", returnValue(strLit("one-or-two"))),
        textCase("_", returnValue(strLit("other"))),
      ],
    );
    (program.modules[0].functions as FunctionDef[]).push({ name: "return", isBase: true });
    program.modules[1].functions = [
      { name: "classify", body: program.modules[1].functions[0].body, metadata: { kind: "function", params: [{ name: "n" }] } },
      {
        name: "main",
        body: {
          block: {
            statements: [
              printOf({ call: { function: "classify", input: intLit(1) } }),
              printOf({ call: { function: "classify", input: intLit(2) } }),
              printOf({ call: { function: "classify", input: intLit(3) } }),
            ],
          },
        },
      },
    ];
    assert.equal(compileAndRunProgram(program, "text_fallthrough"), "one-or-two\none-or-two\nother");
  });

  test("switch STATEMENT: a `when` guard on a TEXT pattern with no bindings is ANDed directly (no IIFE)", () => {
    const textCase = (patternText: string, guard: Expression, body: Expression): Expression => ({
      messageCreation: {
        fields: [
          { name: "pattern", value: strLit(patternText) },
          { name: "guard", value: guard },
          { name: "body", value: body },
        ],
      },
    });
    const program = switchStmtProgram(
      { reference: { name: "n" } },
      [
        textCase(
          "1",
          std5("gte", { left: { reference: { name: "flag" } }, right: intLit(1) }),
          returnValue(strLit("one-and-flagged")),
        ),
        { messageCreation: { fields: [{ name: "pattern", value: strLit("_") }, { name: "body", value: returnValue(strLit("other")) }] } },
      ],
    );
    (program.modules[0].functions as FunctionDef[]).push({ name: "return", isBase: true }, { name: "gte", isBase: true });
    program.modules[1].functions = [
      { name: "classify", body: program.modules[1].functions[0].body, metadata: { kind: "function", params: [{ name: "n" }, { name: "flag" }] } },
      {
        name: "main",
        body: {
          block: {
            statements: [
              printOf({
                call: {
                  function: "classify",
                  input: { messageCreation: { fields: [{ name: "arg0", value: intLit(1) }, { name: "arg1", value: intLit(1) }] } },
                },
              }),
              printOf({
                call: {
                  function: "classify",
                  input: { messageCreation: { fields: [{ name: "arg0", value: intLit(1) }, { name: "arg1", value: intLit(0) }] } },
                },
              }),
            ],
          },
        },
      },
    ];
    assert.equal(compileAndRunProgram(program, "text_guard_no_bindings"), "one-and-flagged\nother");
  });
});

describe("compiler — switch_expr's case with NO matcher at all (neither pattern nor value)", () => {
  test("a case carrying only a `body` field (no pattern/value/is_default) is treated as a default", () => {
    const bareBodyCase: Expression = { messageCreation: { fields: [{ name: "body", value: strLit("caught-all") }] } };
    const program = switchExprProgram(intLit(42), [bareBodyCase]);
    assert.equal(compileAndRunProgram(program, "switch_expr_no_matcher"), "caught-all");
  });
});

describe("compiler — patternToTsCondition's final fallback for an unrecognized bare text pattern", () => {
  test("a bare identifier pattern text (not a literal/type-test/map/relational form) compiles to strict equality against it", () => {
    const textCase = (patternText: string, body: Expression): Expression => ({
      messageCreation: { fields: [{ name: "pattern", value: strLit(patternText) }, { name: "body", value: body }] },
    });
    // "someConst" matches none of: "_"/when/||/numeric/true-false-null/
    // quoted-string/type-test/map-pattern/relational -- it falls to the
    // final `(subject === (trimmed))` fallback, treating the bare text as
    // a verbatim JS expression to compare against.
    const program: Program = {
      name: "bare_ident_pattern_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "switch_expr", isBase: true }, { name: "print", isBase: true }, { name: "to_string", isBase: true }] as FunctionDef[] },
        {
          name: "main",
          functions: [
            { name: "someConst", body: { literal: { intValue: 7 } } },
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "result",
                        value: {
                          call: {
                            module: "std",
                            function: "switch_expr",
                            input: {
                              messageCreation: {
                                fields: [
                                  { name: "subject", value: intLit(7) },
                                  {
                                    name: "cases",
                                    value: {
                                      literal: {
                                        listValue: {
                                          elements: [
                                            textCase("someConst()", strLit("matched-bare-ident")),
                                            textCase("_", strLit("other")),
                                          ],
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        },
                      },
                    },
                    printOf(toStringOf({ reference: { name: "result" } })),
                  ],
                },
              },
            },
          ],
        },
      ],
    };
    assert.equal(compileAndRunProgram(program, "bare_ident_pattern"), "matched-bare-ident");
  });
});

describe("compiler — a standalone RestPattern with NO `subpattern` field", () => {
  test("an unnamed rest (no capture) is an unconditional catch-all", () => {
    const bareRest: Expression = { messageCreation: { typeName: "RestPattern", fields: [] } };
    const program = switchExprProgram(intLit(21), [patternExprCase(bareRest, strLit("matched"))]);
    assert.equal(compileAndRunProgram(program, "rest_no_subpattern"), "matched");
  });
});

function std5(fn: string, fields: Record<string, Expression>): Expression {
  return {
    call: {
      module: "std",
      function: fn,
      input: { messageCreation: { fields: Object.entries(fields).map(([name, value]) => ({ name, value })) } },
    },
  };
}
