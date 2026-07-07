/**
 * Shared engine setup for the Ball TS self-hosted engine.
 *
 * This module factors the proto3-JSON normalization, method-dispatch handler,
 * extra std-function registrations, and compiled-engine patches OUT of
 * index.ts so they can be applied to ANY compiled-engine module instance —
 * both the committed `compiled_engine.ts` (used by index.ts / ts/engine) and
 * a freshly compiled engine (used by the Phase 2.7b conformance harness in
 * ts/compiler).
 *
 * The single source of truth for 'what a working engine needs' therefore
 * lives here, eliminating drift between the two harnesses.
 *
 * `createEngineSetup(mod)` takes the compiled-engine module namespace
 * (its exports: BallEngine, StdModuleHandler, BallGenerator, _FlowSignal, and
 * optionally BallFuture) and returns the bound setup helpers.
 */

export interface EngineModule {
  BallEngine: any;
  StdModuleHandler: any;
  BallGenerator: any;
  _FlowSignal: any;
  BallFuture?: any;
  [k: string]: any;
}

export function createEngineSetup(mod: EngineModule) {
  const StdModuleHandler = mod.StdModuleHandler;
  type CompiledEngine = InstanceType<typeof mod.BallEngine>;
  type StdHandler = InstanceType<typeof StdModuleHandler>;
  const BallGenerator = mod.BallGenerator;
  const _FlowSignal = mod._FlowSignal;

  const _EngineBallDouble: any = (globalThis as any).BallDouble;
  if (_EngineBallDouble?.prototype) {
    const _origBallDoubleToString = _EngineBallDouble.prototype.toString;
    _EngineBallDouble.prototype.toString = function () {
      const v = this.value;
      if (Object.is(v, -0)) return '-0.0';
      return _origBallDoubleToString.call(this);
    };
  }

  const _EngineBallFuture: any = (mod as any).BallFuture;
  class _ShimBallFuture {
    value: any;
    completed: boolean;
    error?: any;
    constructor(value: any, completed = true) {
      this.value = value;
      this.completed = completed;
      (this as any).__ball_future__ = true;
    }
  }
  const BallFuture: any = _EngineBallFuture ?? _ShimBallFuture;
  function _isFutureLike(v: any): boolean {
    if (v == null || typeof v !== 'object') return false;
    if (_EngineBallFuture && v instanceof _EngineBallFuture) return true;
    return (v as any).__ball_future__ === true;
  }

  // ── BallDouble helper ──────────────────────────────────────────────────────
  //
  // Creates a BallDouble-like value that behaves like a number but prints
  // with a decimal point (e.g. 42 -> "42.0").  Matches the BallDouble class
  // in the compiled engine's preamble.
  
  function _makeBallDouble(v: number): any {
    // Use the compiled engine's BallDouble class (exposed on globalThis by preamble)
    const BD = (globalThis as any).BallDouble;
    if (BD) return new BD(v);
    return v;
  }

  const _INT64_MAX_B = 9223372036854775807n;
  const _INT64_MIN_B = -9223372036854775808n;

  function _extractNumericArg(v: any): any {
    if (typeof v === 'bigint' || typeof v === 'number') return v;
    const BD = (globalThis as any).BallDouble;
    if (BD && v instanceof BD) return v.value;
    if (typeof v === 'object' && v !== null) {
      const raw = v['value'] ?? v['arg0'] ?? v;
      if (typeof raw === 'bigint' || typeof raw === 'number') return raw;
      if (BD && raw instanceof BD) return raw.value;
      return Number(raw);
    }
    return Number(v);
  }

  function _toIntValue(v: any): any {
    const n = _extractNumericArg(v);
    if (typeof n === 'bigint') {
      if (n > _INT64_MAX_B) return _INT64_MAX_B;
      if (n < _INT64_MIN_B) return _INT64_MIN_B;
      const asNum = Number(n);
      return Number.isSafeInteger(asNum) ? asNum : n;
    }
    const tb = BigInt(Math.trunc(n));
    if (tb > _INT64_MAX_B) return _INT64_MAX_B;
    if (tb < _INT64_MIN_B) return _INT64_MIN_B;
    return Number(tb);
  }

  function _toDoubleValue(v: any): any {
    const n = _extractNumericArg(v);
    if (typeof n === 'bigint') return _makeBallDouble(Number(n));
    return _makeBallDouble(typeof n === 'number' && !Number.isNaN(n) ? n : 0);
  }

  function _coerceInt(v: any): any {
    if (v == null) return 0;
    if (typeof v === 'bigint') return v;
    const BD = (globalThis as any).BallDouble;
    if (BD && v instanceof BD) return _coerceInt(v.value);
    if (typeof v === 'number') return Number.isInteger(v) ? v : Math.trunc(v);
    if (typeof v === 'string') {
      const s = v.trim();
      if (/^-?\d+$/.test(s)) {
        const b = BigInt(s);
        if (b > 9007199254740991n || b < -9007199254740991n) return b;
        return Number(b);
      }
      const n = parseInt(s, 10);
      return Number.isNaN(n) ? 0 : n;
    }
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;
  }

  function _coerceNum(v: any): any {
    if (v == null) return 0;
    if (typeof v === 'bigint') return _toIntValue(v);
    const BD = (globalThis as any).BallDouble;
    if (BD && v instanceof BD) return v.value;
    if (typeof v === 'number') return v;
    if (typeof v === 'string') {
      const s = v.trim();
      if (/^-?\d+$/.test(s)) {
        const b = BigInt(s);
        if (b > 9007199254740991n || b < -9007199254740991n) {
          return _toIntValue(b);
        }
        return Number(b);
      }
      const n = Number(s);
      return Number.isNaN(n) ? 0 : n;
    }
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;
  }

  function _coerceNumPair(a: any, b: any): [any, any] {
    const left = _coerceNum(a);
    const right = _coerceNum(b);
    if (typeof left === 'bigint' || typeof right === 'bigint') {
      const lb = typeof left === 'bigint' ? left : BigInt(Math.trunc(Number(left)));
      const rb = typeof right === 'bigint' ? right : BigInt(Math.trunc(Number(right)));
      return [lb, rb];
    }
    return [left, right];
  }

  function _coerceIntPair(a: any, b: any): [any, any] {
    const left = _coerceInt(a);
    const right = _coerceInt(b);
    if (typeof left === 'bigint' || typeof right === 'bigint') {
      const lb = typeof left === 'bigint' ? left : BigInt(Math.trunc(Number(left)));
      const rb = typeof right === 'bigint' ? right : BigInt(Math.trunc(Number(right)));
      return [lb, rb];
    }
    return [left, right];
  }

  function _asInt64(v: any): bigint {
    if (typeof v === 'bigint') return BigInt.asIntN(64, v);
    return BigInt.asIntN(64, BigInt(Math.trunc(Number(v))));
  }

  function _int64Result(v: bigint): any {
    const masked = BigInt.asIntN(64, v);
    const asNum = Number(masked);
    return Number.isSafeInteger(asNum) ? asNum : masked;
  }

  function _int64Binary(op: (l: bigint, r: bigint) => bigint, a: any, b: any): any {
    return _int64Result(op(_asInt64(a), _asInt64(b)));
  }

  function _int64Unary(op: (v: bigint) => bigint, v: any): any {
    return _int64Result(op(_asInt64(v)));
  }

  function _int64ShiftLeft(a: any, b: any): any {
    const shift = Number(_asInt64(b) & 63n);
    return _int64Result(_asInt64(a) << BigInt(shift));
  }

  function _int64ShiftRight(a: any, b: any): any {
    const shift = Number(_asInt64(b) & 63n);
    return _int64Result(_asInt64(a) >> BigInt(shift));
  }

  function _int64UnsignedShiftRight(a: any, b: any): any {
    const shift = Number(_asInt64(b) & 63n);
    return _int64Result(BigInt.asUintN(64, _asInt64(a)) >> BigInt(shift));
  }

  function _int64Divide(a: any, b: any): any {
    const [l, r] = _coerceIntPair(a, b);
    if (typeof l === 'bigint' || typeof r === 'bigint') {
      const lb = typeof l === 'bigint' ? l : BigInt(l);
      const rb = typeof r === 'bigint' ? r : BigInt(r);
      return _int64Result(lb / rb);
    }
    return Math.trunc(l / r);
  }

  function _int64Modulo(a: any, b: any): any {
    const [l, r] = _coerceIntPair(a, b);
    if (typeof l === 'bigint' || typeof r === 'bigint') {
      const lb = typeof l === 'bigint' ? l : BigInt(l);
      const rb = typeof r === 'bigint' ? r : BigInt(r);
      let rem = lb % rb;
      if (rem < 0n) rem += (rb < 0n ? -rb : rb);
      return _int64Result(rem);
    }
    const rem = l % r;
    return rem < 0 ? rem + Math.abs(r) : rem;
  }

  function _mathAbs(v: any): any {
    // `_coerceInt` unconditionally truncates through int64 coercion (needed
    // for BigInt-magnitude int abs), which silently dropped double-ness for
    // a BallDouble operand — e.g. `(2.5).abs()` returned `2` instead of
    // `2.5` (#115). Route a BallDouble operand through double abs instead.
    const BD = (globalThis as any).BallDouble;
    if (BD && v instanceof BD) return new BD(Math.abs(v.value));
    const coerced = _coerceInt(v);
    if (typeof coerced === 'bigint') {
      return _int64Result(coerced < 0n ? -coerced : coerced);
    }
    return Math.abs(coerced);
  }

  function _int64Add(a: any, b: any): any {
    const [l, r] = _coerceIntPair(a, b);
    // The false branch (neither operand a bigint) is unreachable via this
    // function's one caller (_stdAdd's 'add' handler): it only calls
    // _int64Add once it has already confirmed _coerceInt(left) or
    // _coerceInt(right) is a bigint, and _coerceIntPair coerces BOTH
    // operands to bigint whenever either one is -- so this `if` always
    // takes the true branch here.
    /* c8 ignore next */
    if (typeof l === 'bigint' || typeof r === 'bigint') {
      const lb = typeof l === 'bigint' ? l : BigInt(l);
      const rb = typeof r === 'bigint' ? r : BigInt(r);
      return _int64Result(lb + rb);
    }
    /* c8 ignore start -- defensive fallback, see the comment above */
    return l + r;
    /* c8 ignore stop */
  }

  function _int64Subtract(a: any, b: any): any {
    const [l, r] = _coerceIntPair(a, b);
    // Unreachable false branch via this function's one caller (see
    // _int64Add above).
    /* c8 ignore next */
    if (typeof l === 'bigint' || typeof r === 'bigint') {
      const lb = typeof l === 'bigint' ? l : BigInt(l);
      const rb = typeof r === 'bigint' ? r : BigInt(r);
      return _int64Result(lb - rb);
    }
    /* c8 ignore start -- defensive fallback, see the comment above */
    return l - r;
    /* c8 ignore stop */
  }

  function _int64Multiply(a: any, b: any): any {
    const [l, r] = _coerceIntPair(a, b);
    // Unreachable false branch via this function's one caller (see
    // _int64Add above).
    /* c8 ignore next */
    if (typeof l === 'bigint' || typeof r === 'bigint') {
      const lb = typeof l === 'bigint' ? l : BigInt(l);
      const rb = typeof r === 'bigint' ? r : BigInt(r);
      return _int64Result(lb * rb);
    }
    /* c8 ignore start -- defensive fallback, see the comment above */
    return l * r;
    /* c8 ignore stop */
  }

  function _int64Negate(v: any): any {
    const coerced = _coerceInt(v);
    if (typeof coerced === 'bigint') return _int64Result(-coerced);
    return -coerced;
  }

  function _collectionFieldAccess(object: any, fieldName: string): any {
    if (object == null || typeof object !== 'object' || Array.isArray(object)) return undefined;
    if (object instanceof Set || object instanceof Map) return undefined;
    const keys = Object.keys(object).filter((k: string) => !k.startsWith('__'));
    switch (fieldName) {
      case 'isEmpty': return keys.length === 0;
      case 'isNotEmpty': return keys.length > 0;
      case 'length': return keys.length;
      default: return undefined;
    }
  }

  function _numFieldAccess(object: any, fieldName: string): any {
    let n: number | undefined;
    if (typeof object === 'number') n = object;
    else {
      const BD = (globalThis as any).BallDouble;
      if (BD && object instanceof BD) n = object.value;
    }
    if (n === undefined) return undefined;
    switch (fieldName) {
      case 'isNaN': return Number.isNaN(n);
      case 'isFinite': return Number.isFinite(n);
      case 'isInfinite': return !Number.isFinite(n) && !Number.isNaN(n);
      case 'isNegative': return n < 0;
      case 'sign': return n > 0 ? 1 : n < 0 ? -1 : 0;
      default: return undefined;
    }
  }

  // Dart List.indexWhere — used by compiled-engine list-pattern matching.
  if (!(Array.prototype as any).indexWhere) {
    Object.defineProperty(Array.prototype, 'indexWhere', {
      value(pred: (e: any, i: number) => boolean) {
        for (let i = 0; i < this.length; i++) {
          if (pred(this[i], i)) return i;
        }
        return -1;
      },
      writable: true,
      configurable: true,
    });
  }

  // ── Proto3 JSON normalization ──────────────────────────────────────────────
  //
  // The compiled engine is a transpilation of the Dart reference engine and
  // expects objects that behave like Dart's protobuf runtime:
  //   - Every repeated field defaults to [].
  //   - Every string field defaults to ''.
  //   - metadata objects expose .fields['key'] returning a Value wrapper
  //     with .stringValue, .boolValue, .listValue, .whichKind(), etc.
  //   - undefined is replaced with null (Dart has no undefined).
  
  /** String fields that Dart's protobuf defaults to ''. */
  const STRING_DEFAULTS = [
    'name', 'module', 'function', 'outputType', 'inputType',
    'typeName', 'field', 'version', 'entryModule', 'entryFunction',
    'description', 'integrity', 'url', 'path', 'ref', 'package',
    'type_name', 'type', 'label', 'variable',
  ];
  
  /** Repeated fields that Dart's protobuf defaults to []. */
  const REPEATED_DEFAULTS = [
    'modules', 'functions', 'typeDefs', 'types', 'typeAliases',
    'enums', 'moduleImports', 'fields', 'statements', 'elements',
    'values', 'parameters', 'field',
  ];
  
  function protoWrap(obj: any, isMetadata = false): any {
    if (obj == null || typeof obj !== 'object') return obj;
    if (Array.isArray(obj)) return obj.map((v: any) => protoWrap(v));
  
    // Normalize `return` statements into expression calls to `std.return`.
    // The Ball encoder emits `{ "return": { "value": <expr> } }` as a statement,
    // but the compiled engine only recognizes `let` and `expression` statement types.
    // std.return is a control-flow call that expects a messageCreation input with a
    // `value` field, matching the Dart engine's _evalReturn(call, scope) dispatch.
    if (obj.return !== undefined && obj.expression === undefined && obj.let === undefined) {
      const retVal = obj.return;
      const valueExpr = retVal?.value ?? retVal;
      const inputMsg = valueExpr != null
        ? { messageCreation: { typeName: '', fields: [{ name: 'value', value: valueExpr }] } }
        : { messageCreation: { typeName: '', fields: [] } };
      return protoWrap({
        expression: {
          call: {
            module: 'std',
            function: 'return',
            input: inputMsg,
          },
        },
      });
    }
  
    const base: any = {};
    for (const [k, v] of Object.entries(obj)) {
      base[k] = protoWrap(v, k === 'metadata');
    }
  
    for (const f of STRING_DEFAULTS) {
      if (base[f] === undefined) base[f] = '';
    }
    for (const f of REPEATED_DEFAULTS) {
      if (base[f] === undefined) base[f] = [];
    }

    // A Literal.bytesValue arrives here as the raw proto3-JSON value: a
    // base64 string, un-decoded (this is a plain JSON.parse of the target
    // program, not a real protobuf deserializer). Dart's protobuf runtime
    // decodes `bytes` fields into raw bytes immediately on JSON parse, so
    // match that here — otherwise the engine's own Literal-eval logic
    // (`lit.bytesValue.toList()`, compiled from engine_eval.dart) sees a
    // STRING and `.toList()` on a string just iterates its characters,
    // silently returning the base64 text's own bytes instead of the value
    // it encodes. (issue #244)
    if (typeof base.bytesValue === 'string') {
      const bin = atob(base.bytesValue);
      base.bytesValue = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    }
  
    // Ensure metadata is present on definition-like objects.
    if (base['name'] !== undefined && base['name'] !== '') {
      if (base['metadata'] === undefined || base['metadata'] === null) {
        base['metadata'] = protoWrap({}, true);
      }
    }
  
    // Wrap metadata objects with a Struct-compatible .fields accessor.
    if (isMetadata) {
      const rawMap: Record<string, any> = {};
      for (const [k, v] of Object.entries(base)) {
        if (k === 'fields' && Array.isArray(v) && v.length === 0) continue;
        rawMap[k] = v;
      }
      const dartMethods = new Set(['containsKey', 'forEach', 'entries', 'keys', 'values', 'length', 'isEmpty', 'isNotEmpty', 'toString', 'toList']);
      const fieldsProxy = new Proxy(rawMap, {
        get(target, prop) {
          if (typeof prop !== 'string') return undefined;
          if (prop in target) return wrapValue(target[prop]);
          if (dartMethods.has(prop)) return (Object.prototype as any)[prop];
          return null;
        },
      });
      Object.defineProperty(base, 'fields', {
        value: fieldsProxy,
        writable: true,
        configurable: true,
        enumerable: false,
      });
    }
  
    // Dart has no undefined — replace with null.
    for (const k of Object.keys(base)) {
      if (base[k] === undefined) base[k] = null;
    }
    return base;
  }
  
  /** Wrap a plain JS value to provide proto Struct Value API. */
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
  
  /** Dart-style toString for Ball values. */
  function __bts(v: any): string {
    if (v === null || v === undefined) return 'null';
    if (typeof v === 'boolean') return v ? 'true' : 'false';
    const BD = (globalThis as any).BallDouble;
    if (BD && v instanceof BD) return v.toString();
    if (typeof v === 'bigint') return v.toString();
    if (typeof v === 'number') {
      if (Number.isNaN(v)) return 'NaN';
      if (!Number.isFinite(v)) return v.toString();
      if (Object.is(v, -0)) return '-0.0';
      if (Number.isInteger(v)) return v.toString();
      const s = v.toString();
      return s.includes('.') || s.includes('e') ? s : s + '.0';
    }
    if (typeof v === 'string') return v;
    // Unwrap BallFuture / BallGenerator before formatting
    if (_isFutureLike(v)) return __bts(v.value);
    if (BallGenerator && v instanceof BallGenerator) return __bts(v.values);
    if (v && typeof v === 'object' && v.__ball_future__ === true) return __bts(v.value);
    if (v && typeof v === 'object' && v.__ball_generator__ === true) return __bts(v.values);
    if (Array.isArray(v)) return '[' + v.map(__bts).join(', ') + ']';
    if (v instanceof Map) {
      // NOT `v.entries()` — the compiled engine's own preamble shadows
      // `Map.prototype.entries` with a Dart-style GETTER (returning an array
      // of {key,value} objects, matching Dart's `Map.entries` property) so
      // Ball's `.entries` field access works. That shadow makes `v.entries`
      // non-callable, so `v.entries()` throws "not a function" for any real
      // Map value. Iterate the Map directly instead — a Map's default
      // iterator already yields [key, value] pairs and is unaffected by the
      // entries/keys/values property shadowing.
      const parts: string[] = [];
      for (const [k, val] of v) parts.push(__bts(k) + ': ' + __bts(val));
      return '{' + parts.join(', ') + '}';
    }
    if (v instanceof Set) return '{' + [...v].map(__bts).join(', ') + '}';
    if (typeof v === 'object') {
      if (typeof v['__buffer__'] === 'string') return v['__buffer__'];
      if (v['__buffer__'] && Array.isArray(v['__buffer__'])) return v['__buffer__'].join('');
      const tn = v['__type__'];
      if (typeof tn === 'string' && (tn.endsWith(':StringBuffer') || tn === 'StringBuffer')) return v['__buffer__'] ?? '';
      if (v.toString !== Object.prototype.toString && typeof v.toString === 'function') return v.toString();
      const keys = Object.keys(v).filter((k: string) => !k.startsWith('__'));
      if (keys.length > 0) return '{' + keys.map((k: string) => __bts(k) + ': ' + __bts(v[k])).join(', ') + '}';
      return '{}';
    }
    return String(v);
  }

  // ── Method dispatch handler ────────────────────────────────────────────────
  //
  // Intercepts method-style calls (no module, self field in input) and
  // dispatches to JS built-in collection/string/number methods.
  
  class MethodDispatchHandler {
    handles(module: any): boolean { return module === '' || module == null; }
    init(_engine: any): void {}
    call(fn: string, input: any, _engine: any): any {
      if (input == null || typeof input !== 'object') return undefined;
      const self = input.self ?? input['self'];
      if (self === undefined) return undefined;
      const arg0 = input.arg0 ?? input['arg0'];
      const arg1 = input.arg1 ?? input['arg1'];
      if (Array.isArray(self)) {
        switch (fn) {
          case 'add': self.push(arg0); return null;
          case 'removeLast': return self.pop();
          case 'removeAt': return self.splice(typeof arg0 === 'number' ? arg0 : 0, 1)[0];
          case 'insert': self.splice(typeof arg0 === 'number' ? arg0 : 0, 0, arg1); return null;
          case 'clear': if (Array.isArray(self)) { self.length = 0; } else { for (const k of Object.keys(self)) if (!k.startsWith('__')) delete self[k]; } return null;
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
          case 'codeUnitAt': return self.charCodeAt(Number(arg0 ?? 0));
          case 'compareTo': return self < String(arg0) ? -1 : self > String(arg0) ? 1 : 0;
          case 'replaceFirst': return self.replace(arg0 instanceof RegExp ? arg0 : String(arg0), String(arg1 ?? ''));
        }
      }
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
          case 'remainder': return self % Number(_coerceNum(arg0));
        }
      }
      // A BallDouble-wrapped receiver (e.g. `double d = 2.5; d.remainder(2)`)
      // falls through every case above (`typeof self !== 'number'`), and the
      // compiled engine's own dispatch calls `self.remainder(...)` — a real
      // method call that doesn't exist on the BallDouble class (unlike
      // floor/ceil/round/abs, which work by accident via Math.* coercing
      // through BallDouble.valueOf()) (#115). Handle it explicitly here.
      {
        const BD = (globalThis as any).BallDouble;
        if (BD && self instanceof BD && fn === 'remainder') {
          return new BD(self.value % Number(_coerceNum(arg0)));
        }
      }
      if (typeof self === 'object' && self !== null && '__type__' in self) {
        switch (fn) {
          case 'write':
            if (!self['__buffer__']) self['__buffer__'] = [];
            self['__buffer__'].push(String(arg0 ?? ''));
            return null;
          case 'writeCharCode':
            if (!self['__buffer__']) self['__buffer__'] = [];
            self['__buffer__'].push(String.fromCharCode(Number(arg0 ?? 0)));
            return null;
          case 'toString':
            if (self['__buffer__']) return self['__buffer__'].join('');
            break;
        }
      }
      if (self instanceof Set) {
        switch (fn) {
          case 'union': { const o = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self, ...o]); }
          case 'intersection': { const o = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self].filter(x => o.has(x))); }
          case 'difference': { const o = arg0 instanceof Set ? arg0 : new Set(Array.isArray(arg0) ? arg0 : []); return new Set([...self].filter(x => !o.has(x))); }
          case 'contains': return self.has(arg0);
          case 'add': self.add(arg0); return null;
          case 'remove': return self.delete(arg0);
          case 'length': return self.size;
          case 'isEmpty': return self.size === 0;
          case 'isNotEmpty': return self.size > 0;
          case 'toList': return [...self];
          case 'toString': return '{' + [...self].join(', ') + '}';
        }
      }
      if (typeof self === 'object' && self !== null && !Array.isArray(self) && !(self instanceof Set)) {
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

  // ── Register extra std functions ───────────────────────────────────────────
  //
  // The compiled Dart engine's StdModuleHandler builds its dispatch table from
  // the Dart std library.  In TypeScript we need to provide JS implementations
  // for functions that the compiled engine's _buildStdDispatch doesn't cover
  // (collection higher-order functions, string helpers, etc.).
  
  /**
   * Register the hand-written std-function overrides on `stdHandler`.
   *
   * `engine` is the compiled BallEngine instance the handler is wired to.
   * It is REQUIRED for handlers that allocate proportionally to their input
   * (list_filled / list_generate): they charge the allocation against the
   * engine's memory accounting so `maxMemoryBytes` is enforced (#24). The
   * compiled engine's handler-call protocol passes a bound `callFunction`
   * (not the engine) as the third argument, so the engine must be captured
   * here at registration time.
   */
  function registerExtraStdFunctions(stdHandler: StdHandler, engine: any): void {
    const _r = stdHandler.register.bind(stdHandler);
    const _m = (i: any) => (typeof i === 'object' && i !== null) ? i : {};
    // Mirrors the compiled engine's `_ballPointerBytes` accounting constant.
    const _ptrBytes = 8;
    const _track = (bytes: number) => engine._trackMemoryAllocation(bytes);
  
    // ── Collection: list_* ─────────────────────────────────────────────
    _r('list_foreach', async (i: any) => {
      const m = _m(i);
      const coll = m['list'] ?? m['collection'];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (typeof fn !== 'function') return null;
      if (Array.isArray(coll)) { for (const item of coll) { let r = fn(item); if (r?.then) r = await r; } }
      else if (coll instanceof Set) { for (const item of coll) { let r = fn(item); if (r?.then) r = await r; } }
      else if (typeof coll === 'object' && coll !== null) {
        for (const [k, v] of Object.entries(coll).filter(([k]: any) => !k.startsWith('__'))) {
          let r = fn({'key': k, 'value': v, 'arg0': k, 'arg1': v});
          if (r?.then) r = await r;
        }
      }
      return null;
    });
    _r('list_map', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return [];
      const result: any[] = [];
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; result.push(r); }
      return result;
    });
    _r('list_filter', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return [];
      const result: any[] = [];
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (r) result.push(item); }
      return result;
    });
    _r('list_where', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return [];
      const result: any[] = [];
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (r) result.push(item); }
      return result;
    });
    _r('list_reduce', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      const init = m['initial'] ?? m['initialValue'];
      if (!Array.isArray(list) || typeof fn !== 'function') return init ?? null;
      let acc = init;
      for (const item of list) {
        if (acc === undefined) { acc = item; continue; }
        let r = fn({'arg0': acc, 'arg1': item, 'left': acc, 'right': item});
        if (r?.then) r = await r; acc = r;
      }
      return acc;
    });
    _r('list_sort', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['compare'] ?? m['comparator'] ?? m['function'] ?? m['value'];
      if (!Array.isArray(list)) return [];
      const sorted = [...list];
      if (typeof fn === 'function') {
        async function ms(arr: any[]): Promise<any[]> {
          if (arr.length <= 1) return arr;
          const mid = Math.floor(arr.length / 2);
          const l = await ms(arr.slice(0, mid)), r = await ms(arr.slice(mid));
          const res: any[] = []; let li = 0, ri = 0;
          while (li < l.length && ri < r.length) {
            let c = fn({'arg0': l[li], 'arg1': r[ri], 'left': l[li], 'right': r[ri]});
            if (c?.then) c = await c;
            if ((typeof c === 'number' ? c : 0) <= 0) res.push(l[li++]); else res.push(r[ri++]);
          }
          while (li < l.length) res.push(l[li++]);
          while (ri < r.length) res.push(r[ri++]);
          return res;
        }
        return await ms(sorted);
      }
      sorted.sort((a: any, b: any) => a < b ? -1 : a > b ? 1 : 0);
      return sorted;
    });
    _r('list_any', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return false;
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (r) return true; }
      return false;
    });
    _r('list_every', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return false;
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (!r) return false; }
      return true;
    });
    _r('list_find', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return null;
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (r) return item; }
      return null;
    });
    _r('list_expand', async (i: any) => {
      const m = _m(i); const list = m['list'] ?? m['collection'] ?? [];
      const fn = m['function'] ?? m['value'] ?? m['callback'];
      if (!Array.isArray(list) || typeof fn !== 'function') return [];
      const result: any[] = [];
      for (const item of list) { let r = fn(item); if (r?.then) r = await r; if (Array.isArray(r)) result.push(...r); else result.push(r); }
      return result;
    });
    _r('list_length', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? i; return Array.isArray(l) ? l.length : (typeof l === 'string' ? l.length : 0); });
    _r('list_reversed', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; return Array.isArray(l) ? [...l].reverse() : []; });
    _r('list_sublist', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const s = Number(m['start'] ?? m['arg0'] ?? 0); const e = m['end'] ?? m['arg1']; return Array.isArray(l) ? l.slice(s, e != null ? Number(e) : undefined) : []; });
    _r('list_index_of', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const v = m['value'] ?? m['element']; if (typeof l === 'string') return l.indexOf(String(v)); return Array.isArray(l) ? l.indexOf(v) : -1; });
    _r('list_add', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const v = m['value'] ?? m['element']; if (l instanceof Set) { l.add(v); return null; } if (Array.isArray(l)) l.push(v); return null; });
    _r('list_add_all', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const o = m['other'] ?? m['elements'] ?? []; if (Array.isArray(l) && Array.isArray(o)) l.push(...o); return null; });
    _r('list_remove_at', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const idx = Number(m['index'] ?? 0); return Array.isArray(l) ? l.splice(idx, 1)[0] : null; });
    // Both mutate in place AND return the (mutated) list: the encoder wraps
    // `list.insert(...)` / `list.clear()` statements in
    // `assign(target: list, value: list_insert(...)/list_clear(...))`
    // (`mutatingMethods` in encoder.dart), so returning `null` here — as a
    // literal Dart-`void`-return translation would — reassigns the variable
    // to `null` instead of the mutated list (issue #64 std-coverage gap:
    // `385_list_insert_at_index` was the first fixture to actually exercise
    // the non-cascade `list_insert` path on the TS self-host and caught
    // this). `list_clear` has the identical bug shape but was previously
    // only exercised via a cascade (`111_cascade_operator.dart`), which
    // discards the mutating call's return value and never surfaced it.
    _r('list_insert', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const idx = Number(m['index'] ?? 0); const v = m['value'] ?? m['element']; if (Array.isArray(l)) l.splice(idx, 0, v); return l; });
    _r('list_clear', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; if (Array.isArray(l)) l.length = 0; return l; });
    _r('list_contains', (i: any) => {
      const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const v = m['value'] ?? m['element'];
      if (l instanceof Set) { if (l.has(v)) return true; if (typeof v === 'number') return l.has(String(v)); if (typeof v === 'string') { const n = Number(v); if (!isNaN(n)) return l.has(n); } return false; }
      if (Array.isArray(l)) return l.includes(v); if (typeof l === 'string') return l.includes(String(v)); return false;
    });
    _r('list_remove', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const v = m['value'] ?? m['element']; if (Array.isArray(l)) { const idx = l.indexOf(v); if (idx >= 0) { l.splice(idx, 1); return true; } } return false; });
    _r('list_remove_last', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; return Array.isArray(l) ? l.pop() : null; });
    _r('list_to_list', (i: any) => { const m = _m(i); const r = m['list'] ?? m['value']; if (Array.isArray(r)) return [...r]; if (r instanceof Set) return [...r]; return []; });
    _r('list_join', (i: any) => {
      const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const sep = m['separator'] ?? m['delimiter'] ?? ', ';
      if (!Array.isArray(l)) return '';
      return l.map((x: any) => { if (x === null || x === undefined) return 'null'; if (typeof x === 'boolean') return x ? 'true' : 'false'; return String(x); }).join(String(sep));
    });
    _r('list_push', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const v = m['value'] ?? m['element']; if (l instanceof Set) { l.add(v); return l; } if (Array.isArray(l)) { l.push(v); return l; } return [...(l ?? []), v]; });
    _r('list_pop', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; return (Array.isArray(l) && l.length > 0) ? l.pop() : null; });
    _r('list_peek', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; return (Array.isArray(l) && l.length > 0) ? l[l.length - 1] : null; });
    _r('list_take', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const n = Number(m['count'] ?? m['value'] ?? m['n'] ?? 0); return Array.isArray(l) ? l.slice(0, n) : []; });
    _r('list_skip', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; const n = Number(m['count'] ?? m['value'] ?? m['n'] ?? 0); return Array.isArray(l) ? l.slice(n) : []; });
    _r('list_first', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; return (Array.isArray(l) && l.length > 0) ? l[0] : null; });
    _r('list_last', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; return (Array.isArray(l) && l.length > 0) ? l[l.length - 1] : null; });
    _r('list_set', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection']; const idx = Number(m['index'] ?? 0); if (Array.isArray(l)) l[idx] = m['value']; return null; });
    _r('list_slice', (i: any) => {
      const m = _m(i); const l = m['list'] ?? m['collection'] ?? []; if (!Array.isArray(l)) return [];
      if ('start' in m || 'end' in m) return l.slice(Number(m['start'] ?? 0), m['end'] != null ? Number(m['end']) : undefined);
      const val = m['value']; if (Array.isArray(val) && val.length >= 2) return l.slice(Number(val[0]), Number(val[1]));
      if ('arg0' in m) return l.slice(Number(m['arg0'] ?? 0), m['arg1'] != null ? Number(m['arg1']) : undefined);
      if (val != null && !Array.isArray(val)) return l.slice(Number(val));
      return [...l];
    });
    _r('list_of', (i: any) => { const m = _m(i); const s = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i; return Array.isArray(s) ? [...s] : (s instanceof Set ? [...s] : []); });
    _r('dart_list_of', (i: any) => { const m = _m(i); const s = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i; return Array.isArray(s) ? [...s] : (s instanceof Set ? [...s] : []); });
    _r('list_from', (i: any) => { const m = _m(i); const s = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i; return Array.isArray(s) ? [...s] : (s instanceof Set ? [...s] : []); });
    _r('dart_list_from', (i: any) => { const m = _m(i); const s = m['list'] ?? m['iterable'] ?? m['arg0'] ?? m['value'] ?? i; return Array.isArray(s) ? [...s] : (s instanceof Set ? [...s] : []); });
  
    // ── Collection: map_* ──────────────────────────────────────────────
    const _mapFromEntries = (i: any) => {
      const m = _m(i); const _own = (o: any, k: string) => Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined;
      const entries = _own(m, 'entries') ?? _own(m, 'list') ?? _own(m, 'arg0') ?? [];
      const result: any = {};
      if (Array.isArray(entries)) { for (const e of entries) { if (typeof e === 'object' && e !== null) { result[_own(e, 'key') ?? _own(e, 'arg0') ?? _own(e, 'name') ?? ''] = Object.prototype.hasOwnProperty.call(e, 'value') ? e['value'] : (_own(e, 'arg1') ?? undefined); } } }
      return result;
    };
    _r('map_from_entries', _mapFromEntries);
    _r('map_fromEntries', _mapFromEntries);
    _r('fromEntries', _mapFromEntries);
    _r('map_containsKey', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; const key = m['key'] ?? m['value'] ?? ''; return typeof map === 'object' && map !== null ? String(key) in map : false; });
    _r('map_contains_key', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; const key = m['key'] ?? m['value'] ?? ''; return typeof map === 'object' && map !== null ? String(key) in map : false; });
    _r('map_length', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; return typeof map === 'object' && map !== null ? Object.keys(map).filter(k => !k.startsWith('__')).length : 0; });
    _r('map_keys', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; return typeof map === 'object' && map !== null ? Object.keys(map).filter(k => !k.startsWith('__')) : []; });
    _r('map_values', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; return typeof map === 'object' && map !== null ? Object.keys(map).filter(k => !k.startsWith('__')).map(k => map[k]) : []; });
    _r('map_entries', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; return typeof map === 'object' && map !== null ? Object.entries(map).filter(([k]) => !k.startsWith('__')).map(([k, v]) => ({key: k, value: v})) : []; });
    _r('map_remove', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection']; const key = m['key'] ?? ''; if (typeof map === 'object' && map !== null) { const v = map[String(key)]; delete map[String(key)]; return v; } return null; });
    _r('map_put_if_absent', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection']; const key = String(m['key'] ?? ''); const value = m['value']; const ia = m['ifAbsent'] ?? m['if_absent']; if (typeof map === 'object' && map !== null) { if (!(key in map)) map[key] = typeof ia === 'function' ? ia() : (value ?? null); return map[key]; } return null; });
    _r('map_for_each', async (i: any) => {
      const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; const fn = m['function'] ?? m['callback'];
      if (typeof fn === 'function' && typeof map === 'object' && map !== null) {
        for (const [k, v] of Object.entries(map).filter(([k]) => !k.startsWith('__'))) { let r = fn({key: k, value: v, arg0: k, arg1: v}); if (r?.then) await r; }
      } return null;
    });
    _r('map_map', async (i: any) => {
      const m = _m(i); const map = m['map'] ?? m['collection'] ?? {}; const fn = m['function'] ?? m['callback']; const result: any = {};
      if (typeof fn === 'function' && typeof map === 'object' && map !== null) {
        for (const [k, v] of Object.entries(map).filter(([mk]) => !mk.startsWith('__'))) {
          let r = fn({key: k, value: v, arg0: k, arg1: v}); if (r?.then) r = await r;
          if (typeof r === 'object' && r !== null && 'key' in r) result[r.key] = r.value; else result[k] = r;
        }
      } return result;
    });
    _r('map_create', (i: any) => {
      const m = _m(i); const result: any = {};
      // Read `entry`/`entries` as OWN properties only. Plain bracket access hits
      // the Object.prototype `.entries` getter installed by the preamble, which
      // would (wrongly) treat the input map's own keys (e.g. `type_args`) as
      // entry records and re-inject them into the result.
      const hop = Object.prototype.hasOwnProperty;
      const entries = hop.call(m, 'entry') ? m['entry'] : (hop.call(m, 'entries') ? m['entries'] : undefined);
      if (Array.isArray(entries)) { for (const e of entries) { if (typeof e === 'object' && e !== null) result[e['key'] ?? e['name'] ?? ''] = e['value']; } }
      else if (typeof entries === 'object' && entries !== null) result[entries['key'] ?? entries['name'] ?? ''] = entries['value'];
      return result;
    });
    _r('map_update', (i: any) => {
      const m = _m(i); const map = m['map'] ?? m['collection']; const key = String(m['key'] ?? ''); const fn = m['update'] ?? m['function'] ?? m['value']; const ia = m['ifAbsent'] ?? m['if_absent'];
      if (typeof map === 'object' && map !== null) { if (key in map && typeof fn === 'function') map[key] = fn(map[key]); else if (typeof ia === 'function') map[key] = ia(); return map[key]; } return null;
    });
    _r('map_clear', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection']; if (typeof map === 'object' && map !== null) { for (const k of Object.keys(map)) { if (!k.startsWith('__')) delete map[k]; } } return null; });
    _r('map_add_all', (i: any) => { const m = _m(i); const map = m['map'] ?? m['collection']; const other = m['other'] ?? m['entries'] ?? {}; if (typeof map === 'object' && map !== null && typeof other === 'object' && other !== null) { for (const [k, v] of Object.entries(other)) { if (!k.startsWith('__')) map[k] = v; } } return null; });
  
    // ── Collection: set_* ──────────────────────────────────────────────
    _r('set_union', (i: any) => { const m = _m(i); const a = m['set'] ?? m['set1'] ?? m['collection'] ?? []; const b = m['other'] ?? m['set2'] ?? []; return new Set([...(Array.isArray(a) ? a : (a instanceof Set ? [...a] : [])), ...(Array.isArray(b) ? b : (b instanceof Set ? [...b] : []))]); });
    _r('set_intersection', (i: any) => { const m = _m(i); const a = m['set'] ?? m['set1'] ?? m['collection'] ?? []; const b = m['other'] ?? m['set2'] ?? []; const sA = a instanceof Set ? a : new Set(Array.isArray(a) ? a : []); const sB = b instanceof Set ? b : new Set(Array.isArray(b) ? b : []); return new Set([...sA].filter(x => sB.has(x))); });
    _r('set_difference', (i: any) => { const m = _m(i); const a = m['set'] ?? m['set1'] ?? m['collection'] ?? []; const b = m['other'] ?? m['set2'] ?? []; const sA = a instanceof Set ? a : new Set(Array.isArray(a) ? a : []); const sB = b instanceof Set ? b : new Set(Array.isArray(b) ? b : []); return new Set([...sA].filter(x => !sB.has(x))); });
    _r('set_contains', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection'] ?? new Set(); const v = m['value'] ?? m['element']; if (s instanceof Set) return s.has(v); if (Array.isArray(s)) return s.includes(v); return false; });
    _r('set_to_list', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection'] ?? []; return s instanceof Set ? [...s] : (Array.isArray(s) ? [...new Set(s)] : []); });
    _r('set_length', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection'] ?? new Set(); return s instanceof Set ? s.size : (Array.isArray(s) ? new Set(s).size : 0); });
    _r('set_from', (i: any) => { const m = _m(i); const l = m['list'] ?? m['collection'] ?? m['iterable'] ?? []; return new Set(Array.isArray(l) ? l : []); });
    _r('set_create', (i: any) => { const m = _m(i); return new Set(Array.isArray(m['elements'] ?? m['values'] ?? []) ? (m['elements'] ?? m['values'] ?? []) : []); });
    _r('set_add', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection']; const v = m['value'] ?? m['element']; if (s instanceof Set) { s.add(v); return true; } return false; });
    _r('set_remove', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection']; const v = m['value'] ?? m['element']; return s instanceof Set ? s.delete(v) : false; });
    _r('set_add_all', (i: any) => { const m = _m(i); const s = m['set'] ?? m['collection']; const other = m['other'] ?? m['elements'] ?? []; if (s instanceof Set) { const items = Array.isArray(other) ? other : (other instanceof Set ? [...other] : []); for (const item of items) s.add(item); } return null; });
    _r('union', (i: any) => { const m = _m(i); const self = m['self'] ?? m['set'] ?? new Set(); const other = m['arg0'] ?? m['other'] ?? new Set(); const sA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []); const sB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []); return new Set([...sA, ...sB]); });
    _r('intersection', (i: any) => { const m = _m(i); const self = m['self'] ?? m['set'] ?? new Set(); const other = m['arg0'] ?? m['other'] ?? new Set(); const sA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []); const sB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []); return new Set([...sA].filter(x => sB.has(x))); });
    _r('difference', (i: any) => { const m = _m(i); const self = m['self'] ?? m['set'] ?? new Set(); const other = m['arg0'] ?? m['other'] ?? new Set(); const sA = self instanceof Set ? self : new Set(Array.isArray(self) ? self : []); const sB = other instanceof Set ? other : new Set(Array.isArray(other) ? other : []); return new Set([...sA].filter(x => !sB.has(x))); });
  
    // ── String ─────────────────────────────────────────────────────────
    _r('string_code_unit_at', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').charCodeAt(Number(m['index'] ?? 0)); });
    _r('string_char_code_at', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').charCodeAt(Number(m['index'] ?? m['arg0'] ?? 0)); });
    _r('string_from_char_code', (i: any) => { const m = _m(i); return String.fromCharCode(Number(m['value'] ?? m['code'] ?? m['arg0'] ?? 0)); });
    _r('string_from_char_codes', (i: any) => { const m = _m(i); const codes = m['codes'] ?? m['list'] ?? []; return Array.isArray(codes) ? String.fromCharCode(...codes.map(Number)) : ''; });
    _r('string_replace', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').replace(String(m['from'] ?? m['pattern'] ?? ''), String(m['to'] ?? m['replacement'] ?? '')); });
    _r('string_replace_all', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').split(String(m['from'] ?? m['pattern'] ?? '')).join(String(m['to'] ?? m['replacement'] ?? '')); });
    _r('string_repeat', (i: any) => { const m = _m(i); return String(m['value'] ?? '').repeat(Number(m['count'] ?? m['times'] ?? 0)); });
    _r('string_split', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').split(String(m['separator'] ?? m['pattern'] ?? m['delimiter'] ?? '')); });
    _r('string_substring', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').substring(Number(m['start'] ?? 0), m['end'] != null ? Number(m['end']) : undefined); });
    _r('string_contains', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').includes(String(m['substring'] ?? m['pattern'] ?? m['other'] ?? '')); });
    _r('string_length', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').length; });
    _r('string_index_of', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? m['left'] ?? m['arg0'] ?? '').indexOf(String(m['substring'] ?? m['pattern'] ?? m['right'] ?? m['arg1'] ?? '')); });
    _r('string_to_upper_case', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').toUpperCase(); });
    _r('string_to_lower_case', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').toLowerCase(); });
    _r('string_trim', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').trim(); });
    _r('string_starts_with', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').startsWith(String(m['prefix'] ?? m['pattern'] ?? '')); });
    _r('string_ends_with', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').endsWith(String(m['suffix'] ?? m['pattern'] ?? '')); });
    _r('string_pad_left', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').padStart(Number(m['width'] ?? m['length'] ?? 0), String(m['padding'] ?? m['pad'] ?? ' ')); });
    _r('string_pad_right', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').padEnd(Number(m['width'] ?? m['length'] ?? 0), String(m['padding'] ?? m['pad'] ?? ' ')); });
    _r('string_char_at', (i: any) => { const m = _m(i); return String(m['value'] ?? m['string'] ?? '').charAt(Number(m['index'] ?? m['arg0'] ?? 0)); });
    _r('string_to_int', (i: any) => {
      const m = _m(i); const s = String(m['value'] ?? m['string'] ?? i ?? '').trim();
      // `.message` must be the bare invalid text (Dart's `FormatException.message`
      // is never prefixed with the type name — only `.toString()` adds that).
      // Setting `name: 'FormatException'` (not just a `message` override) lets
      // the default `Error.prototype.toString()` ("name: message") produce the
      // Dart-correct "FormatException: <text>" for anything that prints the
      // caught exception itself rather than `.message`. Previously the message
      // override clobbered the "FormatException: " prefix right back out,
      // leaving `.name` as the native "Error" — undetected because no
      // conformance fixture prints a caught FormatException directly.
      if (!/^-?\d+$/.test(s)) throw Object.assign(new Error(s), { name: 'FormatException', __type__: 'FormatException' });
      return parseInt(s, 10);
    });
    _r('writeCharCode', (i: any) => { const m = _m(i); const self = m['self']; if (typeof self === 'object' && self !== null) { self['__buffer__'] = (self['__buffer__'] ?? '') + String.fromCharCode(Number(m['arg0'] ?? m['value'] ?? 0)); } return null; });
    _r('write', (i: any) => { const m = _m(i); const self = m['self']; if (typeof self === 'object' && self !== null) { self['__buffer__'] = (self['__buffer__'] ?? '') + String(m['arg0'] ?? m['value'] ?? ''); } return null; });
  
    // ── Conversion ─────────────────────────────────────────────────────
    _r('to_double', (i: any) => _toDoubleValue(_m(i)['value'] ?? _m(i)['arg0'] ?? i));
    _r('int_to_double', (i: any) => _toDoubleValue(_m(i)['value'] ?? _m(i)['arg0'] ?? i));
    _r('to_int', (i: any) => _toIntValue(_m(i)['value'] ?? _m(i)['arg0'] ?? i));
    _r('double_to_int', (i: any) => _toIntValue(_m(i)['value'] ?? _m(i)['arg0'] ?? i));
    _r('to_string', (i: any) => {
      const m = _m(i);
      let v = Object.prototype.hasOwnProperty.call(m, 'value') ? m['value'] : i;
      const BD = (globalThis as any).BallDouble;
      while (v != null && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Set) && !(v instanceof Map)) {
        if (BD && v instanceof BD) break;
        const keys = Object.keys(v).filter((k: string) => !k.startsWith('__'));
        if (keys.length === 1 && keys[0] === 'value' && Object.prototype.hasOwnProperty.call(v, 'value')) {
          v = v['value'];
          continue;
        }
        break;
      }
      return __bts(v);
    });
    _r('equals', (i: any) => {
      const m = _m(i);
      const a = m['left'] ?? m['value'] ?? m['arg0'];
      const b = m['right'] ?? m['other'] ?? m['arg1'];
      const BD = (globalThis as any).BallDouble;
      const unwrap = (v: any) => (BD && v instanceof BD) ? v.value : v;
      const av = unwrap(a);
      const bv = unwrap(b);
      if (typeof av === 'number' && typeof bv === 'number') {
        if (Number.isNaN(av) || Number.isNaN(bv)) return false;
        return av === bv;
      }
      if (av === bv) return true;
      if (av != null && bv != null) return __bts(av) === __bts(bv);
      return false;
    });
    _r('not_equals', (i: any) => {
      const m = _m(i);
      const a = m['left'] ?? m['value'] ?? m['arg0'];
      const b = m['right'] ?? m['other'] ?? m['arg1'];
      const BD = (globalThis as any).BallDouble;
      const unwrap = (v: any) => (BD && v instanceof BD) ? v.value : v;
      const av = unwrap(a);
      const bv = unwrap(b);
      if (typeof av === 'number' && typeof bv === 'number') {
        if (Number.isNaN(av) || Number.isNaN(bv)) return true;
        return av !== bv;
      }
      if (av === bv) return false;
      if (av != null && bv != null) return __bts(av) !== __bts(bv);
      return true;
    });
    _r('concat', (i: any) => { const m = _m(i); return String(m['left'] ?? '') + String(m['right'] ?? ''); });
    // `?? i` (used by most unary helpers below) can't distinguish "no `value`
    // field" from "`value` is explicitly null" — for every OTHER helper that's
    // harmless (a null numeric/string arg just coerces away), but for
    // null_check it inverts the function's entire purpose: `x!` where `x` is
    // null must throw (matches the Dart engine's `_extractUnaryArg` + null
    // check — see engine_std.dart's 'null_check' and its
    // "throws BallRuntimeError on null" test), yet `m['value'] ?? i` silently
    // fell back to the (truthy) input map and returned it instead of
    // throwing. hasOwnProperty-gate so an explicit null is honored.
    _r('null_check', (i: any) => {
      const m = _m(i);
      const v = Object.prototype.hasOwnProperty.call(m, 'value') ? m['value'] : i;
      if (v == null) throw new Error('Null check operator used on a null value');
      return v;
    });
    _r('compare_to', (i: any) => {
      const m = _m(i); const l = m['left'] ?? m['value'] ?? m['self'] ?? m['a'] ?? 0; const r = m['right'] ?? m['other'] ?? m['arg0'] ?? m['b'] ?? 0;
      if (typeof l === 'string' && typeof r === 'string') return l < r ? -1 : l > r ? 1 : 0;
      const [lv, rv] = _coerceNumPair(l, r);
      return lv < rv ? -1 : lv > rv ? 1 : 0;
    });
  
    // Dart / always returns double — wrap result in BallDouble
    _r('divide_double', (i: any) => {
      const m = _m(i);
      const l = Number(m['left'] ?? m['value'] ?? m['arg0'] ?? 0);
      const r = Number(m['right'] ?? m['other'] ?? m['arg1'] ?? 1);
      return _makeBallDouble(l / r);
    });
  
    // ── Math ───────────────────────────────────────────────────────────
    _r('math_abs', (i: any) => _mathAbs(_m(i)['value'] ?? 0));
    _r('math_max', (i: any) => { const m = _m(i); return Math.max(Number(m['left'] ?? m['a'] ?? 0), Number(m['right'] ?? m['b'] ?? 0)); });
    _r('math_min', (i: any) => { const m = _m(i); return Math.min(Number(m['left'] ?? m['a'] ?? 0), Number(m['right'] ?? m['b'] ?? 0)); });
    _r('math_sqrt', (i: any) => Math.sqrt(Number(_m(i)['value'] ?? 0)));
    _r('math_pow', (i: any) => { const m = _m(i); return Math.pow(Number(m['base'] ?? m['left'] ?? 0), Number(m['exponent'] ?? m['right'] ?? 0)); });
    // math_sign / math_is_infinite are registered here so a freshly regenerated
    // compiled_engine.ts (which emits them as base calls, not embedded impls)
    // stays self-consistent. Mirrors the Dart engine (engine_std.dart). See #47.
    _r('math_sign', (i: any) => Math.sign(Number(_m(i)['value'] ?? 0)));
    _r('math_is_infinite', (i: any) => { const v = Number(_m(i)['value'] ?? 0); return v === Infinity || v === -Infinity; });
  
    // ── Sort (method dispatch on list) ─────────────────────────────────
    _r('sort', async (i: any) => {
      const m = _m(i); const self = m['self'] ?? m['list'] ?? m['collection'];
      const fn = m['compare'] ?? m['comparator'] ?? m['function'] ?? m['value'] ?? m['arg0'];
      if (!Array.isArray(self)) return null;
      if (typeof fn === 'function') {
        async function ms(arr: any[]): Promise<any[]> {
          if (arr.length <= 1) return arr;
          const mid = Math.floor(arr.length / 2);
          const l = await ms(arr.slice(0, mid)), r = await ms(arr.slice(mid));
          const res: any[] = []; let li = 0, ri = 0;
          while (li < l.length && ri < r.length) {
            let c = fn({'arg0': l[li], 'arg1': r[ri], 'left': l[li], 'right': r[ri]});
            if (c?.then) c = await c;
            if ((typeof c === 'number' ? c : 0) <= 0) res.push(l[li++]); else res.push(r[ri++]);
          }
          while (li < l.length) res.push(l[li++]);
          while (ri < r.length) res.push(r[ri++]);
          return res;
        }
        const sorted = await ms([...self]);
        for (let si = 0; si < sorted.length; si++) self[si] = sorted[si];
      } else { self.sort((a: any, b: any) => a < b ? -1 : a > b ? 1 : 0); }
      return null;
    });
  
    // ── Static dispatch aliases ────────────────────────────────────────
    _r('generate', async (i: any) => {
      const m = _m(i); const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
      const gen = m['generator'] ?? m['function'] ?? m['arg1'] ?? m['value'];
      const result: any[] = [];
      if (typeof gen === 'function') { for (let j = 0; j < count; j++) { let r = gen(j); if (r?.then) r = await r; result.push(r); } }
      else { for (let j = 0; j < count; j++) result.push(null); }
      return result;
    });
    _r('filled', (i: any) => { const m = _m(i); return Array(Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0)).fill(m['value'] ?? m['fill'] ?? m['arg1'] ?? null); });
  
    // Override length — compiled engine's _stdLength misses map length
    _r('length', (i: any) => {
      const m = _m(i); const v = m['value'] ?? i;
      if (typeof v === 'string') return v.length;
      if (Array.isArray(v)) return v.length;
      if (v instanceof Set) return v.size;
      if (typeof v === 'object' && v !== null) return Object.keys(v).filter((k: string) => !k.startsWith('__')).length;
      return 0;
    });
  
    // Override map_keys/map_values/map_entries — the compiled version reads via a
    // `.entries` getter, which does not handle the proto3-JSON map shapes
    // (`{map}`/`{value}`/bare object) these overrides normalize here.
    _r('map_keys', (i: any) => { const m = _m(i); const map = m['map'] ?? m['value'] ?? i; if (typeof map !== 'object' || map === null) return []; return Object.keys(map).filter((k: string) => !k.startsWith('__')); });
    _r('map_values', (i: any) => { const m = _m(i); const map = m['map'] ?? m['value'] ?? i; if (typeof map !== 'object' || map === null) return []; return Object.entries(map).filter(([k]: any) => !k.startsWith('__')).map(([, v]: any) => v); });
    _r('map_entries', (i: any) => { const m = _m(i); const map = m['map'] ?? m['value'] ?? i; if (typeof map !== 'object' || map === null) return []; return Object.entries(map).filter(([k]: any) => !k.startsWith('__')).map(([k, v]: any) => ({key: k, value: v})); });
    _r('map_length', (i: any) => { const m = _m(i); const map = m['map'] ?? m['value'] ?? i; if (typeof map !== 'object' || map === null) return 0; return Object.keys(map).filter((k: string) => !k.startsWith('__')).length; });
    _r('map_from_entries', (i: any) => { const m = _m(i); const list = m['list'] ?? m['entries'] ?? m['value'] ?? []; if (!Array.isArray(list)) return {}; const r: any = {}; for (const e of list) { if (typeof e === 'object' && e !== null) { r[e.key ?? e.name ?? e.arg0 ?? e[0]] = e.value ?? e.arg1 ?? e[1]; } } return r; });
  
    // Override set operations
    _r('set_create', (i: any) => { const m = _m(i); const elements = m['elements']; if (Array.isArray(elements)) return new Set(elements); return new Set(); });
  
    // std.typed_list: a typed list literal `<T>[...]`. The type argument is
    // erased at runtime — the value is just the element array.
    _r('typed_list', (i: any) => { const m = _m(i); const elements = m['elements']; return Array.isArray(elements) ? elements : []; });
  
    // ── Async / Generator ──────────────────────────────────────────────
    //
    // std.await: unwrap BallFuture (simulated async result).
    // In a synchronous engine, BallFuture.value is always available.
    _r('await', async (i: any) => {
      const m = _m(i);
      let val = m['value'] ?? m['arg0'] ?? i;
      // Unwrap real JS Promises (from async lambda bodies)
      if (val && typeof val === 'object' && typeof val.then === 'function') val = await val;
      // Unwrap BallFuture (compiled engine's simulation)
      if (_isFutureLike(val)) return val.value;
      // Unwrap plain-object BallFuture markers
      if (val && typeof val === 'object' && val.__ball_future__ === true) return val.value;
      return val;
    });
  
    // std.yield: in generator context, the caller collects yields via _FlowSignal.
    // Outside generator context, just return the value.
    _r('yield', (i: any) => {
      const m = _m(i);
      return m['value'] ?? m['arg0'] ?? i;
    });
  
    // std.yield_each: flatten iterable yields.
    _r('yield_each', (i: any) => {
      const m = _m(i);
      const val = m['value'] ?? m['arg0'] ?? i;
      if (Array.isArray(val)) return val;
      return val;
    });
  
    // Override dart_list_generate (compiled version's lambda calling may fail).
    // These overrides shadow the compiled `_stdListFilled`/`_stdListGenerate`
    // implementations, which already track allocations — so they must charge
    // the allocation against the engine's memory accounting themselves
    // (maxMemoryBytes, #24).
    _r('dart_list_generate', async (i: any) => {
      const m = _m(i);
      const count = Number(m['count'] ?? m['arg0'] ?? 0);
      const gen = m['generator'] ?? m['arg1'];
      if (typeof gen !== 'function') return [];
      _track(Math.max(0, count | 0) * _ptrBytes);
      const result: any[] = [];
      for (let idx = 0; idx < count; idx++) {
        let v = gen(idx);
        if (v?.then) v = await v;
        result.push(v);
      }
      return result;
    });
    _r('dart_list_filled', (i: any) => {
      const m = _m(i);
      const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
      _track(Math.max(0, count | 0) * _ptrBytes);
      return Array(Math.max(0, count | 0)).fill(m['value'] ?? m['arg1'] ?? null);
    });
    _r('list_filled', (i: any) => {
      const m = _m(i);
      const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
      _track(Math.max(0, count | 0) * _ptrBytes);
      return Array(Math.max(0, count | 0)).fill(m['value'] ?? m['arg1'] ?? null);
    });
    _r('list_generate', (i: any) => {
      const m = _m(i);
      const count = Number(m['count'] ?? m['length'] ?? m['arg0'] ?? 0);
      const fn = m['function'] ?? m['generator'] ?? m['callback'] ?? m['value'];
      if (typeof fn !== 'function') return [];
      _track(Math.max(0, count | 0) * _ptrBytes);
      const out: any[] = [];
      for (let i2 = 0; i2 < count; i2++) {
        let r = fn(i2);
        out.push(r);
      }
      return out;
    });
  
    // std_time
    // NOTE: these override the compiled engine's native std_time handlers,
    // which reference a `DateTime` class that the (stale) committed engine
    // does not define. Implementing them here keeps std_time working without
    // depending on a preamble DateTime polyfill.
    _r('now', () => Date.now());
    _r('now_micros', () => Date.now() * 1000);
    _r('timestamp_ms', () => Date.now());
    _r('timestamp_micros', () => Date.now() * 1000);
    _r('format_timestamp', (i: any) => {
      const m = _m(i);
      const ms = Number(m['timestamp_ms'] ?? m['arg0'] ?? 0);
      return new Date(ms).toISOString();
    });
    _r('parse_timestamp', (i: any) => {
      const m = _m(i);
      const s = String(m['value'] ?? m['arg0'] ?? '');
      return Date.parse(s);
    });
    _r('duration_add', (i: any) => { const m = _m(i); return Number(m['left'] ?? m['arg0'] ?? 0) + Number(m['right'] ?? m['arg1'] ?? 0); });
    _r('duration_subtract', (i: any) => { const m = _m(i); return Number(m['left'] ?? m['arg0'] ?? 0) - Number(m['right'] ?? m['arg1'] ?? 0); });
    _r('year', () => new Date().getUTCFullYear());
    _r('month', () => new Date().getUTCMonth() + 1);
    _r('day', () => new Date().getUTCDate());
    _r('hour', () => new Date().getUTCHours());
    _r('minute', () => new Date().getUTCMinutes());
    _r('second', () => new Date().getUTCSeconds());
  
    // std_convert
    _r('json_encode', (i: any) => {
      const m = _m(i);
      const v = m['value'] ?? (m['arg0'] !== undefined ? m['arg0'] : i);
      return JSON.stringify(v);
    });
    _r('json_decode', (i: any) => {
      const m = _m(i);
      const s = String(m['value'] ?? m['arg0'] ?? '');
      return JSON.parse(s);
    });
    _r('utf8_encode', (i: any) => {
      const m = _m(i);
      const s = String(m['value'] ?? m['arg0'] ?? '');
      return Array.from(new TextEncoder().encode(s));
    });
    _r('utf8_decode', (i: any) => {
      const m = _m(i);
      const bytes = m['value'] ?? m['arg0'] ?? [];
      return new TextDecoder().decode(new Uint8Array(bytes));
    });
    _r('base64_encode', (i: any) => {
      const m = _m(i);
      const bytes = m['value'] ?? m['arg0'] ?? [];
      if (typeof Buffer !== 'undefined') return Buffer.from(bytes).toString('base64');
      return btoa(String.fromCharCode(...(bytes as number[])));
    });
    _r('base64_decode', (i: any) => {
      const m = _m(i);
      const s = String(m['value'] ?? m['arg0'] ?? '');
      if (typeof Buffer !== 'undefined') return Array.from(Buffer.from(s, 'base64'));
      return Array.from(atob(s), (c: any) => (c as string).charCodeAt(0));
    });
  }

  // ── BallFuture / BallGenerator helpers ─────────────────────────────────────
  //
  // BallFuture and BallGenerator are imported directly from the compiled engine
  // module. We use them for instanceof checks, constructor calls, and patching.
  
  /** Unwrap BallFuture/BallGenerator values for display and consumption. */
  function _unwrapBallValue(v: any): any {
    if (_isFutureLike(v)) return v.value;
    if (v instanceof BallGenerator) return v.values;
    if (v && typeof v === 'object' && v.__ball_future__ === true) return v.value;
    if (v && typeof v === 'object' && v.__ball_generator__ === true) return v.values;
    return v;
  }

  // ── Patch compiled engine for async/generator support ──────────────────────
  
  function patchCompiledEngine(engine: CompiledEngine): void {
    const e = engine as any;

    const origEvalFieldAccess = e._evalFieldAccess.bind(e);
    e._evalFieldAccess = async function(access: any, scope: any) {
      const object = await e._evalExpression(access.object, scope);
      const fieldName = access.field_2;
      const numResult = _numFieldAccess(object, fieldName);
      if (numResult !== undefined) return numResult;
      const collectionResult = _collectionFieldAccess(object, fieldName);
      if (collectionResult !== undefined) return collectionResult;
      return origEvalFieldAccess(access, scope);
    };

    e._toInt = function(v: any) { return _coerceInt(v); };
    e._toNum = function(v: any) { return _coerceNum(v); };

    const origStdBinary = e._stdBinary.bind(e);
    e._stdBinary = function(input: any, op: any) {
      const rec = e._extractBinaryArgs(input);
      const left = rec[0];
      const right = rec[1];
      const BD = (globalThis as any).BallDouble;
      const lBD = BD && left instanceof BD;
      const rBD = BD && right instanceof BD;
      const [l, r] = _coerceNumPair(left, right);
      const result = op(l, r);
      if ((lBD || rBD) && typeof result === 'number') return new BD(result);
      return result;
    };

    const origStdBinaryInt = e._stdBinaryInt.bind(e);
    e._stdBinaryInt = function(input: any, op: any) {
      const rec = e._extractBinaryArgs(input);
      const [l, r] = _coerceIntPair(rec[0], rec[1]);
      return op(l, r);
    };

    e._stdUnaryNum = function(input: any, op: any) {
      // Preserve BallDouble-ness through negate (#67): a whole-number
      // double like `-7.0` must not collapse to a bare JS integer. Mirrors
      // the _stdBinary patch above. bitwise_not (the only other consumer)
      // always operates on int, so it never sees a BallDouble operand here.
      const value = e._extractUnaryArg(input);
      const BD = (globalThis as any).BallDouble;
      const vBD = BD && value instanceof BD;
      const result = op(_coerceNum(value));
      if (vBD && typeof result === 'number') return new BD(result);
      return result;
    };

    e._stdBinaryComp = function(input: any, op: any) {
      const rec = e._extractBinaryArgs(input);
      const [l, r] = _coerceNumPair(rec[0], rec[1]);
      return op(l, r);
    };

    e._stdAdd = function(input: any) {
      const rec = e._extractBinaryArgs(input);
      const left = rec[0];
      const right = rec[1];
      if ((typeof left === 'string') || (typeof right === 'string')) {
        return (__bts(left ?? '') + __bts(right ?? ''));
      }
      const BD = (globalThis as any).BallDouble;
      const lBD = BD && left instanceof BD;
      const rBD = BD && right instanceof BD;
      if (typeof left === 'bigint' || typeof right === 'bigint' ||
          (typeof _coerceInt(left) === 'bigint') || (typeof _coerceInt(right) === 'bigint')) {
        const result = _int64Add(left, right);
        return (lBD || rBD) ? new BD(Number(result)) : result;
      }
      const [l, r] = _coerceNumPair(left, right);
      const result = l + r;
      if (lBD || rBD) {
        if (typeof result === 'bigint') return new BD(Number(result));
        return new BD(result);
      }
      return result;
    };

    // `remainder` is the one num instance method the compiled engine's own
    // `_dispatchBuiltinInstanceMethod` calls as a literal Dart method
    // (`self.remainder(...)`) rather than routing through a Math.*-backed
    // std function (floor/ceil/round/abs/truncate all get encoder-routed to
    // math_floor/math_ceil/etc, which is why they survive a BallDouble
    // receiver via valueOf() coercion). A BallDouble-wrapped receiver has no
    // `.remainder` method, so it throws (#115). Intercept just that case.
    const origDispatchBuiltinInstanceMethod = e._dispatchBuiltinInstanceMethod.bind(e);
    e._dispatchBuiltinInstanceMethod = async function(self: any, method: any, input: any) {
      const BD = (globalThis as any).BallDouble;
      if (BD && self instanceof BD && method === 'remainder') {
        const rec = e._cfAsMap(input) ?? {};
        const rawArg = rec['arg0'] ?? rec['value'];
        const other = (BD && rawArg instanceof BD) ? rawArg.value : _coerceNum(rawArg);
        return new BD(self.value % Number(other));
      }
      return origDispatchBuiltinInstanceMethod(self, method, input);
    };

    const origPatternKind = e._patternKind?.bind(e);
    e._patternKind = function(pattern: any): any {
      const explicit = pattern?.['__pattern_kind__'];
      if (explicit != null) return explicit;
      const type = pattern?.['__type__'] ?? pattern?.typeName;
      switch (type) {
        case 'VarPattern': return 'var';
        case 'WildcardPattern': return 'wildcard';
        case 'ConstPattern': return 'const';
        case 'ListPattern': return 'list';
        case 'MapPattern': return 'map';
        case 'RecordPattern': return 'record';
        case 'ObjectPattern': return 'object';
        case 'LogicalAndPattern': return 'logical_and';
        case 'LogicalOrPattern': return 'logical_or';
        case 'CastPattern': return 'cast';
        case 'NullCheckPattern': return 'null_check';
        case 'NullAssertPattern': return 'null_assert';
        case 'RelationalPattern': return 'relational';
        case 'RestPattern': return 'rest';
        default: return origPatternKind ? origPatternKind(pattern) : null;
      }
    };

    const origMatchPattern = e._matchPattern.bind(e);
    e._matchPattern = function(value: any, pattern: any, bindings: any) {
      if (pattern != null && typeof pattern === 'object') {
        const kind = e._patternKind(pattern);
        if (kind === 'map') {
          const entries = pattern.entries;
          if (Array.isArray(entries) && entries.some((entry: any) => Array.isArray(entry))) {
            pattern = { ...pattern, entries: entries.flat() };
          }
        }
        // Fix LogicalAndPattern binding propagation: the compiled engine's
        // logical_and handler does `bindings = __ball_concat(tempBindings, tempBindings)`
        // which reassigns the local variable instead of mutating the caller's
        // object. Override here to correctly propagate bindings.
        if (kind === 'logical_and') {
          const tempBindings: any = {};
          const leftMatch = e._matchPattern(value, pattern.left, tempBindings);
          if (!leftMatch) return false;
          const rightMatch = e._matchPattern(value, pattern.right, tempBindings);
          if (!rightMatch) return false;
          Object.assign(bindings, tempBindings);
          return true;
        }
        // Fix LogicalOrPattern binding propagation (same bug pattern)
        if (kind === 'logical_or') {
          const leftBindings: any = {};
          if (e._matchPattern(value, pattern.left, leftBindings)) {
            Object.assign(bindings, leftBindings);
            return true;
          }
          return e._matchPattern(value, pattern.right, bindings);
        }
      }
      return origMatchPattern(value, pattern, bindings);
    };

    e._matchesTypePattern = function(value: any, pattern: any): boolean {
      const BD = (globalThis as any).BallDouble;
      const p = typeof pattern === 'string'
        ? pattern
        : (e._ballToStringSimple ? e._ballToStringSimple(pattern) : String(pattern));
      // Nullable type `T?` matches null OR the base type. The no-space guard
      // stops raw fragments like "var v?" being read as a nullable type (which
      // would wrongly match null). Mirrors the Dart engine _matchesTypePattern.
      if (p.length > 1 && p.endsWith('?') && !p.includes(' ')) {
        if (value == null) return true;
        return e._matchesTypePattern(value, p.substring(0, p.length - 1));
      }
      switch (p) {
        case 'int':
          return typeof value === 'bigint' || (typeof value === 'number' && Number.isInteger(value));
        case 'double':
          return BD != null && value instanceof BD;
        case 'num':
          return typeof value === 'bigint' || typeof value === 'number' || (BD != null && value instanceof BD);
        case 'String':
          return typeof value === 'string';
        case 'bool':
          return typeof value === 'boolean';
        case 'List':
          return Array.isArray(value);
        case 'Map':
          return typeof value === 'object' && value !== null && !Array.isArray(value) && !(value instanceof Set);
        case 'Set':
          return value instanceof Set;
        case 'Object':
          return value != null;
        case 'dynamic':
          return true;
        case 'Null':
        case 'null':
          return value == null;
        default:
          return false;
      }
    };

    const origScopeWithPatternBindings = e._scopeWithPatternBindings.bind(e);
    e._scopeWithPatternBindings = function(parent: any, bindings: any) {
      if (bindings == null || typeof bindings !== 'object') return parent;
      const entries = Object.entries(bindings).filter(([k]) => !k.startsWith('__'));
      if (entries.length === 0) return parent;
      const child = parent.child();
      for (const [k, v] of entries) child.bind(k, v);
      return child;
    };

    e._stdMapCreate = function(input: any) {
      const m = e._stdAsMap(input);
      if (m == null) return {};
      const hop = Object.prototype.hasOwnProperty;
      const entries = hop.call(m, 'entries') ? m['entries'] : (hop.call(m, 'entry') ? m['entry'] : undefined);
      const result: any = {};
      const ingest = (entry: any) => {
        const entryMap = e._stdAsMap(entry);
        if (entryMap == null) return;
        const key = entryMap['key'] ?? entryMap['name'] ?? entryMap['arg0'] ?? '';
        result[String(key)] = entryMap['value'] ?? entryMap['arg1'];
      };
      if (Array.isArray(entries)) {
        for (const entry of entries) ingest(entry);
      } else if (entries != null && typeof entries === 'object') {
        ingest(entries);
      }
      return result;
    };

    const origBallEquals = e._ballEquals.bind(e);
    e._ballEquals = function(a: any, b: any) {
      const unwrap = (v: any) => {
        const BD = (globalThis as any).BallDouble;
        if (BD && v instanceof BD) return v.value;
        return v;
      };
      const av = unwrap(a);
      const bv = unwrap(b);
      if (typeof av === 'number' && typeof bv === 'number') {
        if (Number.isNaN(av) || Number.isNaN(bv)) return false;
        return av === bv;
      }
      return origBallEquals(a, b);
    };

    // Store the current generator on the engine instance so yield/yield_each
    // base functions can push values into it. This avoids scope-chain walking
    // since _callBaseFunction doesn't receive a scope parameter.
    e._currentGenerator = null;
  
    // Patch _callFunction to:
    // 1. Fix input binding bug: inside _callFunction, the compiled engine first
    //    binds 'input' to the correct extracted arg0 value, then re-binds 'input'
    //    to the raw input object, overwriting it. We fix this by extracting arg0
    //    before calling the original.
    // 2. Handle is_sync_star / is_async_star metadata (compiled engine only checks
    //    is_generator and is_async).
    // 3. Create BallGenerator scope for yield to push values into.
    // 4. Avoid double-wrapping BallFuture for async functions.
    const origCallFunction = e._callFunction.bind(e);
    e._callFunction = async function(moduleName: string, func: any, input: any, parentScope?: any) {
      if (!func || func.isBase || !func.body) {
        return origCallFunction(moduleName, func, input, parentScope);
      }
  
      // Fix input binding: for single-param functions with inputType, the compiled
      // engine binds 'input' twice — first to the extracted arg0 value (correct),
      // then to the raw input object (overwrites). We extract arg0 here and pass
      // it directly so both bindings get the same correct value.
      //
      // CRITICAL: never unwrap when `self` is present — that signals an instance
      // method call and the native _callFunction needs the full map to bind
      // `self` plus the instance fields onto the method scope. Unwrapping to the
      // bare arg0 dropped `self`, so methods saw `Undefined variable: <field>`.
      let fixedInput = input;
      if (func.inputType && func.inputType.isNotEmpty && typeof input === 'object' && input !== null && !Array.isArray(input)) {
        // Lambdas have an empty `func.name`, so the cache key `'<module>.'` is
        // shared by every lambda in the module — two lambdas would collide and
        // the second's params would overwrite the first's (#246). Only consult
        // the shared cache for named functions; extract a nameless function's
        // params directly from its own metadata.
        const params = (__bts(func.name).length > 0
          ? (e._paramCache[((__bts(moduleName) + '.') + __bts(func.name))]) ?? (func.metadata ? e._extractParams(func.metadata) : [])
          : (func.metadata ? e._extractParams(func.metadata) : []));
        if (params.length === 1) {
          const inputMap = e._asMap(input);
          if (inputMap && 'arg0' in inputMap && !(params[0] in inputMap) && !('self' in inputMap)) {
            fixedInput = inputMap['arg0'];
          }
        }
      }
  
      // Check for async/generator metadata
      let isAsync = false;
      let isSyncStar = false;
      let isAsyncStar = false;
      let isGenerator = false;
      if (func.metadata) {
        const fields = func.metadata?.fields;
        if (fields) {
          const getBool = (key: string) => {
            const v = fields[key];
            if (v == null) return false;
            if (typeof v === 'object' && v !== null) return !!v.boolValue;
            return !!v;
          };
          isAsync = getBool('is_async');
          isSyncStar = getBool('is_sync_star');
          isAsyncStar = getBool('is_async_star');
          isGenerator = getBool('is_generator');
        }
      }
      const isGenFunc = isSyncStar || isAsyncStar || isGenerator;
  
      // Generator functions are handled natively by the regenerated engine:
      // it creates a BallGenerator, binds it to scope as `__generator__`, and
      // `_evalYield`/`_evalYieldEach` walk the scope chain to push values into
      // it. We must NOT shadow that with our own engine-level `_currentGenerator`
      // (the old engine's mechanism) — doing so collected zero yields and
      // returned an empty list. Delegate straight to the native implementation.
      if (isGenFunc) {
        return origCallFunction(moduleName, func, fixedInput, parentScope);
      }
  
      let result = await origCallFunction(moduleName, func, fixedInput, parentScope);
  
      // Handle async function results.
      // The compiled engine's _callFunction already wraps async results in BallFuture.
      // We just need to ensure the result is properly unwrapped if it's a FlowSignal.
      if (isAsync) {
        // Unwrap FlowSignal if present
        if (result instanceof _FlowSignal && result.kind === 'return') {
          result = result.value;
        }
        // If already a BallFuture, return as-is (compiled engine already wrapped it)
        if (_isFutureLike(result)) {
          return result;
        }
        // Shouldn't happen, but wrap in BallFuture as fallback
        return new BallFuture(result, true);
      }
  
      return result;
    };
  
    // Patch _evalCall to auto-unwrap BallFuture values, matching the Dart engine's
    // _unwrapFuture behavior. Async functions return BallFuture(value), but callers
    // should receive the unwrapped value so async is transparent.
    const origEvalCall = e._evalCall.bind(e);
    e._evalCall = async function(call: any, scope: any) {
      const result = await origEvalCall(call, scope);
      // Auto-unwrap BallFuture so async functions are transparent to callers.
      if (_isFutureLike(result)) {
        return result.value;
      }
      return result;
    };
  
    // Patch _callBaseFunction to handle yield/yield_each/await.
    // yield: push value into current generator (stored on engine instance).
    // yield_each: push all values from iterable into current generator.
    // await: unwrap BallFuture (the compiled engine already does this, but we
    //        add a safety net for cases where it doesn't fire).
    const origCallBaseFunction = e._callBaseFunction.bind(e);
    e._callBaseFunction = function(moduleName: string, fn: string, input: any): any {
      // Handle yield — add value to current generator
      if (fn === 'yield') {
        const val = e._extractUnaryArg(input);
        const gen = e._currentGenerator;
        if (gen && gen instanceof BallGenerator) {
          gen.values.push(val);
        }
        return val;
      }
  
      // Handle yield_each — add all values from iterable to current generator
      if (fn === 'yield_each') {
        const iterable = e._extractUnaryArg(input);
        const gen = e._currentGenerator;
        if (gen && gen instanceof BallGenerator) {
          if (iterable instanceof BallGenerator) {
            gen.values.push(...iterable.values);
          } else if (Array.isArray(iterable)) {
            gen.values.push(...iterable);
          }
        }
        return iterable;
      }
  
      // Handle await — unwrap BallFuture
      if (fn === 'await') {
        const val = e._extractUnaryArg(input);
        if (_isFutureLike(val)) return val.value;
        return val;
      }
  
      return origCallBaseFunction(moduleName, fn, input);
    };
  
    // Patch _evalMessageCreation to avoid Object.prototype getter pollution.
    //
    // The preamble installs Dart-flavoured getters (`length`, `keys`, `values`,
    // `entries`) on Object.prototype so the compiled engine can call
    // `map.length` etc. The downside is that `('length' in {})` is now `true`,
    // and the compiled engine's `_evalMessageCreation` uses
    // `(pair.name in fields)` to detect duplicate field names. A single field
    // literally named `length` / `keys` / `values` / `entries` therefore trips
    // the "merge duplicates into a list" path and becomes `[<getterValue>, v]`
    // (e.g. `List.filled(length: 3, ...)` arrives as `length: [0, 3]`).
    //
    // We override the field-collection step to use a null-prototype object plus
    // hasOwnProperty, then hand the cleaned field map to the original method's
    // typeName/constructor dispatch by re-binding `_evalExpression` to a no-op
    // lookup over the already-evaluated values. To keep the heavy dispatch logic
    // in one place we instead pre-evaluate here and delegate via a synthetic
    // message whose field values are pre-computed literals.
    const _POLLUTED_KEYS = new Set(['length', 'keys', 'values', 'entries']);
    const origEvalMessageCreation = e._evalMessageCreation.bind(e);
    e._evalMessageCreation = async function(msg: any, scope: any) {
      const rawFields = msg?.fields ?? [];
      const typeName = msg?.typeName ?? '';
      // The bug only bites a typeName-less message (a plain std/base-function
      // input map) whose field is named with a polluted key. Those never go
      // through the heavy constructor/dispatch tail — they return the field map
      // directly — so we can safely build a clean (null-proto) map here.
      const hasPollutedField = rawFields.some(
        (p: any) => _POLLUTED_KEYS.has(p?.name),
      );
      if (typeName !== '' || !hasPollutedField) {
        return origEvalMessageCreation(msg, scope);
      }
      // Mirror the engine's duplicate-merge rule but with hasOwnProperty so the
      // inherited Dart getters never produce a false positive.
      const fields: any = Object.create(null);
      const hop = Object.prototype.hasOwnProperty;
      for (const pair of rawFields) {
        const val = await e._evalExpression(pair.value, scope);
        if (hop.call(fields, pair.name)) {
          const existing = fields[pair.name];
          fields[pair.name] = Array.isArray(existing) ? [...existing, val] : [existing, val];
        } else {
          fields[pair.name] = val;
        }
      }
      return fields;
    };
  
    // Fix BallGenerator.yieldAll — the compiled engine's version replaces
    // values with an empty array instead of appending items.
    const proto = BallGenerator.prototype;
    if (proto && typeof proto.yieldAll === 'function') {
      proto.yieldAll = function(items: any) {
        if (Array.isArray(items)) {
          this.values.push(...items);
        } else if (items && typeof items[Symbol.iterator] === 'function') {
          for (const item of items) this.values.push(item);
        }
        return this.values;
      };
    }
  
    // Patch __bts (ball-to-string) to unwrap BallFuture/BallGenerator, IF the
    // compiled engine has installed one on globalThis. As of the current
    // compiled_engine.ts, it never does (grepped: zero assignments to
    // globalThis.__bts) — this is a defensive no-op guarding against a future
    // preamble that starts exposing one, not an active code path today.
    const origBts = (globalThis as any).__bts;
    if (typeof origBts === 'function') {
      (globalThis as any).__bts = function(v: any): string {
        const unwrapped = _unwrapBallValue(v);
        if (unwrapped !== v) return origBts(unwrapped);
        return origBts(v);
      };
    }

    for (const handler of (e.moduleHandlers ?? [])) {
      if (handler == null || typeof handler.register !== 'function') continue;
      handler.register('add', (i: any) => e._stdAdd(i));
      handler.register('subtract', (i: any) => {
        const rec = e._extractBinaryArgs(i);
        const left = rec[0];
        const right = rec[1];
        const BD = (globalThis as any).BallDouble;
        const lBD = BD && left instanceof BD;
        const rBD = BD && right instanceof BD;
        if (!lBD && !rBD && (typeof _coerceInt(left) === 'bigint' || typeof _coerceInt(right) === 'bigint')) {
          return _int64Subtract(left, right);
        }
        return e._stdBinary(i, (a: any, b: any) => a - b);
      });
      handler.register('multiply', (i: any) => {
        const rec = e._extractBinaryArgs(i);
        const left = rec[0];
        const right = rec[1];
        // Polymorphic over strings: `'ab' * 3` repeats (Dart String * int).
        if (typeof left === 'string') return left.repeat(Number(right));
        const BD = (globalThis as any).BallDouble;
        const lBD = BD && left instanceof BD;
        const rBD = BD && right instanceof BD;
        if (!lBD && !rBD && (typeof _coerceInt(left) === 'bigint' || typeof _coerceInt(right) === 'bigint')) {
          return _int64Multiply(left, right);
        }
        return e._stdBinary(i, (a: any, b: any) => a * b);
      });
      handler.register('divide', (i: any) => {
        const rec = e._extractBinaryArgs(i);
        return _int64Divide(rec[0], rec[1]);
      });
      handler.register('modulo', (i: any) => {
        const rec = e._extractBinaryArgs(i);
        return _int64Modulo(rec[0], rec[1]);
      });
      handler.register('negate', (i: any) => {
        // `_int64Negate` unconditionally coerces through `_coerceInt` (it's
        // the int64-safe path for `bigint`-magnitude values), which silently
        // truncated a double operand to an int — losing double-ness for
        // e.g. `-7.0` (#67). Route a BallDouble operand through double
        // negation instead; only a genuine int reaches `_int64Negate`.
        const value = e._extractUnaryArg(i);
        const BD = (globalThis as any).BallDouble;
        if (BD && value instanceof BD) return new BD(-value.value);
        return _int64Negate(value);
      });
      handler.register('bitwise_and', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64Binary((l, r) => l & r, a, b)));
      handler.register('bitwise_or', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64Binary((l, r) => l | r, a, b)));
      handler.register('bitwise_xor', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64Binary((l, r) => l ^ r, a, b)));
      handler.register('bitwise_not', (i: any) => e._stdUnaryNum(i, (v: any) => _int64Unary((x) => ~x, v)));
      handler.register('left_shift', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64ShiftLeft(a, b)));
      handler.register('right_shift', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64ShiftRight(a, b)));
      handler.register('unsigned_right_shift', (i: any) => e._stdBinaryInt(i, (a: any, b: any) => _int64UnsignedShiftRight(a, b)));
      handler.register('math_abs', (i: any) => _mathAbs(e._extractUnaryArg(i)));
      handler.register('less_than', (i: any) => e._stdBinaryComp(i, (a: any, b: any) => a < b));
      handler.register('greater_than', (i: any) => e._stdBinaryComp(i, (a: any, b: any) => a > b));
      handler.register('lte', (i: any) => e._stdBinaryComp(i, (a: any, b: any) => a <= b));
      handler.register('gte', (i: any) => e._stdBinaryComp(i, (a: any, b: any) => a >= b));
      handler.register('map_create', (i: any) => e._stdMapCreate(i));
    }
  }

  // ── Seed global scope ──────────────────────────────────────────────────────
  
  function seedGlobalScope(engine: CompiledEngine): void {
    const gs = (engine as any)._globalScope;
    if (!gs || !gs.bind) return;
  
    gs.bind('List', {'__class_ref__': 'List', '__type__': '__builtin_class__'});
    gs.bind('Map', {'__class_ref__': 'Map', '__type__': '__builtin_class__'});
    gs.bind('Set', {'__class_ref__': 'Set', '__type__': '__builtin_class__'});
    gs.bind('RegExp', {'__class_ref__': 'RegExp', '__type__': '__builtin_class__'});
    gs.bind('DateTime', {'__class_ref__': 'DateTime', '__type__': '__builtin_class__'});
    gs.bind('Duration', {'__class_ref__': 'Duration', '__type__': '__builtin_class__'});
    gs.bind('identical', (input: any) => {
      if (input && typeof input === 'object' && !Array.isArray(input)) {
        const a = input['arg0'] ?? input['left'] ?? input['a'];
        const b = input['arg1'] ?? input['right'] ?? input['b'];
        return a === b;
      }
      return false;
    });
  }


  // ── Scope-binding patch ────────────────────────────────────────────────
  //
  // Replace each scope's _bindings with a null-prototype object so the
  // Dart-flavoured getters the preamble installs on Object.prototype
  // (length/keys/values/entries) do not pollute `in` checks.
  function patchScopeBindings(globalScope: any): void {
    const sp = Object.getPrototypeOf(globalScope);
    if (!sp || sp.__bindings_patched) return;
    const origBind = sp.bind;
    sp.bind = function(name: any, value: any) {
      if (Object.getPrototypeOf(this._bindings) !== null) {
        const e = Object.entries(this._bindings);
        this._bindings = Object.create(null);
        for (const [k, v] of e) this._bindings[k] = v;
      }
      return (this._bindings[name] = value);
    };
    const origChild = sp.child;
    if (origChild) {
      sp.child = function() {
        const c = origChild.call(this);
        if (c._bindings && Object.getPrototypeOf(c._bindings) !== null) {
          c._bindings = Object.create(null);
        }
        return c;
      };
    }
    sp.__bindings_patched = true;
  }

  return {
    protoWrap,
    wrapValue,
    __bts,
    BallFuture,
    MethodDispatchHandler,
    registerExtraStdFunctions,
    patchCompiledEngine,
    seedGlobalScope,
    patchScopeBindings,
    _isFutureLike,
    _unwrapBallValue,
  };
}
