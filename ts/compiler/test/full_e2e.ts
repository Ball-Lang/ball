/**
 * Full e2e conformance harness for the TS compiler (Ball IR -> TS -> node),
 * modeled directly on cpp/test/full_e2e.sh's "compile + run EVERY conformance
 * program with an expected_output.txt" approach, category-tagged failure
 * summary, and named carve-out list for known, tracked gaps.
 *
 * This is #210's blocking conformance leg: every fixture in
 * tests/conformance/ is compiled through the TS compiler (Ball IR -> native
 * TS source) and executed with node, diffing stdout against the golden
 * output. A fixture in CARVE_OUTS is a KNOWN gap (each entry references a
 * filed issue) and is expected to keep failing -- but unlike
 * cpp/test/full_e2e.sh (which SKIPS carve-outs before even running them),
 * every carved-out fixture here is still actually run: if one starts
 * PASSING, that's a stale carve-out and the leg fails loudly so the entry
 * gets removed (Ball is real-value semantics; a bug fix should never go
 * unnoticed because a stale carve-out entry silently keeps ignoring it).
 *
 * Gate: fails if ANY non-carved fixture fails (a regression) OR any
 * carved-out fixture unexpectedly passes (a stale carve-out). Deliberately
 * not named `*.test.ts` so `npm test`'s `test/*.test.ts` glob does not pick
 * it up -- this spawns one node process per fixture (slow) and is meant to
 * be invoked directly, not as part of the fast unit-test loop.
 *
 * Usage: node --experimental-strip-types test/full_e2e.ts
 * Prints "Results: N passed, M failed, T total" (same format
 * conformance-matrix.yml's other engine legs parse; N/M/T exclude carved-out
 * fixtures, matching the C++ Compiled leg's convention of excluding its
 * carve-outs from the total).
 */
import { readFileSync, writeFileSync, unlinkSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";
import { unwrapBallFile } from "./ball_file.ts";

/**
 * Known, tracked ts/compiler conformance gaps, one entry per fixture, each
 * pointing at the issue that tracks it. Delete an entry the moment the
 * compiler supports it -- a fixture that starts passing while still listed
 * here fails the leg (see the "stale carve-out" check below).
 */
const CARVE_OUTS: Record<string, number> = {
  // #218 -- map_keys/map_values/.values silently return empty instead of
  // failing loud on non-Map (TS analog of #197/#202).
  "395_map_keys_values_fail_loud": 218,
  "397_map_values": 218,
  // #219 -- Set literal/operation codegen produces empty {} and wrong
  // equality results.
  "350_set_value": 219,
  "392_empty_set_literal": 219,
  // #220 -- inherited field / implicit-ctor initializers drop to null
  // (TS analog of #183/#187/#198).
  "345_inherited_field_type_name_collision": 220,
  "355_inherited_field_initializer": 220,
  // #221 -- double.toStringAsFixed loses negative zero.
  "316_to_string_as_fixed": 221,
  // #222 -- whole doubles print without trailing .0 in some contexts.
  "321_whole_double_parse_print": 222,
  // #223 -- unsigned right shift (>>>) uses raw 32-bit JS semantics.
  "381_unsigned_right_shift": 223,
  // #224 -- type-literal-as-value compiles to null.
  "340_type_literal": 224,
  // #225 -- uninitialized-variable sentinel (__no_init__) leaks into output.
  "315_compound_assign_all_ops": 225,
  // #226 -- list_reduce and label (goto) have no codegen (bare unresolved
  // calls -- ReferenceError, not just wrong output).
  "318_list_reduce": 226,
  "390_goto_label": 226,
  // #227 -- numeric-literal property/getter access emits invalid TS
  // (e.g. `0.isNegative`).
  "317_primitive_number_getters": 227,
  // #228 -- BallDouble is missing .remainder() (Number.prototype has it,
  // the wrapper class doesn't).
  "320_num_methods_on_double_local": 228,
};

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

type Outcome =
  | { kind: "pass" }
  | { kind: "compile_error"; message: string }
  | { kind: "run_error"; message: string }
  | { kind: "timeout" }
  | { kind: "mismatch"; expected: string; actual: string };

const results: Array<{ name: string; outcome: Outcome }> = [];
let skip = 0;

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
    results.push({ name, outcome: { kind: "compile_error", message: (e && e.message) || String(e) } });
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
        results.push({ name, outcome: { kind: "timeout" } });
        continue;
      }
      const stderr = typeof e.stderr === "string" ? e.stderr : (e.stderr?.toString() ?? "");
      const firstLine = stderr.split("\n").find((l: string) => l.trim().length > 0) ?? stderr.slice(0, 200);
      results.push({ name, outcome: { kind: "run_error", message: firstLine.trim() } });
      continue;
    }
    const expected = readFileSync(expectedPath, "utf8");
    if (norm(stdout) === norm(expected)) {
      results.push({ name, outcome: { kind: "pass" } });
    } else {
      results.push({ name, outcome: { kind: "mismatch", expected: norm(expected), actual: norm(stdout) } });
    }
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

// Partition: real (non-carved) pass/fail drive the gate and the "Results"
// line; carved-out fixtures are reported separately (still failing as
// expected, or stale -- now passing).
const realPass = results.filter((r) => r.outcome.kind === "pass" && !(r.name in CARVE_OUTS));
const realFail = results.filter((r) => r.outcome.kind !== "pass" && !(r.name in CARVE_OUTS));
const carvedStillFailing = results.filter((r) => r.outcome.kind !== "pass" && r.name in CARVE_OUTS);
const carvedNowPassing = results.filter((r) => r.outcome.kind === "pass" && r.name in CARVE_OUTS);

const pass = realPass.length;
const fail = realFail.length;
const total = pass + fail;

function describe(outcome: Outcome): string {
  switch (outcome.kind) {
    case "compile_error": return `COMPILE ERROR: ${outcome.message.split("\n")[0]}`;
    case "run_error": return `RUNTIME ERROR: ${outcome.message}`;
    case "timeout": return "TIMEOUT";
    case "mismatch":
      return `MISMATCH\n      expected: ${JSON.stringify(outcome.expected).slice(0, 150)}\n      actual:   ${JSON.stringify(outcome.actual).slice(0, 150)}`;
    case "pass": return "pass";
  }
}

console.log("==================================================");
console.log(`TS compiler e2e: ${pass}/${total} passed (${fail} failed, ${skip} skipped no-output, ${Object.keys(CARVE_OUTS).length} carve-outs)`);
console.log("==================================================");
console.log("");

console.log(`Carve-outs (${Object.keys(CARVE_OUTS).length}, tracked gaps -- each references a filed issue):`);
for (const [name, issue] of Object.entries(CARVE_OUTS)) console.log(`  - ${name} (#${issue})`);
console.log("");

console.log(`Carved-outs still failing as expected (${carvedStillFailing.length}):`);
for (const { name, outcome } of carvedStillFailing) console.log(`  - ${name} [#${CARVE_OUTS[name]}]: ${describe(outcome)}`);
console.log("");

if (carvedNowPassing.length > 0) {
  console.log(`!!! STALE CARVE-OUTS now passing (${carvedNowPassing.length}) -- remove from CARVE_OUTS: !!!`);
  for (const { name } of carvedNowPassing) console.log(`  - ${name} [#${CARVE_OUTS[name]}]`);
  console.log("");
}

console.log(`Regressions -- non-carved-out failures (${realFail.length}):`);
for (const { name, outcome } of realFail) console.log(`  - ${name}: ${describe(outcome)}`);
console.log("");

// Standard format line for CI conformance-matrix parsing (matches the C++
// Compiled leg's "Results: N passed, M failed, T total" -- N/M/T exclude
// carve-outs, same as the C++ leg excludes its own).
console.log(`Results: ${pass} passed, ${fail} failed, ${total} total`);

if (realFail.length > 0 || carvedNowPassing.length > 0) process.exitCode = 1;
