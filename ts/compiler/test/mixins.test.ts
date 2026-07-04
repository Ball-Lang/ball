/**
 * Compiler tests for class mixin resolution (`compiler.ts` ~lines 210-238)
 * and the entry-module-not-found error path (~lines 118-122).
 *
 * Mixin resolution: a class typeDef may declare `metadata.mixins: string[]`
 * (short mixin type names). The compiler must pull each mixin's own methods
 * into the class's member list UNLESS the class already defines a method of
 * the same short name (an explicit override always wins over the mixin).
 *
 * This mirrors the real encoder output for `class Document with Printable,
 * Serializable` (see `tests/conformance/110_mixin.ball.json`), which was
 * previously never exercised through the native TS-codegen path (only via
 * the interpreted-engine conformance corpus) — a completely untested
 * real feature until this file.
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

const root = findRepoRoot();
const conformanceDir = resolve(root, "tests/conformance");

describe("compiler — entry module not found", () => {
  test("throws when Program.entryModule doesn't match any module name", () => {
    const program: Program = {
      name: "broken",
      entryModule: "nonexistent",
      entryFunction: "main",
      modules: [
        { name: "main", functions: [{ name: "main", body: { literal: { intValue: 1 } } }] },
      ],
    };
    assert.throws(
      () => compile(program),
      /Entry module "nonexistent" not found/,
    );
  });
});

describe("compiler — class mixins (real fixture, tests/conformance/110_mixin.ball.json)", () => {
  test("resolves mixin methods end-to-end: byte-identical stdout via native codegen", () => {
    const program: Program = unwrapBallFile(
      JSON.parse(readFileSync(join(conformanceDir, "110_mixin.ball.json"), "utf8")),
    );
    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_mixin_${process.pid}.ts`);
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
      const expected = readFileSync(
        join(conformanceDir, "110_mixin.expected_output.txt"),
        "utf8",
      );
      const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
      assert.equal(norm(stdout), norm(expected));
    } finally {
      try { unlinkSync(tmpPath); } catch { /* ignore */ }
    }
  });

  test("a class's own method overrides a mixin method of the same short name", () => {
    // Document defines its own `label`, which must win over Printable's
    // `label` (not be duplicated / shadowed by the mixin's version).
    const program: Program = unwrapBallFile(
      JSON.parse(readFileSync(join(conformanceDir, "110_mixin.ball.json"), "utf8")),
    );
    const ts = compile(program, { includePreamble: false });
    // Only ONE `label(` method should be emitted on Document — the mixin's
    // copy must be excluded because the class already defines its own.
    const classMatch = /class Document[\s\S]*?\n\}/.exec(ts);
    assert.ok(classMatch, "Document class body found");
    const labelMatches = classMatch![0].match(/\blabel\s*\(/g) ?? [];
    assert.equal(labelMatches.length, 1, "label() must appear exactly once (own override wins)");
    // Serializable's serialize() must still be pulled in (not overridden).
    assert.match(classMatch![0], /serialize\s*\(/);
  });

  test("an unresolvable mixin name is skipped without throwing", () => {
    const program: Program = {
      name: "p",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          functions: [
            { name: "main", body: { literal: { intValue: 0 } } },
            {
              name: "main:Widget.new",
              metadata: { kind: "constructor", params: [] },
            },
          ],
          typeDefs: [
            {
              name: "main:Widget",
              metadata: { kind: "class", mixins: ["DoesNotExist"] },
            },
          ],
        },
      ],
    };
    // Should not throw even though "DoesNotExist" resolves to no typeDef.
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /class Widget/);
  });
});
