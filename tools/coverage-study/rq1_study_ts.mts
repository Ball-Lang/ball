#!/usr/bin/env node --experimental-strip-types
/**
 * Tier A of the third-party coverage study — TypeScript port (issues #493, #536).
 *
 * The TypeScript sibling of `tools/coverage-study/rq1_study.dart` and
 * `rq1_study_py.py`. Same five stages, same strictness, same output format:
 *
 *     TypeScript source -> @ball-lang/encoder -> @ball-lang/compiler's
 *                          compileLibrary -> TypeScript source -> encoder
 *
 * A file is *clean* only when it encodes, compiles back, re-encodes, keeps
 * every declaration it started with, and reaches a **second-generation
 * fixpoint** (compiling the re-encoded program again yields the same source and
 * the same metadata-stripped Ball IR).
 *
 * Two things this harness deliberately does NOT do:
 *
 * 1. **It does not delegate the declaration inventory to the encoder.** The
 *    inventory is walked with the raw TypeScript Compiler API directly, so a
 *    bug in `@ball-lang/encoder`'s own bookkeeping cannot hide a lost
 *    declaration from the harness. (The Dart harness uses `analyzer`, the
 *    Python one the stdlib `ast`, for the same reason.)
 * 2. **It does not skip entry-point-less files.** `@ball-lang/compiler` has a
 *    real library mode since #536 (`compileLibrary`), so a module that is only
 *    exported declarations is compiled back, scored, and counted — the whole
 *    point of #493 is that real third-party code has no `main`. Before #536 the
 *    only two entry points were `compile()`, which appends a zero-arg `main();`
 *    to anything named `main` regardless of its real arity, and `compileModule`,
 *    which is scoped to the ball_protobuf facade — this harness could not
 *    honestly be written at all.
 *
 * Usage (from the repo root):
 *
 *     node --experimental-strip-types tools/coverage-study/rq1_study_ts.mts \
 *         --pins tools/coverage-study/packages/ts.json \
 *         --checkouts <dir-with-one-clone-per-package> [--json <report.json>]
 *
 *     node --experimental-strip-types tools/coverage-study/rq1_study_ts.mts \
 *         --package <name> --source-dir <dir> [--json <report.json>]
 *
 * Report-only: see tests/conformance/COVERAGE_STUDY.md. The one thing that
 * fails here is a run that scored zero files — that is a harness/checkout
 * failure, not a 0% result.
 */
import { createRequire } from "node:module";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { encode } from "../../ts/encoder/src/index.ts";
import { compileLibrary } from "../../ts/compiler/src/index.ts";

// `typescript` is a runtime dependency of @ball-lang/encoder, so resolving it
// from there means this script needs no node_modules of its own — and it is
// the *raw* compiler API, not the encoder's traversal, that walks the
// inventory below.
const requireFromEncoder = createRequire(
  new URL("../../ts/encoder/package.json", import.meta.url),
);
const ts = requireFromEncoder("typescript");

/**
 * The encode settings this study uses, and the ONE TypeScript-specific
 * accommodation it makes.
 *
 * Every sibling encoder (Dart, Rust, C#, Go, Python) THROWS on a construct it
 * cannot represent, so its Tier A harness gets an honest `encode-error` for
 * free. `@ball-lang/encoder` does not: by default it records a warning and
 * emits an "unhandled" placeholder literal in the IR, which changes what the
 * program computes while still producing a Program the funnel would happily
 * carry all the way to "clean". Measuring with that default would manufacture
 * exactly the flattering number this study exists to avoid.
 *
 * `strictBehaviorAffecting` is the encoder's own mechanical distinction: it
 * turns a behaviour-changing loss into a hard `EncodeError` while still
 * tolerating the erasure-only ones (`TypeAliasDeclaration`,
 * `InterfaceDeclaration`, `EmptyStatement`) that cannot change a result. Full
 * `strict: true` would reject those too — and since the declaration inventory
 * below already counts an erased `type`/`interface` as a lost declaration,
 * they are measured at stage 4 rather than hidden.
 */
const ENCODE_OPTIONS = { strictBehaviorAffecting: true } as const;

// ── verdicts ────────────────────────────────────────────────────────────────

export interface FileResult {
  package: string;
  file: string;
  scored: boolean;
  clean: boolean;
  irStable: boolean;
  reason: string;
}

function verdict(
  pkg: string,
  file: string,
  reason: string,
  extra: Partial<FileResult> = {},
): FileResult {
  return {
    package: pkg,
    file,
    scored: true,
    clean: false,
    irStable: false,
    reason,
    ...extra,
  };
}

/**
 * Recursively drop every `metadata` map.
 *
 * Metadata is cosmetic (Ball invariant #2), so two programs that differ only
 * there are semantically identical — the project's own definition of semantic
 * equality, and the same one rq1_study.dart uses.
 */
export function stripMetadata(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(stripMetadata);
  if (node !== null && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(node as Record<string, unknown>)) {
      if (key === "metadata") continue;
      out[key] = stripMetadata(value);
    }
    return out;
  }
  return node;
}

/** A stable, key-sorted serialization of the metadata-stripped program. */
function canonical(program: unknown): string {
  const seen = stripMetadata(program);
  return JSON.stringify(seen, (_key, value) => {
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      const sorted: Record<string, unknown> = {};
      for (const key of Object.keys(value as object).sort()) {
        sorted[key] = (value as Record<string, unknown>)[key];
      }
      return sorted;
    }
    return value;
  });
}

// ── the declaration inventory (raw TypeScript Compiler API) ─────────────────

const SOURCE_NAME = "inventory.ts";

function sourceFileOf(source: string) {
  return ts.createSourceFile(
    SOURCE_NAME,
    source,
    ts.ScriptTarget.Latest,
    /* setParentNodes */ true,
    ts.ScriptKind.TS,
  );
}

/**
 * Syntax errors in `source`, via the PUBLIC `getSyntacticDiagnostics` API.
 *
 * The TypeScript parser is error-tolerant — `createSourceFile` happily returns
 * a tree for unparseable input — so without this an emitter that produced
 * broken TypeScript would sail straight through the funnel. This is the TS
 * analog of the Dart harness's stage-4 parse check (the one that caught #494).
 */
export function syntaxErrors(source: string): string[] {
  const sf = sourceFileOf(source);
  const host = {
    getSourceFile: (name: string) => (name === SOURCE_NAME ? sf : undefined),
    getDefaultLibFileName: () => "lib.d.ts",
    writeFile: () => {},
    getCurrentDirectory: () => "/",
    getCanonicalFileName: (name: string) => name,
    useCaseSensitiveFileNames: () => true,
    getNewLine: () => "\n",
    fileExists: (name: string) => name === SOURCE_NAME,
    readFile: (name: string) => (name === SOURCE_NAME ? source : undefined),
  };
  const program = ts.createProgram(
    [SOURCE_NAME],
    { noResolve: true, noLib: true, target: ts.ScriptTarget.Latest },
    host,
  );
  return program
    .getSyntacticDiagnostics(sf)
    .map((d: any) => ts.flattenDiagnosticMessageText(d.messageText, " "));
}

function memberName(member: any): string | undefined {
  const name = member.name;
  if (name === undefined) return undefined;
  if (ts.isIdentifier(name) || ts.isPrivateIdentifier(name)) return name.text;
  if (ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
  return undefined;
}

/**
 * The declaration inventory of `source`.
 *
 * One entry per top-level declaration, class and enum members included, so a
 * lost method is visible and mere reordering is not. Walked with the raw
 * TypeScript Compiler API — independent of `@ball-lang/encoder`'s own walk.
 */
export function declarationInventory(source: string): Set<string> {
  const names = new Set<string>();
  for (const stmt of sourceFileOf(source).statements) {
    if (ts.isFunctionDeclaration(stmt) && stmt.name) {
      names.add(`function ${stmt.name.text}`);
    } else if (ts.isClassDeclaration(stmt) && stmt.name) {
      const owner = `class ${stmt.name.text}`;
      names.add(owner);
      for (const member of stmt.members) {
        const short = memberName(member);
        if (short !== undefined) names.add(`${owner}.${short}`);
      }
    } else if (ts.isEnumDeclaration(stmt)) {
      const owner = `enum ${stmt.name.text}`;
      names.add(owner);
      for (const member of stmt.members) {
        const short = memberName(member);
        if (short !== undefined) names.add(`${owner}.${short}`);
      }
    } else if (ts.isTypeAliasDeclaration(stmt)) {
      names.add(`type ${stmt.name.text}`);
    } else if (ts.isInterfaceDeclaration(stmt)) {
      names.add(`interface ${stmt.name.text}`);
    } else if (ts.isVariableStatement(stmt)) {
      for (const decl of stmt.declarationList.declarations) {
        if (ts.isIdentifier(decl.name)) names.add(`var ${decl.name.text}`);
      }
    }
  }
  return names;
}

// ── the funnel ──────────────────────────────────────────────────────────────

/**
 * How far a scored file got, derived from its taxonomy tag. The clean
 * percentage alone cannot distinguish "the encoder rejected the file outright"
 * from "everything worked but the third generation drifted", and on a pipeline
 * that is not yet round-trip-closed the whole signal lives in that difference.
 */
const STAGES: ReadonlyArray<readonly [number, string]> = [
  [1, "1 encoded"],
  [2, "2 compiled back"],
  [3, "3 re-encoded"],
  [4, "4 declarations kept"],
  [5, "5 fixpoint (clean)"],
];

const STAGE_REACHED: Readonly<Record<string, number>> = {
  "read-error": 0,
  "encode-error": 0,
  "compile-error": 1,
  "reencode-error": 2,
  "parse-error": 3,
  "declaration-drift": 3,
  "fixpoint-error": 4,
  "fixpoint-drift": 4,
  clean: 5,
};

/** The last stage a scored file survived, from its taxonomy tag. */
export function stageReached(reason: string): number {
  const tag = reason.split(":", 1)[0];
  if (!(tag in STAGE_REACHED)) {
    throw new Error(`unknown taxonomy tag "${tag}" — the funnel would silently lie`);
  }
  return STAGE_REACHED[tag];
}

function firstLine(error: unknown): string {
  const text = String(
    error instanceof Error ? error.message : error,
  ).replace(/\r/g, "");
  const line = text.split("\n", 1)[0];
  return line.length > 160 ? `${line.slice(0, 160)}…` : line;
}

/** Run Tier A over one file's `source` and return its verdict. */
export function studyFile(pkg: string, file: string, source: string): FileResult {
  // Stage 1 — encode.
  let program: unknown;
  let firstIr: string;
  try {
    program = encode(source, ENCODE_OPTIONS);
    firstIr = canonical(program);
  } catch (error) {
    return verdict(pkg, file, `encode-error: ${firstLine(error)}`);
  }

  // Stage 2 — compile back in LIBRARY mode. Real library files have no entry
  // point, so `compile()` is not an option: it would append a zero-arg
  // `main();` to any declaration that merely shares the encoder's default
  // entry name. `compileLibrary` emits every declaration, exported, with no
  // invocation at all (#536).
  let compiled: string;
  try {
    compiled = compileLibrary(program as never, { includePreamble: false });
  } catch (error) {
    return verdict(pkg, file, `compile-error: ${firstLine(error)}`);
  }
  if (compiled.trim() === "") {
    return verdict(pkg, file, "skipped: the file compiles to nothing (no user module)", {
      scored: false,
    });
  }

  // Stage 3 — re-encode the compiled TypeScript.
  let program2: unknown;
  let secondIr: string;
  try {
    program2 = encode(compiled, ENCODE_OPTIONS);
    secondIr = canonical(program2);
  } catch (error) {
    return verdict(pkg, file, `reencode-error: ${firstLine(error)}`);
  }

  // Stage 4 — is the compiled output even parseable, and did it keep every
  // declaration? TypeScript's parser is error-tolerant, so the syntax check is
  // explicit rather than a thrown exception.
  const errors = syntaxErrors(compiled);
  if (errors.length > 0) {
    return verdict(pkg, file, `parse-error: ${firstLine(errors[0])}`);
  }
  const before = declarationInventory(source);
  const after = declarationInventory(compiled);
  if (before.size === 0) {
    return verdict(pkg, file, "skipped: no top-level declarations to compile", {
      scored: false,
    });
  }
  const irStable = firstIr === secondIr;
  const lost = [...before].filter((name) => !after.has(name)).sort();
  if (lost.length > 0) {
    return verdict(
      pkg,
      file,
      `declaration-drift: lost ${lost.length} declaration(s) — ${lost.slice(0, 3).join(", ")}`,
      { irStable },
    );
  }

  // Stage 5 — SECOND-GENERATION FIXPOINT. Generation 1 vs. 2 is not a usable
  // signal (the compiler faithfully lowers Ball's single `input` parameter back
  // to a named local, so almost nothing is stable across the FIRST pass). From
  // generation 2 on that lowering is already applied, so a pipeline that
  // neither loses nor invents meaning must reach a fixpoint.
  let compiled2: string;
  let thirdIr: string;
  try {
    compiled2 = compileLibrary(program2 as never, { includePreamble: false });
    thirdIr = canonical(encode(compiled2, ENCODE_OPTIONS));
  } catch (error) {
    return verdict(
      pkg,
      file,
      `fixpoint-error: generation 2 failed to compile — ${firstLine(error)}`,
      { irStable },
    );
  }
  if (compiled !== compiled2 || secondIr !== thirdIr) {
    return verdict(
      pkg,
      file,
      "fixpoint-drift: recompiling the re-encoded program changed it again",
      { irStable },
    );
  }

  return verdict(pkg, file, "clean", { clean: true, irStable });
}

// ── walking a checkout ──────────────────────────────────────────────────────

const SKIPPED_DIRS = new Set([
  "node_modules",
  "test",
  "tests",
  "__tests__",
  "dist",
  "build",
  ".git",
]);

function isStudyableFile(name: string): boolean {
  if (!name.endsWith(".ts") && !name.endsWith(".mts") && !name.endsWith(".cts")) {
    return false;
  }
  // `.d.ts` declares types and no runtime declarations; the rest are the
  // package's own test/benchmark sources, which are not what is being studied.
  return !/\.(?:d|spec|test|bench)\.[cm]?ts$/.test(name);
}

/** Every studyable TypeScript file under `directory`, sorted, tests excluded. */
export function typescriptFilesUnder(directory: string): string[] {
  const found: string[] = [];
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    )) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!SKIPPED_DIRS.has(entry.name)) walk(full);
      } else if (entry.isFile() && isStudyableFile(entry.name)) {
        found.push(full);
      }
    }
  };
  walk(directory);
  return found;
}

export function studyDirectory(pkg: string, directory: string): FileResult[] {
  const results: FileResult[] = [];
  for (const file of typescriptFilesUnder(directory)) {
    const rel = path.relative(directory, file).split(path.sep).join("/");
    let source: string;
    try {
      // Read as BYTES and decode explicitly: a text-mode read would be the
      // same here, but being explicit keeps a semantic lone \r intact.
      source = new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(file));
    } catch (error) {
      results.push(verdict(pkg, rel, `read-error: ${firstLine(error)}`));
      continue;
    }
    results.push(studyFile(pkg, rel, source));
  }
  return results;
}

export interface Run {
  results: FileResult[];
  missingPins: string[];
}

export function runPins(pinsPath: string, checkouts: string): Run {
  const run: Run = { results: [], missingPins: [] };
  const pins = JSON.parse(readFileSync(pinsPath, "utf8")).packages as Array<
    { name: string; lib?: string }
  >;
  for (const pin of pins) {
    const directory = path.join(checkouts, pin.name, pin.lib ?? "src");
    let isDir = false;
    try {
      isDir = statSync(directory).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) {
      // An unreachable pin is NOT an encoder regression — report it as a
      // distinct outcome instead of scoring it as a failure.
      run.missingPins.push(pin.name);
      continue;
    }
    run.results.push(...studyDirectory(pin.name, directory));
  }
  return run;
}

// ── reporting ───────────────────────────────────────────────────────────────

export function report(run: Run, jsonOut?: string): number {
  if (jsonOut) {
    writeFileSync(
      jsonOut,
      `${JSON.stringify({ missingPins: run.missingPins, files: run.results }, null, 2)}\n`,
      "utf8",
    );
  }

  const scored = run.results.filter((r) => r.scored);
  const total = scored.length;
  const clean = scored.filter((r) => r.clean).length;
  const irStable = scored.filter((r) => r.irStable).length;
  const skipped = run.results.length - total;

  const byReason = new Map<string, number>();
  for (const r of scored) {
    const tag = r.reason.split(":", 1)[0];
    byReason.set(tag, (byReason.get(tag) ?? 0) + 1);
  }
  for (const [tag, count] of [...byReason].sort(
    (a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1),
  )) {
    console.log(`  ${tag}: ${count}`);
  }
  if (skipped > 0) console.log(`  skipped (no declarations, not scored): ${skipped}`);
  if (run.missingPins.length > 0) {
    console.log(`  unreachable pins (not scored): ${run.missingPins.join(", ")}`);
  }

  if (total > 0) {
    console.log("Funnel (scored files that survived each stage):");
    for (const [threshold, label] of STAGES) {
      const reached = scored.filter((r) => stageReached(r.reason) >= threshold).length;
      console.log(`  ${label}: ${reached}/${total}`);
    }
  }

  const pct = total === 0 ? 0 : Math.round((clean * 100) / total);
  console.log(`Tier A: ${clean}/${total} clean (${pct}%)`);
  console.log(`Tier A (IR fixpoint, informational): ${irStable}/${total} stable`);
  console.log(`Results: ${clean} passed, ${total - clean} failed, ${total} total`);

  // Positive floor: a run that scored nothing is a harness/checkout failure,
  // not a 0% result.
  if (total < 1) {
    console.error("ERROR: Tier A scored 0 files — no package checkout was readable.");
    return 1;
  }
  return 0;
}

// ── CLI ─────────────────────────────────────────────────────────────────────

function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq >= 0) out[arg.slice(2, eq)] = arg.slice(eq + 1);
    else out[arg.slice(2)] = argv[++i] ?? "";
  }
  return out;
}

export function main(argv: string[]): number {
  const args = parseArgs(argv);
  let run: Run;
  if (args.pins) {
    if (!args.checkouts) {
      console.error("--pins requires --checkouts <dir>");
      return 2;
    }
    run = runPins(args.pins, args.checkouts);
  } else if (args.package && args["source-dir"]) {
    let isDir = false;
    try {
      isDir = statSync(args["source-dir"]).isDirectory();
    } catch {
      isDir = false;
    }
    if (!isDir) {
      console.error(`--source-dir does not exist: ${args["source-dir"]}`);
      return 2;
    }
    run = { results: studyDirectory(args.package, args["source-dir"]), missingPins: [] };
  } else {
    console.error("either --pins/--checkouts or --package/--source-dir is required");
    return 2;
  }
  return report(run, args.json);
}

if (import.meta.url === `file://${process.argv[1]}` ||
    import.meta.filename === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
