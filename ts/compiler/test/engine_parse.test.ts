/**
 * Engine.dart parse milestone — compile the Ball-encoded form of the
 * Dart reference interpreter (~3000 LOC) and verify Node loads the
 * output via `--experimental-strip-types`.
 *
 * This regression-gates the self-host milestone previously held by the
 * Dart-side engine_compile_test.dart.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";

function findRepoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    if (existsSync(join(dir, "proto", "ball", "v1", "ball.proto"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) throw new Error("repo root not found");
    dir = parent;
  }
}

test(
  "engine.dart compiles to TS that Node parses",
  { timeout: 120_000 },
  () => {
    const root = findRepoRoot();
    const ballJsonPath = resolve(root, "dart/self_host/engine.ball.json");
    if (!existsSync(ballJsonPath)) {
      // The test regenerates this file on demand — call the Dart tool.
      execSync(
        `dart run dart/encoder/tool/roundtrip_engine.dart --skip-analyze --save-program ${ballJsonPath}`,
        { cwd: root, stdio: "pipe" },
      );
    }
    const program: Program = JSON.parse(readFileSync(ballJsonPath, "utf8"));
    const ts = compile(program);
    assert.ok(
      ts.length > 50 * 1024,
      "emitted TS should be >50 KB for engine.dart",
    );
    assert.ok(ts.includes("export class BallEngine"));
    assert.ok(ts.includes("export type BallValue"));
    assert.ok(ts.includes("async "));

    // Smoke-load via Node.
    const tmpDir = tmpdir();
    const enginePath = join(tmpDir, `ball_engine_rt_${process.pid}.ts`);
    const smokePath = join(tmpDir, `ball_engine_smoke_${process.pid}.ts`);
    writeFileSync(enginePath, ts);
    writeFileSync(
      smokePath,
      `import "${pathToFileURL(enginePath).href}";\nconsole.log("engine_rt loaded OK");\n`,
    );
    try {
      const out = execSync(
        `node --experimental-strip-types ${smokePath}`,
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      );
      assert.match(out, /engine_rt loaded OK/);
    } catch (e: any) {
      throw new Error(
        `Node failed to load engine_rt:\nstderr:\n${e.stderr}`,
      );
    } finally {
      try { unlinkSync(enginePath); } catch {}
      try { unlinkSync(smokePath); } catch {}
    }
  },
);
