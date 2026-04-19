/**
 * Phase 2.9a smoke test — the TS-native compiler can read a Ball
 * program and emit runnable TypeScript.
 *
 * Uses Node's built-in `node:test` runner (no jest/vitest). Run via:
 *   node --experimental-strip-types --test test/*.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { BallCompiler, compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";

function findRepoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  while (true) {
    if (existsSync(join(dir, "proto", "ball", "v1", "ball.proto"))) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) throw new Error("repo root not found");
    dir = parent;
  }
}

function loadFixture(name: string): Program {
  const root = findRepoRoot();
  const path = resolve(root, "tests/fixtures/dart/_generated", `${name}.ball.json`);
  const json = JSON.parse(readFileSync(path, "utf8")) as Program;
  return json;
}

test("hello_world — compiles and runs", () => {
  const program = loadFixture("01_hello");
  const ts = compile(program);
  assert.ok(ts.includes("function main()"), "must have main()");
  assert.ok(ts.includes("main();"), "must call main at end");
  assert.ok(ts.includes("console.log"), "must emit console.log for print");

  const tmpPath = join(tmpdir(), `ball_hello_${process.pid}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    const out = execSync(
      `node --experimental-strip-types ${tmpPath}`,
      { encoding: "utf8" },
    );
    assert.equal(out.trim(), "hello");
  } finally {
    unlinkSync(tmpPath);
  }
});

test("compile() returns string; BallCompiler.compile() also works", () => {
  const program = loadFixture("01_hello");
  const a = compile(program);
  const b = new BallCompiler(program).compile();
  assert.equal(a, b);
});

test("includePreamble: false omits the runtime block", () => {
  const program = loadFixture("01_hello");
  const withPre = compile(program, { includePreamble: true });
  const bare = compile(program, { includePreamble: false });
  assert.ok(
    withPre.includes("Ball runtime preamble"),
    "preamble marker present when requested",
  );
  assert.ok(
    !bare.includes("Ball runtime preamble"),
    "preamble marker absent when disabled",
  );
  // Compiled body still references runtime helpers — consumers without
  // the preamble are expected to provide their own (e.g. the ts/engine
  // package provides equivalents).
  assert.ok(bare.includes("main();"));
});
