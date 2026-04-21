/**
 * Ball TypeScript Engine — interprets Ball programs directly from JSON.
 *
 * Runs in Node.js and browsers. No protobuf dependency — works with
 * proto3 JSON representation of Ball programs.
 *
 * Usage:
 *   import { BallEngine } from '@ball-lang/engine';
 *   const engine = new BallEngine(programJson, { stdout: console.log });
 *   engine.run();
 */

// ── Types ───────────────────────────────────────────────────────────────────

type BallValue = any;
type BallFunction = (input: BallValue) => BallValue;

interface Program {
  name?: string;
  version?: string;
  modules: Module[];
  entryModule: string;
  entryFunction: string;
}

interface Module {
  name: string;
  functions: FunctionDef[];
  moduleImports?: ModuleImport[];
}

interface ModuleImport {
  name: string;
}

interface FunctionDef {
  name: string;
  isBase?: boolean;
  body?: Expression;
  outputType?: string;
  metadata?: Record<string, any>;
}

interface Expression {
  call?: FunctionCall;
  literal?: Literal;
  reference?: { name: string };
  fieldAccess?: { object: Expression; field: string };
  messageCreation?: { fields: FieldValuePair[] };
  block?: Block;
  lambda?: Lambda;
}

interface FunctionCall {
  module?: string;
  function: string;
  input?: Expression;
}

interface Literal {
  intValue?: string | number;
  doubleValue?: number;
  stringValue?: string;
  boolValue?: boolean;
  listValue?: { elements: Expression[] };
}

interface FieldValuePair {
  name: string;
  value: Expression;
}

interface Block {
  statements: Statement[];
  result?: Expression;
}

interface Statement {
  let?: { name: string; value: Expression; metadata?: Record<string, any> };
  expression?: Expression;
}

interface Lambda {
  body: Expression;
  metadata?: Record<string, any>;
}

// ── Flow signals ────────────────────────────────────────────────────────────

class FlowSignal {
  kind: string;
  value?: BallValue;
  label?: string;
  constructor(kind: string, value?: BallValue, label?: string) {
    this.kind = kind;
    this.value = value;
    this.label = label;
  }
}

class BallException {
  typeName: string;
  value: BallValue;
  constructor(typeName: string, value: BallValue) {
    this.typeName = typeName;
    this.value = value;
  }
}

class BallRuntimeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BallRuntimeError';
  }
}

/**
 * Wrapper for double values that need to display with a decimal point.
 * Behaves like a number in arithmetic (via valueOf) but prints as "X.0"
 * when the value is integral.
 */
class BallDouble {
  readonly value: number;
  constructor(value: number) { this.value = value; }
  valueOf(): number { return this.value; }
  toString(): string {
    if (Number.isInteger(this.value) && isFinite(this.value)) return this.value.toFixed(1);
    return this.value.toString();
  }
}

// ── Scope ───────────────────────────────────────────────────────────────────

class Scope {
  private bindings = new Map<string, BallValue>();
  private parent?: Scope;
  constructor(parent?: Scope) {
    this.parent = parent;
  }

  bind(name: string, value: BallValue): void {
    this.bindings.set(name, value);
  }

  has(name: string): boolean {
    return this.bindings.has(name) || (this.parent?.has(name) ?? false);
  }

  lookup(name: string): BallValue {
    if (this.bindings.has(name)) return this.bindings.get(name);
    if (this.parent) return this.parent.lookup(name);
    throw new BallRuntimeError(`Undefined variable: "${name}"`);
  }

  assign(name: string, value: BallValue): void {
    if (this.bindings.has(name)) {
      this.bindings.set(name, value);
      return;
    }
    if (this.parent) {
      this.parent.assign(name, value);
      return;
    }
    throw new BallRuntimeError(`Cannot assign to undefined variable: "${name}"`);
  }

  child(): Scope {
    return new Scope(this);
  }
}

// ── Engine ──────────────────────────────────────────────────────────────────

export interface BallEngineOptions {
  stdout?: (msg: string) => void;
  stderr?: (msg: string) => void;
}

export class BallEngine {
  private program: Program;
  private stdout: (msg: string) => void;
  private stderr: (msg: string) => void;
  private functions = new Map<string, FunctionDef>();
  private constructors = new Map<string, { module: string; fn: FunctionDef }>();
  private enumValues = new Map<string, Record<string, Record<string, BallValue>>>();
  private topLevelVars = new Map<string, BallValue>();
  private currentModule = '';
  private activeException: any = null;
  private output: string[] = [];

  constructor(program: Program | string, options: BallEngineOptions = {}) {
    this.program = typeof program === 'string' ? JSON.parse(program) : program;
    this.stdout = options.stdout ?? ((msg) => this.output.push(msg));
    this.stderr = options.stderr ?? (() => {});
    this.buildLookupTables();
  }

  private buildLookupTables(): void {
    for (const mod of this.program.modules) {
      // Index enum types from module (if present).
      const enums = (mod as any).enums;
      if (Array.isArray(enums)) {
        for (const enumDesc of enums) {
          const enumName: string = enumDesc.name; // e.g. "main:Color"
          const values: Record<string, Record<string, BallValue>> = {};
          for (const v of (enumDesc.value ?? enumDesc.values ?? [])) {
            values[v.name] = { __type__: enumName, name: v.name, index: v.number ?? v.index ?? 0 };
          }
          this.enumValues.set(enumName, values);
          const ec = enumName.indexOf(':');
          if (ec >= 0) this.enumValues.set(enumName.substring(ec + 1), values);
        }
      }

      for (const fn of mod.functions) {
        this.functions.set(`${mod.name}.${fn.name}`, fn);

        // Register constructors (metadata.kind === "constructor").
        const kind = fn.metadata?.kind;
        if (kind === 'constructor') {
          const entry = { module: mod.name, fn };
          // fn.name is "ClassName.new" or "ClassName.named".
          const dotIdx = fn.name.indexOf('.');
          if (dotIdx >= 0) {
            const className = fn.name.substring(0, dotIdx);
            const ctorSuffix = fn.name.substring(dotIdx + 1);
            if (ctorSuffix === 'new') {
              this.constructors.set(className, entry);
              this.constructors.set(`${mod.name}:${className}`, entry);
            }
            this.constructors.set(fn.name, entry);
          }
        }
      }
    }
  }

  run(): string[] {
    const key = `${this.program.entryModule}.${this.program.entryFunction}`;
    const fn = this.functions.get(key);
    if (!fn) throw new BallRuntimeError(`Entry function "${key}" not found`);

    const scope = new Scope();
    this.currentModule = this.program.entryModule;

    // Initialize top-level variables in root scope.
    for (const mod of this.program.modules) {
      for (const f of mod.functions) {
        if (f.metadata?.kind === 'top_level_variable' && f.body) {
          const prevMod = this.currentModule;
          this.currentModule = mod.name;
          const val = this.evalExpr(f.body, scope);
          const cacheKey = `${mod.name}.${f.name}`;
          this.topLevelVars.set(cacheKey, val);
          scope.bind(f.name, val);
          this.currentModule = prevMod;
        }
      }
    }

    const result = this.callFunction(this.program.entryModule, fn, null, scope);

    if (result instanceof FlowSignal && result.kind === 'return') {
      return this.output;
    }
    return this.output;
  }

  getOutput(): string[] {
    return this.output;
  }

  // ── Expression evaluation ─────────────────────────────────────────────

  private evalExpr(expr: Expression, scope: Scope): BallValue {
    if (expr.call) return this.evalCall(expr.call, scope);
    if (expr.literal) return this.evalLiteral(expr.literal, scope);
    if (expr.reference) return this.evalReference(expr.reference, scope);
    if (expr.fieldAccess) return this.evalFieldAccess(expr.fieldAccess, scope);
    if (expr.messageCreation) return this.evalMessageCreation(expr.messageCreation, scope);
    if (expr.block) return this.evalBlock(expr.block, scope);
    if (expr.lambda) return this.evalLambda(expr.lambda, scope);
    return null;
  }

  private evalCall(call: FunctionCall, scope: Scope): BallValue {
    const moduleName = call.module || this.currentModule;

    // Lazy control flow
    if (moduleName === 'std' || moduleName === 'dart_std') {
      switch (call.function) {
        case 'if': return this.evalLazyIf(call, scope);
        case 'for': return this.evalLazyFor(call, scope);
        case 'for_in': return this.evalLazyForIn(call, scope);
        case 'while': return this.evalLazyWhile(call, scope);
        case 'do_while': return this.evalLazyDoWhile(call, scope);
        case 'switch': return this.evalLazySwitch(call, scope);
        case 'try': return this.evalLazyTry(call, scope);
        case 'and': return this.evalShortCircuitAnd(call, scope);
        case 'or': return this.evalShortCircuitOr(call, scope);
        case 'return': return this.evalReturn(call, scope);
        case 'break': return new FlowSignal('break', undefined, this.lazyStringField(call, 'label'));
        case 'continue': return new FlowSignal('continue', undefined, this.lazyStringField(call, 'label'));
        case 'assign': return this.evalAssign(call, scope);
        case 'labeled': return this.evalLabeled(call, scope);
        case 'pre_increment': case 'post_increment':
        case 'pre_decrement': case 'post_decrement':
          return this.evalIncDec(call, scope);
        case 'map_create': return this.evalMapCreate(call, scope);
      }
    }

    // Eager evaluation
    const input = call.input ? this.evalExpr(call.input, scope) : null;

    // Fast path for explicit std calls
    if (call.module === 'std' || call.module === 'dart_std') {
      return this.callBaseFunction(call.module, call.function, input);
    }

    // Method call on object (has 'self' field) — instance method dispatch.
    if (input && typeof input === 'object' && !Array.isArray(input) && 'self' in input) {
      const self = input.self;

      // Runtime method dispatch for built-in types (arrays, strings, numbers, maps).
      const methodResult = this.dispatchBuiltinMethod(call.function, self, input);
      if (methodResult !== undefined) return methodResult;

      if (self && typeof self === 'object' && !Array.isArray(self)) {
        const typeName: string | undefined = self.__type__;
        if (typeName) {
          const colonIdx = typeName.indexOf(':');
          const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : this.currentModule;
          // Try ClassName.methodName
          const methodKey = `${modPart}.${typeName}.${call.function}`;
          const method = this.functions.get(methodKey);
          if (method) return this.callFunction(modPart, method, input, scope);
          // Walk __super__ chain for inherited methods.
          let superObj = self.__super__;
          while (superObj && typeof superObj === 'object' && !Array.isArray(superObj)) {
            const superType: string | undefined = superObj.__type__;
            if (superType) {
              const sColonIdx = superType.indexOf(':');
              const sModPart = sColonIdx >= 0 ? superType.substring(0, sColonIdx) : modPart;
              const sTypeName = sColonIdx >= 0 ? superType : `${sModPart}:${superType}`;
              const superMethodKey = `${sModPart}.${sTypeName}.${call.function}`;
              const superMethod = this.functions.get(superMethodKey);
              if (superMethod) return this.callFunction(sModPart, superMethod, input, scope);
            }
            superObj = superObj.__super__;
          }
        }
      }
      // Fall through to normal resolution if no method found on the type.
    }

    const key = `${moduleName}.${call.function}`;
    const fn = this.functions.get(key);
    if (fn?.isBase) return this.callBaseFunction(moduleName, call.function, input);

    // Scope closure lookup
    if (!call.module && scope.has(call.function)) {
      const bound = scope.lookup(call.function);
      if (typeof bound === 'function') return bound(input);
    }

    // Module function lookup
    if (fn) return this.callFunction(moduleName, fn, input, scope);

    // Fallback: scan all modules
    for (const mod of this.program.modules) {
      for (const f of mod.functions) {
        if (f.name === call.function) {
          return this.callFunction(mod.name, f, input, scope);
        }
      }
    }

    throw new BallRuntimeError(`Function "${key}" not found`);
  }

  private callFunction(moduleName: string, fn: FunctionDef, input: BallValue, parentScope: Scope): BallValue {
    if (fn.isBase) return this.callBaseFunction(moduleName, fn.name, input);
    if (!fn.body) return null;

    // Top-level variables: compute once and cache.
    if (fn.metadata?.kind === 'top_level_variable') {
      const key = `${moduleName}.${fn.name}`;
      if (this.topLevelVars.has(key)) return this.topLevelVars.get(key);
      const val = this.evalExpr(fn.body, parentScope);
      this.topLevelVars.set(key, val);
      return val;
    }

    const prevModule = this.currentModule;
    this.currentModule = moduleName;

    const fnScope = parentScope.child();
    fnScope.bind('input', input);

    // Bind 'self' for instance method calls so `this` references resolve.
    if (input && typeof input === 'object' && !Array.isArray(input) && 'self' in input) {
      fnScope.bind('self', input.self);
    }

    // Destructure input fields as named parameters
    const params = fn.metadata?.params;
    if (params && Array.isArray(params)) {
      if (params.length === 1 && (input === null || input === undefined || typeof input !== 'object' || Array.isArray(input))) {
        // Single-param function with non-object input: bind directly
        const name = typeof params[0] === 'string' ? params[0] : params[0].name;
        if (name) fnScope.bind(name, input);
      } else if (input && typeof input === 'object' && !Array.isArray(input)) {
        for (let i = 0; i < params.length; i++) {
          const p = params[i];
          const name = typeof p === 'string' ? p : p.name;
          if (!name) continue;
          if (name in input) {
            fnScope.bind(name, input[name]);
          } else if (`arg${i}` in input) {
            fnScope.bind(name, input[`arg${i}`]);
          }
        }
      }
    }

    let result = this.evalExpr(fn.body, fnScope);
    this.currentModule = prevModule;

    if (result instanceof FlowSignal && result.kind === 'return') {
      return result.value;
    }
    return result;
  }

  // ── Literals ──────────────────────────────────────────────────────────

  private evalLiteral(lit: Literal, scope: Scope): BallValue {
    if (lit.intValue !== undefined) return typeof lit.intValue === 'string' ? parseInt(lit.intValue) : lit.intValue;
    if (lit.doubleValue !== undefined) return lit.doubleValue;
    if (lit.stringValue !== undefined) return lit.stringValue;
    if (lit.boolValue !== undefined) return lit.boolValue;
    if (lit.listValue) return (lit.listValue.elements ?? []).map(e => this.evalExpr(e, scope));
    return null;
  }

  private evalReference(ref: { name: string }, scope: Scope): BallValue {
    const name = ref.name;
    if (scope.has(name)) return scope.lookup(name);

    // Constructor tear-off: resolve class names to callable closures.
    const ctorEntry = this.constructors.get(name);
    if (ctorEntry) {
      return (input: BallValue) => this.callFunction(ctorEntry.module, ctorEntry.fn, input, scope);
    }

    // Try stripping module prefix (e.g. "main:Foo" -> "Foo").
    const colonIdx = name.indexOf(':');
    if (colonIdx >= 0) {
      const bare = name.substring(colonIdx + 1);
      const bareEntry = this.constructors.get(bare);
      if (bareEntry) {
        return (input: BallValue) => this.callFunction(bareEntry.module, bareEntry.fn, input, scope);
      }
    }

    // Enum type reference: resolve to a map of enum values.
    const enumVals = this.enumValues.get(name);
    if (enumVals) return enumVals;

    // Built-in type references (used as static method receivers like List.filled).
    if (name === 'List' || name === 'Map' || name === 'Set' || name === 'String' || name === 'int' || name === 'double' || name === 'num') {
      return { __builtin_type__: name };
    }

    // Try scope lookup first, then fall back to top-level var / function references.
    if (scope.has(name)) return scope.lookup(name);

    // Top-level variable or function reference: look up by name across modules.
    for (const mod of this.program.modules) {
      for (const f of mod.functions) {
        if (f.name === name && !f.isBase) {
          if (f.metadata?.kind === 'top_level_variable') {
            return this.callFunction(mod.name, f, null, scope);
          }
        }
      }
    }

    return scope.lookup(name);
  }

  private evalFieldAccess(fa: { object: Expression; field: string }, scope: Scope): BallValue {
    const obj = this.evalExpr(fa.object, scope);
    // Handle string properties
    if (typeof obj === 'string') {
      switch (fa.field) {
        case 'length': return obj.length;
        case 'isEmpty': return obj.length === 0;
        case 'isNotEmpty': return obj.length > 0;
      }
      return null;
    }
    // Handle number properties
    if (typeof obj === 'number' || obj instanceof BallDouble) {
      const n = typeof obj === 'number' ? obj : obj.value;
      switch (fa.field) {
        case 'isNaN': return isNaN(n);
        case 'isFinite': return isFinite(n);
        case 'isNegative': return n < 0;
        case 'isInfinite': return !isFinite(n) && !isNaN(n);
        case 'sign': return n > 0 ? 1 : n < 0 ? -1 : 0;
      }
      return null;
    }
    // Handle array properties
    if (Array.isArray(obj)) {
      switch (fa.field) {
        case 'length': return obj.length;
        case 'isEmpty': return obj.length === 0;
        case 'isNotEmpty': return obj.length > 0;
        case 'first': return obj[0];
        case 'last': return obj[obj.length - 1];
        case 'reversed': return [...obj].reverse();
      }
      return null;
    }
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
      if (fa.field in obj) return obj[fa.field];
      // Map-level property access.
      switch (fa.field) {
        case 'length': return Object.keys(obj).length;
        case 'isEmpty': return Object.keys(obj).length === 0;
        case 'isNotEmpty': return Object.keys(obj).length > 0;
        case 'keys': return Object.keys(obj);
        case 'values': return Object.values(obj);
        case 'entries': return Object.entries(obj).map(([k, v]) => ({ key: k, value: v }));
      }
      // Walk __super__ chain for inherited fields.
      let superObj = obj.__super__;
      while (superObj && typeof superObj === 'object' && !Array.isArray(superObj)) {
        if (fa.field in superObj) return superObj[fa.field];
        superObj = superObj.__super__;
      }
    }
    return null;
  }

  private evalMessageCreation(mc: { fields: FieldValuePair[] }, scope: Scope): BallValue {
    const result: Record<string, BallValue> = {};
    for (const f of mc.fields) {
      result[f.name] = this.evalExpr(f.value, scope);
    }
    return result;
  }

  private evalBlock(block: Block, scope: Scope): BallValue {
    const blockScope = scope.child();
    let lastResult: BallValue = null;

    for (const stmt of block.statements) {
      if (stmt.let) {
        const val = this.evalExpr(stmt.let.value, blockScope);
        if (val instanceof FlowSignal) return val;
        blockScope.bind(stmt.let.name, val);
      }
      if (stmt.expression) {
        lastResult = this.evalExpr(stmt.expression, blockScope);
        if (lastResult instanceof FlowSignal) return lastResult;
      }
    }

    if (block.result) {
      lastResult = this.evalExpr(block.result, blockScope);
    }
    return lastResult;
  }

  private evalLambda(lambda: Lambda, scope: Scope): BallValue {
    return (input: BallValue) => {
      const lambdaScope = scope.child();
      lambdaScope.bind('input', input);
      const params = lambda.metadata?.params;
      if (params && Array.isArray(params)) {
        if (params.length === 1 && (input === null || input === undefined || typeof input !== 'object' || Array.isArray(input))) {
          const name = typeof params[0] === 'string' ? params[0] : params[0].name;
          if (name) lambdaScope.bind(name, input);
        } else if (input && typeof input === 'object' && !Array.isArray(input)) {
          for (let i = 0; i < params.length; i++) {
            const p = params[i];
            const name = typeof p === 'string' ? p : p.name;
            if (!name) continue;
            if (name in input) {
              lambdaScope.bind(name, input[name]);
            } else if (`arg${i}` in input) {
              lambdaScope.bind(name, input[`arg${i}`]);
            }
          }
        }
      }
      const result = this.evalExpr(lambda.body, lambdaScope);
      if (result instanceof FlowSignal && result.kind === 'return') return result.value;
      return result;
    };
  }

  // ── Lazy control flow ─────────────────────────────────────────────────

  private lazyFields(call: FunctionCall): Record<string, Expression> {
    if (!call.input?.messageCreation) return {};
    const result: Record<string, Expression> = {};
    for (const f of call.input.messageCreation.fields ?? []) {
      result[f.name] = f.value;
    }
    return result;
  }

  private lazyStringField(call: FunctionCall, name: string): string | undefined {
    const fields = this.lazyFields(call);
    const expr = fields[name];
    if (!expr?.literal?.stringValue) return undefined;
    return expr.literal.stringValue;
  }

  private evalLazyIf(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.condition) return null;
    const cond = this.evalExpr(fields.condition, scope);
    if (this.toBool(cond)) {
      return fields.then ? this.evalExpr(fields.then, scope) : null;
    }
    return fields.else ? this.evalExpr(fields.else, scope) : null;
  }

  private evalLazyWhile(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    while (true) {
      if (fields.condition) {
        if (!this.toBool(this.evalExpr(fields.condition, scope))) break;
      }
      if (fields.body) {
        const result = this.evalExpr(fields.body, scope);
        if (result instanceof FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label) return result;
          if (result.kind === 'break') break;
          if (result.kind === 'continue') continue;
        }
      }
    }
    return null;
  }

  private evalLazyDoWhile(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    do {
      if (fields.body) {
        const result = this.evalExpr(fields.body, scope);
        if (result instanceof FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.kind === 'break') break;
        }
      }
      if (fields.condition) {
        if (!this.toBool(this.evalExpr(fields.condition, scope))) break;
      } else break;
    } while (true);
    return null;
  }

  private evalLazyFor(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const forScope = scope.child();
    if (fields.init) {
      // Handle init as string literal "var i = 0" (encoder format)
      if (fields.init.literal?.stringValue) {
        const match = fields.init.literal.stringValue.match(/^(?:var|final|int|double|String)\s+(\w+)\s*=\s*(.+)$/);
        if (match) {
          const varName = match[1];
          const rawVal = match[2].trim();
          const parsed = this.parseInitValue(rawVal, forScope);
          forScope.bind(varName, parsed);
        }
      } else if (fields.init.block) {
        this.evalBlock(fields.init.block, forScope);
      } else {
        this.evalExpr(fields.init, forScope);
      }
    }
    while (true) {
      if (fields.condition) {
        if (!this.toBool(this.evalExpr(fields.condition, forScope))) break;
      }
      if (fields.body) {
        const result = this.evalExpr(fields.body, forScope);
        if (result instanceof FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label) return result;
          if (result.kind === 'break') break;
          if (result.kind === 'continue') { if (fields.update) this.evalExpr(fields.update, forScope); continue; }
        }
      }
      if (fields.update) this.evalExpr(fields.update, forScope);
    }
    return null;
  }

  private evalLazyForIn(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const varName = fields.variable?.literal?.stringValue ?? 'item';
    if (!fields.iterable || !fields.body) return null;
    const iterable = this.evalExpr(fields.iterable, scope);
    if (!Array.isArray(iterable)) throw new BallRuntimeError('for_in: iterable is not a List');
    for (const item of iterable) {
      const loopScope = scope.child();
      loopScope.bind(varName, item);
      const result = this.evalExpr(fields.body, loopScope);
      if (result instanceof FlowSignal) {
        if (result.kind === 'return') return result;
        if (result.label) return result;
        if (result.kind === 'break') break;
        if (result.kind === 'continue') continue;
      }
    }
    return null;
  }

  private evalLazySwitch(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.subject || !fields.cases) return null;
    const subject = this.evalExpr(fields.subject, scope);
    const cases = fields.cases.literal?.listValue?.elements ?? [];
    let defaultBody: Expression | undefined;
    for (const c of cases) {
      if (!c.messageCreation) continue;
      const cf: Record<string, Expression> = {};
      for (const f of c.messageCreation.fields) cf[f.name] = f.value;
      if (cf.is_default?.literal?.boolValue) { defaultBody = cf.body; continue; }
      if (cf.value) {
        const caseVal = this.evalExpr(cf.value, scope);
        if (caseVal === subject && cf.body) return this.evalExpr(cf.body, scope);
      }
    }
    if (defaultBody) return this.evalExpr(defaultBody, scope);
    return null;
  }

  private evalLazyTry(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    let result: BallValue = null;
    try {
      result = fields.body ? this.evalExpr(fields.body, scope) : null;
    } catch (e: any) {
      result = null;
      const catches = fields.catches?.literal?.listValue?.elements ?? [];
      let caught = false;
      for (const c of catches) {
        if (!c.messageCreation) continue;
        const cf: Record<string, Expression> = {};
        for (const f of c.messageCreation.fields) cf[f.name] = f.value;
        const catchType = cf.type?.literal?.stringValue;
        if (catchType) {
          const matches = e instanceof BallException ? e.typeName === catchType : e.constructor?.name === catchType;
          if (!matches) continue;
        }
        const variable = cf.variable?.literal?.stringValue ?? 'e';
        if (cf.body) {
          const catchScope = scope.child();
          catchScope.bind(variable, e instanceof BallException ? e.value : (e instanceof Error ? e.message : String(e)));
          const prev = this.activeException;
          this.activeException = e;
          try { result = this.evalExpr(cf.body, catchScope); }
          finally { this.activeException = prev; }
          caught = true;
          break;
        }
      }
      if (!caught) throw e;
    } finally {
      if (fields.finally) this.evalExpr(fields.finally, scope);
    }
    return result;
  }

  private evalShortCircuitAnd(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.left || !fields.right) return false;
    if (!this.toBool(this.evalExpr(fields.left, scope))) return false;
    return this.toBool(this.evalExpr(fields.right, scope));
  }

  private evalShortCircuitOr(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.left || !fields.right) return false;
    if (this.toBool(this.evalExpr(fields.left, scope))) return true;
    return this.toBool(this.evalExpr(fields.right, scope));
  }

  private evalReturn(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const val = fields.value ? this.evalExpr(fields.value, scope) : null;
    return new FlowSignal('return', val);
  }

  private evalAssign(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.value) return null;
    const val = this.evalExpr(fields.value, scope);

    // Target can be a reference expression or a string literal name.
    const target = fields.target ?? fields.name ?? fields.variable;
    if (!target) return null;

    // Handle index-based assignment: target is std.index(target, index) => arr[i] = val
    if (target.call && target.call.function === 'index' && (target.call.module === 'std' || !target.call.module)) {
      const indexInput = target.call.input ? this.evalExpr(target.call.input, scope) : null;
      if (indexInput) {
        const container = indexInput.target ?? indexInput.list ?? indexInput.map;
        const idx = indexInput.index ?? indexInput.key;
        const op = fields.op?.literal?.stringValue;
        if (container != null && idx != null) {
          if (op && op !== '=') {
            const current = Array.isArray(container) ? container[idx] : container[idx];
            const computed = this.applyCompoundOp(op, current, val);
            container[idx] = computed;
            return computed;
          }
          container[idx] = val;
          return val;
        }
      }
    }

    let name: string | undefined;
    if (target.reference) {
      name = target.reference.name;
    } else if (target.literal?.stringValue) {
      name = target.literal.stringValue;
    }
    if (!name) return null;

    const op = fields.op?.literal?.stringValue;
    if (op && op !== '=') {
      const current = scope.lookup(name);
      const computed = this.applyCompoundOp(op, current, val);
      try { scope.assign(name, computed); } catch { scope.bind(name, computed); }
      return computed;
    }
    try { scope.assign(name, val); } catch { scope.bind(name, val); }
    return val;
  }

  private applyCompoundOp(op: string, current: BallValue, val: BallValue): BallValue {
    // String concatenation for +=
    if (op === '+=' && (typeof current === 'string' || typeof val === 'string')) {
      return String(current ?? '') + String(val ?? '');
    }
    const a = this.toNum(current);
    const b = this.toNum(val);
    switch (op) {
      case '+=': return a + b;
      case '-=': return a - b;
      case '*=': return a * b;
      case '/=': return Math.trunc(a / b);
      case '~/=': return Math.trunc(a / b);
      case '%=': { const r = a % b; return r < 0 ? r + Math.abs(b) : r; }
      case '&=': return (a | 0) & (b | 0);
      case '|=': return (a | 0) | (b | 0);
      case '^=': return (a | 0) ^ (b | 0);
      case '<<=': return (a | 0) << (b | 0);
      case '>>=': return (a | 0) >> (b | 0);
      default: return val;
    }
  }

  private evalIncDec(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const valueExpr = fields.value;
    if (!valueExpr) return null;

    if (valueExpr.reference) {
      const name = valueExpr.reference.name;
      const current = this.toNum(scope.lookup(name));
      const isInc = call.function.includes('increment');
      const isPre = call.function.startsWith('pre');
      const updated = isInc ? current + 1 : current - 1;
      scope.assign(name, updated);
      return isPre ? updated : current;
    }

    // Fallback: just compute
    const val = this.toNum(this.evalExpr(valueExpr, scope));
    const isInc = call.function.includes('increment');
    return isInc ? val + 1 : val - 1;
  }

  private evalLabeled(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const label = fields.label?.literal?.stringValue;
    if (!fields.body) return null;
    const result = this.evalExpr(fields.body, scope);
    if (result instanceof FlowSignal && result.label === label) {
      if (result.kind === 'break') return null;
    }
    return result;
  }

  /**
   * Parse a string-literal init value (from for-loop init like "int j = i * i").
   * Handles: numeric literals, booleans, variable references, and simple
   * binary expressions (a * b, a + b, etc.) involving variables/numbers.
   */
  private parseInitValue(rawVal: string, scope: Scope): BallValue {
    if (rawVal === 'true') return true;
    if (rawVal === 'false') return false;
    if (!isNaN(Number(rawVal))) return Number(rawVal);

    // Try binary expression: "expr op expr" where expr can be "var.prop" or number or var
    const binMatch = rawVal.match(/^(.+?)\s*([+\-*/%])\s*(.+)$/);
    if (binMatch) {
      const lhs = this.resolveTokenValue(binMatch[1].trim(), scope);
      const rhs = this.resolveTokenValue(binMatch[3].trim(), scope);
      switch (binMatch[2]) {
        case '+': return this.toNum(lhs) + this.toNum(rhs);
        case '-': return this.toNum(lhs) - this.toNum(rhs);
        case '*': return this.toNum(lhs) * this.toNum(rhs);
        case '/': return Math.trunc(this.toNum(lhs) / this.toNum(rhs));
        case '%': return this.toNum(lhs) % this.toNum(rhs);
      }
    }

    // Try dotted property access (e.g. "s.length")
    return this.resolveTokenValue(rawVal, scope);
  }

  private resolveTokenValue(token: string, scope: Scope): BallValue {
    if (!isNaN(Number(token))) return Number(token);
    if (token === 'true') return true;
    if (token === 'false') return false;

    // Handle dotted property access: "obj.prop"
    const dotIdx = token.indexOf('.');
    if (dotIdx >= 0) {
      const objName = token.substring(0, dotIdx);
      const propName = token.substring(dotIdx + 1);
      try {
        const obj = scope.lookup(objName);
        if (typeof obj === 'string' && propName === 'length') return obj.length;
        if (Array.isArray(obj) && propName === 'length') return obj.length;
        if (obj && typeof obj === 'object' && propName in obj) return obj[propName];
      } catch { /* fall through */ }
    }

    try { return scope.lookup(token); } catch { return 0; }
  }

  private evalMapCreate(call: FunctionCall, scope: Scope): BallValue {
    const result: Record<string, BallValue> = {};
    if (call.input?.messageCreation) {
      for (const f of call.input.messageCreation.fields ?? []) {
        if (f.name === 'entry' || f.name.startsWith('entry')) {
          const entryVal = this.evalExpr(f.value, scope);
          if (entryVal && typeof entryVal === 'object' && 'key' in entryVal && 'value' in entryVal) {
            result[String(entryVal.key)] = entryVal.value;
          }
        }
      }
    }
    return result;
  }

  // ── Built-in method dispatch ──────────────────────────────────────────

  /**
   * Dispatches method-style calls (with `self` in input) on built-in types.
   * Returns `undefined` (not `null`) when the method is not recognized, so
   * callers can fall through to user-defined method resolution.
   */
  private dispatchBuiltinMethod(method: string, self: BallValue, input: BallValue): BallValue | undefined {
    const arg0 = input?.arg0;

    // Static methods on built-in type references (e.g., List.filled, List.generate).
    if (self && typeof self === 'object' && '__builtin_type__' in self) {
      const typeName = self.__builtin_type__;
      if (typeName === 'List') {
        switch (method) {
          case 'filled': {
            const n = this.toNum(arg0);
            const val = input?.arg1 ?? null;
            return new Array(n).fill(val);
          }
          case 'generate': {
            const n = this.toNum(arg0);
            const fn = input?.arg1;
            if (typeof fn === 'function') return Array.from({ length: n }, (_, i) => fn(i));
            return new Array(n).fill(null);
          }
          case 'empty': return [];
          case 'from': return Array.isArray(arg0) ? [...arg0] : [];
          case 'of': return Array.isArray(arg0) ? [...arg0] : [arg0];
        }
      }
      return undefined;
    }

    // ── Array methods ──
    if (Array.isArray(self)) {
      switch (method) {
        case 'add': self.push(arg0); return null;
        case 'removeLast': return self.pop();
        case 'removeAt': { const idx = this.toNum(arg0); return self.splice(idx, 1)[0]; }
        case 'insert': { const idx = this.toNum(arg0); self.splice(idx, 0, input?.arg1); return null; }
        case 'clear': { self.length = 0; return null; }
        case 'length': return self.length;
        case 'isEmpty': return self.length === 0;
        case 'isNotEmpty': return self.length > 0;
        case 'last': return self[self.length - 1];
        case 'first': return self[0];
        case 'contains': return self.includes(arg0);
        case 'indexOf': return self.indexOf(arg0);
        case 'join': return self.map(x => this.ballToString(x)).join(arg0 != null ? String(arg0) : ', ');
        case 'sublist': {
          const start = this.toNum(arg0);
          const end = input?.arg1 != null ? this.toNum(input.arg1) : undefined;
          return self.slice(start, end);
        }
        case 'reversed': return [...self].reverse();
        case 'sort': {
          const compareFn = arg0;
          if (typeof compareFn === 'function') {
            self.sort((a: any, b: any) => compareFn({ left: a, right: b, arg0: a, arg1: b }));
          } else {
            self.sort((a: any, b: any) => (a < b ? -1 : a > b ? 1 : 0));
          }
          return null;
        }
        case 'map': {
          const fn = arg0;
          if (typeof fn === 'function') return self.map((item: any) => fn(item));
          return self;
        }
        case 'where':
        case 'filter': {
          const fn = arg0;
          if (typeof fn === 'function') return self.filter((item: any) => fn(item));
          return self;
        }
        case 'forEach': {
          const fn = arg0;
          if (typeof fn === 'function') self.forEach((item: any) => fn(item));
          return null;
        }
        case 'any': {
          const fn = arg0;
          if (typeof fn === 'function') return self.some((item: any) => fn(item));
          return false;
        }
        case 'every': {
          const fn = arg0;
          if (typeof fn === 'function') return self.every((item: any) => fn(item));
          return true;
        }
        case 'reduce': {
          const fn = arg0;
          const init = input?.arg1;
          if (typeof fn === 'function') return self.reduce((acc: any, item: any) => fn({ arg0: acc, arg1: item }), init);
          return init;
        }
        case 'toList': return [...self];
        case 'toString': return `[${self.map((x: any) => this.ballToString(x)).join(', ')}]`;
        case 'filled': {
          // List.filled(n, value) — sometimes encoded as self=[], arg0=n, arg1=value
          const n = this.toNum(arg0);
          const val = input?.arg1 ?? null;
          return new Array(n).fill(val);
        }
      }
      return undefined;
    }

    // ── String methods ──
    if (typeof self === 'string') {
      switch (method) {
        case 'length': return self.length;
        case 'isEmpty': return self.length === 0;
        case 'isNotEmpty': return self.length > 0;
        case 'contains': return self.includes(String(arg0 ?? ''));
        case 'substring': {
          const start = this.toNum(arg0);
          const end = input?.arg1 != null ? this.toNum(input.arg1) : undefined;
          return self.substring(start, end);
        }
        case 'indexOf': return self.indexOf(String(arg0 ?? ''));
        case 'split': return self.split(String(arg0 ?? ''));
        case 'trim': return self.trim();
        case 'toUpperCase': return self.toUpperCase();
        case 'toLowerCase': return self.toLowerCase();
        case 'replaceAll': return self.replaceAll(String(arg0 ?? ''), String(input?.arg1 ?? ''));
        case 'startsWith': return self.startsWith(String(arg0 ?? ''));
        case 'endsWith': return self.endsWith(String(arg0 ?? ''));
        case 'padLeft': return self.padStart(this.toNum(arg0), input?.arg1 != null ? String(input.arg1) : ' ');
        case 'padRight': return self.padEnd(this.toNum(arg0), input?.arg1 != null ? String(input.arg1) : ' ');
        case 'toString': return self;
        case 'codeUnitAt': return self.charCodeAt(this.toNum(arg0));
      }
      return undefined;
    }

    // ── Number methods ──
    if (typeof self === 'number' || self instanceof BallDouble) {
      const numVal = typeof self === 'number' ? self : self.value;
      switch (method) {
        case 'toDouble': return new BallDouble(numVal);
        case 'toInt': return Math.trunc(numVal);
        case 'toString': return this.ballToString(self);
        case 'toStringAsFixed': return numVal.toFixed(this.toNum(arg0));
        case 'abs': return Math.abs(numVal);
        case 'round': return Math.round(numVal);
        case 'floor': return Math.floor(numVal);
        case 'ceil': return Math.ceil(numVal);
        case 'compareTo': return numVal < this.toNum(arg0) ? -1 : numVal > this.toNum(arg0) ? 1 : 0;
        case 'clamp': return Math.min(Math.max(numVal, this.toNum(arg0)), this.toNum(input?.arg1 ?? numVal));
        case 'isNaN': return isNaN(numVal);
        case 'isFinite': return isFinite(numVal);
        case 'isNegative': return numVal < 0;
        case 'truncate': return Math.trunc(numVal);
        case 'remainder': return numVal % this.toNum(arg0);
      }
      return undefined;
    }

    // ── Map/Object methods (non-array objects without __type__) ──
    if (self && typeof self === 'object' && !Array.isArray(self)) {
      switch (method) {
        case 'containsKey': return arg0 in self;
        case 'containsValue': return Object.values(self).includes(arg0);
        case 'remove': { const v = self[arg0]; delete self[arg0]; return v; }
        case 'keys': return Object.keys(self);
        case 'values': return Object.values(self);
        case 'entries': return Object.entries(self).map(([k, v]) => ({ key: k, value: v }));
        case 'length': return Object.keys(self).length;
        case 'isEmpty': return Object.keys(self).length === 0;
        case 'isNotEmpty': return Object.keys(self).length > 0;
        case 'putIfAbsent': {
          if (!(arg0 in self)) {
            const valueFn = input?.arg1;
            self[arg0] = typeof valueFn === 'function' ? valueFn(null) : valueFn;
          }
          return self[arg0];
        }
        case 'toString': return JSON.stringify(self);
      }
      // Don't return undefined here — fall through so typed objects get class-method lookup.
    }

    return undefined;
  }

  // ── Base function dispatch ────────────────────────────────────────────

  private callBaseFunction(module: string, fn: string, input: BallValue): BallValue {
    const left = input?.left;
    const right = input?.right;
    const value = input?.value;

    switch (fn) {
      // I/O
      case 'print': this.stdout(this.ballToString(value ?? input?.message ?? input)); return null;

      // Arithmetic
      case 'add': {
        if (typeof left === 'string' || typeof right === 'string') return String(left ?? '') + String(right ?? '');
        return this.numOp(left, right, (a, b) => a + b);
      }
      case 'subtract': return this.numOp(left, right, (a, b) => a - b);
      case 'multiply': return this.numOp(left, right, (a, b) => a * b);
      case 'divide': return Math.trunc(this.toNum(left) / this.toNum(right));
      case 'divide_double': return this.toNum(left) / this.toNum(right);
      case 'modulo': return this.numOp(left, right, (a, b) => { const r = a % b; return r < 0 ? r + Math.abs(b) : r; });
      case 'negate': return -this.toNum(value ?? input);

      // Comparison
      case 'equals': {
        const l = left instanceof BallDouble ? left.value : left;
        const r = right instanceof BallDouble ? right.value : right;
        return l === r;
      }
      case 'not_equals': {
        const l = left instanceof BallDouble ? left.value : left;
        const r = right instanceof BallDouble ? right.value : right;
        return l !== r;
      }
      case 'less_than': return this.toNum(left) < this.toNum(right);
      case 'greater_than': return this.toNum(left) > this.toNum(right);
      case 'lte': return this.toNum(left) <= this.toNum(right);
      case 'gte': return this.toNum(left) >= this.toNum(right);

      // Logical
      case 'not': return !this.toBool(value ?? input);

      // String
      case 'concat': return String(left ?? '') + String(right ?? '');
      case 'to_string': return this.ballToString(value ?? input);
      case 'string_length': return String(value ?? input).length;
      case 'string_contains': return String(input?.string ?? '').includes(String(input?.substring ?? ''));
      case 'string_substring': return String(input?.string ?? '').substring(input?.start ?? 0, input?.end);
      case 'string_to_upper': return String(value ?? input).toUpperCase();
      case 'string_to_lower': return String(value ?? input).toLowerCase();
      case 'string_trim': return String(value ?? input).trim();
      case 'string_split': return String(input?.string ?? '').split(String(input?.delimiter ?? ''));
      case 'string_replace': return String(input?.string ?? '').replace(String(input?.from ?? ''), String(input?.to ?? ''));
      case 'string_replace_all': return String(input?.string ?? '').replaceAll(String(input?.from ?? ''), String(input?.to ?? ''));
      case 'string_starts_with': return String(input?.string ?? '').startsWith(String(input?.prefix ?? ''));
      case 'string_ends_with': return String(input?.string ?? '').endsWith(String(input?.suffix ?? ''));
      case 'string_index_of': return String(input?.string ?? '').indexOf(String(input?.substring ?? ''));

      // Type ops
      case 'is': return this.typeMatches(input?.value, input?.type);
      case 'is_not': return !this.typeMatches(input?.value, input?.type);
      case 'as': return input?.value;

      // Math
      case 'math_abs': return Math.abs(this.toNum(value ?? input));
      case 'math_floor': return Math.floor(this.toNum(value ?? input));
      case 'math_ceil': return Math.ceil(this.toNum(value ?? input));
      case 'math_round': return Math.round(this.toNum(value ?? input));
      case 'math_sqrt': return Math.sqrt(this.toNum(value ?? input));
      case 'math_pow': return Math.pow(this.toNum(input?.base ?? left), this.toNum(input?.exponent ?? right));
      case 'math_min': return Math.min(this.toNum(left), this.toNum(right));
      case 'math_max': return Math.max(this.toNum(left), this.toNum(right));
      case 'math_pi': return Math.PI;

      // Error handling
      case 'throw': {
        const rawVal = input?.value ?? input?.message ?? input;
        const typeName = input?.type ?? rawVal?.__type ?? 'Exception';
        throw new BallException(typeName, rawVal);
      }
      case 'rethrow': {
        if (this.activeException) throw this.activeException;
        throw new BallRuntimeError('rethrow outside of catch');
      }
      case 'assert': {
        if (!this.toBool(input?.condition ?? input)) {
          throw new BallRuntimeError(`Assertion failed: ${input?.message ?? ''}`);
        }
        return null;
      }

      // Collections
      case 'list_push': { const l = [...(input?.list ?? [])]; l.push(input?.value); return l; }
      case 'list_length': return (input?.list ?? input ?? []).length;
      case 'list_get': return (input?.list ?? [])[input?.index ?? 0];
      case 'list_map': {
        const list = input?.list ?? [];
        const fn = input?.function;
        if (typeof fn === 'function') return list.map((item: any) => fn(item));
        return list;
      }
      case 'list_filter': {
        const list = input?.list ?? [];
        const fn = input?.function;
        if (typeof fn === 'function') return list.filter((item: any) => fn(item));
        return list;
      }
      case 'list_add': {
        const list = input?.list ?? [];
        if (Array.isArray(list)) { list.push(input?.value); return list; }
        return [...list, input?.value];
      }
      case 'list_remove_last': {
        const list = input?.list ?? [];
        if (Array.isArray(list)) return list.pop();
        return null;
      }
      case 'list_contains': return (input?.list ?? []).includes(input?.value);
      case 'list_index_of': return (input?.list ?? []).indexOf(input?.value);
      case 'list_set': {
        const list = input?.list ?? [];
        if (Array.isArray(list)) { list[input?.index ?? 0] = input?.value; return list; }
        return list;
      }
      case 'list_sublist': {
        const list = input?.list ?? [];
        const start = this.toNum(input?.start ?? 0);
        const end = input?.end != null ? this.toNum(input.end) : undefined;
        return list.slice(start, end);
      }
      case 'list_join': {
        const list = input?.list ?? [];
        const sep = input?.separator ?? input?.delimiter ?? ', ';
        return list.map((x: any) => this.ballToString(x)).join(String(sep));
      }
      case 'list_reversed': return [...(input?.list ?? [])].reverse();
      case 'list_sort': {
        const list = input?.list ?? [];
        const cmp = input?.compare ?? input?.comparator;
        if (typeof cmp === 'function') {
          list.sort((a: any, b: any) => cmp({ arg0: a, arg1: b }));
        } else {
          list.sort((a: any, b: any) => (a < b ? -1 : a > b ? 1 : 0));
        }
        return list;
      }
      case 'list_filled': {
        const n = this.toNum(input?.length ?? input?.count ?? input?.size ?? 0);
        return new Array(n).fill(input?.value ?? input?.fill ?? null);
      }
      case 'list_foreach': {
        const list = input?.list ?? [];
        const fn = input?.function;
        if (typeof fn === 'function') list.forEach((item: any) => fn(item));
        return null;
      }
      case 'list_any': {
        const list = input?.list ?? [];
        const fn = input?.function;
        if (typeof fn === 'function') return list.some((item: any) => fn(item));
        return false;
      }
      case 'list_every': {
        const list = input?.list ?? [];
        const fn = input?.function;
        if (typeof fn === 'function') return list.every((item: any) => fn(item));
        return true;
      }
      case 'list_reduce': {
        const list = input?.list ?? [];
        const fn = input?.function;
        const init = input?.initial ?? input?.initialValue;
        if (typeof fn === 'function') return list.reduce((acc: any, item: any) => fn({ arg0: acc, arg1: item }), init);
        return init;
      }
      case 'map_get': return (input?.map ?? {})[input?.key];
      case 'map_set': { const m = { ...(input?.map ?? {}) }; m[input?.key] = input?.value; return m; }
      case 'map_keys': return Object.keys(input?.map ?? input ?? {});
      case 'map_values': return Object.values(input?.map ?? input ?? {});
      case 'map_contains_key': return (input?.key) in (input?.map ?? {});
      case 'map_contains_value': return Object.values(input?.map ?? {}).includes(input?.value);
      case 'map_remove': { const m = input?.map ?? {}; const v = m[input?.key]; delete m[input?.key]; return v; }
      case 'map_create': {
        // map_create({entry: {key:..., value:...}, entry: {key:..., value:...}})
        // Since multiple 'entry' fields collapse, we need to look at the raw input.
        // The input object may have a single 'entry' or we parse from messageCreation.
        const result: Record<string, BallValue> = {};
        if (input && typeof input === 'object') {
          // When input has named key-value pairs directly
          for (const [k, v] of Object.entries(input)) {
            if (k === 'entry') {
              // Single entry
              if (v && typeof v === 'object' && 'key' in v && 'value' in v) {
                result[String(v.key)] = v.value;
              }
            } else if (k.startsWith('entry')) {
              if (v && typeof v === 'object' && 'key' in v && 'value' in v) {
                result[String(v.key)] = v.value;
              }
            }
          }
        }
        return result;
      }
      case 'set_create': {
        const elems = input?.elements;
        if (!elems || (Array.isArray(elems) && elems.length === 0)) return {};
        return elems;
      }
      case 'range': {
        const start = this.toNum(input?.start ?? input?.arg0 ?? 0);
        const end = this.toNum(input?.end ?? input?.arg1 ?? 0);
        const step = this.toNum(input?.step ?? 1);
        const result: number[] = [];
        if (step > 0) { for (let i = start; i < end; i += step) result.push(i); }
        else if (step < 0) { for (let i = start; i > end; i += step) result.push(i); }
        return result;
      }

      // Increment/decrement (pure value ops)
      case 'pre_increment': case 'post_increment': return this.toNum(value ?? input) + 1;
      case 'pre_decrement': case 'post_decrement': return this.toNum(value ?? input) - 1;

      // Index
      case 'index': {
        const target = input?.target ?? input?.list;
        const idx = input?.index ?? input?.key;
        if (Array.isArray(target)) return target[idx];
        if (target && typeof target === 'object') return target[idx];
        if (typeof target === 'string') return target[idx];
        return null;
      }

      // Bitwise
      case 'bitwise_and': return (this.toNum(left) | 0) & (this.toNum(right) | 0);
      case 'bitwise_or': return (this.toNum(left) | 0) | (this.toNum(right) | 0);
      case 'bitwise_xor': return (this.toNum(left) | 0) ^ (this.toNum(right) | 0);
      case 'bitwise_not': return ~(this.toNum(value ?? input) | 0);
      case 'left_shift': return (this.toNum(left) | 0) << (this.toNum(right) | 0);
      case 'right_shift': return (this.toNum(left) | 0) >> (this.toNum(right) | 0);

      // Null
      case 'null_coalesce': return left ?? right;

      // Misc
      case 'paren': return value ?? input;
      case 'string_interpolation': return String(value ?? input);
      case 'null_check': return value ?? input;
      case 'invoke': {
        // dart_std.invoke: call a function reference with args
        const target = input?.callee ?? input?.target ?? input?.function ?? input?.self;
        const args = input?.args ?? input?.arguments;
        if (typeof target === 'function') {
          if (args !== undefined && args !== null) return target(args);
          // No explicit args: pass remaining input fields (excluding callee/target) as the argument
          return target(null);
        }
        return null;
      }
      case 'cascade': return input?.target ?? input?.self ?? input;
      case 'null_aware_access': {
        const target = input?.target ?? input?.self;
        if (target === null || target === undefined) return null;
        const field = input?.field ?? input?.name;
        if (field && typeof target === 'object') return target[field];
        return target;
      }
      case 'int_to_string': return String(Math.trunc(this.toNum(value ?? input)));
      case 'double_to_string': return String(this.toNum(value ?? input));
      case 'string_to_int': return parseInt(String(value ?? input));
      case 'string_to_double': return parseFloat(String(value ?? input));
      case 'length': return (value ?? input)?.length ?? 0;
      case 'to_double': return new BallDouble(this.toNum(value ?? input));
      case 'to_int': return Math.trunc(this.toNum(value ?? input));
      case 'int_to_double': return new BallDouble(this.toNum(value ?? input));
      case 'double_to_int': return Math.trunc(this.toNum(value ?? input));
      case 'is_empty': {
        const v = value ?? input;
        if (typeof v === 'string') return v.length === 0;
        if (Array.isArray(v)) return v.length === 0;
        if (v && typeof v === 'object') return Object.keys(v).length === 0;
        return true;
      }
      case 'is_not_empty': {
        const v = value ?? input;
        if (typeof v === 'string') return v.length > 0;
        if (Array.isArray(v)) return v.length > 0;
        if (v && typeof v === 'object') return Object.keys(v).length > 0;
        return false;
      }
      case 'string_pad_left': return String(input?.string ?? '').padStart(this.toNum(input?.width ?? 0), String(input?.padding ?? ' '));
      case 'string_pad_right': return String(input?.string ?? '').padEnd(this.toNum(input?.width ?? 0), String(input?.padding ?? ' '));
      case 'string_code_unit_at': return String(input?.string ?? '').charCodeAt(this.toNum(input?.index ?? 0));
      case 'string_from_char_code': return String.fromCharCode(this.toNum(value ?? input));

      default:
        throw new BallRuntimeError(`Unknown base function: ${module}.${fn}`);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  private typeMatches(value: BallValue, type: string | undefined): boolean {
    if (type === undefined || type === null) return false;
    // Primitive type checks
    switch (type) {
      case 'int': return typeof value === 'number' && Number.isInteger(value);
      case 'double': return typeof value === 'number';
      case 'num': return typeof value === 'number';
      case 'String': return typeof value === 'string';
      case 'bool': return typeof value === 'boolean';
      case 'List': return Array.isArray(value);
      case 'Map': return value !== null && typeof value === 'object' && !Array.isArray(value);
      case 'Null': case 'void': return value === null || value === undefined;
      case 'Object': case 'dynamic': return true;
      case 'Function': return typeof value === 'function';
    }
    // Check BallObject __type__ and walk __super__ chain
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      if (this.typeNameMatches(value.__type__, type)) return true;
      let superObj = value.__super__;
      while (superObj && typeof superObj === 'object' && !Array.isArray(superObj)) {
        if (this.typeNameMatches(superObj.__type__, type)) return true;
        superObj = superObj.__super__;
      }
    }
    // Fallback: JS typeof check
    return typeof value === type;
  }

  private typeNameMatches(objType: string | undefined, checkType: string): boolean {
    if (!objType) return false;
    if (objType === checkType) return true;
    // objType is "module:Foo", checkType is "Foo"
    if (objType.endsWith(':' + checkType)) return true;
    // objType is "Foo", checkType is "module:Foo"
    if (checkType.endsWith(':' + objType)) return true;
    return false;
  }

  private toBool(v: BallValue): boolean {
    if (v === null || v === undefined || v === false || v === 0 || v === '') return false;
    return true;
  }

  private toNum(v: BallValue): number {
    if (typeof v === 'number') return v;
    if (v instanceof BallDouble) return v.value;
    if (typeof v === 'string') return Number(v) || 0;
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;
  }

  private numOp(left: BallValue, right: BallValue, op: (a: number, b: number) => number): number {
    return op(this.toNum(left), this.toNum(right));
  }

  private ballToString(v: BallValue): string {
    if (v === null || v === undefined) return 'null';
    if (v instanceof BallDouble) return v.toString();
    if (typeof v === 'number') {
      return Number.isInteger(v) ? v.toString() : v.toString();
    }
    if (typeof v === 'boolean') return v.toString();
    if (Array.isArray(v)) return `[${v.map(x => this.ballToString(x)).join(', ')}]`;
    if (typeof v === 'object') return JSON.stringify(v);
    return String(v);
  }
}
