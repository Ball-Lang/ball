/**
 * Full-parity stress test — run every fixture under
 * `tests/fixtures/dart/_generated/` through the TS-native compiler,
 * execute via `node --experimental-strip-types`, and diff stdout
 * against the fixture's `.expected_output.txt`.
 *
 * Target: 37/37 byte-identical, matching the Dart-side compiler.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
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

const root = findRepoRoot();
const fixturesDir = resolve(root, "tests/fixtures/dart/_generated");
const files = readdirSync(fixturesDir)
  .filter((f) => f.endsWith(".ball.json"))
  .sort();

for (const file of files) {
  const name = file.replace(/\.ball\.json$/, "");
  test(`fixture — ${name}`, () => {
    const program: Program = JSON.parse(
      readFileSync(join(fixturesDir, file), "utf8"),
    );
    const ts = compile(program);
    const tmpPath = join(tmpdir(), `ball_fixture_${name}_${process.pid}.ts`);
    writeFileSync(tmpPath, ts);
    try {
      let stdout: string;
      try {
        stdout = execSync(
          `node --experimental-strip-types ${tmpPath}`,
          { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
        );
      } catch (e: any) {
        throw new Error(
          `Node failed for ${name}:\nstderr:\n${e.stderr}\n\nFirst 100 lines of TS:\n${ts.split("\n").slice(0, 100).join("\n")}`,
        );
      }
      const expectedPath = join(fixturesDir, `${name}.expected_output.txt`);
      if (existsSync(expectedPath)) {
        const expected = readFileSync(expectedPath, "utf8");
        const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
        assert.equal(
          norm(stdout),
          norm(expected),
          `Stdout mismatch for ${name}`,
        );
      }
    } finally {
      try { unlinkSync(tmpPath); } catch {}
    }
  });
}
