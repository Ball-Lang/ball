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
// 1. Imports the compiled engine
// 2. Reads a Ball program JSON from argv[1]
// 3. Runs it through the compiled BallEngine
// 4. Prints stdout
function buildHarness(enginePath: string): string {
  const engineUrl = pathToFileURL(enginePath).href;
  // The compiled BallEngine constructor takes positional params matching
  // the Dart signature: (program, stdout, stderr, stdinReader, envGet,
  // args, enableProfiling, moduleHandlers, resolver). We provide the
  // stdout callback and safe defaults for everything else.
  return `
import { readFileSync } from "node:fs";
import { BallEngine } from "${engineUrl}";

// Deep-wrap proto3 JSON objects so missing fields behave like Dart's
// protobuf runtime. Also wraps 'metadata' objects with a Struct-
// compatible .fields accessor that returns __BallValueWrapper instances.
function protoWrap(obj: any, isMetadata = false): any {
  if (obj == null || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map((v: any) => protoWrap(v));

  const base: any = {};
  for (const [k, v] of Object.entries(obj)) {
    // 'metadata' values are Struct-shaped — flag them for special
    // wrapping so .fields['key'].whichKind() works.
    base[k] = protoWrap(v, k === 'metadata');
  }
  // String fields that Dart's protobuf defaults to ''.
  for (const f of ['name','module','function','outputType','inputType',
    'typeName','field','version','entryModule','entryFunction',
    'description','integrity','url','path','ref','package',
    'type_name','type','label','variable']) {
    if (base[f] === undefined) base[f] = '';
  }
  // Repeated fields that Dart's protobuf defaults to [].
  for (const f of ['modules','functions','typeDefs','types','typeAliases',
    'enums','moduleImports','fields','statements','elements','values',
    'parameters','field']) {
    if (base[f] === undefined) base[f] = [];
  }
  // Object fields that Dart's protobuf defaults to empty Struct / message.
  // Only set on objects that look like Ball definitions (have a name
  // field) to avoid infinite recursion on plain value objects.
  if (base['name'] !== undefined && base['name'] !== '') {
    if (base['metadata'] === undefined || base['metadata'] === null) {
      base['metadata'] = protoWrap({}, true);
    }
  }

  // For metadata objects, replace the .fields data property with a
  // Struct-compatible Map-like object. Dart's protobuf runtime has
  // metadata.fields['key'] returning a Value wrapper. We build a
  // plain object whose values are wrapValue'd.
  if (isMetadata) {
    const rawMap = {};
    for (const [k, v] of Object.entries(base)) {
      if (k === 'fields' && Array.isArray(v) && v.length === 0) continue;
      rawMap[k] = v;
    }
    // Proxy that returns wrapValue'd entries for known keys, and
    // null for unknown keys (matching Dart protobuf Struct.fields
    // behavior where missing keys return Value(null)).
    const fieldsProxy = new Proxy(rawMap, {
      get(target, prop) {
        if (typeof prop !== 'string') return undefined;
        if (prop in target) return wrapValue(target[prop]);
        return null; // Dart Struct.fields returns null for missing keys
      },
    });
    Object.defineProperty(base, 'fields', {
      value: fieldsProxy,
      writable: true,
      configurable: true,
      enumerable: false,
    });
  }
  // Dart only has null (no undefined). Replace remaining undefined
  // values with null so === null checks work correctly in the compiled
  // engine (which uses Dart-style null checks).
  for (const k of Object.keys(base)) {
    if (base[k] === undefined) base[k] = null;
  }
  return base;
}

// Mini Value wrapper — duplicated from the preamble's
// __BallValueWrapper. Needed here because the harness runs in a
// separate module from the compiled engine.
function wrapValue(raw: any): any {
  return {
    _raw: raw,
    whichKind() {
      if (raw === null || raw === undefined) return 'nullValue';
      if (typeof raw === 'string') return 'stringValue';
      if (typeof raw === 'boolean') return 'boolValue';
      if (typeof raw === 'number') return 'numberValue';
      if (Array.isArray(raw)) return 'listValue';
      if (typeof raw === 'object') return 'structValue';
      return 'nullValue';
    },
    get stringValue() { return typeof raw === 'string' ? raw : String(raw ?? ''); },
    get boolValue() { return !!raw; },
    get numberValue() { return Number(raw); },
    get listValue() {
      const arr = Array.isArray(raw) ? raw : [];
      return { values: arr.map(wrapValue) };
    },
    get structValue() {
      const obj = (typeof raw === 'object' && raw !== null) ? raw : {};
      const f: any = {};
      for (const [k, v] of Object.entries(obj)) f[k] = wrapValue(v);
      return { fields: f };
    },
    hasStringValue() { return typeof raw === 'string'; },
    hasBoolValue() { return typeof raw === 'boolean'; },
    hasNumberValue() { return typeof raw === 'number'; },
    hasListValue() { return Array.isArray(raw); },
    hasStructValue() { return typeof raw === 'object' && raw !== null && !Array.isArray(raw); },
    hasNullValue() { return raw == null; },
    toString() { return String(raw); },
    valueOf() { return raw; },
  };
}

const programJson = protoWrap(JSON.parse(readFileSync(process.argv[2], "utf8")));

// Debug: check a function's metadata.fields to verify wrapping.
const _debugMod = programJson.modules?.find((m: any) => m.name === programJson.entryModule);
if (_debugMod) {
  const _debugFn = _debugMod.functions?.find((f: any) => f.metadata?.params);
  if (_debugFn) {
    const _flds = _debugFn.metadata?.fields;
    const _pv = _flds?.['params'];
    if (!_pv || !_pv.whichKind) {
      console.error('PROTO WRAP DEBUG: metadata.fields.params missing or unwrapped');
      console.error('  metadata keys:', Object.keys(_debugFn.metadata));
      console.error('  fields value:', _flds);
      console.error('  params value:', _pv);
      process.exit(99);
    }
  }
}

const lines: string[] = [];
const stdoutFn = (s: string) => lines.push(s);
const engine = new BallEngine(
  programJson,     // program
  stdoutFn,        // stdout
  undefined,       // stderr
  undefined,       // stdinReader
  undefined,       // envGet
  [],              // args
  false,           // enableProfiling
  [],              // moduleHandlers
  undefined,       // resolver
);
await engine.run();
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

  const program: Program = JSON.parse(readFileSync(engineBallJsonPath, "utf8"));
  const engineTs = compile(program);

  const tmpDir = tmpdir();
  const enginePath = join(tmpDir, `ball_rt_engine_${process.pid}.ts`);
  const harnessPath = join(tmpDir, `ball_rt_harness_${process.pid}.ts`);

  writeFileSync(enginePath, engineTs);
  writeFileSync(harnessPath, buildHarness(enginePath));

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
