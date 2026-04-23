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

// Dart-style toString for Ball values (standalone version for harness)
function __bts(v: any): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    if (Number.isInteger(v)) return v.toString();
    const s = v.toString();
    return s.includes('.') || s.includes('e') ? s : s + '.0';
  }
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) {
    return '[' + v.map(__bts).join(', ') + ']';
  }
  if (v instanceof Map) {
    const parts: string[] = [];
    for (const [k, val] of v.entries()) {
      parts.push(__bts(k) + ': ' + __bts(val));
    }
    return '{' + parts.join(', ') + '}';
  }
  if (v instanceof Set) {
    return '{' + [...v].map(__bts).join(', ') + '}';
  }
  if (typeof v === 'object') {
    // StringBuffer-like objects
    if (v['__buffer__'] && Array.isArray(v['__buffer__'])) {
      return v['__buffer__'].join('');
    }
    if (v.toString !== Object.prototype.toString && typeof v.toString === 'function') {
      return v.toString();
    }
    const keys = Object.keys(v).filter((k: string) => !k.startsWith('__'));
    if (keys.length > 0) {
      return '{' + keys.map((k: string) => __bts(k) + ': ' + __bts(v[k])).join(', ') + '}';
    }
    return '{}';
  }
  return String(v);
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
    // String methods
    if (typeof self === 'string') {
      switch (fn) {
        case 'length': return self.length;
        case 'isEmpty': return self.length === 0;
        case 'isNotEmpty': return self.length > 0;
        case 'contains': return self.includes(String(arg0 ?? ''));
        case 'startsWith': return self.startsWith(String(arg0 ?? ''));
        case 'endsWith': return self.endsWith(String(arg0 ?? ''));
        case 'substring': return self.substring(Number(arg0 ?? 0), arg1 != null ? Number(arg1) : undefined);
        case 'split': return self.split(String(arg0 ?? ''));
        case 'trim': return self.trim();
        case 'toUpperCase': return self.toUpperCase();
        case 'toLowerCase': return self.toLowerCase();
        case 'replaceAll': return self.split(String(arg0 ?? '')).join(String(arg1 ?? ''));
        case 'codeUnitAt': return self.charCodeAt(Number(arg0 ?? 0));
        case 'toString': return self;
        case 'compareTo': return self < String(arg0) ? -1 : self > String(arg0) ? 1 : 0;
      }
    }
    // StringBuffer-like object methods (write, writeCharCode, toString)
    if (typeof self === 'object' && self !== null && '__type__' in self) {
      switch (fn) {
        case 'write': {
          if (!self['__buffer__']) self['__buffer__'] = [];
          self['__buffer__'].push(String(arg0 ?? ''));
          return null;
        }
        case 'writeCharCode': {
          if (!self['__buffer__']) self['__buffer__'] = [];
          self['__buffer__'].push(String.fromCharCode(Number(arg0 ?? 0)));
          return null;
        }
        case 'toString': {
          if (self['__buffer__']) return self['__buffer__'].join('');
          break;
        }
      }
    }
    // Set methods
    if (self instanceof Set) {
      switch (fn) {
        case 'union': { const other = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self, ...other]); }
        case 'intersection': { const other = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self].filter(x => other.has(x))); }
        case 'difference': { const other = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self].filter(x => !other.has(x))); }
        case 'contains': {
          if (self.has(arg0)) return true;
          // Try numeric coercion
          if (typeof arg0 === 'number') return self.has(String(arg0));
          if (typeof arg0 === 'string') { const n = Number(arg0); if (!isNaN(n)) return self.has(n); }
          return false;
        }
        case 'add': self.add(arg0); return null;
        case 'remove': return self.delete(arg0);
        case 'length': return self.size;
        case 'isEmpty': return self.size === 0;
        case 'isNotEmpty': return self.size > 0;
        case 'toList': return [...self];
        case 'toString': return '{' + [...self].join(', ') + '}';
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
          let r = fn(item);
          if (r && typeof r.then === 'function') r = await r;
        }
      } else if (collection instanceof Set) {
        for (const item of collection) {
          let r = fn(item);
          if (r && typeof r.then === 'function') r = await r;
        }
      } else if (typeof collection === 'object' && collection !== null) {
        for (const [k, v] of Object.entries(collection).filter(([k]: any) => !k.startsWith('__'))) {
          let r = fn({'key': k, 'value': v, 'arg0': k, 'arg1': v});
          if (r && typeof r.then === 'function') r = await r;
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
    const fn = m['compare'] ?? m['comparator'] ?? m['function'] ?? m['value'];
    if (!Array.isArray(list)) return [];
    const sorted = [...list];
    if (typeof fn === 'function') {
      // Stable merge sort supporting async comparators
      async function mergeSort(arr: any[]): Promise<any[]> {
        if (arr.length <= 1) return arr;
        const mid = Math.floor(arr.length / 2);
        const left = await mergeSort(arr.slice(0, mid));
        const right = await mergeSort(arr.slice(mid));
        const result: any[] = [];
        let li = 0, ri = 0;
        while (li < left.length && ri < right.length) {
          let r = fn({'arg0': left[li], 'arg1': right[ri], 'left': left[li], 'right': right[ri]});
          if (r && typeof r.then === 'function') r = await r;
          const cmp = typeof r === 'number' ? r : 0;
          if (cmp <= 0) result.push(left[li++]);
          else result.push(right[ri++]);
        }
        while (li < left.length) result.push(left[li++]);
        while (ri < right.length) result.push(right[ri++]);
        return result;
      }
      const result = await mergeSort(sorted);
      return result;
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
  stdHandler.register('list_join', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const sep = m['separator'] ?? m['delimiter'] ?? ', ';
    if (!Array.isArray(list)) return '';
    return list.map((x: any) => {
      if (x === null || x === undefined) return 'null';
      if (typeof x === 'boolean') return x ? 'true' : 'false';
      return String(x);
    }).join(String(sep));
  });
  stdHandler.register('list_every', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return false;
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      if (!r) return false;
    }
    return true;
  });
  stdHandler.register('list_length', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? i;
    if (Array.isArray(list)) return list.length;
    if (typeof list === 'string') return list.length;
    return 0;
  });
  stdHandler.register('list_reversed', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    if (Array.isArray(list)) return [...list].reverse();
    return [];
  });
  stdHandler.register('list_sublist', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const start = Number(m['start'] ?? m['arg0'] ?? 0);
    const end = m['end'] ?? m['arg1'];
    if (!Array.isArray(list)) return [];
    return list.slice(start, end != null ? Number(end) : undefined);
  });
  stdHandler.register('list_index_of', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const value = m['value'] ?? m['element'];
    if (Array.isArray(list)) return list.indexOf(value);
    return -1;
  });
  stdHandler.register('list_add', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const value = m['value'] ?? m['element'];
    if (Array.isArray(list)) { list.push(value); return null; }
    return null;
  });
  stdHandler.register('list_add_all', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const other = m['other'] ?? m['elements'] ?? [];
    if (Array.isArray(list) && Array.isArray(other)) { list.push(...other); }
    return null;
  });
  stdHandler.register('list_remove_at', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const idx = Number(m['index'] ?? 0);
    if (Array.isArray(list)) return list.splice(idx, 1)[0];
    return null;
  });
  stdHandler.register('list_insert', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const idx = Number(m['index'] ?? 0);
    const value = m['value'] ?? m['element'];
    if (Array.isArray(list)) { list.splice(idx, 0, value); }
    return null;
  });
  stdHandler.register('list_clear', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    if (Array.isArray(list)) list.length = 0;
    return null;
  });
  stdHandler.register('list_filled', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
    const value = m['value'] ?? m['fill'] ?? m['arg1'] ?? null;
    return Array(count).fill(value);
  });
  stdHandler.register('list_generate', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
    const gen = m['generator'] ?? m['function'] ?? m['arg1'] ?? m['value'];
    const result: any[] = [];
    if (typeof gen === 'function') {
      for (let j = 0; j < count; j++) {
        let r = gen(j);
        if (r && typeof r.then === 'function') r = await r;
        result.push(r);
      }
    } else {
      // No generator, fill with null
      for (let j = 0; j < count; j++) result.push(null);
    }
    return result;
  });
  stdHandler.register('list_contains', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const value = m['value'] ?? m['element'];
    if (list instanceof Set) {
      if (list.has(value)) return true;
      if (typeof value === 'number') return list.has(String(value));
      if (typeof value === 'string') { const n = Number(value); if (!isNaN(n)) return list.has(n); }
      return false;
    }
    if (Array.isArray(list)) return list.includes(value);
    if (typeof list === 'string') return list.includes(String(value));
    return false;
  });
  stdHandler.register('list_remove', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const value = m['value'] ?? m['element'];
    if (Array.isArray(list)) {
      const idx = list.indexOf(value);
      if (idx >= 0) { list.splice(idx, 1); return true; }
    }
    return false;
  });
  stdHandler.register('list_remove_last', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    if (Array.isArray(list)) return list.pop();
    return null;
  });
  stdHandler.register('map_from_entries', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const entries = m['entries'] ?? m['list'] ?? m['arg0'] ?? [];
    const result: any = {};
    if (Array.isArray(entries)) {
      for (const e of entries) {
        if (typeof e === 'object' && e !== null) {
          const k = e['key'] ?? e['arg0'] ?? e['name'] ?? '';
          const v = 'value' in e ? e['value'] : ('arg1' in e ? e['arg1'] : undefined);
          result[k] = v;
        }
      }
    }
    return result;
  });
  stdHandler.register('map_containsKey', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    const key = m['key'] ?? m['value'] ?? '';
    if (typeof map === 'object' && map !== null) return String(key) in map;
    return false;
  });
  stdHandler.register('map_contains_key', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    const key = m['key'] ?? m['value'] ?? '';
    if (typeof map === 'object' && map !== null) return String(key) in map;
    return false;
  });
  stdHandler.register('map_length', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    if (typeof map === 'object' && map !== null) return Object.keys(map).filter(k => !k.startsWith('__')).length;
    return 0;
  });
  stdHandler.register('map_keys', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    if (typeof map === 'object' && map !== null) return Object.keys(map).filter(k => !k.startsWith('__'));
    return [];
  });
  stdHandler.register('map_values', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    if (typeof map === 'object' && map !== null) return Object.keys(map).filter(k => !k.startsWith('__')).map(k => map[k]);
    return [];
  });
  stdHandler.register('map_remove', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'];
    const key = m['key'] ?? '';
    if (typeof map === 'object' && map !== null) { const v = map[String(key)]; delete map[String(key)]; return v; }
    return null;
  });
  stdHandler.register('map_put_if_absent', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'];
    const key = String(m['key'] ?? '');
    const value = m['value'];
    const ifAbsent = m['ifAbsent'] ?? m['if_absent'];
    if (typeof map === 'object' && map !== null) {
      if (!(key in map)) map[key] = typeof ifAbsent === 'function' ? ifAbsent() : (value ?? null);
      return map[key];
    }
    return null;
  });
  stdHandler.register('map_entries', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    if (typeof map === 'object' && map !== null) {
      return Object.entries(map).filter(([k]) => !k.startsWith('__')).map(([k, v]) => ({key: k, value: v}));
    }
    return [];
  });
  stdHandler.register('map_for_each', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    const fn = m['function'] ?? m['callback'];
    if (typeof fn === 'function' && typeof map === 'object' && map !== null) {
      for (const [k, v] of Object.entries(map).filter(([k]) => !k.startsWith('__'))) {
        let r = fn({key: k, value: v, arg0: k, arg1: v});
        if (r && typeof r.then === 'function') await r;
      }
    }
    return null;
  });
  stdHandler.register('map_map', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    const fn = m['function'] ?? m['callback'];
    const result: any = {};
    if (typeof fn === 'function' && typeof map === 'object' && map !== null) {
      for (const [k, v] of Object.entries(map).filter(([mk]) => !mk.startsWith('__'))) {
        let r = fn({key: k, value: v, arg0: k, arg1: v});
        if (r && typeof r.then === 'function') r = await r;
        if (typeof r === 'object' && r !== null && 'key' in r) {
          result[r.key] = r.value;
        } else {
          result[k] = r;
        }
      }
    }
    return result;
  });
  stdHandler.register('set_union', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const a = m['set'] ?? m['set1'] ?? m['collection'] ?? [];
    const b = m['other'] ?? m['set2'] ?? [];
    const setA = Array.isArray(a) ? new Set(a) : (a instanceof Set ? a : new Set());
    const setB = Array.isArray(b) ? new Set(b) : (b instanceof Set ? b : new Set());
    return new Set([...setA, ...setB]);
  });
  stdHandler.register('set_intersection', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const a = m['set'] ?? m['set1'] ?? m['collection'] ?? [];
    const b = m['other'] ?? m['set2'] ?? [];
    const setA = Array.isArray(a) ? new Set(a) : (a instanceof Set ? a : new Set());
    const setB = Array.isArray(b) ? new Set(b) : (b instanceof Set ? b : new Set());
    return new Set([...setA].filter(x => setB.has(x)));
  });
  stdHandler.register('set_difference', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const a = m['set'] ?? m['set1'] ?? m['collection'] ?? [];
    const b = m['other'] ?? m['set2'] ?? [];
    const setA = Array.isArray(a) ? new Set(a) : (a instanceof Set ? a : new Set());
    const setB = Array.isArray(b) ? new Set(b) : (b instanceof Set ? b : new Set());
    return new Set([...setA].filter(x => !setB.has(x)));
  });
  stdHandler.register('set_contains', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'] ?? new Set();
    const v = m['value'] ?? m['element'];
    if (s instanceof Set) return s.has(v);
    if (Array.isArray(s)) return s.includes(v);
    return false;
  });
  stdHandler.register('set_to_list', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'] ?? [];
    if (s instanceof Set) return [...s];
    if (Array.isArray(s)) return [...new Set(s)];
    return [];
  });
  stdHandler.register('set_length', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'] ?? new Set();
    if (s instanceof Set) return s.size;
    if (Array.isArray(s)) return new Set(s).size;
    return 0;
  });
  stdHandler.register('set_from', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? m['iterable'] ?? [];
    return new Set(Array.isArray(list) ? list : []);
  });
  stdHandler.register('string_split', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const sep = String(m['separator'] ?? m['pattern'] ?? m['delimiter'] ?? '');
    return s.split(sep);
  });
  stdHandler.register('string_substring', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const start = Number(m['start'] ?? 0);
    const end = m['end'] != null ? Number(m['end']) : undefined;
    return s.substring(start, end);
  });
  stdHandler.register('string_contains', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const sub = String(m['substring'] ?? m['pattern'] ?? m['other'] ?? '');
    return s.includes(sub);
  });
  stdHandler.register('string_length', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    return s.length;
  });
  stdHandler.register('string_index_of', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const sub = String(m['substring'] ?? m['pattern'] ?? '');
    return s.indexOf(sub);
  });
  stdHandler.register('string_to_upper_case', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return String(m['value'] ?? m['string'] ?? '').toUpperCase();
  });
  stdHandler.register('string_to_lower_case', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return String(m['value'] ?? m['string'] ?? '').toLowerCase();
  });
  stdHandler.register('string_trim', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return String(m['value'] ?? m['string'] ?? '').trim();
  });
  stdHandler.register('string_starts_with', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const prefix = String(m['prefix'] ?? m['pattern'] ?? '');
    return s.startsWith(prefix);
  });
  stdHandler.register('string_ends_with', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const suffix = String(m['suffix'] ?? m['pattern'] ?? '');
    return s.endsWith(suffix);
  });
  stdHandler.register('string_pad_left', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const width = Number(m['width'] ?? m['length'] ?? 0);
    const pad = String(m['padding'] ?? m['pad'] ?? ' ');
    return s.padStart(width, pad);
  });
  stdHandler.register('string_pad_right', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const width = Number(m['width'] ?? m['length'] ?? 0);
    const pad = String(m['padding'] ?? m['pad'] ?? ' ');
    return s.padEnd(width, pad);
  });
  stdHandler.register('string_from_char_codes', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const codes = m['codes'] ?? m['list'] ?? [];
    if (Array.isArray(codes)) return String.fromCharCode(...codes.map(Number));
    return '';
  });
  stdHandler.register('math_abs', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return Math.abs(Number(m['value'] ?? 0));
  });
  stdHandler.register('math_max', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return Math.max(Number(m['left'] ?? m['a'] ?? 0), Number(m['right'] ?? m['b'] ?? 0));
  });
  stdHandler.register('math_min', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return Math.min(Number(m['left'] ?? m['a'] ?? 0), Number(m['right'] ?? m['b'] ?? 0));
  });
  stdHandler.register('math_sqrt', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return Math.sqrt(Number(m['value'] ?? 0));
  });
  stdHandler.register('math_pow', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    return Math.pow(Number(m['base'] ?? m['left'] ?? 0), Number(m['exponent'] ?? m['right'] ?? 0));
  });
  stdHandler.register('list_push', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const value = m['value'] ?? m['element'];
    if (Array.isArray(list)) { list.push(value); return list; }
    return [...(list ?? []), value];
  });
  stdHandler.register('list_pop', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    if (Array.isArray(list) && list.length > 0) return list.pop();
    return null;
  });
  stdHandler.register('list_peek', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    if (Array.isArray(list) && list.length > 0) return list[list.length - 1];
    return null;
  });
  stdHandler.register('map_create', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const result: any = {};
    // Handle 'entry' fields (repeated)
    const entries = m['entry'] ?? m['entries'];
    if (Array.isArray(entries)) {
      for (const e of entries) {
        if (typeof e === 'object' && e !== null) {
          result[e['key'] ?? e['name'] ?? ''] = e['value'];
        }
      }
    } else if (typeof entries === 'object' && entries !== null) {
      result[entries['key'] ?? entries['name'] ?? ''] = entries['value'];
    }
    return result;
  });
  stdHandler.register('set_create', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const elements = m['elements'] ?? m['values'] ?? [];
    return new Set(Array.isArray(elements) ? elements : []);
  });
  stdHandler.register('null_check', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const value = m['value'] ?? i;
    return value != null;
  });
  stdHandler.register('concat', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const left = m['left'] ?? '';
    const right = m['right'] ?? '';
    return String(left) + String(right);
  });
  stdHandler.register('to_string', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const value = m['value'] ?? i;
    return __bts(value);
  });
  stdHandler.register('map_contains_key', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'] ?? {};
    const key = String(m['key'] ?? m['value'] ?? '');
    if (typeof map === 'object' && map !== null) return key in map;
    return false;
  });
  // sort method dispatch: when called as a method on a list (self.sort)
  // This mutates the list in-place (Dart's List.sort)
  stdHandler.register('sort', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'] ?? m['list'] ?? m['collection'];
    const fn = m['compare'] ?? m['comparator'] ?? m['function'] ?? m['value'] ?? m['arg0'];
    if (Array.isArray(self)) {
      if (typeof fn === 'function') {
        async function mergeSort(arr: any[]): Promise<any[]> {
          if (arr.length <= 1) return arr;
          const mid = Math.floor(arr.length / 2);
          const left = await mergeSort(arr.slice(0, mid));
          const right = await mergeSort(arr.slice(mid));
          const result: any[] = [];
          let li = 0, ri = 0;
          while (li < left.length && ri < right.length) {
            let r = fn({'arg0': left[li], 'arg1': right[ri], 'left': left[li], 'right': right[ri]});
            if (r && typeof r.then === 'function') r = await r;
            const cmp = typeof r === 'number' ? r : 0;
            if (cmp <= 0) result.push(left[li++]);
            else result.push(right[ri++]);
          }
          while (li < left.length) result.push(left[li++]);
          while (ri < right.length) result.push(right[ri++]);
          return result;
        }
        const sorted = await mergeSort([...self]);
        for (let si = 0; si < sorted.length; si++) self[si] = sorted[si];
      } else {
        self.sort((a: any, b: any) => a < b ? -1 : a > b ? 1 : 0);
      }
      return null; // Dart's List.sort returns void
    }
    return null;
  });
  // list_of, list_from — copy an iterable
  stdHandler.register('list_of', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const src = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i;
    if (Array.isArray(src)) return [...src];
    if (src instanceof Set) return [...src];
    return [];
  });
  stdHandler.register('dart_list_of', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const src = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i;
    if (Array.isArray(src)) return [...src];
    if (src instanceof Set) return [...src];
    return [];
  });
  stdHandler.register('list_from', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const src = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i;
    if (Array.isArray(src)) return [...src];
    if (src instanceof Set) return [...src];
    return [];
  });
  stdHandler.register('dart_list_from', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const src = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i;
    if (Array.isArray(src)) return [...src];
    if (src instanceof Set) return [...src];
    return [];
  });
  // map_update — update a map key
  stdHandler.register('map_update', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'];
    const key = String(m['key'] ?? '');
    const fn = m['update'] ?? m['function'] ?? m['value'];
    const ifAbsent = m['ifAbsent'] ?? m['if_absent'];
    if (typeof map === 'object' && map !== null) {
      if (key in map && typeof fn === 'function') {
        map[key] = fn(map[key]);
      } else if (typeof ifAbsent === 'function') {
        map[key] = ifAbsent();
      }
      return map[key];
    }
    return null;
  });
  // string_char_at — get character at index
  stdHandler.register('string_char_at', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const idx = Number(m['index'] ?? m['arg0'] ?? 0);
    return s.charAt(idx);
  });
  // list_where / list_where_type — alias for list_filter
  stdHandler.register('list_where', async (i: any) => {
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
  // list_flat_map / list_expand — flatMap
  stdHandler.register('list_expand', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const fn = m['function'] ?? m['value'] ?? m['callback'];
    if (!Array.isArray(list) || typeof fn !== 'function') return [];
    const result: any[] = [];
    for (const item of list) {
      let r = fn(item);
      if (r && typeof r.then === 'function') r = await r;
      if (Array.isArray(r)) result.push(...r);
      else result.push(r);
    }
    return result;
  });
  // list_take / list_skip
  stdHandler.register('list_take', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const count = Number(m['count'] ?? m['value'] ?? m['n'] ?? 0);
    if (Array.isArray(list)) return list.slice(0, count);
    return [];
  });
  stdHandler.register('list_skip', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    const count = Number(m['count'] ?? m['value'] ?? m['n'] ?? 0);
    if (Array.isArray(list)) return list.slice(count);
    return [];
  });
  // list_first / list_last
  stdHandler.register('list_first', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    if (Array.isArray(list) && list.length > 0) return list[0];
    return null;
  });
  stdHandler.register('list_last', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    if (Array.isArray(list) && list.length > 0) return list[list.length - 1];
    return null;
  });
  // list_slice — slice a list (supports both start/end and repeated value fields)
  stdHandler.register('list_slice', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'] ?? [];
    if (!Array.isArray(list)) return [];
    // Check for start/end args
    if ('start' in m || 'end' in m) {
      const start = Number(m['start'] ?? 0);
      const end = m['end'] != null ? Number(m['end']) : undefined;
      return list.slice(start, end);
    }
    // Repeated 'value' fields: [start, end]
    const val = m['value'];
    if (Array.isArray(val) && val.length >= 2) {
      return list.slice(Number(val[0]), Number(val[1]));
    }
    if ('arg0' in m) {
      const start = Number(m['arg0'] ?? 0);
      const end = m['arg1'] != null ? Number(m['arg1']) : undefined;
      return list.slice(start, end);
    }
    if (val != null && !Array.isArray(val)) {
      return list.slice(0, Number(val));
    }
    return [...list];
  });
  // string_char_code_at
  stdHandler.register('string_char_code_at', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? '');
    const idx = Number(m['index'] ?? m['arg0'] ?? 0);
    return s.charCodeAt(idx);
  });
  // string_from_char_code (single)
  stdHandler.register('string_from_char_code', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const code = Number(m['value'] ?? m['code'] ?? m['arg0'] ?? 0);
    return String.fromCharCode(code);
  });
  // writeCharCode — method dispatch on StringBuffer
  stdHandler.register('writeCharCode', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'];
    const code = Number(m['arg0'] ?? m['value'] ?? 0);
    if (typeof self === 'object' && self !== null) {
      if (!self['__buffer__']) self['__buffer__'] = [];
      self['__buffer__'].push(String.fromCharCode(code));
    }
    return null;
  });
  // write — method dispatch on StringBuffer
  stdHandler.register('write', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'];
    const val = m['arg0'] ?? m['value'] ?? '';
    if (typeof self === 'object' && self !== null) {
      if (!self['__buffer__']) self['__buffer__'] = [];
      self['__buffer__'].push(String(val));
    }
    return null;
  });
  // list_set — set element at index
  stdHandler.register('list_set', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const list = m['list'] ?? m['collection'];
    const idx = Number(m['index'] ?? 0);
    const val = m['value'];
    if (Array.isArray(list)) { list[idx] = val; }
    return null;
  });
  // map_add_all
  stdHandler.register('map_add_all', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'];
    const other = m['other'] ?? m['entries'] ?? {};
    if (typeof map === 'object' && map !== null && typeof other === 'object' && other !== null) {
      for (const [k, v] of Object.entries(other)) {
        if (!k.startsWith('__')) map[k] = v;
      }
    }
    return null;
  });
  // set_add / set_remove
  stdHandler.register('set_add', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'];
    const v = m['value'] ?? m['element'];
    if (s instanceof Set) { s.add(v); return true; }
    return false;
  });
  stdHandler.register('set_remove', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'];
    const v = m['value'] ?? m['element'];
    if (s instanceof Set) return s.delete(v);
    return false;
  });
  // union / intersection / difference — method dispatch on Sets
  stdHandler.register('union', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'] ?? m['set'] ?? new Set();
    const other = m['arg0'] ?? m['other'] ?? new Set();
    const setA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []);
    const setB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []);
    return new Set([...setA, ...setB]);
  });
  stdHandler.register('intersection', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'] ?? m['set'] ?? new Set();
    const other = m['arg0'] ?? m['other'] ?? new Set();
    const setA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []);
    const setB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []);
    return new Set([...setA].filter(x => setB.has(x)));
  });
  stdHandler.register('difference', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const self = m['self'] ?? m['set'] ?? new Set();
    const other = m['arg0'] ?? m['other'] ?? new Set();
    const setA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []);
    const setB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []);
    return new Set([...setA].filter(x => !setB.has(x)));
  });
  // set_add_all
  stdHandler.register('set_add_all', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = m['set'] ?? m['collection'];
    const other = m['other'] ?? m['elements'] ?? [];
    if (s instanceof Set) {
      const items = Array.isArray(other) ? other : (other instanceof Set ? [...other] : []);
      for (const item of items) s.add(item);
    }
    return null;
  });
  // compare_to — Dart's Comparable.compareTo
  stdHandler.register('compare_to', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const left = m['left'] ?? m['value'] ?? m['self'] ?? m['a'] ?? 0;
    const right = m['right'] ?? m['other'] ?? m['arg0'] ?? m['b'] ?? 0;
    if (typeof left === 'string' && typeof right === 'string') return left < right ? -1 : left > right ? 1 : 0;
    return Number(left) < Number(right) ? -1 : Number(left) > Number(right) ? 1 : 0;
  });
  // fromEntries — handle Map.fromEntries dispatch
  stdHandler.register('fromEntries', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const entries = m['entries'] ?? m['list'] ?? m['arg0'] ?? [];
    const result: any = {};
    if (Array.isArray(entries)) {
      for (const e of entries) {
        if (typeof e === 'object' && e !== null) {
          const k = e['key'] ?? e['arg0'] ?? e['name'] ?? '';
          const v = 'value' in e ? e['value'] : ('arg1' in e ? e['arg1'] : undefined);
          result[k] = v;
        }
      }
    }
    return result;
  });
  stdHandler.register('map_fromEntries', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const entries = m['entries'] ?? m['list'] ?? m['arg0'] ?? [];
    const result: any = {};
    if (Array.isArray(entries)) {
      for (const e of entries) {
        if (typeof e === 'object' && e !== null) {
          const k = e['key'] ?? e['arg0'] ?? e['name'] ?? '';
          const v = 'value' in e ? e['value'] : ('arg1' in e ? e['arg1'] : undefined);
          result[k] = v;
        }
      }
    }
    return result;
  });
  // generate — alias for list_generate (handles List.generate dispatch)
  stdHandler.register('generate', async (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
    const gen = m['generator'] ?? m['function'] ?? m['arg1'] ?? m['value'];
    const result: any[] = [];
    if (typeof gen === 'function') {
      for (let j = 0; j < count; j++) {
        let r = gen(j);
        if (r && typeof r.then === 'function') r = await r;
        result.push(r);
      }
    } else {
      for (let j = 0; j < count; j++) result.push(null);
    }
    return result;
  });
  // filled — alias for list_filled
  stdHandler.register('filled', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
    const value = m['value'] ?? m['fill'] ?? m['arg1'] ?? null;
    return Array(count).fill(value);
  });
  // string_to_int — more lenient integer parsing
  stdHandler.register('string_to_int', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const s = String(m['value'] ?? m['string'] ?? i ?? '');
    const n = parseInt(s.trim(), 10);
    if (isNaN(n)) return 0;
    return n;
  });
  // map_clear
  stdHandler.register('map_clear', (i: any) => {
    const m = (typeof i === 'object' && i !== null) ? i : {};
    const map = m['map'] ?? m['collection'];
    if (typeof map === 'object' && map !== null) {
      for (const k of Object.keys(map)) {
        if (!k.startsWith('__')) delete map[k];
      }
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
