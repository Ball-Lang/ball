/**
 * The declared text sink (issue #630): `std.sink_create` / `sink_write` /
 * `sink_to_string`.
 *
 * What was wrong. Ball had no DECLARED sink and three DIFFERENT ad-hoc ones on
 * the TS side alone: `preamble.ts`'s `__ball_to_string` special-cased an Array
 * `__buffer__`, while `ts/engine/src/engine_setup.ts` registered a `write`
 * method handler TWICE with incompatible buffer shapes — one pushing onto an
 * Array, one concatenating onto a String (issue #633). Whichever registration
 * won, the other's read-back path was wrong for the shape in use, and nothing
 * asserted which one that was.
 *
 * These tests pin the declared replacement at both levels: the emitted helper
 * names, and the two properties that fail SILENTLY — `std.type_of` must answer
 * "Sink" (never the host type) and the sink must be reference-semantic across a
 * call boundary. The byte-exact behavioural half is `465_string_sink` in
 * `native_conformance.test.ts`.
 *
 * Run: node --experimental-strip-types --test test/string_sink.test.ts
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

function compileFixture(name: string): string {
  const program: Program = unwrapBallFile(
    JSON.parse(readFileSync(join(conformanceDir, `${name}.ball.json`), "utf8")),
  );
  return compile(program);
}

/** Run `source` plus an appended `probe` snippet, returning stdout. */
function runWithProbe(source: string, probe: string): string {
  const tmpPath = join(tmpdir(), `ball_sink_probe_${process.pid}.ts`);
  writeFileSync(tmpPath, `${source}\n${probe}\n`);
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

describe("compiler — the declared text sink (#630)", () => {
  test("the sink trio compiles to the preamble helpers", () => {
    const ts = compileFixture("465_string_sink");
    for (const want of ["__ball_sink_create(", "__ball_sink_write(", "__ball_sink_to_string("]) {
      assert.ok(ts.includes(want), `emitted TS missing ${want}`);
    }
  });

  test("type_of says Sink and appends survive a call boundary", () => {
    const ts = compileFixture("465_string_sink");
    const probe = [
      "const __probe = __ball_sink_create(null);",
      "__ball_sink_write(__probe, 'a');",
      "((s: any) => __ball_sink_write(s, 'b'))(__probe);",
      "console.log(__ball_type_of(__probe));",
      "console.log(__ball_sink_to_string(__probe));",
    ].join("\n");
    const out = runWithProbe(ts, probe).replace(/\r\n/g, "\n").trimEnd();
    const lines = out.split("\n");
    assert.equal(lines[lines.length - 2], "Sink");
    assert.equal(lines[lines.length - 1], "ab");
  });
});
