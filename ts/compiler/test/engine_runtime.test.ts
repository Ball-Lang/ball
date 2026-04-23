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
import { BallEngine, StdModuleHandler } from "${engineUrl}";

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

// Method dispatch handler — intercepts method-style calls (no module,
// self field in input) and dispatches to JS built-in collection methods.
class MethodDispatchHandler {
  handles(module: any): boolean { return module === '' || module == null; }
  init(_engine: any): void {}
  call(fn: string, input: any, _engine: any): any {
    if (input == null || typeof input !== 'object') return undefined;
    const self = input.self ?? input['self'];
    if (self === undefined) return undefined;
    const arg0 = input.arg0 ?? input['arg0'];
    const arg1 = input.arg1 ?? input['arg1'];
    // Array methods
    if (Array.isArray(self)) {
      switch (fn) {
        case 'add': self.push(arg0); return null;
        case 'removeLast': return self.pop();
        case 'removeAt': return self.splice(typeof arg0 === 'number' ? arg0 : 0, 1)[0];
        case 'insert': self.splice(typeof arg0 === 'number' ? arg0 : 0, 0, arg1); return null;
        case 'clear': self.length = 0; return null;
        case 'contains': return self.includes(arg0);
        case 'indexOf': return self.indexOf(arg0);
        case 'join': return self.join(arg0 ?? ',');
        case 'sublist': return self.slice(arg0, arg1);
        case 'sort': self.sort((a: any, b: any) => a < b ? -1 : a > b ? 1 : 0); return null;
        case 'reversed': return [...self].reverse();
        case 'length': return self.length;
        case 'isEmpty': return self.length === 0;
        case 'isNotEmpty': return self.length > 0;
        case 'first': return self[0];
        case 'last': return self[self.length - 1];
        case 'filled': return Array(typeof arg0 === 'number' ? arg0 : 0).fill(arg1);
        case 'toList': return [...self];
        case 'toString': return '[' + self.join(', ') + ']';
      }
    }
    // String methods
    if (typeof self === 'string') {
      switch (fn) {
        case 'contains': return self.includes(String(arg0));
        case 'substring': return self.substring(arg0, arg1);
        case 'indexOf': return self.indexOf(String(arg0));
        case 'split': return self.split(String(arg0));
        case 'trim': return self.trim();
        case 'toUpperCase': return self.toUpperCase();
        case 'toLowerCase': return self.toLowerCase();
        case 'replaceAll': return self.split(String(arg0)).join(String(arg1));
        case 'startsWith': return self.startsWith(String(arg0));
        case 'endsWith': return self.endsWith(String(arg0));
        case 'padLeft': return self.padStart(arg0, arg1 ?? ' ');
        case 'padRight': return self.padEnd(arg0, arg1 ?? ' ');
        case 'length': return self.length;
        case 'isEmpty': return self.length === 0;
        case 'isNotEmpty': return self.length > 0;
        case 'toString': return self;
      }
    }
    // Number methods
    if (typeof self === 'number') {
      switch (fn) {
        case 'toDouble': return self;
        case 'toInt': return Math.trunc(self);
        case 'toString': return String(self);
        case 'toStringAsFixed': return self.toFixed(arg0);
        case 'abs': return Math.abs(self);
        case 'round': return Math.round(self);
        case 'floor': return Math.floor(self);
        case 'ceil': return Math.ceil(self);
        case 'compareTo': return self < arg0 ? -1 : self > arg0 ? 1 : 0;
        case 'clamp': return Math.min(Math.max(self, arg0), arg1);
      }
    }
    // Map/Object methods
    if (typeof self === 'object' && self !== null && !Array.isArray(self)) {
      switch (fn) {
        case 'containsKey': return String(arg0) in self;
        case 'containsValue': return Object.values(self).includes(arg0);
        case 'remove': { const v = self[String(arg0)]; delete self[String(arg0)]; return v; }
        case 'length': return Object.keys(self).length;
        case 'isEmpty': return Object.keys(self).length === 0;
        case 'isNotEmpty': return Object.keys(self).length > 0;
        case 'keys': return Object.keys(self);
        case 'values': return Object.values(self);
        case 'entries': return Object.entries(self).map(([k, v]) => ({key: k, value: v}));
        case 'putIfAbsent': if (!(String(arg0) in self)) self[String(arg0)] = typeof arg1 === 'function' ? arg1() : arg1; return self[String(arg0)];
        case 'toString': return '{' + Object.entries(self).map(([k,v]) => k + ': ' + v).join(', ') + '}';
      }
    }
    return undefined;
  }
}

// Static method dispatch (List.filled, etc.)
class StaticDispatchHandler {
  handles(module: any): boolean { return module === '' || module == null; }
  init(_engine: any): void {}
  call(fn: string, input: any, _engine: any): any {
    if (fn === 'filled' && input != null) {
      const n = input.arg0 ?? input['arg0'] ?? 0;
      const v = input.arg1 ?? input['arg1'] ?? null;
      return Array(typeof n === 'number' ? n : 0).fill(v);
    }
    return undefined;
  }
}

const lines: string[] = [];
const stdoutFn = (s: string) => lines.push(s);
const methodHandler = new MethodDispatchHandler();
const stdHandler = new StdModuleHandler();
const engine = new BallEngine(
  programJson,     // program
  stdoutFn,        // stdout
  undefined,       // stderr
  undefined,       // stdinReader
  undefined,       // envGet
  [],              // args
  false,           // enableProfiling
  [methodHandler, stdHandler],  // moduleHandlers
  undefined,       // resolver
);
// Seed global scope with built-in types that the Dart engine handles
// natively but the encoder didn't capture in the Ball IR.
const gs = (engine as any)._globalScope;
if (gs && gs.bind) {
  // Built-in type references for static method dispatch (List.generate, etc.)
  gs.bind('List', {'__class_ref__': 'List', '__type__': '__builtin_class__'});
  gs.bind('Map', {'__class_ref__': 'Map', '__type__': '__builtin_class__'});
  gs.bind('Set', {'__class_ref__': 'Set', '__type__': '__builtin_class__'});
  gs.bind('RegExp', {'__class_ref__': 'RegExp', '__type__': '__builtin_class__'});
  gs.bind('DateTime', {'__class_ref__': 'DateTime', '__type__': '__builtin_class__'});
  gs.bind('Duration', {'__class_ref__': 'Duration', '__type__': '__builtin_class__'});
  gs.bind('identical', (a: any, b: any) => a === b);
  gs.bind('print', (msg: any) => { console.log(String(msg)); });
}
// Register missing std functions that the encoder didn't capture.
if (stdHandler.register) {
  // BallDouble is defined in the compiled engine's preamble. We access
  // it from the harness by dynamically importing the engine module.
  // For now, use a simple wrapper that marks doubles.
  const __BallDouble = class {
    value: number;
    constructor(v: number) { this.value = v; }
    valueOf() { return this.value; }
    toString() {
      const v = this.value;
      if (!isFinite(v)) return v.toString();
      if (Number.isInteger(v)) return v.toFixed(1);
      return v.toString();
    }
    [Symbol.toPrimitive](hint: string) {
      if (hint === 'string') return this.toString();
      return this.value;
    }
  };
  stdHandler.register('to_double', (i: any) => {
    if (i instanceof __BallDouble) return i;
    if (typeof i === 'number') return new __BallDouble(i);
    if (typeof i === 'object' && i !== null) {
      const v = i['value'] ?? i;
      if (v instanceof __BallDouble) return v;
      const n = typeof v === 'number' ? v : Number(v);
      return new __BallDouble(isNaN(n) ? 0 : n);
    }
    const n = Number(i);
    return new __BallDouble(isNaN(n) ? 0 : n);
  });
  stdHandler.register('int_to_double', (i: any) => {
    if (typeof i === 'number') return new __BallDouble(i);
    if (typeof i === 'object' && i !== null) {
      const v = i['value'] ?? i;
      const n = typeof v === 'number' ? v : Number(v);
      return new __BallDouble(isNaN(n) ? 0 : n);
    }
    const n = Number(i);
    return new __BallDouble(isNaN(n) ? 0 : n);
  });
  stdHandler.register('string_code_unit_at', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const idx = Number(m['index'] ?? 0);
    return s.charCodeAt(idx);
  });
  stdHandler.register('list_foreach', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const collection = m['list'] ?? m['collection'];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (typeof fn === 'function') {
      if (Array.isArray(collection)) {
        for (const item of collection) {
          const r = fn(item);
          if (r && typeof r.then === 'function') await r;
        }
      } else if (typeof collection === 'object' && collection !== null) {
        for (const [k, v] of Object.entries(collection)) {
          const r = fn({'key': k, 'value': v, 'arg0': k, 'arg1': v});
          if (r && typeof r.then === 'function') await r;
        }
      }
    }
    return null;
  });
  stdHandler.register('list_to_list', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const raw = m['list'] ?? m['value'];
    if (Array.isArray(raw)) return [...raw];
    if (raw instanceof Set) return [...raw];
    return [];
  });
  stdHandler.register('to_int', (i: any) => {
    if (typeof i === 'number') return Math.trunc(i);
    if (typeof i === 'object' && i !== null) {
      const v = i['value'] ?? i;
      return Math.trunc(Number(v));
    }
    return Math.trunc(Number(i));
  });
  stdHandler.register('string_from_char_code', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const code = Number(m['value'] ?? m['code'] ?? 0);
    return String.fromCharCode(code);
  });
  stdHandler.register('string_replace', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const from = String(m['from'] ?? m['pattern'] ?? '');
    const to = String(m['to'] ?? m['replacement'] ?? '');
    return s.replace(from, to);
  });
  stdHandler.register('string_replace_all', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const from = String(m['from'] ?? m['pattern'] ?? '');
    const to = String(m['to'] ?? m['replacement'] ?? '');
    return s.split(from).join(to);
  });
  stdHandler.register('string_repeat', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? '');
    const count = Number(m['count'] ?? m['times'] ?? 0);
    return s.repeat(count);
  });
  stdHandler.register('list_map', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return [];
    const result: any[] = [];
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      result.push(r);
    }
    return result;
  });
  stdHandler.register('list_filter', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return [];
    const result: any[] = [];
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      if (r) result.push(item);
    }
    return result;
  });
  stdHandler.register('list_reduce', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    const init = m['initial'] ?? m['initialValue'];
    if (!Array.isArray(list) || typeof fn !== 'function') return init ?? null;
    let acc = init;
    for (const item of list) {
      if (acc === undefined) { acc = item; continue; }
      let r = fn({'arg0': acc, 'arg1': item, 'left': acc, 'right': item});
      if (r && typeof r.then === 'function') r = await r;
      acc = r;
    }
    return acc;
  });
  stdHandler.register('list_sort', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['compare'] ?? m['comparator'] ?? m['function'];
    if (!Array.isArray(list)) return [];
    const sorted = [...list];
    if (typeof fn === 'function') {
      sorted.sort((a: any, b: any) => {
        const r = fn({'arg0': a, 'arg1': b, 'left': a, 'right': b});
        return typeof r === 'number' ? r : 0;
      });
    } else {
      sorted.sort((a: any, b: any) => a < b ? -1 : a > b ? 1 : 0);
    }
    return sorted;
  });
  stdHandler.register('list_any', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return false;
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      if (r) return true;
    }
    return false;
  });
  stdHandler.register('list_find', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return null;
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      if (r) return item;
    }
    return null;
  });
}
try {
  await engine.run();
} catch (e) {
  if (typeof e === 'object' && e !== null && 'typeName' in e) {
    process.stderr.write('BallException: ' + (e as any).typeName + '\\n');
  } else if (e instanceof Error) {
    process.stderr.write('Runtime error: ' + e.message + '\\n' + e.stack + '\\n');
  } else {
    process.stderr.write('Runtime error: ' + String(e) + '\\n');
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
