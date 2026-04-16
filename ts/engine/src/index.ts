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
      for (const fn of mod.functions) {
        this.functions.set(`${mod.name}.${fn.name}`, fn);
      }
    }
  }

  run(): string[] {
    const key = `${this.program.entryModule}.${this.program.entryFunction}`;
    const fn = this.functions.get(key);
    if (!fn) throw new BallRuntimeError(`Entry function "${key}" not found`);

    const scope = new Scope();
    this.currentModule = this.program.entryModule;
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
      }
    }

    // Eager evaluation
    const input = call.input ? this.evalExpr(call.input, scope) : null;

    // Fast path for explicit std calls
    if (call.module === 'std' || call.module === 'dart_std') {
      return this.callBaseFunction(call.module, call.function, input);
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

    const prevModule = this.currentModule;
    this.currentModule = moduleName;

    const fnScope = parentScope.child();
    fnScope.bind('input', input);

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
    if (lit.listValue) return lit.listValue.elements.map(e => this.evalExpr(e, scope));
    return null;
  }

  private evalReference(ref: { name: string }, scope: Scope): BallValue {
    return scope.lookup(ref.name);
  }

  private evalFieldAccess(fa: { object: Expression; field: string }, scope: Scope): BallValue {
    const obj = this.evalExpr(fa.object, scope);
    // Handle string properties
    if (typeof obj === 'string') {
      if (fa.field === 'length') return obj.length;
      return null;
    }
    // Handle array properties
    if (Array.isArray(obj)) {
      if (fa.field === 'length') return obj.length;
      return null;
    }
    if (obj && typeof obj === 'object' && fa.field in obj) return obj[fa.field];
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
    for (const f of call.input.messageCreation.fields) {
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
          const parsed = rawVal === 'true' ? true : rawVal === 'false' ? false : (isNaN(Number(rawVal)) ? rawVal : Number(rawVal));
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
    const a = this.toNum(current);
    const b = this.toNum(val);
    switch (op) {
      case '+=': return a + b;
      case '-=': return a - b;
      case '*=': return a * b;
      case '/=': return Math.trunc(a / b);
      case '%=': return a % b;
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
      case 'modulo': return this.numOp(left, right, (a, b) => a % b);
      case 'negate': return -this.toNum(value ?? input);

      // Comparison
      case 'equals': return left === right;
      case 'not_equals': return left !== right;
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
      case 'is': return typeof input?.value === input?.type;
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
      case 'map_get': return (input?.map ?? {})[input?.key];
      case 'map_set': { const m = { ...(input?.map ?? {}) }; m[input?.key] = input?.value; return m; }
      case 'map_keys': return Object.keys(input?.map ?? input ?? {});

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
      case 'int_to_string': return String(Math.trunc(this.toNum(value ?? input)));
      case 'double_to_string': return String(this.toNum(value ?? input));
      case 'string_to_int': return parseInt(String(value ?? input));
      case 'string_to_double': return parseFloat(String(value ?? input));
      case 'length': return (value ?? input)?.length ?? 0;

      default:
        throw new BallRuntimeError(`Unknown base function: ${module}.${fn}`);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  private toBool(v: BallValue): boolean {
    if (v === null || v === undefined || v === false || v === 0 || v === '') return false;
    return true;
  }

  private toNum(v: BallValue): number {
    if (typeof v === 'number') return v;
    if (typeof v === 'string') return Number(v) || 0;
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;
  }

  private numOp(left: BallValue, right: BallValue, op: (a: number, b: number) => number): number {
    return op(this.toNum(left), this.toNum(right));
  }

  private ballToString(v: BallValue): string {
    if (v === null || v === undefined) return 'null';
    if (typeof v === 'number') {
      return Number.isInteger(v) ? v.toString() : v.toString();
    }
    if (typeof v === 'boolean') return v.toString();
    if (Array.isArray(v)) return `[${v.map(x => this.ballToString(x)).join(', ')}]`;
    if (typeof v === 'object') return JSON.stringify(v);
    return String(v);
  }
}
