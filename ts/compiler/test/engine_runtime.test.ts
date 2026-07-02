/**
 * Phase 2.7b — TS runtime parity.
 *
 * Compiles engine.dart to TS, then RUNS it against the conformance
 * suite. Each conformance program is loaded as a Ball JSON object and
 * executed through the compiled engine. Output is diffed against the
 * `.expected_output.txt` file.
 *
 * This is the ultimate self-host proof: a Ball program (the engine
 * itself), compiled to TypeScript by @ball-lang/compiler, executing
 * other Ball programs on Node — with byte-identical output to the
 * Dart reference engine.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  readFileSync,
  writeFileSync,
  unlinkSync,
  existsSync,
  readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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

// Build a TS file that:
// 1. Imports the freshly compiled engine + the shared engine_setup factory.
// 2. Reads a Ball program JSON from argv[2].
// 3. Wires the engine through createEngineSetup() — the EXACT same setup
//    (proto3-JSON normalization, method-dispatch handler, extra std-function
//    registrations, compiled-engine patches) that ts/engine’s index.ts uses
//    to reach 227/227. This eliminates harness/index.ts drift.
// 4. Runs the program and prints captured stdout.
function buildHarness(enginePath: string, setupPath: string): string {
  const engineUrl = pathToFileURL(enginePath).href;
  const setupUrl = pathToFileURL(setupPath).href;
  return `
import { readFileSync } from "node:fs";
import * as engineMod from "${engineUrl}";
import { createEngineSetup } from "${setupUrl}";

const {
  protoWrap,
  MethodDispatchHandler,
  registerExtraStdFunctions,
  patchCompiledEngine,
  seedGlobalScope,
  patchScopeBindings,
} = createEngineSetup(engineMod as any);

const BallEngine = engineMod.BallEngine;
const StdModuleHandler = engineMod.StdModuleHandler;

// Ball files are self-describing google.protobuf.Any envelopes; strip the
// "@type" key (if present) before normalizing into the engine's program tree.
function unwrapBallFile(json) {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return json;
  const type = json["@type"];
  if (type === undefined) return json;
  const ok = typeof type === "string" &&
    (type.endsWith("/ball.v1.Program") || type.endsWith("/ball.v1.Module"));
  if (!ok) throw new Error("unknown ball file @type: " + JSON.stringify(type));
  const body = {};
  for (const [k, v] of Object.entries(json)) { if (k !== "@type") body[k] = v; }
  return body;
}

const programJson = protoWrap(
  unwrapBallFile(JSON.parse(readFileSync(process.argv[2], "utf8"))),
);

const lines: string[] = [];
const stdoutFn = (s: string) => lines.push(s);
const stdHandler = new StdModuleHandler();
const methodHandler = new MethodDispatchHandler();

// Mirror ts/engine/src/index.ts’s BallEngine constructor exactly: 16 positional
// params, permissive security defaults, [methodHandler, stdHandler] in slot 15.
const engine = new BallEngine(
  programJson,
  stdoutFn,
  () => {},          // stderr
  null,              // stdinReader
  null,              // envGet
  [],                // args
  false,             // enableProfiling
  100000,            // maxRecursionDepth
  null,              // timeoutMs (null = unbounded)
  null,              // maxMemoryBytes (null = unbounded)
  1000000,           // maxModules
  1000000,           // maxExpressionDepth
  null,              // maxProgramSizeBytes
  false,             // sandbox
  [methodHandler as any, stdHandler],  // moduleHandlers
  null,              // resolver
);

// Apply the same post-construction wiring index.ts performs.
patchScopeBindings((engine as any)._globalScope);
registerExtraStdFunctions(stdHandler, engine);
seedGlobalScope(engine as any);
patchCompiledEngine(engine as any);

try {
  await engine.run();
} catch (e) {
  if (typeof e === "object" && e !== null && "typeName" in e) {
    process.stderr.write("BallException: " + (e as any).typeName + "\\n");
  } else if (e instanceof Error) {
    process.stderr.write("Runtime error: " + e.message + "\\n" + e.stack + "\\n");
  } else {
    process.stderr.write("Runtime error: " + String(e) + "\\n");
  }
  process.exit(1);
}
for (const line of lines) console.log(line);
`;
}

describe("Phase 2.7b: compiled engine runtime parity", () => {
  // Compile engine.dart once for all tests.
  const engineBallJsonPath = resolve(root, "dart/self_host/engine.ball.json");

  // Skip the whole suite if engine.ball.json doesn't exist.
  if (!existsSync(engineBallJsonPath)) {
    test.skip("engine.ball.json not found — run roundtrip_engine.dart first", () => {});
    return;
  }

  // The shared engine-setup factory (single source of truth for the
  // proto3-JSON normalization + handlers + std registrations + patches that a
  // working compiled engine needs). Lives in ts/engine; we reuse it so this
  // harness can never drift from the known-good ts/engine setup.
  const setupPath = resolve(root, "ts/engine/src/engine_setup.ts");
  if (!existsSync(setupPath)) {
    test.skip("ts/engine/src/engine_setup.ts not found", () => {});
    return;
  }

  const program: Program = unwrapBallFile(
    JSON.parse(readFileSync(engineBallJsonPath, "utf8")),
  );
  const engineTs = compile(program);

  const tmpDir = tmpdir();
  const enginePath = join(tmpDir, `ball_rt_engine_${process.pid}.ts`);
  const harnessPath = join(tmpDir, `ball_rt_harness_${process.pid}.ts`);

  writeFileSync(enginePath, engineTs);
  writeFileSync(harnessPath, buildHarness(enginePath, setupPath));

  const conformanceFiles = readdirSync(conformanceDir)
    .filter((f) => f.endsWith(".ball.json"))
    .sort();

  for (const file of conformanceFiles) {
    const name = file.replace(/\.ball\.json$/, "");
    const expectedPath = join(conformanceDir, `${name}.expected_output.txt`);
    if (!existsSync(expectedPath)) continue;

    test(name, { timeout: 30_000 }, () => {
      const programPath = join(conformanceDir, file);

      try {
        const stdout = execSync(
          `node --experimental-strip-types ${harnessPath} ${programPath}`,
          { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
        );
        const expected = readFileSync(expectedPath, "utf8");
        const norm = (s: string) => s.replace(/\r\n/g, "\n").trimEnd();
        assert.equal(
          norm(stdout),
          norm(expected),
          `Output mismatch for ${name}`,
        );
      } catch (e: any) {
        throw new Error(
          `Conformance ${name} failed:\n${e.stderr ?? e.message}`,
        );
      }
    });
  }

  // Cleanup after all tests.
  test("cleanup", () => {
    try { unlinkSync(enginePath); } catch {}
    try { unlinkSync(harnessPath); } catch {}
  });
});
