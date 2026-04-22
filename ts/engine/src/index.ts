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

interface TypeDef {
  name: string;
  descriptor?: { field?: Array<{ name: string; number?: number; label?: string; type?: string }> };
  metadata?: Record<string, any>;
}

interface Module {
  name: string;
  functions: FunctionDef[];
  moduleImports?: ModuleImport[];
  types?: any[];
  typeDefs?: TypeDef[];
  enums?: any[];
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
  messageCreation?: { typeName?: string; fields?: FieldValuePair[] };
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
  private classRegistry = new Map<string, { superclass?: string; fieldNames: string[]; moduleName: string }>();
  private staticFields = new Map<string, FunctionDef>();
  private getters = new Map<string, FunctionDef>();
  private setters = new Map<string, FunctionDef>();
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

      // Index typeDefs for class registry.
      const typeDefs = mod.typeDefs;
      if (Array.isArray(typeDefs)) {
        for (const td of typeDefs) {
          const meta = td.metadata ?? {};
          if (meta.kind === 'class' || meta.kind === 'abstract_class' || meta.kind === 'mixin') {
            const fieldNames: string[] = [];
            // Collect fields from descriptor
            if (td.descriptor?.field) {
              for (const f of td.descriptor.field) {
                fieldNames.push(f.name);
              }
            }
            // Also collect from metadata fields
            if (Array.isArray(meta.fields)) {
              for (const f of meta.fields) {
                if (f.name && !fieldNames.includes(f.name)) {
                  fieldNames.push(f.name);
                }
              }
            }
            const superclass = meta.superclass;
            this.classRegistry.set(td.name, { superclass, fieldNames, moduleName: mod.name });
            // Also register by bare name (without module prefix)
            const colonIdx = td.name.indexOf(':');
            if (colonIdx >= 0) {
              const bare = td.name.substring(colonIdx + 1);
              this.classRegistry.set(bare, { superclass, fieldNames, moduleName: mod.name });
            }
          }
        }
      }

      for (const fn of mod.functions) {
        const fnKey = `${mod.name}.${fn.name}`;
        // Register getters and setters in separate maps to avoid collisions.
        if (fn.metadata?.is_getter) {
          this.getters.set(fnKey, fn);
        } else if (fn.metadata?.is_setter) {
          this.setters.set(fnKey, fn);
          // Also register with "=" suffix for setter lookup.
          this.setters.set(`${fnKey}=`, fn);
        }
        // Only store in main functions map if not already taken by a getter (avoid setter overwriting getter).
        if (!this.functions.has(fnKey) || !fn.metadata?.is_setter) {
          this.functions.set(fnKey, fn);
        }

        // Register constructors (metadata.kind === "constructor").
        const kind = fn.metadata?.kind;
        if (kind === 'constructor') {
          const entry = { module: mod.name, fn };
          // fn.name is "ClassName.new" or "ClassName.named" or "mod:ClassName.new".
          const dotIdx = fn.name.indexOf('.');
          if (dotIdx >= 0) {
            const className = fn.name.substring(0, dotIdx);
            const ctorSuffix = fn.name.substring(dotIdx + 1);
            if (ctorSuffix === 'new') {
              this.constructors.set(className, entry);
              this.constructors.set(`${mod.name}:${className}`, entry);
              // Also register by bare class name (strip module prefix from className)
              const colonIdx = className.indexOf(':');
              if (colonIdx >= 0) {
                const bare = className.substring(colonIdx + 1);
                this.constructors.set(bare, entry);
              }
            }
            this.constructors.set(fn.name, entry);
          }
        }

        // Register static fields (metadata.kind === "static_field").
        if (fn.metadata?.kind === 'static_field') {
          this.staticFields.set(`${mod.name}.${fn.name}`, fn);
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
    if (moduleName === 'std' || moduleName === 'dart_std' || moduleName === 'std_collections' || moduleName === 'std_io') {
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
        case 'cascade': case 'null_aware_cascade': return this.evalCascade(call, scope);
      }
    }

    // Eager evaluation
    const input = call.input ? this.evalExpr(call.input, scope) : null;

    // Fast path for explicit std calls
    if (call.module === 'std' || call.module === 'dart_std' || call.module === 'std_collections' || call.module === 'std_io') {
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
          const resolved = this.resolveMethod(typeName, call.function);
          if (resolved) return this.callFunction(resolved.modPart, resolved.fn, input, scope);
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

    // Try to find function as a named constructor or class-qualified method.
    // For calls like "_internal" with self=Logger class, try "ClassName._internal".
    if (input && typeof input === 'object' && !Array.isArray(input) && 'self' in input) {
      const self = input.self;
      // If self is a class descriptor
      if (self && typeof self === 'object' && '__class_name__' in self) {
        const className = self.__class_name__;
        const modName = self.__module__;
        const qualClassName = className.includes(':') ? className : `${modName}:${className}`;
        const classMethodKey = `${modName}.${qualClassName}.${call.function}`;
        const classMethod = this.functions.get(classMethodKey);
        if (classMethod) {
          // For named constructors, create an instance first
          if (classMethod.metadata?.kind === 'constructor') {
            return this.callNamedConstructor(modName, qualClassName, classMethod, input, scope);
          }
          return this.callFunction(modName, classMethod, input, scope);
        }
      }
    }

    // Fallback: scan all modules for matching function name (including qualified names)
    for (const mod of this.program.modules) {
      for (const f of mod.functions) {
        if (f.name === call.function) {
          return this.callFunction(mod.name, f, input, scope);
        }
        // Also try matching the last segment of qualified names
        const dotIdx = f.name.lastIndexOf('.');
        if (dotIdx >= 0 && f.name.substring(dotIdx + 1) === call.function) {
          return this.callFunction(mod.name, f, input, scope);
        }
      }
    }

    // Handle well-known global functions that aren't in any module.
    switch (call.function) {
      case 'identical': {
        const a = input?.arg0 ?? input?.left;
        const b = input?.arg1 ?? input?.right;
        return a === b;
      }
    }

    throw new BallRuntimeError(`Function "${key}" not found`);
  }

  private callFunction(moduleName: string, fn: FunctionDef, input: BallValue, parentScope: Scope): BallValue {
    if (fn.isBase) return this.callBaseFunction(moduleName, fn.name, input);

    const kind = fn.metadata?.kind;

    // Constructor with no body: just return the instance (fields already set by messageCreation).
    if (!fn.body) {
      if (kind === 'constructor') {
        // For constructors with no body, the instance is created by evalMessageCreation.
        // If input has 'self', return it. Otherwise return input itself.
        if (input && typeof input === 'object' && !Array.isArray(input) && '__type__' in input) {
          return input;
        }
        return input;
      }
      return null;
    }

    // Top-level variables: compute once and cache.
    if (kind === 'top_level_variable' || kind === 'static_field') {
      const key = `${moduleName}.${fn.name}`;
      if (this.topLevelVars.has(key)) return this.topLevelVars.get(key);
      let val = this.evalExpr(fn.body, parentScope);
      // If outputType says Map but we got an empty array, convert to object
      if (fn.outputType && fn.outputType.startsWith('Map') && Array.isArray(val) && val.length === 0) {
        val = {};
      }
      this.topLevelVars.set(key, val);
      return val;
    }

    const prevModule = this.currentModule;
    this.currentModule = moduleName;

    const fnScope = parentScope.child();
    // Only bind 'input' if the function actually receives input.
    // Binding null would shadow top-level variables named 'input'.
    if (input !== null && input !== undefined) {
      fnScope.bind('input', input);
    }

    // Bind 'self' for instance method/constructor calls so field references resolve.
    const selfObj = (input && typeof input === 'object' && !Array.isArray(input) && 'self' in input) ? input.self : null;
    if (selfObj) {
      fnScope.bind('self', selfObj);
      // Bind instance fields into scope so unqualified references (e.g. "x") resolve.
      if (typeof selfObj === 'object' && selfObj !== null && !Array.isArray(selfObj)) {
        const typeName: string | undefined = selfObj.__type__;
        if (typeName) {
          this.bindInstanceFields(fnScope, selfObj, typeName);
        }
        // Bind 'super' to the __super__ object if present.
        if (selfObj.__super__) {
          fnScope.bind('super', selfObj.__super__);
        }
      }
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

    // For constructor with body: after executing the body, sync fields back to self and return self.
    if (kind === 'constructor' && selfObj && typeof selfObj === 'object') {
      // If the body returned a flow signal with a value, that may be the return value (factory constructor).
      if (result instanceof FlowSignal && result.kind === 'return' && result.value !== undefined) {
        return result.value;
      }
      return selfObj;
    }

    if (result instanceof FlowSignal && result.kind === 'return') {
      result = result.value;
    }

    // Wrap result as BallDouble if the function's outputType is "double" and result is a plain number.
    if (fn.outputType === 'double' && typeof result === 'number' && !((result as any) instanceof BallDouble)) {
      return new BallDouble(result as number);
    }

    return result;
  }

  /**
   * Resolve a method function by walking the class hierarchy.
   */
  private resolveMethod(typeName: string, methodName: string): { modPart: string; fn: FunctionDef } | null {
    const colonIdx = typeName.indexOf(':');
    const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : this.currentModule;

    // Try ClassName.methodName
    const methodKey = `${modPart}.${typeName}.${methodName}`;
    const method = this.functions.get(methodKey);
    if (method) return { modPart, fn: method };

    // Walk superclass chain via class registry.
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo?.superclass) {
      // Build qualified superclass name
      let superTypeName = classInfo.superclass;
      if (!superTypeName.includes(':')) {
        superTypeName = `${modPart}:${superTypeName}`;
      }
      const superResult = this.resolveMethod(superTypeName, methodName);
      if (superResult) return superResult;
    }

    // Check mixins.
    if (classInfo) {
      const mixinsMeta = this.getMixins(typeName);
      for (const mixin of mixinsMeta) {
        let mixinTypeName = mixin;
        if (!mixinTypeName.includes(':')) {
          mixinTypeName = `${modPart}:${mixinTypeName}`;
        }
        const mixinResult = this.resolveMethod(mixinTypeName, methodName);
        if (mixinResult) return mixinResult;
      }
    }

    return null;
  }

  /**
   * Get mixin names for a type from its module's typeDef metadata.
   */
  private getMixins(typeName: string): string[] {
    for (const mod of this.program.modules) {
      for (const td of (mod.typeDefs ?? [])) {
        if (td.name === typeName || (typeName.includes(':') && td.name === typeName)) {
          const mixins = td.metadata?.mixins;
          if (Array.isArray(mixins)) return mixins;
        }
      }
    }
    return [];
  }

  /**
   * Call a named constructor. Creates an instance, maps args to fields, and calls the constructor.
   */
  private callNamedConstructor(modName: string, qualClassName: string, ctorFn: FunctionDef, input: BallValue, scope: Scope): BallValue {
    const classInfo = this.classRegistry.get(qualClassName);
    if (!classInfo) return null;

    const instance: Record<string, BallValue> = { __type__: qualClassName };
    const allFieldNames = this.collectAllFieldNames(qualClassName);
    for (const fname of allFieldNames) {
      instance[fname] = null;
    }

    // Map constructor params to fields
    const ctorParams = ctorFn.metadata?.params;
    if (ctorParams && Array.isArray(ctorParams)) {
      for (let i = 0; i < ctorParams.length; i++) {
        const p = ctorParams[i];
        const pName = typeof p === 'string' ? p : p.name;
        const isThis = typeof p === 'object' && p.is_this;
        if (pName) {
          let val: BallValue = undefined;
          if (input && typeof input === 'object' && pName in input) {
            val = input[pName];
          } else if (input && typeof input === 'object' && `arg${i}` in input) {
            val = input[`arg${i}`];
          }
          if (val !== undefined && (isThis || allFieldNames.has(pName))) {
            // Coerce to BallDouble if the field type is double
            const fieldType = this.getFieldType(qualClassName, pName);
            if (fieldType === 'double' && typeof val === 'number' && !((val as any) instanceof BallDouble)) {
              instance[pName] = new BallDouble(val as number);
            } else {
              instance[pName] = val;
            }
          }
        }
      }
    }

    // Resolve constructor params into a scope for initializer evaluation.
    const initScope = new Scope();
    if (ctorParams && Array.isArray(ctorParams)) {
      for (let i = 0; i < ctorParams.length; i++) {
        const p = ctorParams[i];
        const pName = typeof p === 'string' ? p : p.name;
        if (pName) {
          let val: BallValue = undefined;
          if (input && typeof input === 'object' && pName in input) val = input[pName];
          else if (input && typeof input === 'object' && `arg${i}` in input) val = input[`arg${i}`];
          if (val !== undefined) initScope.bind(pName, val);
        }
      }
    }

    // Apply initializers from constructor metadata.
    const initializers = ctorFn.metadata?.initializers;
    if (Array.isArray(initializers)) {
      for (const init of initializers) {
        if (init.kind === 'field' && init.name) {
          const val = init.value;
          if (typeof val === 'string') {
            // Try to evaluate as expression referencing params (e.g. "coords[0]")
            const indexMatch = val.match(/^(\w+)\[(\d+)\]$/);
            if (indexMatch) {
              try {
                const arr = initScope.lookup(indexMatch[1]);
                const idx = parseInt(indexMatch[2]);
                instance[init.name] = Array.isArray(arr) ? arr[idx] : null;
                continue;
              } catch { /* fall through */ }
            }
            if (val === 'true') instance[init.name] = true;
            else if (val === 'false') instance[init.name] = false;
            else if (!isNaN(Number(val))) {
              const numVal = Number(val);
              instance[init.name] = val.includes('.') ? new BallDouble(numVal) : numVal;
            }
            else {
              try {
                instance[init.name] = initScope.lookup(val);
              } catch {
                instance[init.name] = val;
              }
            }
          } else {
            instance[init.name] = val ?? null;
          }
        }
      }
    }

    // Build super chain
    if (classInfo.superclass) {
      let superTypeName = classInfo.superclass;
      if (!superTypeName.includes(':')) {
        const colonIdx = qualClassName.indexOf(':');
        const modPart = colonIdx >= 0 ? qualClassName.substring(0, colonIdx) : modName;
        superTypeName = `${modPart}:${superTypeName}`;
      }
      instance.__super__ = this.buildSuperObject(superTypeName, instance);
    }

    if (ctorFn.body) {
      const ctorInput: Record<string, BallValue> = { ...(input ?? {}), self: instance };
      return this.callFunction(modName, ctorFn, ctorInput, scope);
    }

    return instance;
  }

  /**
   * Get the type of a field from class metadata.
   */
  private getFieldType(typeName: string, fieldName: string): string | undefined {
    for (const mod of this.program.modules) {
      for (const td of (mod.typeDefs ?? [])) {
        if (td.name === typeName) {
          const fields = td.metadata?.fields;
          if (Array.isArray(fields)) {
            for (const f of fields) {
              if (f.name === fieldName) return f.type;
            }
          }
        }
      }
    }
    // Check superclass
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo?.superclass) {
      let superTypeName = classInfo.superclass;
      if (!superTypeName.includes(':')) {
        const colonIdx = typeName.indexOf(':');
        const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : classInfo.moduleName;
        superTypeName = `${modPart}:${superTypeName}`;
      }
      return this.getFieldType(superTypeName, fieldName);
    }
    return undefined;
  }

  /**
   * Collect all field names from a class and its superclasses.
   */
  private collectAllFieldNames(typeName: string): Set<string> {
    const result = new Set<string>();
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo) {
      for (const f of classInfo.fieldNames) result.add(f);
      if (classInfo.superclass) {
        let superTypeName = classInfo.superclass;
        if (!superTypeName.includes(':')) {
          const colonIdx = typeName.indexOf(':');
          const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : classInfo.moduleName;
          superTypeName = `${modPart}:${superTypeName}`;
        }
        for (const f of this.collectAllFieldNames(superTypeName)) result.add(f);
      }
    }
    return result;
  }

  /**
   * Bind instance fields into scope so method bodies can reference fields
   * by unqualified name (e.g. "x" instead of "self.x").
   */
  private bindInstanceFields(scope: Scope, obj: Record<string, any>, typeName: string): void {
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo) {
      // Bind superclass fields first
      if (classInfo.superclass) {
        let superTypeName = classInfo.superclass;
        if (!superTypeName.includes(':')) {
          const colonIdx = typeName.indexOf(':');
          const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : classInfo.moduleName;
          superTypeName = `${modPart}:${superTypeName}`;
        }
        this.bindInstanceFields(scope, obj, superTypeName);
      }
      for (const field of classInfo.fieldNames) {
        if (field in obj) {
          scope.bind(field, obj[field]);
        } else if (obj.__super__ && typeof obj.__super__ === 'object' && field in obj.__super__) {
          scope.bind(field, obj.__super__[field]);
        }
      }
    }
    // Also bind any direct fields on the object that start with underscore (private fields like _celsius)
    for (const key of Object.keys(obj)) {
      if (key.startsWith('_') && key !== '__type__' && key !== '__super__' && key !== '__methods__' && key !== '__type_args__') {
        scope.bind(key, obj[key]);
      }
    }
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

    // Enum type reference: resolve to a map of enum values.
    const enumVals = this.enumValues.get(name);
    if (enumVals) return enumVals;

    // Built-in type references (used as static method receivers like List.filled).
    if (name === 'List' || name === 'Map' || name === 'Set' || name === 'String' || name === 'int' || name === 'double' || name === 'num') {
      return { __builtin_type__: name };
    }

    // Class name reference: return a class descriptor that supports both
    // static method dispatch and constructor tear-off (via __call__).
    const classInfo = this.classRegistry.get(name);
    if (classInfo) {
      const ctorEntry = this.constructors.get(name);
      const descriptor: Record<string, any> = { __class_name__: name, __module__: classInfo.moduleName };
      if (ctorEntry) {
        // Make it callable for constructor tear-off.
        const callableFn = (input: BallValue) => this.callFunction(ctorEntry.module, ctorEntry.fn, input, scope);
        callableFn.__class_name__ = name;
        callableFn.__module__ = classInfo.moduleName;
        return callableFn;
      }
      return descriptor;
    }

    // Constructor tear-off for classes not in registry (e.g., no typeDef but has constructor).
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

    // Static field reference: look up "module.ClassName._fieldName" style.
    for (const [key, fn] of this.staticFields) {
      if (fn.name === name || fn.name.endsWith('.' + name)) {
        return this.callFunction(key.substring(0, key.indexOf('.')), fn, null, scope);
      }
    }

    // Top-level variable or function reference: look up by name across modules.
    for (const mod of this.program.modules) {
      for (const f of mod.functions) {
        if (f.name === name && !f.isBase) {
          if (f.metadata?.kind === 'top_level_variable') {
            return this.callFunction(mod.name, f, null, scope);
          }
          // Function tear-off: return a closure that calls the function.
          if (f.metadata?.kind === 'function' && f.body) {
            const modName = mod.name;
            return (input: BallValue) => this.callFunction(modName, f, input, scope);
          }
        }
      }
    }

    try {
      return scope.lookup(name);
    } catch {
      // If inside a method, try getter dispatch on self.
      if (scope.has('self')) {
        try {
          const self = scope.lookup('self');
          if (self && typeof self === 'object' && !Array.isArray(self) && self.__type__) {
            const getterResult = this.tryGetterDispatch(self, name);
            if (getterResult !== undefined) return getterResult;
            // Also try as a field on self
            if (name in self) return self[name];
          }
        } catch { /* ignore */ }
      }
      return null;
    }
  }

  private evalFieldAccess(fa: { object: Expression; field: string }, scope: Scope): BallValue {
    const obj = this.evalExpr(fa.object, scope);
    // Handle function objects with __class_name__ (class references as static receivers)
    if (typeof obj === 'function' && obj.__class_name__) {
      const className = obj.__class_name__;
      const modName = obj.__module__;
      const qualName = `${modName}:${className}`;
      const staticFieldKey = `${modName}.${qualName}.${fa.field}`;
      const staticFn = this.functions.get(staticFieldKey);
      if (staticFn) {
        if (staticFn.metadata?.kind === 'static_field' && staticFn.body) {
          return this.callFunction(modName, staticFn, null, scope);
        }
        return (input: BallValue) => this.callFunction(modName, staticFn, input, scope);
      }
      return null;
    }
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
      // Class name static field access (e.g., MathUtils.max, ClassName.staticField).
      if (obj.__class_name__) {
        const className = obj.__class_name__;
        const modName = obj.__module__;
        // Try static method/field
        const qualName = `${modName}:${className}`;
        // Static field: look up "modName.qualName.field"
        const staticFieldKey = `${modName}.${qualName}.${fa.field}`;
        const staticFn = this.functions.get(staticFieldKey);
        if (staticFn) {
          if (staticFn.metadata?.kind === 'static_field' && staticFn.body) {
            return this.callFunction(modName, staticFn, null, scope);
          }
          // Static method: return a callable
          return (input: BallValue) => this.callFunction(modName, staticFn, input, scope);
        }
        // Enum values on class
        const enumVals = this.enumValues.get(className) ?? this.enumValues.get(qualName);
        if (enumVals && fa.field in enumVals) return enumVals[fa.field];
        return null;
      }

      // Instance field access: check direct field first.
      if (fa.field in obj) return obj[fa.field];

      // Try getter dispatch for typed objects.
      if (obj.__type__) {
        const getterResult = this.tryGetterDispatch(obj, fa.field);
        if (getterResult !== undefined) return getterResult;
      }

      // Map-level property access (only for non-typed objects, or if field wasn't found).
      if (!obj.__type__) {
        switch (fa.field) {
          case 'length': return Object.keys(obj).length;
          case 'isEmpty': return Object.keys(obj).length === 0;
          case 'isNotEmpty': return Object.keys(obj).length > 0;
          case 'keys': return Object.keys(obj);
          case 'values': return Object.values(obj);
          case 'entries': return Object.entries(obj).map(([k, v]) => ({ key: k, value: v }));
        }
      }

      // Walk __super__ chain for inherited fields.
      let superObj = obj.__super__;
      while (superObj && typeof superObj === 'object' && !Array.isArray(superObj)) {
        if (fa.field in superObj) return superObj[fa.field];
        superObj = superObj.__super__;
      }

      // Try getter on super chain.
      if (obj.__type__) {
        // Already tried in tryGetterDispatch which walks super
      }

      // Map-level property access for typed objects as fallback.
      if (obj.__type__) {
        switch (fa.field) {
          case 'length': {
            // Filter out internal fields
            const userKeys = Object.keys(obj).filter(k => !k.startsWith('__'));
            return userKeys.length;
          }
          case 'keys': return Object.keys(obj).filter(k => !k.startsWith('__'));
          case 'values': return Object.entries(obj).filter(([k]) => !k.startsWith('__')).map(([, v]) => v);
        }
      }
    }
    return null;
  }

  private evalMessageCreation(mc: { typeName?: string; fields?: FieldValuePair[] }, scope: Scope): BallValue {
    const result: Record<string, BallValue> = {};
    const fields = mc.fields ?? [];
    // Track duplicate field names and convert to positional args
    const seenNames = new Map<string, number>(); // name -> count
    for (const f of fields) {
      const val = this.evalExpr(f.value, scope);
      const prevCount = seenNames.get(f.name) ?? 0;
      if (prevCount > 0) {
        // This is a duplicate field. Store the first occurrence's value as arg0
        // (if not already stored) and this one as arg1, arg2, etc.
        if (prevCount === 1) {
          // Move the first value to arg0
          result['arg0'] = result[f.name];
        }
        result[`arg${prevCount}`] = val;
      }
      result[f.name] = val;
      seenNames.set(f.name, prevCount + 1);
    }

    const typeName = mc.typeName;
    if (typeName && typeName.length > 0) {
      // Check if this is a class instantiation.
      const classInfo = this.classRegistry.get(typeName);
      if (classInfo) {
        // Build the instance object.
        const instance: Record<string, BallValue> = { __type__: typeName };

        // Initialize all class fields to null by default.
        for (const fname of classInfo.fieldNames) {
          instance[fname] = null;
        }

        // Map constructor args to instance fields.
        // Collect all field names including inherited ones.
        const allFieldNames = this.collectAllFieldNames(typeName);
        const ctorEntry = this.constructors.get(typeName);
        const ctorParams = ctorEntry?.fn.metadata?.params;
        const resolvedArgs: Record<string, BallValue> = {};
        if (ctorParams && Array.isArray(ctorParams)) {
          for (let i = 0; i < ctorParams.length; i++) {
            const p = ctorParams[i];
            const pName = typeof p === 'string' ? p : p.name;
            const isThis = typeof p === 'object' && p.is_this;
            if (pName) {
              // Get the value from args (by name or by argN)
              let val: BallValue = undefined;
              if (pName in result) {
                val = result[pName];
              } else if (`arg${i}` in result) {
                val = result[`arg${i}`];
              }
              if (val !== undefined) {
                resolvedArgs[pName] = val;
                // Set on instance if is_this or if the param name matches a known field
                if (isThis || allFieldNames.has(pName)) {
                  const fType = this.getFieldType(typeName!, pName);
                  if (fType === 'double' && typeof val === 'number' && !((val as any) instanceof BallDouble)) {
                    instance[pName] = new BallDouble(val as number);
                  } else {
                    instance[pName] = val;
                  }
                }
              }
            }
          }
        }

        // Build __super__ chain for inheritance.
        if (classInfo.superclass) {
          let superTypeName = classInfo.superclass;
          if (!superTypeName.includes(':')) {
            const colonIdx = typeName.indexOf(':');
            const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : classInfo.moduleName;
            superTypeName = `${modPart}:${superTypeName}`;
          }
          instance.__super__ = this.buildSuperObject(superTypeName, instance);
        }

        // Apply initializers from constructor metadata.
        if (ctorEntry) {
          const initializers = ctorEntry.fn.metadata?.initializers;
          if (Array.isArray(initializers)) {
            for (const init of initializers) {
              if (init.kind === 'field' && init.name) {
                const val = init.value;
                if (typeof val === 'string') {
                  if (val === 'true') instance[init.name] = true;
                  else if (val === 'false') instance[init.name] = false;
                  else if (!isNaN(Number(val))) {
                    const numVal = Number(val);
                    instance[init.name] = val.includes('.') ? new BallDouble(numVal) : numVal;
                  }
                  else instance[init.name] = val;
                } else {
                  instance[init.name] = val ?? null;
                }
              }
              // Handle super constructor initializer
              if (init.kind === 'super' && typeof init.args === 'string') {
                this.applySuperInitializer(instance, classInfo, typeName!, resolvedArgs, init.args, scope);
              }
            }
          }
        }

        // Call the constructor function if it has a body.
        if (ctorEntry && ctorEntry.fn.body) {
          // Pass the instance as self + constructor args
          const ctorInput: Record<string, BallValue> = { ...result, ...resolvedArgs, self: instance };
          return this.callFunction(ctorEntry.module, ctorEntry.fn, ctorInput, scope);
        }

        return instance;
      } else {
        // Check if typeName is actually a function/method call (encoder sometimes encodes
        // method calls as messageCreation with typeName = "module:ClassName.method" or "module:method").
        // Try direct lookup first.
        const fnKey = `${this.currentModule}.${typeName}`;
        const fnMatch = this.functions.get(fnKey);
        if (fnMatch && !fnMatch.isBase) {
          if (scope.has('self') && fnMatch.metadata?.kind === 'method') {
            try {
              const selfObj = scope.lookup('self');
              return this.callFunction(this.currentModule, fnMatch, { ...result, self: selfObj }, scope);
            } catch { /* fall through */ }
          }
          return this.callFunction(this.currentModule, fnMatch, result, scope);
        }

        // Try resolving via self's type: typeName "module:_gcd" -> "module:ClassName._gcd"
        if (scope.has('self')) {
          try {
            const selfObj = scope.lookup('self');
            if (selfObj && typeof selfObj === 'object' && selfObj.__type__) {
              const selfType: string = selfObj.__type__;
              // Extract method name from typeName (e.g., "main:_gcd" -> "_gcd")
              const colonIdx = typeName.indexOf(':');
              const methodName = colonIdx >= 0 ? typeName.substring(colonIdx + 1) : typeName;
              // Try resolving as a method on the self type
              const resolved = this.resolveMethod(selfType, methodName);
              if (resolved) {
                return this.callFunction(resolved.modPart, resolved.fn, { ...result, self: selfObj }, scope);
              }
            }
          } catch { /* fall through */ }
        }

        // Also try scanning all modules for the function
        for (const mod of this.program.modules) {
          for (const f of mod.functions) {
            if (f.name === typeName && !f.isBase) {
              if (scope.has('self') && f.metadata?.kind === 'method') {
                try {
                  const selfObj = scope.lookup('self');
                  return this.callFunction(mod.name, f, { ...result, self: selfObj }, scope);
                } catch { /* fall through */ }
              }
              return this.callFunction(mod.name, f, result, scope);
            }
          }
        }
        // Unknown class type: still set __type__ for dispatch.
        result.__type__ = typeName;
      }
    }

    return result;
  }

  /**
   * Build a __super__ object for inheritance chain.
   */
  private buildSuperObject(superTypeName: string, childFields: Record<string, BallValue>): Record<string, BallValue> {
    const superFields: Record<string, BallValue> = { __type__: superTypeName };
    const classInfo = this.classRegistry.get(superTypeName);
    if (classInfo) {
      // Copy descriptor fields from parent type.
      for (const fname of classInfo.fieldNames) {
        if (fname in childFields) {
          superFields[fname] = childFields[fname];
        }
      }
      // Recurse for grandparent.
      if (classInfo.superclass) {
        let grandparent = classInfo.superclass;
        if (!grandparent.includes(':')) {
          const colonIdx = superTypeName.indexOf(':');
          const modPart = colonIdx >= 0 ? superTypeName.substring(0, colonIdx) : classInfo.moduleName;
          grandparent = `${modPart}:${grandparent}`;
        }
        superFields.__super__ = this.buildSuperObject(grandparent, childFields);
      }
    }
    return superFields;
  }

  /**
   * Apply a super constructor initializer to set fields on the super chain.
   * Parses args like "('Car', horsepower)" and maps them to the super constructor's params.
   */
  private applySuperInitializer(
    instance: Record<string, BallValue>,
    classInfo: { superclass?: string; fieldNames: string[]; moduleName: string },
    typeName: string,
    resolvedArgs: Record<string, BallValue>,
    argsStr: string,
    scope: Scope,
  ): void {
    if (!classInfo.superclass) return;

    // Resolve super type
    let superTypeName = classInfo.superclass;
    if (!superTypeName.includes(':')) {
      const colonIdx = typeName.indexOf(':');
      const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : classInfo.moduleName;
      superTypeName = `${modPart}:${superTypeName}`;
    }

    // Find the super constructor
    const superCtorEntry = this.constructors.get(superTypeName);
    if (!superCtorEntry) return;
    const superParams = superCtorEntry.fn.metadata?.params;
    if (!superParams || !Array.isArray(superParams)) return;

    // Parse the args string: "(val1, val2, ...)"
    let inner = argsStr.trim();
    if (inner.startsWith('(')) inner = inner.substring(1);
    if (inner.endsWith(')')) inner = inner.substring(0, inner.length - 1);
    const argTokens = inner.split(',').map(s => s.trim()).filter(s => s.length > 0);

    // Map args to super constructor params
    const superFieldNames = this.collectAllFieldNames(superTypeName);
    for (let i = 0; i < Math.min(argTokens.length, superParams.length); i++) {
      const p = superParams[i];
      const pName = typeof p === 'string' ? p : p.name;
      const isThis = typeof p === 'object' && p.is_this;
      if (!pName) continue;

      let val: BallValue;
      const token = argTokens[i];
      // Parse the token: could be a string literal, number, or variable reference
      if ((token.startsWith("'") && token.endsWith("'")) || (token.startsWith('"') && token.endsWith('"'))) {
        val = token.substring(1, token.length - 1);
      } else if (!isNaN(Number(token))) {
        val = token.includes('.') ? new BallDouble(Number(token)) : Number(token);
      } else if (token === 'true') {
        val = true;
      } else if (token === 'false') {
        val = false;
      } else {
        // Variable reference: look up in resolvedArgs or scope
        val = resolvedArgs[token] ?? (scope.has(token) ? scope.lookup(token) : null);
      }

      // Set on instance and super chain
      if (isThis || superFieldNames.has(pName)) {
        instance[pName] = val;
        // Also set on __super__ chain
        let superObj = instance.__super__;
        while (superObj && typeof superObj === 'object') {
          if (pName in superObj || (superObj.__type__ && this.collectAllFieldNames(superObj.__type__ as string).has(pName))) {
            superObj[pName] = val;
          }
          superObj = superObj.__super__ as Record<string, BallValue> | undefined;
        }
      }
    }

    // Recursively apply super initializers up the chain
    const superCtorInit = superCtorEntry.fn.metadata?.initializers;
    if (Array.isArray(superCtorInit)) {
      const superClassInfo = this.classRegistry.get(superTypeName);
      if (superClassInfo) {
        // Build resolved args for the super constructor
        const superResolvedArgs: Record<string, BallValue> = {};
        for (let i = 0; i < Math.min(argTokens.length, superParams.length); i++) {
          const p = superParams[i];
          const pName = typeof p === 'string' ? p : p.name;
          if (pName) {
            const token = argTokens[i];
            if ((token.startsWith("'") && token.endsWith("'")) || (token.startsWith('"') && token.endsWith('"'))) {
              superResolvedArgs[pName] = token.substring(1, token.length - 1);
            } else if (!isNaN(Number(token))) {
              superResolvedArgs[pName] = Number(token);
            } else {
              superResolvedArgs[pName] = resolvedArgs[token] ?? (scope.has(token) ? scope.lookup(token) : null);
            }
          }
        }
        for (const si of superCtorInit) {
          if (si.kind === 'super' && typeof si.args === 'string') {
            this.applySuperInitializer(instance, superClassInfo, superTypeName, superResolvedArgs, si.args, scope);
          }
        }
      }
    }
  }

  /**
   * Try to dispatch a getter for fieldName on a typed object.
   * Returns undefined if no getter found.
   */
  private tryGetterDispatch(obj: Record<string, any>, fieldName: string): BallValue | undefined {
    const typeName: string = obj.__type__;
    if (!typeName) return undefined;

    const colonIdx = typeName.indexOf(':');
    const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : this.currentModule;

    // Check "module.typeName.fieldName" as a getter.
    const getterKey = `${modPart}.${typeName}.${fieldName}`;
    const getterFunc = this.getters.get(getterKey) ?? this.functions.get(getterKey);
    if (getterFunc && this.isGetter(getterFunc)) {
      return this.callFunction(modPart, getterFunc, { self: obj }, new Scope());
    }

    // Walk superclass chain for inherited getters.
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo?.superclass) {
      let superTypeName = classInfo.superclass;
      if (!superTypeName.includes(':')) {
        superTypeName = `${modPart}:${superTypeName}`;
      }
      const superObj: Record<string, any> = { ...obj, __type__: superTypeName };
      return this.tryGetterDispatch(superObj, fieldName);
    }

    return undefined;
  }

  /**
   * Check if a function is a getter (no params, kind=method or has is_getter).
   */
  private isGetter(fn: FunctionDef): boolean {
    if (fn.metadata?.is_getter) return true;
    // A method with no params that has a body acts as a getter.
    if (fn.metadata?.kind === 'method' && !fn.metadata?.params && fn.body) return true;
    if (fn.metadata?.kind === 'getter') return true;
    return false;
  }

  /**
   * Check if a function is a setter.
   */
  private isSetter(fn: FunctionDef): boolean {
    if (fn.metadata?.is_setter) return true;
    if (fn.metadata?.kind === 'setter') return true;
    return false;
  }

  private evalBlock(block: Block, scope: Scope): BallValue {
    const blockScope = scope.child();
    let lastResult: BallValue = null;
    if (!block.statements) block.statements = [];

    for (const stmt of block.statements) {
      if (stmt.let) {
        let val = this.evalExpr(stmt.let.value, blockScope);
        if (val instanceof FlowSignal) return val;
        // If the let type says Map but we got an empty array (from set_create), convert to object.
        const letType = stmt.let.metadata?.type;
        if (letType && typeof letType === 'string' && letType.startsWith('Map') && Array.isArray(val) && val.length === 0) {
          val = {};
        }
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
        for (const stmt of fields.init.block.statements ?? []) {
          if (stmt.let) {
            const val = stmt.let.value ? this.evalExpr(stmt.let.value, forScope) : null;
            forScope.bind(stmt.let.name, val);
          } else if (stmt.expression) {
            this.evalExpr(stmt.expression, forScope);
          }
        }
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
    let matched = false;
    for (const c of cases) {
      if (!c.messageCreation) continue;
      const cf: Record<string, Expression> = {};
      for (const f of (c.messageCreation.fields ?? [])) cf[f.name] = f.value;
      if (cf.is_default?.literal?.boolValue) { defaultBody = cf.body; continue; }

      if (!matched) {
        // Standard value-based case
        if (cf.value) {
          const caseVal = this.evalExpr(cf.value, scope);
          if (this.ballEquals(caseVal, subject)) matched = true;
        }
        // Pattern-based case (e.g., ConstPattern)
        if (!matched && cf.pattern_expr) {
          const pattern = this.evalExpr(cf.pattern_expr, scope);
          const patternVal = (pattern && typeof pattern === 'object' && 'value' in pattern) ? pattern.value : pattern;
          if (this.ballEquals(patternVal, subject)) matched = true;
        }
      }

      // If matched, execute the body. Support fall-through: if body is empty, continue to next case.
      if (matched && cf.body) {
        const isEmpty = cf.body.block && (!cf.body.block.statements || cf.body.block.statements.length === 0) && !cf.body.block.result;
        if (isEmpty) continue; // fall-through to next case
        let result = this.evalExpr(cf.body, scope);
        // Consume unlabeled break (switch break, not loop break)
        if (result instanceof FlowSignal && result.kind === 'break' && !result.label) {
          return null;
        }
        return result;
      }
    }
    if (defaultBody) {
      let result = this.evalExpr(defaultBody, scope);
      if (result instanceof FlowSignal && result.kind === 'break' && !result.label) {
        return null;
      }
      return result;
    }
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
        for (const f of (c.messageCreation.fields ?? [])) cf[f.name] = f.value;
        const catchType = cf.type?.literal?.stringValue;
        if (catchType) {
          let matches = false;
          if (e instanceof BallException) {
            // Match with or without module prefix: "FormatException" matches "main:FormatException"
            matches = this.typeNameMatches(e.typeName, catchType);
          } else {
            matches = e?.constructor?.name === catchType;
          }
          if (!matches) continue;
        }
        const variable = cf.variable?.literal?.stringValue ?? 'e';
        if (cf.body) {
          const catchScope = scope.child();
          let exceptionValue: BallValue;
          if (e instanceof BallException) {
            const val = e.value;
            // Create an exception object with a 'message' field for typed exceptions
            if (val && typeof val === 'object' && !Array.isArray(val)) {
              exceptionValue = val;
              // Set message from arg0 if not already set
              if (!('message' in val) && 'arg0' in val) {
                val.message = val.arg0;
              }
            } else {
              exceptionValue = val;
            }
          } else if (e instanceof Error) {
            exceptionValue = e.message;
          } else {
            exceptionValue = String(e);
          }
          catchScope.bind(variable, exceptionValue);
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

    // Detect pattern: assign(target: var, value: list_remove_at(list: var, ...))
    // The list mutation already happens in-place. The return value is the removed element.
    // We should NOT overwrite the variable with the removed element.
    const valueExpr = fields.value;
    const target = fields.target ?? fields.name ?? fields.variable;
    if (valueExpr?.call && target?.reference) {
      const valFn = valueExpr.call.function;
      const valMod = valueExpr.call.module ?? '';
      if ((valFn === 'list_remove_at' || valFn === 'list_pop' || valFn === 'list_remove_last') &&
          (valMod === 'std' || valMod === 'std_collections' || valMod === '')) {
        // Check if the list argument references the same variable as the target
        const valInput = valueExpr.call.input;
        if (valInput?.messageCreation?.fields) {
          const listField = valInput.messageCreation.fields.find((f: any) => f.name === 'list');
          if (listField?.value?.reference?.name === target.reference.name) {
            // In-place mutation: evaluate the value (which mutates the list) and return it.
            // Don't reassign the target variable.
            const removedVal = this.evalExpr(fields.value, scope);
            return removedVal;
          }
        }
      }
    }

    const val = this.evalExpr(fields.value, scope);

    if (!target) return null;

    // Handle field access assignment: target is a fieldAccess (obj.field = val)
    if (target.fieldAccess) {
      const obj = this.evalExpr(target.fieldAccess.object, scope);
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
        const fieldName = target.fieldAccess.field;
        const op = fields.op?.literal?.stringValue;

        if (op && op !== '=') {
          const current = obj[fieldName];
          const computed = this.applyCompoundOp(op, current, val);
          obj[fieldName] = computed;
          // Sync to scope if self is bound
          if (scope.has(fieldName)) {
            try { scope.assign(fieldName, computed); } catch { /* ignore */ }
          }
          return computed;
        }

        // Check for setter dispatch on typed objects.
        if (obj.__type__) {
          const setterResult = this.trySetterDispatch(obj, fieldName, val, scope);
          if (setterResult !== undefined) return setterResult;
        }

        obj[fieldName] = val;
        // Sync to scope if field name is bound (for method bodies)
        if (scope.has(fieldName)) {
          try { scope.assign(fieldName, val); } catch { /* ignore */ }
        }
        return val;
      }
    }

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
      let current: BallValue;
      try { current = scope.lookup(name); } catch { current = null; }
      const computed = this.applyCompoundOp(op, current, val);
      try { scope.assign(name, computed); } catch { scope.bind(name, computed); }
      // Sync to self object if inside a method.
      this.syncFieldToSelf(scope, name, computed);
      return computed;
    }
    try { scope.assign(name, val); } catch { scope.bind(name, val); }
    // Sync to self object if inside a method.
    this.syncFieldToSelf(scope, name, val);
    return val;
  }

  /**
   * When inside a method, sync a field assignment back to the self object.
   */
  private syncFieldToSelf(scope: Scope, fieldName: string, val: BallValue): void {
    if (!scope.has('self')) return;
    try {
      const self = scope.lookup('self');
      if (self && typeof self === 'object' && !Array.isArray(self) && self.__type__) {
        // Check if this field belongs to the instance
        if (fieldName in self) {
          self[fieldName] = val;
        }
        // Also sync to __super__ chain
        let superObj = self.__super__;
        while (superObj && typeof superObj === 'object' && !Array.isArray(superObj)) {
          if (fieldName in superObj) {
            superObj[fieldName] = val;
          }
          superObj = superObj.__super__;
        }
      }
    } catch { /* ignore */ }
  }

  /**
   * Try to dispatch a setter function for fieldName on a typed object.
   * Returns undefined if no setter found.
   */
  private trySetterDispatch(obj: Record<string, any>, fieldName: string, value: BallValue, scope: Scope): BallValue | undefined {
    const typeName: string = obj.__type__;
    if (!typeName) return undefined;

    const colonIdx = typeName.indexOf(':');
    const modPart = colonIdx >= 0 ? typeName.substring(0, colonIdx) : this.currentModule;

    // Look in setters map first.
    const setterKey = `${modPart}.${typeName}.${fieldName}`;
    const setterFunc = this.setters.get(setterKey) ?? this.setters.get(`${setterKey}=`);
    if (setterFunc) {
      return this.callFunction(modPart, setterFunc, { self: obj, value, arg0: value }, scope);
    }

    // Walk superclass chain.
    const classInfo = this.classRegistry.get(typeName);
    if (classInfo?.superclass) {
      let superTypeName = classInfo.superclass;
      if (!superTypeName.includes(':')) {
        superTypeName = `${modPart}:${superTypeName}`;
      }
      const superObj: Record<string, any> = { ...obj, __type__: superTypeName };
      return this.trySetterDispatch(superObj, fieldName, value, scope);
    }

    return undefined;
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

    const isInc = call.function.includes('increment');
    const isPre = call.function.startsWith('pre');

    if (valueExpr.reference) {
      const name = valueExpr.reference.name;
      const current = this.toNum(scope.lookup(name));
      const updated = isInc ? current + 1 : current - 1;
      scope.assign(name, updated);
      // Sync to self if inside a method
      this.syncFieldToSelf(scope, name, updated);
      return isPre ? updated : current;
    }

    // Handle indexed expressions: count[x]++ => post_increment(value: index(target, index))
    if (valueExpr.call && valueExpr.call.function === 'index' && (valueExpr.call.module === 'std' || !valueExpr.call.module)) {
      const indexInput = valueExpr.call.input ? this.evalExpr(valueExpr.call.input, scope) : null;
      if (indexInput) {
        const container = indexInput.target ?? indexInput.list ?? indexInput.map;
        const idx = indexInput.index ?? indexInput.key;
        if (container != null && idx != null) {
          const current = this.toNum(Array.isArray(container) ? container[idx] : container[idx]);
          const updated = isInc ? current + 1 : current - 1;
          container[idx] = updated;
          return isPre ? updated : current;
        }
      }
    }

    // Handle field access: obj.field++ => post_increment(value: fieldAccess)
    if (valueExpr.fieldAccess) {
      const obj = this.evalExpr(valueExpr.fieldAccess.object, scope);
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
        const fieldName = valueExpr.fieldAccess.field;
        const current = this.toNum(obj[fieldName]);
        const updated = isInc ? current + 1 : current - 1;
        obj[fieldName] = updated;
        return isPre ? updated : current;
      }
    }

    // Fallback: just compute
    const val = this.toNum(this.evalExpr(valueExpr, scope));
    return isInc ? val + 1 : val - 1;
  }

  private evalLabeled(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const label = fields.label?.literal?.stringValue;
    if (!fields.body) return null;

    // Check if the body contains a for/while/for_in loop. If so, pass the label
    // to the loop so it can handle labeled break/continue directly.
    const bodyExpr = fields.body;
    const loopCall = this.extractLoopFromBody(bodyExpr);
    if (loopCall && label) {
      // Evaluate the loop with the label
      const result = this.evalLabeledLoop(loopCall, label, scope);
      if (result instanceof FlowSignal &&
          (result.kind === 'break' || result.kind === 'continue') &&
          result.label === label) {
        return null;
      }
      return result;
    }

    const result = this.evalExpr(fields.body, scope);
    if (result instanceof FlowSignal &&
        (result.kind === 'break' || result.kind === 'continue') &&
        result.label === label) {
      return null; // consumed
    }
    return result;
  }

  /**
   * Extract the loop call from a labeled body expression.
   * The body might be a block containing a single for/while/for_in call.
   */
  private extractLoopFromBody(expr: Expression): FunctionCall | null {
    // Direct call to a loop
    if (expr.call) {
      const fn = expr.call.function;
      if (fn === 'for' || fn === 'while' || fn === 'for_in' || fn === 'do_while') {
        return expr.call;
      }
    }
    // Block containing a single statement that is a loop call
    if (expr.block?.statements?.length === 1) {
      const stmt = expr.block.statements[0];
      if (stmt.expression?.call) {
        const fn = stmt.expression.call.function;
        if (fn === 'for' || fn === 'while' || fn === 'for_in' || fn === 'do_while') {
          return stmt.expression.call;
        }
      }
    }
    return null;
  }

  /**
   * Evaluate a for/while loop with a label, handling labeled break/continue.
   */
  private evalLabeledLoop(loopCall: FunctionCall, label: string, scope: Scope): BallValue {
    const fn = loopCall.function;
    if (fn === 'for') return this.evalLabeledFor(loopCall, label, scope);
    if (fn === 'for_in') return this.evalLabeledForIn(loopCall, label, scope);
    if (fn === 'while') return this.evalLabeledWhile(loopCall, label, scope);
    // Fallback: evaluate normally
    return this.evalExpr({ call: loopCall }, scope);
  }

  private evalLabeledFor(call: FunctionCall, label: string, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    const forScope = scope.child();
    if (fields.init) {
      if (fields.init.literal?.stringValue) {
        const match = fields.init.literal.stringValue.match(/^(?:var|final|int|double|String)\s+(\w+)\s*=\s*(.+)$/);
        if (match) {
          const varName = match[1];
          const rawVal = match[2].trim();
          const parsed = this.parseInitValue(rawVal, forScope);
          forScope.bind(varName, parsed);
        }
      } else if (fields.init.block) {
        for (const stmt of fields.init.block.statements ?? []) {
          if (stmt.let) {
            const val = stmt.let.value ? this.evalExpr(stmt.let.value, forScope) : null;
            forScope.bind(stmt.let.name, val);
          } else if (stmt.expression) {
            this.evalExpr(stmt.expression, forScope);
          }
        }
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
          // Check labeled signals against our label
          if (result.label === label) {
            if (result.kind === 'break') break;
            if (result.kind === 'continue') { if (fields.update) this.evalExpr(fields.update, forScope); continue; }
          }
          // Other labeled signals: propagate
          if (result.label) return result;
          if (result.kind === 'break') break;
          if (result.kind === 'continue') { if (fields.update) this.evalExpr(fields.update, forScope); continue; }
        }
      }
      if (fields.update) this.evalExpr(fields.update, forScope);
    }
    return null;
  }

  private evalLabeledForIn(call: FunctionCall, label: string, scope: Scope): BallValue {
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
        if (result.label === label) {
          if (result.kind === 'break') break;
          if (result.kind === 'continue') continue;
        }
        if (result.label) return result;
        if (result.kind === 'break') break;
        if (result.kind === 'continue') continue;
      }
    }
    return null;
  }

  private evalLabeledWhile(call: FunctionCall, label: string, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    while (true) {
      if (fields.condition) {
        if (!this.toBool(this.evalExpr(fields.condition, scope))) break;
      }
      if (fields.body) {
        const result = this.evalExpr(fields.body, scope);
        if (result instanceof FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label === label) {
            if (result.kind === 'break') break;
            if (result.kind === 'continue') continue;
          }
          if (result.label) return result;
          if (result.kind === 'break') break;
          if (result.kind === 'continue') continue;
        }
      }
    }
    return null;
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

  /**
   * Evaluate cascade lazily: evaluate target, bind __cascade_self__, evaluate sections, return target.
   */
  private evalCascade(call: FunctionCall, scope: Scope): BallValue {
    const fields = this.lazyFields(call);
    if (!fields.target) return null;
    const target = this.evalExpr(fields.target, scope);

    // Bind __cascade_self__ to the target for section evaluation.
    const cascadeScope = scope.child();
    cascadeScope.bind('__cascade_self__', target);

    // Evaluate sections (they reference __cascade_self__).
    if (fields.sections) {
      const sections = fields.sections.literal?.listValue?.elements ?? [];
      for (const section of sections) {
        const result = this.evalExpr(section, cascadeScope);
        if (result instanceof FlowSignal) return result;
      }
    }

    return target;
  }

  // ── Built-in method dispatch ──────────────────────────────────────────

  /**
   * Dispatches method-style calls (with `self` in input) on built-in types.
   * Returns `undefined` (not `null`) when the method is not recognized, so
   * callers can fall through to user-defined method resolution.
   */
  private dispatchBuiltinMethod(method: string, self: BallValue, input: BallValue): BallValue | undefined {
    const arg0 = input?.arg0;

    // Static method calls on class descriptors (e.g., MathUtils.max).
    if (self && (typeof self === 'object' || typeof self === 'function') && self.__class_name__) {
      const className = self.__class_name__;
      const modName = self.__module__;
      const qualName = `${modName}:${className}`;
      // Look up "modName.qualName.method"
      const methodKey = `${modName}.${qualName}.${method}`;
      const fn = this.functions.get(methodKey);
      if (fn) {
        if (fn.metadata?.kind === 'constructor') {
          return this.callNamedConstructor(modName, qualName, fn, input, new Scope());
        }
        return this.callFunction(modName, fn, input, new Scope());
      }
      return undefined;
    }

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
      if (typeName === 'Map') {
        switch (method) {
          case 'fromEntries': {
            const entries = Array.isArray(arg0) ? arg0 : [];
            const result: Record<string, BallValue> = {};
            for (const entry of entries) {
              if (entry && typeof entry === 'object') {
                // MapEntry: {key, value} or {arg0, arg1} or {__type__: ...MapEntry, arg0, arg1}
                const k = entry.key ?? entry.arg0;
                const v = entry.value ?? entry.arg1;
                if (k !== undefined) result[String(k)] = v;
              }
            }
            return result;
          }
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
        // Set operations (sets are encoded as arrays)
        case 'union': {
          const other = Array.isArray(arg0) ? arg0 : [];
          return [...new Set([...self, ...other])];
        }
        case 'intersection': {
          const other = new Set(Array.isArray(arg0) ? arg0 : []);
          return self.filter((x: any) => other.has(x));
        }
        case 'difference': {
          const other = new Set(Array.isArray(arg0) ? arg0 : []);
          return self.filter((x: any) => !other.has(x));
        }
        case 'addAll': {
          const other = Array.isArray(arg0) ? arg0 : [];
          for (const item of other) {
            if (!self.includes(item)) self.push(item);
          }
          return null;
        }
        case 'toSet': return [...new Set(self)];
        case 'expand': {
          const fn = arg0;
          if (typeof fn === 'function') {
            const result: any[] = [];
            for (const item of self) {
              const expanded = fn(item);
              if (Array.isArray(expanded)) result.push(...expanded);
              else result.push(expanded);
            }
            return result;
          }
          return self;
        }
        case 'take': return self.slice(0, this.toNum(arg0));
        case 'skip': return self.slice(this.toNum(arg0));
        case 'fold': {
          const fn = input?.arg1;
          const init = arg0;
          if (typeof fn === 'function') return self.reduce((acc: any, item: any) => fn({ arg0: acc, arg1: item }), init);
          return init;
        }
        case 'followedBy': {
          const other = Array.isArray(arg0) ? arg0 : [];
          return [...self, ...other];
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

    // ── Map/Object methods (non-array objects without __type__) ─��
    if (self && typeof self === 'object' && !Array.isArray(self)) {
      // StringBuffer support
      const typeName = self.__type__;
      if (typeName && (typeName.endsWith(':StringBuffer') || typeName === 'StringBuffer')) {
        switch (method) {
          case 'write': {
            self.__buffer__ = (self.__buffer__ ?? '') + this.ballToString(arg0);
            return null;
          }
          case 'writeCharCode': {
            self.__buffer__ = (self.__buffer__ ?? '') + String.fromCharCode(this.toNum(arg0));
            return null;
          }
          case 'writeAll': {
            const items = Array.isArray(arg0) ? arg0 : [];
            const sep = input?.arg1 != null ? String(input.arg1) : '';
            self.__buffer__ = (self.__buffer__ ?? '') + items.map((x: any) => this.ballToString(x)).join(sep);
            return null;
          }
          case 'toString': return self.__buffer__ ?? '';
          case 'length': return (self.__buffer__ ?? '').length;
          case 'isEmpty': return (self.__buffer__ ?? '').length === 0;
          case 'isNotEmpty': return (self.__buffer__ ?? '').length > 0;
          case 'clear': { self.__buffer__ = ''; return null; }
        }
      }
      switch (method) {
        case 'containsKey': return arg0 in self;
        case 'containsValue': return Object.values(self).includes(arg0);
        case 'remove': { const v = self[arg0]; delete self[arg0]; return v; }
        case 'keys': return Object.keys(self).filter(k => !k.startsWith('__'));
        case 'values': return Object.entries(self).filter(([k]) => !k.startsWith('__')).map(([, v]) => v);
        case 'entries': return Object.entries(self).filter(([k]) => !k.startsWith('__')).map(([k, v]) => ({ key: k, value: v }));
        case 'length': return Object.keys(self).filter(k => !k.startsWith('__')).length;
        case 'isEmpty': return Object.keys(self).filter(k => !k.startsWith('__')).length === 0;
        case 'isNotEmpty': return Object.keys(self).filter(k => !k.startsWith('__')).length > 0;
        case 'putIfAbsent': {
          if (!(arg0 in self)) {
            const valueFn = input?.arg1;
            self[arg0] = typeof valueFn === 'function' ? valueFn(null) : valueFn;
          }
          return self[arg0];
        }
        case 'toString': {
          if (self.__type__) {
            // For typed objects, try toString method
            const resolved = this.resolveMethod(self.__type__, 'toString');
            if (resolved) {
              return this.callFunction(resolved.modPart, resolved.fn, { self }, new Scope());
            }
          }
          return JSON.stringify(self);
        }
        case 'forEach': case 'for_each': {
          const fn = arg0;
          if (typeof fn === 'function') {
            for (const [k, v] of Object.entries(self).filter(([k]) => !k.startsWith('__'))) {
              fn({ key: k, value: v, arg0: k, arg1: v });
            }
          }
          return null;
        }
        case 'map': {
          const fn = arg0;
          if (typeof fn === 'function') {
            const result: Record<string, any> = {};
            for (const [k, v] of Object.entries(self).filter(([k]) => !k.startsWith('__'))) {
              const mapped = fn({ key: k, value: v, arg0: k, arg1: v });
              if (mapped && typeof mapped === 'object' && 'key' in mapped && 'value' in mapped) {
                result[String(mapped.key)] = mapped.value;
              } else {
                result[k] = mapped;
              }
            }
            return result;
          }
          return self;
        }
        case 'addAll': {
          if (arg0 && typeof arg0 === 'object' && !Array.isArray(arg0)) {
            Object.assign(self, arg0);
          }
          return null;
        }
        case 'update': {
          const key = String(arg0);
          const updateFn = input?.arg1;
          if (typeof updateFn === 'function' && key in self) {
            self[key] = updateFn(self[key]);
          }
          return self[key];
        }
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

    // Operator overloading: if left operand is a typed object, try operator dispatch.
    const operatorMap: Record<string, string> = {
      'add': '+', 'subtract': '-', 'multiply': '*', 'divide': '/',
      'modulo': '%', 'equals': '==', 'not_equals': '!=',
      'less_than': '<', 'greater_than': '>', 'lte': '<=', 'gte': '>=',
    };
    if (left && typeof left === 'object' && !Array.isArray(left) && left.__type__ && fn in operatorMap) {
      const opName = operatorMap[fn];
      const resolved = this.resolveMethod(left.__type__, opName);
      if (resolved) {
        return this.callFunction(resolved.modPart, resolved.fn, { self: left, arg0: right, right }, new Scope());
      }
    }

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
      case 'divide_double': return new BallDouble(this.toNum(left) / this.toNum(right));
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
      case 'contains':
      case 'string_contains': {
        const v = value ?? input?.value ?? input?.string ?? input;
        const search = input?.arg0 ?? input?.value ?? input?.substring ?? '';
        if (typeof v === 'string') return v.includes(String(search));
        if (Array.isArray(v)) return v.includes(search);
        return false;
      }
      case 'string_substring': return String(input?.string ?? input?.value ?? '').substring(input?.start ?? 0, input?.end);
      case 'string_to_upper': return String(value ?? input).toUpperCase();
      case 'string_to_lower': return String(value ?? input).toLowerCase();
      case 'string_trim': return String(value ?? input).trim();
      case 'string_split': return String(input?.string ?? input?.value ?? '').split(String(input?.delimiter ?? input?.separator ?? ''));
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
      case 'math_clamp': {
        // Handle both direct calls math_clamp({value, min, max}) and
        // static method style math_clamp({value: classRef, min: val, max: lo, arg2: hi})
        let v: number, lo: number, hi: number;
        if (input?.value && typeof input.value === 'object') {
          // Static method style: min=value, max=lower, arg2=upper
          v = this.toNum(input?.min);
          lo = this.toNum(input?.max);
          hi = this.toNum(input?.arg2);
        } else {
          v = this.toNum(input?.value ?? input);
          lo = this.toNum(input?.min ?? input?.low ?? input?.lower ?? left);
          hi = this.toNum(input?.max ?? input?.high ?? input?.upper ?? right);
        }
        return Math.min(Math.max(v, lo), hi);
      }
      case 'math_pi': return Math.PI;

      // Error handling
      case 'throw': {
        const rawVal = input?.value ?? input?.message ?? input;
        const typeName = input?.type ?? rawVal?.__type__ ?? rawVal?.__type ?? 'Exception';
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
      case 'list_push': {
        const l = input?.list;
        if (Array.isArray(l)) { l.push(input?.value); return l; }
        return [...(l ?? []), input?.value];
      }
      case 'list_length': return (input?.list ?? input ?? []).length;
      case 'list_get': return (input?.list ?? [])[input?.index ?? 0];
      case 'list_map': {
        const list = input?.list ?? [];
        const fn = input?.function ?? input?.value;
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
      case 'list_pop':
      case 'list_remove_last': {
        const list = input?.list ?? [];
        if (Array.isArray(list)) return list.pop();
        return null;
      }
      case 'list_remove_at': {
        const list = input?.list ?? [];
        const idx = this.toNum(input?.index ?? 0);
        if (Array.isArray(list)) return list.splice(idx, 1)[0];
        return null;
      }
      case 'list_contains': {
        const list = input?.list ?? [];
        if (typeof list === 'string') return list.includes(String(input?.value ?? ''));
        if (Array.isArray(list)) return list.includes(input?.value);
        if (typeof list === 'object' && list !== null) return Object.values(list).includes(input?.value);
        return false;
      }
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
      case 'list_reverse': return [...(input?.list ?? [])].reverse();
      case 'list_clear': return [];
      case 'list_to_list': return [...(input?.list ?? [])];
      case 'list_slice': {
        const l = input?.list ?? [];
        // Support both named fields (start/end) and positional args (arg0/arg1) and 'value' field
        let s: number, e: number | undefined;
        if (input?.start != null) {
          s = this.toNum(input.start);
          e = input?.end != null ? this.toNum(input.end) : undefined;
        } else if (input?.arg0 != null && input?.arg1 != null) {
          // Duplicate 'value' fields were converted to arg0/arg1
          s = this.toNum(input.arg0);
          e = this.toNum(input.arg1);
        } else if (input?.value != null) {
          // Single 'value' field: treat as start index (end = undefined)
          s = this.toNum(input.value);
          e = undefined;
        } else {
          s = 0;
          e = undefined;
        }
        return l.slice(s, e);
      }
      case 'list_all': {
        const l = input?.list ?? [];
        const fn = input?.function ?? input?.callback;
        if (typeof fn === 'function') return l.every((x: any) => fn(x));
        return true;
      }
      case 'map_put_if_absent': {
        const m = input?.map ?? {};
        const k = String(input?.key ?? '');
        if (!(k in m)) { const v = input?.value; m[k] = typeof v === 'function' ? v() : v; }
        return m[k];
      }
      case 'list_sort': {
        const list = input?.list ?? [];
        const cmp = input?.compare ?? input?.comparator ?? input?.value;
        if (typeof cmp === 'function') {
          list.sort((a: any, b: any) => cmp({ arg0: a, arg1: b, a, b }));
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
        const fn = input?.function ?? input?.value;
        if (typeof fn === 'function') {
          if (Array.isArray(list)) {
            list.forEach((item: any) => fn(item));
          } else if (typeof list === 'object' && list !== null) {
            // Map iteration: call fn with {key, value, arg0: key, arg1: value} entries
            for (const [k, v] of Object.entries(list).filter(([k]) => !k.startsWith('__'))) {
              fn({ key: k, value: v, arg0: k, arg1: v });
            }
          }
        }
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
        if (!elems || (Array.isArray(elems) && elems.length === 0)) return [];
        if (Array.isArray(elems)) return [...new Set(elems)];
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
      case 'identical': return left === right;
      case 'compare_to': {
        const v = input?.value ?? left;
        const other = input?.other ?? right;
        if (typeof v === 'string' && typeof other === 'string') return v < other ? -1 : v > other ? 1 : 0;
        return this.toNum(v) < this.toNum(other) ? -1 : this.toNum(v) > this.toNum(other) ? 1 : 0;
      }
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
      case 'string_code_unit_at': return String(input?.string ?? input?.value ?? '').charCodeAt(this.toNum(input?.index ?? 0));
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

  private ballEquals(a: BallValue, b: BallValue): boolean {
    // Unwrap BallDouble for comparison
    const av = a instanceof BallDouble ? a.value : a;
    const bv = b instanceof BallDouble ? b.value : b;
    if (av === bv) return true;
    // Compare numbers
    if (typeof av === 'number' && typeof bv === 'number') return av === bv;
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
    if (typeof v === 'object') {
      // StringBuffer: return the buffer
      if (v.__type__ && (v.__type__.endsWith(':StringBuffer') || v.__type__ === 'StringBuffer')) {
        return v.__buffer__ ?? '';
      }
      // If the object has a __type__ and a toString method, call it.
      if (v.__type__) {
        const resolved = this.resolveMethod(v.__type__, 'toString');
        if (resolved) {
          const result = this.callFunction(resolved.modPart, resolved.fn, { self: v }, new Scope());
          if (typeof result === 'string') return result;
          return String(result);
        }
      }
      return JSON.stringify(v);
    }
    return String(v);
  }
}
