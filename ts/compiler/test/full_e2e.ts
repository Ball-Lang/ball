/**
 * Full e2e conformance harness for the TS compiler (Ball IR -> TS -> node),
 * modeled directly on cpp/test/full_e2e.sh's "compile + run EVERY conformance
 * program with an expected_output.txt" approach and per-category failure
 * summary.
 *
 * This is #210's Phase 1 measurement harness: it exists to make the current
 * ts/compiler conformance surface VISIBLE (pass/fail counts + failure
 * categories), not to gate CI yet and not to fix anything. It is
 * DELIBERATELY not named `*.test.ts` so `npm test`'s `test/*.test.ts` glob
 * does not pick it up -- running the full corpus one-process-per-fixture is
 * slow and (until #210 is scoped) not meant to fail the standard test run.
 *
 * Usage: node --experimental-strip-types test/full_e2e.ts
 * Prints "Results: N passed, M failed, T total" (same format
 * conformance-matrix.yml's other engine legs parse) plus category-tagged
 * failure lists (compile errors, node/runtime errors, timeouts, mismatches).
 */
import { readFileSync, writeFileSync, unlinkSync, readdirSync, existsSync } from "node:fs";
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

const files = readdirSync(conformanceDir)
  .filter((f) => f.endsWith(".ball.json"))
  .sort();

let pass = 0, fail = 0, skip = 0;
const compileErr: Array<{ name: string; message: string }> = [];
const runErr: Array<{ name: string; message: string }> = [];
const timeout: string[] = [];
const mismatch: Array<{ name: string; expected: string; actual: string }> = [];

const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();

for (const file of files) {
  const name = file.replace(/\.ball\.json$/, "");
  const expectedPath = join(conformanceDir, `${name}.expected_output.txt`);
  if (!existsSync(expectedPath)) { skip++; continue; }

  let ts: string;
  try {
    const program: Program = unwrapBallFile(JSON.parse(readFileSync(join(conformanceDir, file), "utf8")));
    ts = compile(program);
  } catch (e: any) {
    compileErr.push({ name, message: (e && e.message) || String(e) });
    fail++;
    continue;
  }

  const tmpPath = join(tmpdir(), `ball_full_e2e_${name}_${process.pid}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    let stdout: string;
    try {
      stdout = execSync(`node --experimental-strip-types "${tmpPath}"`, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15_000,
      });
    } catch (e: any) {
      if (e.signal === "SIGTERM" || e.code === "ETIMEDOUT") {
        timeout.push(name);
        fail++;
        continue;
      }
      const stderr = typeof e.stderr === "string" ? e.stderr : (e.stderr?.toString() ?? "");
      const firstLine = stderr.split("\n").find((l: string) => l.trim().length > 0) ?? stderr.slice(0, 200);
      runErr.push({ name, message: firstLine.trim() });
      fail++;
      continue;
    }
    const expected = readFileSync(expectedPath, "utf8");
    if (norm(stdout) === norm(expected)) {
      pass++;
    } else {
      mismatch.push({ name, expected: norm(expected), actual: norm(stdout) });
      fail++;
    }
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

const total = pass + fail;
console.log("==================================================");
console.log(`TS compiler e2e: ${pass}/${total} passed (${fail} failed, ${skip} skipped no-output)`);
console.log("==================================================");
console.log("");
console.log(`Ball->TS compile errors (${compileErr.length}):`);
for (const { name, message } of compileErr) console.log(`  - ${name}: ${message.split("\n")[0]}`);
console.log("");
console.log(`node runtime errors (${runErr.length}):`);
for (const { name, message } of runErr) console.log(`  - ${name}: ${message}`);
console.log("");
console.log(`Timeouts (${timeout.length}): ${timeout.join(", ") || "none"}`);
console.log("");
console.log(`Output mismatches (${mismatch.length}):`);
for (const { name, expected, actual } of mismatch) {
  console.log(`  - ${name}`);
  console.log(`      expected: ${JSON.stringify(expected).slice(0, 150)}`);
  console.log(`      actual:   ${JSON.stringify(actual).slice(0, 150)}`);
}
console.log("");
// Standard format line for CI conformance-matrix parsing (matches the C++
// Compiled leg's "Results: N passed, M failed, T total").
console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);

if (fail > 0) process.exitCode = 1;
