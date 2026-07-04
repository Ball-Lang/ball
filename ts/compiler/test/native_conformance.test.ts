/**
 * Native-path conformance spot checks.
 *
 * Compiles curated fixtures from `tests/conformance/` to native TypeScript
 * via the TS compiler and executes them with Node, diffing stdout against
 * the fixture's `.expected_output.txt`. These fixtures pin compiler bugs
 * that the interpreted (compiled-engine) conformance path cannot catch:
 *
 *   - 109_enum_values: the Dart encoder emits enums BOTH as a typeDef
 *     (metadata.kind == "enum") and as `Module.enums[]`; now that the
 *     compiler materializes `Module.enums[]` (#120) this pins the
 *     no-duplicate-declaration guard and the end-to-end enum semantics
 *     (index/values/switch) on the native path.
 *   - 229_closure_loop_var_semantics / 312_collection_for_capture: C-style
 *     for/comprehension headers emitted `var`, so closures created in the
 *     loop body shared one binding instead of Dart's per-iteration
 *     bindings (#69).
 *   - 113_operator_overloading: preamble.ts's `__ball_add`/`__ball_sub`/
 *     `__ball_mul`/`__ball_eq` looked up `a.__op_mul` (no trailing double
 *     underscore) but the encoder's canonical operator names always end in
 *     `__op_mul__` — the names never matched, so overloaded operators
 *     silently fell through to raw JS arithmetic (#205).
 *   - 394_mappattern_excludes_set / 258_logical_and_pattern: `MapPattern`
 *     and `LogicalAndPattern` (and the `RelationalPattern`/`ObjectPattern`
 *     kinds the audit turned up) were missing from
 *     `compiler.ts`'s `KNOWN_PATTERN_KINDS`, so they fell to the legacy
 *     text-pattern parser, which embedded literal Dart syntax (e.g. `final
 *     items`) into the emitted TS and crashed with
 *     `ERR_INVALID_TYPESCRIPT_SYNTAX` (#206, #207).
 *
 * Run: node --experimental-strip-types --test test/native_conformance.test.ts
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

const NATIVE_FIXTURES = [
  "109_enum_values",
  "223_closure_loop_capture",
  "229_closure_loop_var_semantics",
  "312_collection_for_capture",
  "113_operator_overloading",
  "394_mappattern_excludes_set",
  "258_logical_and_pattern",
];

describe("compiler — native conformance spot checks", () => {
  for (const name of NATIVE_FIXTURES) {
    test(`native fixture — ${name}`, () => {
      const program: Program = unwrapBallFile(
        JSON.parse(readFileSync(join(conformanceDir, `${name}.ball.json`), "utf8")),
      );
      const ts = compile(program);
      const tmpPath = join(tmpdir(), `ball_native_${name}_${process.pid}.ts`);
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
