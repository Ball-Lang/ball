#!/usr/bin/env node --experimental-strip-types
/**
 * Self-test for the TypeScript Tier A coverage-study harness (issues #493, #536).
 *
 * A new measuring instrument must not inherit the blind spot it exists to
 * close. The gap #493 documents is that every existing gate is scoped to the
 * project's own single-file, entry-point-shaped conformance fixtures, so real
 * library code — no `main`, declarations split across files — was never looked
 * at. The cheapest way for this harness to inherit that blind spot would be to
 * SKIP such files and then report a flattering number over whatever is left.
 *
 * For TypeScript there is a second, sharper way to inherit it. Until #536 the
 * compiler had no library mode at all: `compile()` appends a zero-arg `main();`
 * to any declaration that happens to share the encoder's default entry name
 * (`"main"`), whatever its real arity, and `compileModule()` is scoped to the
 * ball_protobuf facade. A harness built on either would either crash on, or
 * silently mis-handle, exactly the files it is supposed to measure. Assertion
 * "an entry-point-named library declaration is scored" below is the guard.
 *
 * WHAT THIS DOES AND DOES NOT PROVE. These assertions validate the HARNESS.
 * They are not regression tests for any encoder/compiler defect: the Tier A run
 * itself is report-only (`coverage-study.yml` has no `pull_request:` trigger),
 * and a TypeScript-pipeline regression it measures would not redden this or any
 * other PR.
 *
 * The Dart original (`rq1_study_self_test.dart`) can assert "a plain file is
 * reported clean" because the Dart round trip is closed. The TypeScript round
 * trip is NOT closed: the compiler re-emits its own `const input = <param>;`
 * alias on every generation, so a second-generation recompile of even a
 * one-line function drifts. There is therefore no TypeScript source this
 * harness can honestly promise stays clean, and asserting one would mean
 * weakening the harness until something passed. The assertions below assert the
 * *funnel* instead — the strongest statement that is true today — and they
 * strengthen by themselves the moment the round trip closes.
 *
 * TEST-ONLY EXCLUSION (the owner's 2026-09-14 methodology decision on #491).
 * Tier A scores the LIBRARY code a user would encode; a package's own test
 * suite is a different population and is out of the denominator. The rule must
 * be EXPLICIT, self-tested and COUNTED in the run summary — a silent filter is
 * how a denominator shrinks without anyone noticing, and this harness already
 * had exactly such a filter (`*.test.ts`/`*.spec.ts`/`*.bench.ts` and the
 * `test`/`tests`/`__tests__` directories were dropped with no count printed
 * anywhere). `checkTestOnlyExclusion` pins both directions: every test-only
 * shape is excluded *with the rule that excluded it*, and every library file
 * whose NAME merely contains "test" (`latest.ts`, `contest.ts`,
 * `attestation/`) is still scored. A sloppy substring rule passes the first
 * half and fails the second, which is the point.
 *
 * Run from the repo root:
 *     node --experimental-strip-types tools/coverage-study/test/rq1_study_ts_self_test.mts
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";

import {
  classifyTypescriptFiles,
  declarationInventory,
  renderReport,
  stageReached,
  studyDirectory,
  studyFile,
  syntaxErrors,
} from "../rq1_study_ts.mts";

let passed = 0;
let failed = 0;

function check(name: string, ok: boolean, detail = ""): void {
  if (ok) {
    passed++;
    console.log(`PASS  ${name}`);
  } else {
    failed++;
    console.log(`FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

/**
 * `stageReached` with an unknown tag reported as -1 rather than thrown, so one
 * broken verdict fails its own assertion instead of aborting the run.
 */
function safeStage(reason: string): number {
  try {
    return stageReached(reason);
  } catch {
    return -1;
  }
}

// `helper.ts` — a plain helper library. No `main`, no entry point, nothing
// exotic: exactly the shape every gate before #493 never looked at.
const HELPER = `export function twice(value: number): number {
  return value * 2;
}
`;

// `consumer.ts` — calls into the sibling file, so it cannot be understood in
// isolation, and still has no entry point.
const CONSUMER = `import { twice } from "./helper";

export function doubled(value: number): number {
  return twice(value);
}

export function combine(a: number, b: number): number {
  return a + b;
}
`;

// A construct the encoder explicitly rejects ("Unhandled expression kind:
// YieldExpression"). The negative control: it must be REPORTED with its own
// taxonomy tag and must stop strictly earlier in the funnel than the plain
// file, so the harness cannot pass by painting every file with one reason.
const UNSUPPORTED = `export function* counter(limit: number) {
  for (let i = 0; i < limit; i++) {
    yield i;
  }
}
`;

// The #536 shape: a library file whose only declaration is called `main` and
// takes a real argument. `@ball-lang/encoder` stamps `entryFunction: "main"` on
// every file it encodes, so a harness built on `compile()` would append a
// zero-arg `main();` here and measure something the source never said.
const ENTRY_NAMED = `export function main(argv: string[]): number {
  return argv.length;
}
`;

// Library files whose NAME merely contains "test" as a substring ("la-test",
// "con-test", "at-test-ation"). The negative control for the test-only
// exclusion: a rule that excluded any of them would be excluding LIBRARY code,
// so this self-test must go red on it rather than quietly shrink the
// denominator.
const LIBRARY_LOOKALIKES = ["latest.ts", "contest.ts", "attestation/verify.ts"];

// TypeScript's own convention, per the owner decision on #491: `*.test.ts`,
// `*.spec.ts`, `*.bench.ts`, and anything under `__tests__`/`test`/`tests`.
const TEST_ONLY = [
  "core.test.ts",
  "core.spec.ts",
  "core.bench.ts",
  "__tests__/more.ts",
  "test/support.ts",
  "tests/legacy.ts",
];

function write(root: string, rel: string, source: string): void {
  const full = path.join(root, rel);
  mkdirSync(path.dirname(full), { recursive: true });
  writeFileSync(full, source, "utf8");
}

/**
 * Tier A scores library code; a package's own tests are excluded, COUNTED and
 * named — never silently dropped (the owner's 2026-09-14 decision on #491).
 */
function checkTestOnlyExclusion(): void {
  const root = mkdtempSync(path.join(tmpdir(), "rq1_ts_exclusion"));
  try {
    const library = ["core.ts", ...LIBRARY_LOOKALIKES];
    for (const rel of library) write(root, rel, "export const value = 1;\n");
    for (const rel of TEST_ONLY) write(root, rel, "export const check = 1;\n");

    const scan = classifyTypescriptFiles("synthetic", root);
    const studied = new Set(
      scan.studied.map((f) => path.relative(root, f).split(path.sep).join("/")),
    );
    const excluded = new Set(scan.excluded.map((e) => e.file));

    check(
      'a library file whose name merely contains "test" is still studied',
      studied.size === library.length && library.every((rel) => studied.has(rel)),
      `studied ${JSON.stringify([...studied].sort())}`,
    );
    check(
      "every test-only file is excluded",
      excluded.size === TEST_ONLY.length && TEST_ONLY.every((rel) => excluded.has(rel)),
      `excluded ${JSON.stringify([...excluded].sort())}`,
    );
    check(
      "every exclusion names the rule that made it",
      scan.excluded.length > 0 && scan.excluded.every((e) => e.rule.length > 0),
      `rules ${JSON.stringify([...new Set(scan.excluded.map((e) => e.rule))].sort())}`,
    );

    const results = studyDirectory("synthetic", root);
    check(
      "an excluded file never reaches the scored results",
      results.every((r) => !TEST_ONLY.includes(r.file)),
      `results ${JSON.stringify(results.map((r) => r.file))}`,
    );

    const out: string[] = [];
    renderReport(out, results, scan.excluded, []);
    check(
      "the summary prints the exclusion count, so nothing disappears silently",
      out.join("").includes(`  excluded (test-only): ${TEST_ONLY.length}\n`),
      `summary was:\n${out.join("")}`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }

  // A run that excluded nothing still prints the line: a MISSING line is
  // indistinguishable from a rule that vanished, and summarize.sh fails on it.
  const zero: string[] = [];
  renderReport(zero, [studyFile("synthetic", "helper.ts", HELPER)], [], []);
  check(
    "the exclusion count is printed even when it is zero",
    zero.join("").includes("  excluded (test-only): 0\n"),
    `summary was:\n${zero.join("")}`,
  );
}

function main(): number {
  checkTestOnlyExclusion();

  const root = mkdtempSync(path.join(tmpdir(), "rq1_ts_self_test"));
  let plainStage = -1;
  try {
    writeFileSync(path.join(root, "helper.ts"), HELPER, "utf8");
    writeFileSync(path.join(root, "consumer.ts"), CONSUMER, "utf8");

    const results = studyDirectory("synthetic", root);

    // 1 — the whole point of #493: entry-point-less files are SCORED.
    check(
      "both files of an entry-point-less package are scored, none skipped",
      results.length === 2 && results.every((r) => r.scored),
      `got ${results.map((r) => `${r.file}(scored=${r.scored})`).join(", ")}`,
    );

    // 2 — the harness's own positive floor: a run that scores nothing proves
    // nothing, so the synthetic package must produce a denominator.
    check(
      "the scored denominator is >= 1",
      results.filter((r) => r.scored).length >= 1,
    );

    const helper = results.filter((r) => r.file === "helper.ts");
    check(
      "the plain library file gets a real verdict, not a skip",
      helper.length === 1 && helper[0].scored && helper[0].reason.length > 0,
    );

    // 3 — every verdict carries a taxonomy tag the funnel knows. An unknown tag
    // makes `stageReached` throw, so this also proves the funnel cannot
    // silently mis-attribute a new failure mode.
    const stages = new Map(results.map((r) => [r.file, safeStage(r.reason)]));
    check(
      "every verdict carries a known taxonomy tag",
      results.every((r) => r.reason.includes(":")) &&
        [...stages.values()].every((v) => v >= 0) &&
        stages.size === 2,
      `reasons: ${JSON.stringify(results.map((r) => r.reason))}`,
    );

    plainStage = stages.get("helper.ts") ?? -1;
    // 4 — the funnel is real: a plain library file gets PAST encode and
    // compile-back. If the harness were failing everything at stage 1 and
    // calling that a measurement, this would be 0. (TypeScript actually reaches
    // stage 4 today; >= 2 is deliberately the weakest statement that still
    // proves the funnel runs, matching the sibling harnesses.)
    check(
      "a plain library file survives encode and compile-back (funnel >= 2)",
      plainStage >= 2,
      `stage reached was ${plainStage} (reason: ${helper[0]?.reason ?? "n/a"})`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }

  // 5 (negative control) — a construct the encoder rejects must be scored, not
  // clean, tagged `encode-error`, and must stop STRICTLY EARLIER than the plain
  // file. Same-tag-for-everything is the failure mode this catches.
  const unsupported = studyFile("synthetic", "unsupported.ts", UNSUPPORTED);
  check(
    "an unsupported construct is scored, not clean, and tagged encode-error",
    unsupported.scored &&
      !unsupported.clean &&
      unsupported.reason.startsWith("encode-error:"),
    `scored=${unsupported.scored} clean=${unsupported.clean} reason="${unsupported.reason}"`,
  );
  check(
    "the harness discriminates: the rejected file stops earlier than the plain one",
    safeStage(unsupported.reason) < plainStage,
    `unsupported stage=${safeStage(unsupported.reason)} plain stage=${plainStage}`,
  );

  // 6 (#536) — a library file whose only declaration is NAMED like the entry
  // point is measured as the library it is: scored, and the compiled output
  // carries no synthesized invocation. On `compile()` this file would gain a
  // zero-arg `main();` against a one-argument function.
  const entryNamed = studyFile("synthetic", "entry_named.ts", ENTRY_NAMED);
  check(
    "an entry-point-named library declaration is scored, not skipped or crashed on",
    entryNamed.scored && safeStage(entryNamed.reason) >= 2,
    `scored=${entryNamed.scored} stage=${safeStage(entryNamed.reason)} reason="${entryNamed.reason}"`,
  );

  // 7 — an unknown taxonomy tag must be LOUD. If `stageReached` quietly
  // returned 0 for a tag it did not know, a new failure mode would silently
  // vanish from the funnel while the totals still added up.
  let threwOnUnknownTag = false;
  try {
    stageReached("brand-new-failure-mode: something");
  } catch {
    threwOnUnknownTag = true;
  }
  check("an unknown taxonomy tag makes the funnel fail loud", threwOnUnknownTag);

  // 8 — the declaration-inventory walker is the harness's own eyes for stage 4.
  // Prove it is a real AST walk — it must see class members, and it must
  // actually MISS a declaration that was removed, or stage 4 is a rubber stamp.
  const full = declarationInventory(
    "export class Box {\n" +
      "  size = 1;\n" +
      "  area(): number { return this.size; }\n" +
      "}\n" +
      "\n" +
      "export enum Color { red, blue }\n" +
      "export type Id = string;\n" +
      "export interface Named { name: string }\n" +
      "export const version = 1;\n" +
      "export function free(value: number): number { return value; }\n",
  );
  const expected = new Set([
    "class Box",
    "class Box.size",
    "class Box.area",
    "enum Color",
    "enum Color.red",
    "enum Color.blue",
    "type Id",
    "interface Named",
    "var version",
    "function free",
  ]);
  check(
    "the declaration inventory sees classes, members, enums, aliases and free functions",
    full.size === expected.size && [...expected].every((n) => full.has(n)),
    `got ${JSON.stringify([...full].sort())}`,
  );

  const pruned = declarationInventory("export class Box {\n  size = 1;\n}\n");
  const lost = [...full].filter((n) => !pruned.has(n)).sort();
  check(
    "the declaration inventory detects lost declarations",
    lost.length === 8 &&
      lost.includes("class Box.area") &&
      lost.includes("function free"),
    `got ${JSON.stringify(lost)}`,
  );

  // 9 — stage 4's syntax gate is not a rubber stamp. TypeScript's parser is
  // error-tolerant, so without an explicit check an emitter that produced
  // broken TypeScript would sail through the whole funnel and be reported
  // clean. Feed the checker output that is deliberately broken.
  check(
    "the syntax gate rejects deliberately broken output",
    syntaxErrors("export function broken(: number {").length > 0,
  );
  check(
    "the syntax gate accepts well-formed output",
    syntaxErrors("export function ok(x: number): number { return x; }\n").length === 0,
  );

  const total = passed + failed;
  console.log(`Results: ${passed} passed, ${failed} failed, ${total} total`);
  if (total < 1) {
    console.error("ERROR: the self-test asserted nothing.");
    return 1;
  }
  return failed > 0 ? 1 : 0;
}

process.exit(main());
