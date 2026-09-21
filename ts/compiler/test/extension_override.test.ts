/**
 * Extension-override dispatch (issue #670, fixture
 * `478_extension_override_selection`).
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
const FIXTURE = "478_extension_override_selection";

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
});
