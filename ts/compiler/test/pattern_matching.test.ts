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
import type { Expression, FunctionDef, Program } from "../src/index.ts";
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
