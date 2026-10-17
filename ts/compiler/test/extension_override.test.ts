/**
 * Extension-override dispatch (issue #670, fixture
 * `480_extension_override_selection`).
 *
 * `Ext(receiver).member` is encoded as a call NAMING the extension's own member
 * (`<module>:<Ext>.<member>`) with the receiver in `self`, because the
 * selection is the whole meaning of the node: two extensions can declare the
 * SAME member on the SAME type, and the plain `receiver.member` emission
 * resolves by ordinary lookup — a DIFFERENT member.
 *
 * TypeScript has no extensions, so this compiler emits each extension as a
 * class and its members as methods. The call used to sanitize the qualified
 * name into a MEMBER name and emit `xs.AlphaTag_tag()` — a method no array
 * has, so the compiled program threw at the first override. The member is
 * reached on the class PROTOTYPE with the receiver as `this` instead:
 * `Reflect.get` for a getter (it invokes the accessor with the receiver as
 * `this`), `.call` for a method.
 *
 * Run: node --experimental-strip-types --test test/extension_override.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";
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

const conformanceDir = resolve(findRepoRoot(), "tests/conformance");
const FIXTURE = "480_extension_override_selection";

function compileFixture(name: string): string {
  const program: Program = unwrapBallFile(
    JSON.parse(readFileSync(join(conformanceDir, `${name}.ball.json`), "utf8")),
  );
  return compile(program);
}

function runSource(source: string): string {
  const tmpPath = join(tmpdir(), `ball_ext_override_${process.pid}.ts`);
  writeFileSync(tmpPath, source);
  try {
    return execSync(`node --experimental-strip-types "${tmpPath}"`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e: any) {
    throw new Error(`Node failed:\nstderr:\n${e.stderr}`);
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

describe("compiler — extension-override dispatch (#670)", () => {
  test("each override reaches its own extension's member", () => {
    const ts = compileFixture(FIXTURE);
    for (const want of [
      "(AlphaTag.prototype as any).tag.call(",
      "(BetaTag.prototype as any).tag.call(",
      "Reflect.get(AlphaTag.prototype, 'label',",
      "Reflect.get(BetaTag.prototype, 'label',",
      "(AlphaTag.prototype as any).scale.call(",
      "(BetaTag.prototype as any).scale.call(",
    ]) {
      assert.ok(ts.includes(want), `emitted TS missing ${want}\n---\n${ts}`);
    }
    // The old shape asked the RECEIVER for a member named after the extension,
    // which cannot exist on an array.
    assert.ok(
      !/\.AlphaTag_tag\(|\.BetaTag_tag\(/.test(ts),
      "an override still resolves a member name on the receiver",
    );
  });

  test("the compiled program selects the extension the source named", () => {
    const golden = readFileSync(
      join(conformanceDir, `${FIXTURE}.expected_output.txt`),
    )
      .toString("utf8")
      .replace(/\r\n/g, "\n");
    const got = runSource(compileFixture(FIXTURE)).replace(/\r\n/g, "\n");
    assert.equal(got, golden);
  });

  // ─── A READ through an override of a BOTH-getter-AND-setter member ───
  //
  // Hand-built IR, not a fixture: `480_extension_override_selection`
  // deliberately carries no setter arm (#865), so this shape — valid Dart,
  // just excluded from the cross-target corpus — is unreachable from the
  // committed fixture set. The getter and setter share the qualified name
  // `main:AlphaTag.slot`, and the call site reaches them exactly as a
  // parsed `Ext(x).m` read does: a call whose packed input carries an
  // explicit `self` field. (PR #829 review.)
  function getterAndSetterOverrideProgram(): Program {
    const getter = {
      name: "main:AlphaTag.slot",
      outputType: "String",
      body: { literal: { stringValue: "GETTER" } },
      metadata: { kind: "method", is_getter: true, expression_body: true },
    };
    const setter = {
      name: "main:AlphaTag.slot",
      inputType: "int",
      outputType: "void",
      body: { literal: { stringValue: "SETTER" } },
      metadata: { kind: "method", is_setter: true, expression_body: true },
    };
    const overrideCall = {
      call: {
        module: "main",
        function: "main:AlphaTag.slot",
        input: {
          messageCreation: {
            fields: [
              {
                name: "self",
                value: {
                  literal: {
                    listValue: {
                      elements: [
                        { literal: { intValue: "1" } },
                        { literal: { intValue: "2" } },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      },
    };
    const mainFn = {
      name: "main",
      metadata: { kind: "function" },
      body: {
        block: {
          statements: [
            {
              expression: {
                call: {
                  module: "std",
                  function: "print",
                  input: {
                    messageCreation: {
                      fields: [{ name: "message", value: overrideCall }],
                    },
                  },
                },
              },
            },
          ],
        },
      },
    };
    return unwrapBallFile({
      name: "test",
      version: "1.0.0",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        { name: "std", functions: [{ name: "print", isBase: true }] },
        {
          name: "main",
          typeDefs: [
            { name: "main:AlphaTag", metadata: { kind: "extension", on: "List<int>" } },
          ],
          functions: [getter, setter, mainFn],
        },
      ],
    }) as Program;
  }

  test("a read through an override with both a getter and a setter dispatches the getter", () => {
    // Before the fix, `extensionMembers` was filled in one pass with no
    // getter/setter precedence: the getter and setter share the Ball
    // function name, so whichever member the loop visited LAST won the map
    // slot. The setter is collected after the getter in every real
    // extension (`get` syntactically precedes `set`), so a plain read
    // compiled to `(AlphaTag.prototype as any).slot.call(xs)` — invoking
    // the SETTER accessor's VALUE as a function, which is not callable.
    const got = runSource(compile(getterAndSetterOverrideProgram())).replace(/\r\n/g, "\n");
    assert.equal(got, "GETTER\n");
  });

  test("the setter still compiles — the getter winning the read is not at the setter's expense", () => {
    const ts = compile(getterAndSetterOverrideProgram());
    assert.ok(/\bget\s+slot\s*\(/.test(ts), `emitted TS has no getter accessor\n---\n${ts}`);
    assert.ok(/\bset\s+slot\s*\(/.test(ts), `emitted TS has no setter accessor\n---\n${ts}`);
  });
});
