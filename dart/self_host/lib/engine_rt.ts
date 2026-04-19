// Ball TypeScript runtime preamble.
// Auto-prepended to every emitted program. Provides the small set of
// helpers the compiler's std-call emissions rely on.

function __ball_to_string(v: any): string {
  if (typeof v === 'string') return v;
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    // Dart's `.toString()` on an int produces "13", not "13.0". Ball
    // programs that explicitly want the ".0" suffix on whole doubles
    // call `std.double_to_string` instead, which routes to
    // `__ball_double_to_string`. The generic path assumes int-like
    // formatting when the number is integral, matching Dart's int
    // default.
    if (Number.isInteger(v)) return v.toString();
    return __ball_double_to_string(v);
  }
  if (typeof v === 'bigint') return v.toString();
  if (v === null || v === undefined) return 'null';
  if (Array.isArray(v)) return '[' + v.map(__ball_to_string).join(', ') + ']';
  return String(v);
}

function __ball_double_to_string(d: number): string {
  if (Number.isNaN(d)) return 'NaN';
  if (d === Infinity) return 'Infinity';
  if (d === -Infinity) return '-Infinity';
  // Dart-style: whole numbers render as "6.0", not "6".
  if (Number.isInteger(d) && Math.abs(d) < 1e16) {
    return `${d.toString()}.0`;
  }
  return d.toString();
}

function __ball_parse_int(s: string): number {
  const trimmed = s.trim();
  if (!/^-?\d+$/.test(trimmed)) {
    const err = new Error(`FormatException: ${s}`);
    throw err;
  }
  return parseInt(trimmed, 10);
}

function __ball_parse_double(s: string): number {
  const n = parseFloat(s);
  if (Number.isNaN(n)) {
    const err = new Error(`FormatException: ${s}`);
    throw err;
  }
  return n;
}

// Active exception marker used by `rethrow` — the catch block binds
// the raw error to this name and `throw __ball_active_error;` re-raises
// it. Declared as `any` so it's visible everywhere; the catch binding
// shadows it within scope.
let __ball_active_error: any = undefined;

// ── Dart → JS Map / Array / String polyfills ──────────────────────
// Ball-compiled code still calls Dart-flavored method names (.containsKey,
// .add, etc.) because the TS compiler doesn't rewrite call sites. Node's
// --experimental-strip-types removes TS annotations at runtime, so type
// errors don't matter here; these polyfills make the calls actually work.
// Each guard skips the patch if it already exists so multiple emitted
// files sharing the preamble don't double-install.
(function installBallPolyfills() {
  const mp: any = Map.prototype;
  if (!mp.containsKey) mp.containsKey = function (k: any) { return this.has(k); };
  if (!mp.putIfAbsent) {
    mp.putIfAbsent = function (k: any, supplier: any) {
      if (!this.has(k)) this.set(k, supplier());
      return this.get(k);
    };
  }
  if (!mp.addAll) {
    mp.addAll = function (other: any) {
      if (other instanceof Map) {
        for (const [k, v] of other.entries()) this.set(k, v);
      } else if (other && typeof other === 'object') {
        for (const k of Object.keys(other)) this.set(k, other[k]);
      }
    };
  }
  // Map.entries / .keys / .values already exist; Dart uses the same names.
  // Dart Map.isEmpty / isNotEmpty are getters.
  Object.defineProperty(mp, 'isEmpty', {
    configurable: true,
    get() { return this.size === 0; },
  });
  Object.defineProperty(mp, 'isNotEmpty', {
    configurable: true,
    get() { return this.size !== 0; },
  });

  const ap: any = Array.prototype;
  if (!ap.add) ap.add = function (v: any) { this.push(v); };
  if (!ap.addAll) ap.addAll = function (iter: any) {
    for (const v of iter) this.push(v);
  };
  if (!ap.removeLast) ap.removeLast = function () { return this.pop(); };
  Object.defineProperty(ap, 'isEmpty', {
    configurable: true,
    get() { return this.length === 0; },
  });
  Object.defineProperty(ap, 'isNotEmpty', {
    configurable: true,
    get() { return this.length !== 0; },
  });
  Object.defineProperty(ap, 'first', {
    configurable: true,
    get() { return this[0]; },
  });
  Object.defineProperty(ap, 'last', {
    configurable: true,
    get() { return this[this.length - 1]; },
  });
  // Array.prototype.map / forEach / every / some already exist. Dart's
  // `where` is JS's `filter`; add an alias.
  if (!ap.where) ap.where = Array.prototype.filter;
  if (!ap.toList) ap.toList = function () { return this.slice(); };
  if (!ap.contains) ap.contains = function (v: any) { return this.indexOf(v) >= 0; };
  if (!ap.toSet) ap.toSet = function () { return new Set(this); };

  const sp: any = String.prototype;
  // Dart String getters.
  Object.defineProperty(sp, 'isEmpty', {
    configurable: true,
    get() { return this.length === 0; },
  });
  Object.defineProperty(sp, 'isNotEmpty', {
    configurable: true,
    get() { return this.length !== 0; },
  });
})();

export type BallValue = any;
export type BallCallable = any;

export class _FlowSignal {
  readonly kind: string;
  readonly label: string;
  readonly value: BallValue;

  constructor(kind: any, label: any, value: any) {
    this.kind = kind;
    this.label = label;
    this.value = value;
  }
}

export class _Scope {
  readonly _bindings: Map<string, BallValue>;
  readonly _parent: _Scope;
  readonly _scopeExits: Array<any>;

  constructor(_parent: any) {
    this._parent = _parent;
  }

  lookup(name: any): any {
    const input = name;
    if (this._bindings.containsKey(name)) {
      return this._bindings[name];
    }
    if ((this._parent !== null)) {
      return this._parent.lookup(name);
    }
    throw new BallRuntimeError((('Undefined variable: "' + __ball_to_string(name)) + '"'));
  }

  bind(name: any, value: any): any {
    return (this._bindings[name] = value);
  }

  has(name: any): any {
    const input = name;
    if (this._bindings.containsKey(name)) {
      return true;
    }
    return (this._parent?.has(name) ?? false);
  }

  set(name: any, value: any): any {
    if (this._bindings.containsKey(name)) {
      this._bindings[name] = value;
      return;
    }
    if (((this._parent !== null) && this._parent.has(name))) {
      this._parent.set(name, value);
      return;
    }
    this._bindings[name] = value;
  }

  registerScopeExit(cleanup: any, evalScope: any): any {
    return this._scopeExits.add(/* std.record */ record(cleanup, evalScope));
  }

  child(): any {
    return new _Scope(this);
  }
}

export class BallRuntimeError {
  readonly message: string;

  constructor(message: any) {
    this.message = message;
  }

  toString(): any {
    return ('BallRuntimeError: ' + __ball_to_string(this.message));
  }
}

export class BallFuture {
  readonly value: BallValue;
  readonly completed: boolean;

  constructor(value: any, completed: any) {
    this.value = value;
    this.completed = completed;
  }

  toString(): any {
    return (('BallFuture(' + __ball_to_string(this.value)) + ')');
  }
}

export class BallGenerator {
  readonly values: Array<BallValue>;
  completed: boolean;

  yield_(value: any): any {
    const input = value;
    return this.values.add(value);
  }

  yieldAll(items: any): any {
    const input = items;
    return this.values.addAll(items);
  }

  toString(): any {
    return (('BallGenerator(' + __ball_to_string(this.values.length)) + ' values)');
  }
}

export class BallException {
  readonly typeName: string;
  readonly value: any;

  constructor(typeName: any, value: any) {
    this.typeName = typeName;
    this.value = value;
  }

  toString(): any {
    return (this.value?.toString() ?? this.typeName);
  }
}

export class _ExitSignal {
  readonly code: number;

  constructor(code: any) {
    this.code = code;
  }
}

export abstract class BallModuleHandler {
  handles(module: any): any {
    const input = module;
  }

  call(function_: any, input: any, engine: any): any {

  }

  init(engine: any): any {
    const input = engine;
  }
}

export class StdModuleHandler extends BallModuleHandler {
  readonly _dispatch: any;
  readonly _composedDispatch: any;
  readonly _allowlist: Array<string>;
  readonly _tombstones: Array<string>;

  constructor() {
    super();
  }

  get registeredFunctions(): any {
    return Set.unmodifiable(/* std.set_create */ set_create([/* std.spread */ spread(this._dispatch.keys), /* std.spread */ spread(this._composedDispatch.keys)]));
  }

  static subset(functions: any): any {
    const input = functions;
  }

  handles(module: any): any {
    const input = module;
    return ((module) === '\'std\' || \'dart_std\' || \'std_collections\' || \'std_io\' || \'std_memory\' || \'std_convert\' || \'std_fs\' || \'std_time\' || \'std_concurrency\' || \'cpp_std\'' ? (true) : ((module) === '_' ? (false) : undefined));
  }

  init(engine: any): any {
    const input = engine;
    const full = engine._buildStdDispatch();
    const allowlist = this._allowlist;
    for (const entry of full.entries) {
      if (this._tombstones.contains(entry.key)) {
        continue;
      }
      if (this._composedDispatch.containsKey(entry.key)) {
        continue;
      }
      if (((allowlist !== null) && !allowlist.contains(entry.key))) {
        continue;
      }
      this._dispatch.putIfAbsent(entry.key, (() => {
        return entry.value;
      }));
    }
  }

  register(function_: any, handler: any): any {
    this._tombstones.remove(function_);
    this._composedDispatch.remove(function_);
    this._dispatch[function_] = handler;
  }

  registerComposer(function_: any, handler: any): any {
    this._tombstones.remove(function_);
    this._dispatch.remove(function_);
    this._composedDispatch[function_] = handler;
  }

  unregister(function_: any): any {
    const input = function_;
    this._tombstones.add(function_);
    this._dispatch.remove(function_);
    this._composedDispatch.remove(function_);
  }

  call(function_: any, input: any, engine: any): any {
    const composed = this._composedDispatch[function_];
    if ((composed !== null)) {
      return composed(input, engine);
    }
    const handler = this._dispatch[function_];
    if ((handler === null)) {
      throw new BallRuntimeError((('Unknown std function: "' + __ball_to_string(function_)) + '"'));
    }
    return handler(input);
  }
}

export class BallEngine {
  readonly program: Program;
  readonly _types: Map<string, google.DescriptorProto>;
  readonly _functions: Map<string, FunctionDefinition>;
  readonly _globalScope: _Scope;
  stdout: any;
  _currentModule: string;
  readonly _paramCache: Map<string, Array<string>>;
  readonly _callCache: Map<string, any>;
  readonly _enumValues: Map<string, Map<string, Map<string, any>>>;
  readonly _constructors: Map<string, any>;
  _callCounts: Map<string, number>;
  readonly moduleHandlers: Array<BallModuleHandler>;
  readonly _random: math.Random;
  stderr: any;
  stdinReader: any;
  _envGet: any;
  _args: Array<string>;
  _nextMutexId: number;
  _activeException: any;
  readonly _resolver: ModuleResolver;
  readonly _initialized: Promise<void>;

  constructor(program: any, stdout: any, stderr: any, stdinReader: any, envGet: any, args: any, enableProfiling: any, moduleHandlers: any, resolver: any) {
    this.program = program;
    this.stdinReader = stdinReader;
    if (enableProfiling) {
      this._callCounts = /* std.set_create */ set_create([]);
    }
    for (const handler of this.moduleHandlers) {
      handler.init(this);
    }
    this._buildLookupTables();
    this._initialized = this._initTopLevelVariables();
  }

  profilingReport(): any {
    return Map.unmodifiable((this._callCounts ?? /* std.set_create */ set_create([])));
  }

  callFunction(module: any, function_: any, input: any): any {
    return this._resolveAndCallFunction(module, function_, input);
  }

  _buildLookupTables(): any {
    for (const module of this.program.modules) {
      for (const type of module.types) {
        this._types[type.name] = type;
        const tc = type.name.indexOf(':');
        if ((tc >= 0)) {
          this._types[type.name.substring((tc + 1))] = type;
        }
      }
      for (const td of module.typeDefs) {
        if (td.hasDescriptor()) {
          this._types[td.name] = td.descriptor;
          const tc = td.name.indexOf(':');
          if ((tc >= 0)) {
            this._types[td.name.substring((tc + 1))] = td.descriptor;
          }
        }
      }
      for (const enumDesc of module.enums) {
        const enumName = enumDesc.name;
        const values = new Map();
        for (const v of enumDesc.value) {
          values[v.name] = new Map();
        }
        this._enumValues[enumName] = values;
        const ec = enumName.indexOf(':');
        if ((ec >= 0)) {
          this._enumValues[enumName.substring((ec + 1))] = values;
        }
      }
      for (const func of module.functions) {
        const key = ((__ball_to_string(module.name) + '.') + __ball_to_string(func.name));
        this._functions[key] = func;
        if (func.hasMetadata()) {
          const params = this._extractParams(func.metadata);
          if (params.isNotEmpty) {
            this._paramCache[key] = params;
          }
          const kindField = func.metadata.fields['kind'];
          if ((kindField?.stringValue === 'constructor')) {
            const entry = /* std.record */ record(module.name, func);
            const dotIdx = func.name.indexOf('.');
            if ((dotIdx >= 0)) {
              const className = func.name.substring(0, dotIdx);
              const ctorSuffix = func.name.substring((dotIdx + 1));
              if ((ctorSuffix === 'new')) {
                this._constructors[className] = entry;
                this._constructors[((__ball_to_string(module.name) + ':') + __ball_to_string(className))] = entry;
              }
              this._constructors[func.name] = entry;
            }
          }
        }
      }
    }
  }

  async _initTopLevelVariables(): Promise<any> {
    for (const module of this.program.modules) {
      if (((module.name === 'std') || (module.name === 'dart_std'))) {
        continue;
      }
      for (const func of module.functions) {
        if (!func.hasMetadata()) {
          continue;
        }
        const kindValue = func.metadata.fields['kind'];
        if ((kindValue?.stringValue !== 'top_level_variable')) {
          continue;
        }
        this._currentModule = module.name;
        const value = (func.hasBody() ? await this._evalExpression(func.body, this._globalScope) : null);
        this._globalScope.bind(func.name, value);
      }
    }
  }

  async run(): Promise<any> {
    await this._initialized;
    const key = ((__ball_to_string(this.program.entryModule) + '.') + __ball_to_string(this.program.entryFunction));
    const entryFunc = this._functions[key];
    if ((entryFunc === null)) {
      throw new BallRuntimeError(((('Entry point "' + __ball_to_string(this.program.entryFunction)) + '" not found ') + (('in module "' + __ball_to_string(this.program.entryModule)) + '"')));
    }
    this._currentModule = this.program.entryModule;
    return this._callFunction(this.program.entryModule, entryFunc, null);
  }

  async _callFunction(moduleName: any, func: any, input: any): Promise<any> {
    if (func.isBase) {
      return this._callBaseFunction(moduleName, func.name, input);
    }
    if (!func.hasBody()) {
      return null;
    }
    const prevModule = this._currentModule;
    this._currentModule = moduleName;
    const scope = new _Scope(this._globalScope);
    const params = (this._paramCache[((__ball_to_string(moduleName) + '.') + __ball_to_string(func.name))] ?? ((func.hasMetadata() ? this._extractParams(func.metadata) : [])));
    if (params.isNotEmpty) {
      if (((params.length === 1) && !(true /* is check */ && input.containsKey('self')))) {
        scope.bind(params[0], input);
      } else {
        if (true /* is check */) {
          for (let i = 0; (i < params.length); (i++)) {
            const p = params[i];
            if (input.containsKey(p)) {
              scope.bind(p, input[p]);
            } else {
              if (input.containsKey(('arg' + __ball_to_string(i)))) {
                scope.bind(p, input[('arg' + __ball_to_string(i))]);
              }
            }
          }
        } else {
          if (true /* is check */) {
            for (let i = 0; ((i < params.length) && (i < input.length)); (i++)) {
              scope.bind(params[i], input[i]);
            }
          }
        }
      }
    }
    if ((true /* is check */ && input.containsKey('self'))) {
      scope.bind('self', input['self']);
    }
    if ((func.inputType.isNotEmpty && (input !== null))) {
      scope.bind('input', input);
    }
    const result = await this._evalExpression(func.body, scope);
    this._currentModule = prevModule;
    let finalResult = __no_init__;
    if ((true /* is check */ && (result.kind === 'return'))) {
      finalResult = result.value;
    } else {
      finalResult = result;
    }
    if (func.hasMetadata()) {
      const asyncField = func.metadata.fields['is_async'];
      const generatorField = func.metadata.fields['is_generator'];
      if (((asyncField !== null) && asyncField.boolValue)) {
        if (false /* is_not check */) {
          return new BallFuture(finalResult);
        }
      }
      if (((generatorField !== null) && generatorField.boolValue)) {
        if (true /* is check */) {
          return finalResult.values;
        }
        if (true /* is check */) {
          return finalResult;
        }
        return [finalResult];
      }
    }
    return finalResult;
  }

  _extractParams(metadata: any): any {
    const input = metadata;
    const paramsValue = metadata.fields['params'];
    if (((paramsValue === null) || (paramsValue.whichKind() !== structpb_Value_Kind.listValue))) {
      return [];
    }
    return paramsValue.listValue.values.where(((v) => {
      const input = v;
      return (v.whichKind() === structpb_Value_Kind.structValue);
    })).map(((v) => {
      const input = v;
      const nameField = v.structValue.fields['name'];
      return (nameField?.stringValue ?? '');
    })).where(((n) => {
      const input = n;
      return n.isNotEmpty;
    })).toList();
  }

  async _resolveAndCallFunction(module: any, function_: any, input: any): Promise<any> {
    const moduleName = (module.isEmpty ? this._currentModule : module);
    const key = ((__ball_to_string(moduleName) + '.') + __ball_to_string(function_));
    const func = this._functions[key];
    if ((func !== null)) {
      return this._callFunction(moduleName, func, input);
    }
    const cached = this._callCache[function_];
    if ((cached !== null)) {
      return this._callFunction(cached.module, cached.func, input);
    }
    for (const m of this.program.modules) {
      for (const f of m.functions) {
        if ((f.name === function_)) {
          this._callCache[function_] = /* std.record */ record(m.name, f);
          return this._callFunction(m.name, f, input);
        }
      }
    }
    const ctorKey = (((__ball_to_string(moduleName) + '.') + __ball_to_string(function_)) + '.new');
    const ctorFunc = this._functions[ctorKey];
    if ((ctorFunc !== null)) {
      return this._callFunction(moduleName, ctorFunc, input);
    }
    const ctorEntry = this._constructors[function_];
    if ((ctorEntry !== null)) {
      return this._callFunction(ctorEntry.module, ctorEntry.func, input);
    }
    if ((this._resolver !== null)) {
      const resolved = await this._tryLazyResolve(moduleName);
      if ((resolved !== null)) {
        this._indexModule(resolved);
        const resolvedFunc = this._functions[((__ball_to_string(moduleName) + '.') + __ball_to_string(function_))];
        if ((resolvedFunc !== null)) {
          return this._callFunction(moduleName, resolvedFunc, input);
        }
      }
    }
    throw new BallRuntimeError((('Function "' + __ball_to_string(key)) + '" not found'));
  }

  async _tryLazyResolve(moduleName: any): Promise<any> {
    const input = moduleName;
    for (const m of this.program.modules) {
      for (const import_ of m.moduleImports) {
        if (((import_.name === moduleName) && (import_.whichSource() !== ModuleImport_Source.notSet))) {
          try {
            return await this._resolver.resolve(import_);
          } catch (__ball_active_error) {
            const _ = __ball_active_error;
          }
        }
      }
    }
  }

  _indexModule(module: any): any {
    const input = module;
    this.program.modules.add(module);
    for (const type of module.types) {
      this._types[type.name] = type;
    }
    for (const td of module.typeDefs) {
      if (td.hasDescriptor()) {
        this._types[td.name] = td.descriptor;
      }
    }
    for (const func of module.functions) {
      const key = ((__ball_to_string(module.name) + '.') + __ball_to_string(func.name));
      this._functions[key] = func;
      if (func.hasMetadata()) {
        const params = this._extractParams(func.metadata);
        if (params.isNotEmpty) {
          this._paramCache[key] = params;
        }
        const kindField = func.metadata.fields['kind'];
        if ((kindField?.stringValue === 'constructor')) {
          const entry = /* std.record */ record(module.name, func);
          const dotIdx = func.name.indexOf('.');
          if ((dotIdx >= 0)) {
            const className = func.name.substring(0, dotIdx);
            const ctorSuffix = func.name.substring((dotIdx + 1));
            if ((ctorSuffix === 'new')) {
              this._constructors[className] = entry;
              this._constructors[((__ball_to_string(module.name) + ':') + __ball_to_string(className))] = entry;
            }
            this._constructors[func.name] = entry;
          }
        }
      }
    }
  }

  async _evalExpression(expr: any, scope: any): Promise<any> {
    return ((expr.whichExpr()) === 'Expression_Expr.call' ? (await this._evalCall(expr.call, scope)) : ((expr.whichExpr()) === 'Expression_Expr.literal' ? (await this._evalLiteral(expr.literal, scope)) : ((expr.whichExpr()) === 'Expression_Expr.reference' ? (await this._evalReference(expr.reference, scope)) : ((expr.whichExpr()) === 'Expression_Expr.fieldAccess' ? (await this._evalFieldAccess(expr.fieldAccess, scope)) : ((expr.whichExpr()) === 'Expression_Expr.messageCreation' ? (await this._evalMessageCreation(expr.messageCreation, scope)) : ((expr.whichExpr()) === 'Expression_Expr.block' ? (await this._evalBlock(expr.block, scope)) : ((expr.whichExpr()) === 'Expression_Expr.lambda' ? (this._evalLambda(expr.lambda, scope)) : ((expr.whichExpr()) === 'Expression_Expr.notSet' ? (null) : undefined))))))));
  }

  async _evalCall(call: any, scope: any): Promise<any> {
    const moduleName = (call.module.isEmpty ? this._currentModule : call.module);
    if (((moduleName === 'std') || (moduleName === 'dart_std'))) {
    }
    if (((moduleName === 'cpp_std') && (call.function === 'cpp_scope_exit'))) {
      return this._evalCppScopeExit(call, scope);
    }
    const input = (call.hasInput() ? await this._evalExpression(call.input, scope) : null);
    if (((call.module === 'std') || (call.module === 'dart_std'))) {
      return this._callBaseFunction(call.module, call.function, input);
    }
    const key = ((__ball_to_string(moduleName) + '.') + __ball_to_string(call.function));
    const func = this._functions[key];
    if (((func !== null) && func.isBase)) {
      return this._callBaseFunction(moduleName, call.function, input);
    }
    if ((call.module.isEmpty && scope.has(call.function))) {
      const bound = scope.lookup(call.function);
      if (true /* is check */) {
        const result = bound(input);
        if (true /* is check */) {
          return await result;
        }
        return result;
      }
    }
    if ((true /* is check */ && input.containsKey('self'))) {
      const self = input['self'];
      if (true /* is check */) {
        const typeName = self['__type__'];
        if ((typeName !== null)) {
          const colonIdx = typeName.indexOf(':');
          const modPart = ((colonIdx >= 0) ? typeName.substring(0, colonIdx) : this._currentModule);
          const methodKey = ((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(call.function));
          const method = this._functions[methodKey];
          if ((method !== null)) {
            return this._callFunction(modPart, method, input);
          }
          let super_ = self['__super__'];
          while (true /* is check */) {
            const superType = super_['__type__'];
            if ((superType !== null)) {
              const sColonIdx = superType.indexOf(':');
              const sModPart = ((sColonIdx >= 0) ? superType.substring(0, sColonIdx) : modPart);
              const sTypeName = ((sColonIdx >= 0) ? superType : ((__ball_to_string(sModPart) + ':') + __ball_to_string(superType)));
              const superMethodKey = ((((__ball_to_string(sModPart) + '.') + __ball_to_string(sTypeName)) + '.') + __ball_to_string(call.function));
              const superMethod = this._functions[superMethodKey];
              if ((superMethod !== null)) {
                return this._callFunction(sModPart, superMethod, input);
              }
            }
            super_ = super_['__super__'];
          }
        }
      }
    }
    return this._resolveAndCallFunction(call.module, call.function, input);
  }

  async _evalLiteral(lit: any, scope: any): Promise<any> {
    return ((lit.whichValue()) === 'Literal_Value.intValue' ? (lit.intValue.toInt()) : ((lit.whichValue()) === 'Literal_Value.doubleValue' ? (lit.doubleValue) : ((lit.whichValue()) === 'Literal_Value.stringValue' ? (lit.stringValue) : ((lit.whichValue()) === 'Literal_Value.boolValue' ? (lit.boolValue) : ((lit.whichValue()) === 'Literal_Value.bytesValue' ? (lit.bytesValue.toList()) : ((lit.whichValue()) === 'Literal_Value.listValue' ? (await this._evalListLiteral(lit.listValue, scope)) : ((lit.whichValue()) === 'Literal_Value.notSet' ? (null) : undefined)))))));
  }

  async _evalListLiteral(listVal: any, scope: any): Promise<any> {
    const result = [];
    for (const element of listVal.elements) {
      if (element.hasCall()) {
        const call = element.call;
        const fn = call.function;
        if ((((call.module === 'dart_std') || (call.module === 'std')) && (fn === 'collection_if'))) {
          await this._evalCollectionIf(call, scope, result);
          continue;
        }
        if ((((call.module === 'dart_std') || (call.module === 'std')) && (fn === 'collection_for'))) {
          await this._evalCollectionFor(call, scope, result);
          continue;
        }
      }
      result.add(await this._evalExpression(element, scope));
    }
    return result;
  }

  async _evalCollectionIf(call: any, scope: any, result: any): Promise<any> {
    const fields = this._lazyFields(call);
    const condExpr = fields['condition'];
    if ((condExpr === null)) {
      return;
    }
    const cond = this._toBool(await this._evalExpression(condExpr, scope));
    if (cond) {
      const thenExpr = fields['then'];
      if ((thenExpr !== null)) {
        await this._addCollectionElement(thenExpr, scope, result);
      }
    } else {
      const elseExpr = fields['else'];
      if ((elseExpr !== null)) {
        await this._addCollectionElement(elseExpr, scope, result);
      }
    }
  }

  async _evalCollectionFor(call: any, scope: any, result: any): Promise<any> {
    const fields = this._lazyFields(call);
    const variable = this._stringFieldVal(fields, 'variable');
    const iterableExpr = fields['iterable'];
    const bodyExpr = fields['body'];
    if (((iterableExpr === null) || (bodyExpr === null))) {
      return;
    }
    const iterable = await this._evalExpression(iterableExpr, scope);
    if (false /* is_not check */) {
      return;
    }
    for (const item of iterable) {
      const loopScope = scope.child();
      loopScope.bind(((variable ?? '').isEmpty ? 'item' : variable), item);
      await this._addCollectionElement(bodyExpr, loopScope, result);
    }
  }

  async _addCollectionElement(expr: any, scope: any, result: any): Promise<any> {
    if (expr.hasCall()) {
      const call = expr.call;
      const fn = call.function;
      if ((((call.module === 'dart_std') || (call.module === 'std')) && (fn === 'collection_if'))) {
        await this._evalCollectionIf(call, scope, result);
        return;
      }
      if ((((call.module === 'dart_std') || (call.module === 'std')) && (fn === 'collection_for'))) {
        await this._evalCollectionFor(call, scope, result);
        return;
      }
    }
    result.add(await this._evalExpression(expr, scope));
  }

  async _evalReference(ref: any, scope: any): Promise<any> {
    const name = ref.name;
    if (scope.has(name)) {
      return scope.lookup(name);
    }
    const ctorEntry = this._constructors[name];
    if ((ctorEntry !== null)) {
      return (async (input) => {
        return this._callFunction(ctorEntry.module, ctorEntry.func, input);
      });
    }
    const colonIdx = name.indexOf(':');
    if ((colonIdx >= 0)) {
      const bare = name.substring((colonIdx + 1));
      const bareEntry = this._constructors[bare];
      if ((bareEntry !== null)) {
        return (async (input) => {
          return this._callFunction(bareEntry.module, bareEntry.func, input);
        });
      }
    }
    const enumVals = this._enumValues[name];
    if ((enumVals !== null)) {
      return enumVals;
    }
    const getterKey = ((__ball_to_string(this._currentModule) + '.') + __ball_to_string(name));
    const getterFunc = this._functions[getterKey];
    if (((getterFunc !== null) && this._isGetter(getterFunc))) {
      return this._callFunction(this._currentModule, getterFunc, null);
    }
    return scope.lookup(name);
  }

  async _evalFieldAccess(access: any, scope: any): Promise<any> {
    const object = await this._evalExpression(access.object, scope);
    const fieldName = access.field_2;
    if (true /* is check */) {
      if (object.containsKey(fieldName)) {
        return object[fieldName];
      }
      let superObj = object['__super__'];
      while (true /* is check */) {
        if (superObj.containsKey(fieldName)) {
          return superObj[fieldName];
        }
        superObj = superObj['__super__'];
      }
      const methods = object['__methods__'];
      if ((true /* is check */ && methods.containsKey(fieldName))) {
        return methods[fieldName];
      }
      superObj = object['__super__'];
      while (true /* is check */) {
        const superMethods = superObj['__methods__'];
        if ((true /* is check */ && superMethods.containsKey(fieldName))) {
          return superMethods[fieldName];
        }
        superObj = superObj['__super__'];
      }
      ((fieldName) === '\'keys\'' ? (object.keys.toList()) : ((fieldName) === '\'values\'' ? (object.values.toList()) : ((fieldName) === '\'length\'' ? (object.length) : ((fieldName) === '\'isEmpty\'' ? (object.isEmpty) : ((fieldName) === '\'isNotEmpty\'' ? (object.isNotEmpty) : ((fieldName) === '\'entries\'' ? (object.entries.map(((e) => {
        const input = e;
        return new Map();
      })).toList()) : undefined))))));
      const getterResult = await this._tryGetterDispatch(object, fieldName);
      if ((getterResult !== _sentinel)) {
        return getterResult;
      }
      throw new BallRuntimeError(((('Field "' + __ball_to_string(fieldName)) + '" not found. ') + ('Available: ' + __ball_to_string(object.keys.toList()))));
    }
    throw new BallRuntimeError(((('Cannot access field "' + __ball_to_string(fieldName)) + '" on ') + __ball_to_string((object?.runtimeType ?? 'null'))));
  }

  async _tryGetterDispatch(object: any, fieldName: any): Promise<any> {
    const typeName = object['__type__'];
    if ((typeName === null)) {
      return _sentinel;
    }
    const colonIdx = typeName.indexOf(':');
    const modPart = ((colonIdx >= 0) ? typeName.substring(0, colonIdx) : this._currentModule);
    const getterKey = ((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(fieldName));
    const getterFunc = this._functions[getterKey];
    if (((getterFunc !== null) && this._isGetter(getterFunc))) {
      return this._callFunction(modPart, getterFunc, new Map());
    }
    let superObj = object['__super__'];
    while (true /* is check */) {
      const superType = superObj['__type__'];
      if ((superType !== null)) {
        const sColonIdx = superType.indexOf(':');
        const sModPart = ((sColonIdx >= 0) ? superType.substring(0, sColonIdx) : modPart);
        const sTypeName = ((sColonIdx >= 0) ? superType : ((__ball_to_string(sModPart) + ':') + __ball_to_string(superType)));
        const superGetterKey = ((((__ball_to_string(sModPart) + '.') + __ball_to_string(sTypeName)) + '.') + __ball_to_string(fieldName));
        const superGetterFunc = this._functions[superGetterKey];
        if (((superGetterFunc !== null) && this._isGetter(superGetterFunc))) {
          return this._callFunction(sModPart, superGetterFunc, new Map());
        }
      }
      superObj = superObj['__super__'];
    }
    return _sentinel;
  }

  _isGetter(func: any): any {
    const input = func;
    if (!func.hasMetadata()) {
      return false;
    }
    const field = func.metadata.fields['is_getter'];
    return ((field !== null) && field.boolValue);
  }

  _isSetter(func: any): any {
    const input = func;
    if (!func.hasMetadata()) {
      return false;
    }
    const field = func.metadata.fields['is_setter'];
    return ((field !== null) && field.boolValue);
  }

  async _trySetterDispatch(object: any, fieldName: any, value: any): Promise<any> {
    const typeName = object['__type__'];
    if ((typeName === null)) {
      return _sentinel;
    }
    const colonIdx = typeName.indexOf(':');
    const modPart = ((colonIdx >= 0) ? typeName.substring(0, colonIdx) : this._currentModule);
    const setterKey = (((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(fieldName)) + '=');
    const setterFunc = this._functions[setterKey];
    if (((setterFunc !== null) && this._isSetter(setterFunc))) {
      return this._callFunction(modPart, setterFunc, new Map());
    }
    let superObj = object['__super__'];
    while (true /* is check */) {
      const superType = superObj['__type__'];
      if ((superType !== null)) {
        const sColonIdx = superType.indexOf(':');
        const sModPart = ((sColonIdx >= 0) ? superType.substring(0, sColonIdx) : modPart);
        const sTypeName = ((sColonIdx >= 0) ? superType : ((__ball_to_string(sModPart) + ':') + __ball_to_string(superType)));
        const superSetterKey = (((((__ball_to_string(sModPart) + '.') + __ball_to_string(sTypeName)) + '.') + __ball_to_string(fieldName)) + '=');
        const superSetterFunc = this._functions[superSetterKey];
        if (((superSetterFunc !== null) && this._isSetter(superSetterFunc))) {
          return this._callFunction(sModPart, superSetterFunc, new Map());
        }
      }
      superObj = superObj['__super__'];
    }
    return _sentinel;
  }

  async _evalMessageCreation(msg: any, scope: any): Promise<any> {
    const fields = new Map();
    for (const pair of msg.fields) {
      fields[pair.name] = await this._evalExpression(pair.value, scope);
    }
    if (msg.typeName.isNotEmpty) {
      fields['__type__'] = msg.typeName;
      const genMatch = { '__type': 'main:RegExp', 'arg0': '^(\\w+)<(.+)>$' }.firstMatch(msg.typeName);
      if ((genMatch !== null)) {
        fields['__type__'] = genMatch.group(1);
        fields['__type_args__'] = this._splitTypeArgs(genMatch.group(2));
      }
      const typeDef = this._findTypeDef(msg.typeName);
      if ((typeDef !== null)) {
        const superclass = this._getMetaString(typeDef, 'superclass');
        if (((superclass !== null) && superclass.isNotEmpty)) {
          fields['__super__'] = this._buildSuperObject(superclass, fields);
        }
        const methods = this._resolveTypeMethodsWithInheritance(msg.typeName);
        if (methods.isNotEmpty) {
          fields['__methods__'] = methods;
        }
      }
    }
    return fields;
  }

  _findTypeDef(typeName: any): any {
    const input = typeName;
    for (const module of this.program.modules) {
      for (const td of module.typeDefs) {
        if (((td.name === typeName) || td.name.endsWith((':' + __ball_to_string(typeName))))) {
          let superclass = __no_init__;
          if (td.hasMetadata()) {
            const sc = td.metadata.fields['superclass'];
            if (((sc !== null) && sc.hasStringValue())) {
              superclass = sc.stringValue;
            }
          }
          const fieldNames = [];
          if (td.hasDescriptor()) {
            for (const f of td.descriptor.field) {
              fieldNames.add(f.name);
            }
          }
          return /* std.record */ record(superclass, fieldNames);
        }
      }
    }
  }

  _getMetaString(typeDef: any, key: any): any {
    if ((key === 'superclass')) {
      return typeDef.superclass;
    }
  }

  _buildSuperObject(superclass: any, childFields: any): any {
    const superFields = new Map();
    const parentTypeDef = this._findTypeDef(superclass);
    if ((parentTypeDef !== null)) {
      for (const fname of parentTypeDef.fieldNames) {
        if (childFields.containsKey(fname)) {
          superFields[fname] = childFields[fname];
        }
      }
      const parentMethods = this._resolveTypeMethods(superclass);
      if (parentMethods.isNotEmpty) {
        superFields['__methods__'] = parentMethods;
      }
      const grandparent = parentTypeDef.superclass;
      if (((grandparent !== null) && grandparent.isNotEmpty)) {
        superFields['__super__'] = this._buildSuperObject(grandparent, childFields);
      }
    }
    return superFields;
  }

  _resolveTypeMethods(typeName: any): any {
    const input = typeName;
    const methods = new Map();
    for (const module of this.program.modules) {
      for (const func of module.functions) {
        if (func.hasMetadata()) {
          const className = func.metadata.fields['class'];
          if (((((className !== null) && className.hasStringValue()) && (className.stringValue === typeName)) && func.hasBody())) {
            methods[func.name] = (async (input) => {
              return this._callFunction(module.name, func, input);
            });
          }
        }
      }
    }
    return methods;
  }

  _resolveTypeMethodsWithInheritance(typeName: any): any {
    const input = typeName;
    const methods = new Map();
    const typeDef = this._findTypeDef(typeName);
    if ((((typeDef !== null) && (typeDef.superclass !== null)) && typeDef.superclass.isNotEmpty)) {
      methods.addAll(this._resolveTypeMethodsWithInheritance(typeDef.superclass));
    }
    methods.addAll(this._resolveTypeMethods(typeName));
    return methods;
  }

  async _evalBlock(block: any, scope: any): Promise<any> {
    const blockScope = scope.child();
    let flowResult = __no_init__;
    for (const stmt of block.statements) {
      const result = await this._evalStatement(stmt, blockScope);
      if (true /* is check */) {
        await this._runScopeExits(blockScope);
        return result;
      }
    }
    if (block.hasResult()) {
      flowResult = await this._evalExpression(block.result, blockScope);
    } else {
      flowResult = null;
    }
    await this._runScopeExits(blockScope);
    return flowResult;
  }

  async _runScopeExits(blockScope: any): Promise<any> {
    const input = blockScope;
    if (blockScope._scopeExits.isEmpty) {
      return;
    }
    for (const item of blockScope._scopeExits.reversed) {
      try {
        await this._evalExpression(expr, evalScope);
      } catch (__ball_active_error) {
        const _ = __ball_active_error;
      }
    }
  }

  async _evalStatement(stmt: any, scope: any): Promise<any> {

  }

  _evalLambda(func: any, scope: any): any {
    return (async (input) => {
      const lambdaScope = scope.child();
      lambdaScope.bind('input', input);
      const paramNames = (func.hasMetadata() ? this._extractParams(func.metadata) : []);
      if (((paramNames.length === 1) && false /* is_not check */)) {
        lambdaScope.bind(paramNames.first, input);
      }
      if (true /* is check */) {
        for (const entry of input.entries) {
          if ((entry.key !== '__type__')) {
            lambdaScope.bind(entry.key, entry.value);
          }
        }
      }
      if (!func.hasBody()) {
        return null;
      }
      const result = await this._evalExpression(func.body, lambdaScope);
      if ((true /* is check */ && (result.kind === 'return'))) {
        return result.value;
      }
      return result;
    });
  }

  _lazyFields(call: any): any {
    const input = call;
    if ((!call.hasInput() || (call.input.whichExpr() !== Expression_Expr.messageCreation))) {
      return /* std.set_create */ set_create([]);
    }
    const result = new Map();
    for (const f of call.input.messageCreation.fields) {
      result[f.name] = f.value;
    }
    return result;
  }

  async _evalLazyIf(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const condition = fields['condition'];
    const thenBranch = fields['then'];
    const elseBranch = fields['else'];
    if (((condition === null) || (thenBranch === null))) {
      throw new BallRuntimeError('std.if missing condition or then');
    }
    const condVal = await this._evalExpression(condition, scope);
    if (this._toBool(condVal)) {
      return this._evalExpression(thenBranch, scope);
    } else {
      if ((elseBranch !== null)) {
        return this._evalExpression(elseBranch, scope);
      }
    }
  }

  async _evalLazyFor(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const initExpr = fields['init'];
    const condition = fields['condition'];
    const update = fields['update'];
    const body = fields['body'];
    const forScope = scope.child();
    if ((initExpr !== null)) {
      if ((initExpr.whichExpr() === Expression_Expr.block)) {
        for (const stmt of initExpr.block.statements) {
          await this._evalStatement(stmt, forScope);
        }
      } else {
        if (((initExpr.whichExpr() === Expression_Expr.literal) && initExpr.literal.hasStringValue())) {
          const s = initExpr.literal.stringValue;
          const match = { '__type': 'main:RegExp', 'arg0': '(?:var|final|int|double|String)\\s+(\\w+)\\s*=\\s*(.+)' }.firstMatch(s);
          if ((match !== null)) {
            const varName = match.group(1);
            const rawVal = match.group(2).trim();
            const parsed = ((int.tryParse(rawVal) ?? double.tryParse(rawVal)) ?? (((rawVal === 'true') ? true : ((rawVal === 'false') ? false : rawVal))));
            forScope.bind(varName, parsed);
          }
        } else {
          await this._evalExpression(initExpr, forScope);
        }
      }
    }
    while (true) {
      if ((condition !== null)) {
        const condVal = await this._evalExpression(condition, forScope);
        if (!this._toBool(condVal)) {
          break;
        }
      }
      if ((body !== null)) {
        const result = await this._evalExpression(body, forScope);
        if (true /* is check */) {
          if ((result.kind === 'return')) {
            return result;
          }
          if (((result.label !== null) && result.label.isNotEmpty)) {
            return result;
          }
          if ((result.kind === 'break')) {
            break;
          }
        }
      }
      if ((update !== null)) {
        await this._evalExpression(update, forScope);
      }
    }
  }

  async _evalLazyForIn(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const variable = (this._stringFieldVal(fields, 'variable') ?? 'item');
    const iterable = fields['iterable'];
    const body = fields['body'];
    if (((iterable === null) || (body === null))) {
      return null;
    }
    const iterVal = await this._evalExpression(iterable, scope);
    if (false /* is_not check */) {
      throw new BallRuntimeError('std.for_in: iterable is not a List');
    }
    for (const item of iterVal) {
      const loopScope = scope.child();
      loopScope.bind(variable, item);
      const result = await this._evalExpression(body, loopScope);
      if (true /* is check */) {
        if ((result.kind === 'return')) {
          return result;
        }
        if (((result.label !== null) && result.label.isNotEmpty)) {
          return result;
        }
        if ((result.kind === 'break')) {
          break;
        }
      }
    }
  }

  async _evalLazyWhile(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const condition = fields['condition'];
    const body = fields['body'];
    while (true) {
      if ((condition !== null)) {
        const condVal = await this._evalExpression(condition, scope);
        if (!this._toBool(condVal)) {
          break;
        }
      }
      if ((body !== null)) {
        const result = await this._evalExpression(body, scope);
        if (true /* is check */) {
          if ((result.kind === 'return')) {
            return result;
          }
          if (((result.label !== null) && result.label.isNotEmpty)) {
            return result;
          }
          if ((result.kind === 'break')) {
            break;
          }
        }
      }
    }
  }

  async _evalLazyDoWhile(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const body = fields['body'];
    const condition = fields['condition'];
    do {
      if ((body !== null)) {
        const result = await this._evalExpression(body, scope);
        if (true /* is check */) {
          if ((result.kind === 'return')) {
            return result;
          }
          if (((result.label !== null) && result.label.isNotEmpty)) {
            return result;
          }
          if ((result.kind === 'break')) {
            break;
          }
        }
      }
      if ((condition !== null)) {
        const condVal = await this._evalExpression(condition, scope);
        if (!this._toBool(condVal)) {
          break;
        }
      } else {
        break;
      }
    } while (true);
  }

  async _evalLazySwitch(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const subject = fields['subject'];
    const cases = fields['cases'];
    if (((subject === null) || (cases === null))) {
      return null;
    }
    const subjectVal = await this._evalExpression(subject, scope);
    if (((cases.whichExpr() !== Expression_Expr.literal) || (cases.literal.whichValue() !== Literal_Value.listValue))) {
      return null;
    }
    let defaultBody = __no_init__;
    for (const caseExpr of cases.literal.listValue.elements) {
      if ((caseExpr.whichExpr() !== Expression_Expr.messageCreation)) {
        continue;
      }
      const cf = new Map();
      for (const f of caseExpr.messageCreation.fields) {
        cf[f.name] = f.value;
      }
      const isDefault = cf['is_default'];
      if ((((isDefault !== null) && (isDefault.whichExpr() === Expression_Expr.literal)) && isDefault.literal.boolValue)) {
        defaultBody = cf['body'];
        continue;
      }
      const value = cf['value'];
      if ((value !== null)) {
        const caseVal = await this._evalExpression(value, scope);
        if ((caseVal === subjectVal)) {
          const body = cf['body'];
          if ((body !== null)) {
            return this._evalExpression(body, scope);
          }
        }
      }
    }
    if ((defaultBody !== null)) {
      return this._evalExpression(defaultBody, scope);
    }
  }

  async _evalLazyTry(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const body = fields['body'];
    const catches = fields['catches'];
    const finallyBlock = fields['finally'];
    let result = __no_init__;
    try {
      result = ((body !== null) ? await this._evalExpression(body, scope) : null);
    } catch (__ball_active_error) {
      const e = __ball_active_error;
      result = null;
      if ((((catches !== null) && (catches.whichExpr() === Expression_Expr.literal)) && (catches.literal.whichValue() === Literal_Value.listValue))) {
        let caught = false;
        for (const catchExpr of catches.literal.listValue.elements) {
          if ((catchExpr.whichExpr() !== Expression_Expr.messageCreation)) {
            continue;
          }
          const cf = new Map();
          for (const f of catchExpr.messageCreation.fields) {
            cf[f.name] = f.value;
          }
          const catchType = this._stringFieldVal(cf, 'type');
          if (((catchType !== null) && catchType.isNotEmpty)) {
            const matches = (true /* is check */ ? (e['typeName'] === catchType) : (__ball_to_string(e['runtimeType']) === catchType));
            if (!matches) {
              continue;
            }
          }
          const variable = (this._stringFieldVal(cf, 'variable') ?? 'e');
          const stackVariable = this._stringFieldVal(cf, 'stack_trace');
          const catchBody = cf['body'];
          if ((catchBody !== null)) {
            const catchScope = scope.child();
            catchScope.bind(variable, (true /* is check */ ? e['value'] : __ball_to_string(e)));
            if (((stackVariable !== null) && stackVariable.isNotEmpty)) {
              catchScope.bind(stackVariable, stackTrace);
            }
            const previousActive = this._activeException;
            this._activeException = e;
            try {
              result = await this._evalExpression(catchBody, catchScope);
            } catch (__ball_active_error) {
              throw __ball_active_error;
            } finally {
              this._activeException = previousActive;
            }
            caught = true;
            break;
          }
        }
        if (!caught) {
          throw __ball_active_error;
        }
      } else {
        throw __ball_active_error;
      }
    } finally {
      if ((finallyBlock !== null)) {
        await this._evalExpression(finallyBlock, scope);
      }
    }
    return result;
  }

  async _evalShortCircuitAnd(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const left = fields['left'];
    const right = fields['right'];
    if (((left === null) || (right === null))) {
      return false;
    }
    const leftVal = await this._evalExpression(left, scope);
    if (!this._toBool(leftVal)) {
      return false;
    }
    return this._toBool(await this._evalExpression(right, scope));
  }

  async _evalShortCircuitOr(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const left = fields['left'];
    const right = fields['right'];
    if (((left === null) || (right === null))) {
      return false;
    }
    const leftVal = await this._evalExpression(left, scope);
    if (this._toBool(leftVal)) {
      return true;
    }
    return this._toBool(await this._evalExpression(right, scope));
  }

  async _evalReturn(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const value = fields['value'];
    const val = ((value !== null) ? await this._evalExpression(value, scope) : null);
    return new _FlowSignal('return', { value: val });
  }

  async _evalBreak(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const label = this._stringFieldVal(fields, 'label');
    return new _FlowSignal('break', { label: label });
  }

  async _evalContinue(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const label = this._stringFieldVal(fields, 'label');
    return new _FlowSignal('continue', { label: label });
  }

  async _evalAssign(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const target = fields['target'];
    const value = fields['value'];
    if (((target === null) || (value === null))) {
      return null;
    }
    const op = this._stringFieldVal(fields, 'op');
    if ((op === '??=')) {
      return this._evalNullAwareAssign(target, value, scope);
    }
    const val = await this._evalExpression(value, scope);
    if ((target.whichExpr() === Expression_Expr.reference)) {
      const name = target.reference.name;
      if ((((op !== null) && op.isNotEmpty) && (op !== '='))) {
        const current = scope.lookup(name);
        const computed = this._applyCompoundOp(op, current, val);
        scope.set(name, computed);
        return computed;
      }
      scope.set(name, val);
      return val;
    }
    if ((target.whichExpr() === Expression_Expr.fieldAccess)) {
      const obj = await this._evalExpression(target.fieldAccess.object, scope);
      if (true /* is check */) {
        const fieldName = target.fieldAccess.field_2;
        if ((((op !== null) && op.isNotEmpty) && (op !== '='))) {
          const current = obj[fieldName];
          const computed = this._applyCompoundOp(op, current, val);
          obj[fieldName] = computed;
          return computed;
        }
        const setterResult = await this._trySetterDispatch(obj, fieldName, val);
        if ((setterResult !== _sentinel)) {
          return setterResult;
        }
        obj[fieldName] = val;
        return val;
      }
    }
    if ((((target.whichExpr() === Expression_Expr.call) && (target.call.module === 'std')) && (target.call.function === 'index'))) {
      const indexFields = this._lazyFields(target.call);
      const indexTarget = indexFields['target'];
      const indexExpr = indexFields['index'];
      if (((indexTarget !== null) && (indexExpr !== null))) {
        const list = await this._evalExpression(indexTarget, scope);
        const idx = await this._evalExpression(indexExpr, scope);
        if ((((op !== null) && op.isNotEmpty) && (op !== '='))) {
          if ((true /* is check */ && true /* is check */)) {
            const current = list[idx];
            const computed = this._applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
          if ((true /* is check */ && true /* is check */)) {
            const current = list[idx];
            const computed = this._applyCompoundOp(op, current, val);
            list[idx] = computed;
            return computed;
          }
        }
        if ((true /* is check */ && true /* is check */)) {
          list[idx] = val;
          return val;
        }
        if ((true /* is check */ && true /* is check */)) {
          list[idx] = val;
          return val;
        }
      }
    }
    return val;
  }

  async _evalNullAwareAssign(target: any, value: any, scope: any): Promise<any> {
    if ((target.whichExpr() === Expression_Expr.reference)) {
      const name = target.reference.name;
      const current = scope.lookup(name);
      if ((current !== null)) {
        return current;
      }
      const val = await this._evalExpression(value, scope);
      scope.set(name, val);
      return val;
    }
    if ((target.whichExpr() === Expression_Expr.fieldAccess)) {
      const obj = await this._evalExpression(target.fieldAccess.object, scope);
      if (true /* is check */) {
        const fieldName = target.fieldAccess.field_2;
        const current = obj[fieldName];
        if ((current !== null)) {
          return current;
        }
        const val = await this._evalExpression(value, scope);
        obj[fieldName] = val;
        return val;
      }
    }
    if ((((target.whichExpr() === Expression_Expr.call) && (target.call.module === 'std')) && (target.call.function === 'index'))) {
      const indexFields = this._lazyFields(target.call);
      const indexTarget = indexFields['target'];
      const indexExpr = indexFields['index'];
      if (((indexTarget !== null) && (indexExpr !== null))) {
        const list = await this._evalExpression(indexTarget, scope);
        const idx = await this._evalExpression(indexExpr, scope);
        if ((true /* is check */ && true /* is check */)) {
          const current = list[idx];
          if ((current !== null)) {
            return current;
          }
          const val = await this._evalExpression(value, scope);
          list[idx] = val;
          return val;
        }
        if ((true /* is check */ && true /* is check */)) {
          const current = list[idx];
          if ((current !== null)) {
            return current;
          }
          const val = await this._evalExpression(value, scope);
          list[idx] = val;
          return val;
        }
      }
    }
    return this._evalExpression(value, scope);
  }

  async _evalIncDec(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const valueExpr = fields['value'];
    if ((valueExpr === null)) {
      return null;
    }
    if ((valueExpr.whichExpr() === Expression_Expr.reference)) {
      const name = valueExpr.reference.name;
      const current = scope.lookup(name);
      const isInc = call.function.contains('increment');
      const isPre = call.function.startsWith('pre');
      const updated = (isInc ? (current + 1) : (current - 1));
      scope.set(name, updated);
      return (isPre ? updated : current);
    }
    const val = await this._evalExpression(valueExpr, scope);
    const isInc = call.function.contains('increment');
    return (isInc ? (val + 1) : (val - 1));
  }

  _applyCompoundOp(op: any, current: any, val: any): any {
    return ((op) === '\'+=\'' ? (this._numOp(current, val, ((a, b) => {
      return (a + b);
    }))) : ((op) === '\'-=\'' ? (this._numOp(current, val, ((a, b) => {
      return (a - b);
    }))) : ((op) === '\'*=\'' ? (this._numOp(current, val, ((a, b) => {
      return (a * b);
    }))) : ((op) === '\'~/=\'' ? (this._intOp(current, val, ((a, b) => {
      return Math.trunc(a / b);
    }))) : ((op) === '\'%=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a % b);
    }))) : ((op) === '\'&=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a & b);
    }))) : ((op) === '\'|=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a | b);
    }))) : ((op) === '\'^=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a ^ b);
    }))) : ((op) === '\'<<=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a << b);
    }))) : ((op) === '\'>>=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a >> b);
    }))) : ((op) === '\'>>>=\'' ? (this._intOp(current, val, ((a, b) => {
      return (a >>> b);
    }))) : ((op) === '\'??=\'' ? ((current ?? val)) : ((op) === '_' ? (val) : undefined)))))))))))));
  }

  _numOp(a: any, b: any, op: any): any {
    return op(this._toNum(a), this._toNum(b));
  }

  _intOp(a: any, b: any, op: any): any {
    return op(this._toInt(a), this._toInt(b));
  }

  async _evalLabeled(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const label = this._stringFieldVal(fields, 'label');
    const body = fields['body'];
    if ((body === null)) {
      return null;
    }
    const result = await this._evalExpression(body, scope);
    if (((true /* is check */ && ((result.kind === 'break') || (result.kind === 'continue'))) && (result.label === label))) {
      return null;
    }
    return result;
  }

  async _evalGoto(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const label = this._stringFieldVal(fields, 'label');
    throw new _FlowSignal('goto', { label: label });
  }

  async _evalLabel(call: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const label = this._stringFieldVal(fields, 'name');
    const body = fields['body'];
    if ((body === null)) {
      return null;
    }
    let result = __no_init__;
    do {
      result = await this._evalExpression(body, scope);
      if (((true /* is check */ && (result.kind === 'goto')) && (result.label === label))) {
        continue;
      }
      break;
    } while (true);
    return result;
  }

  _evalAwaitFor(call: any, scope: any): any {
    return this._evalLazyForIn(call, scope);
  }

  _evalCppScopeExit(call: any, scope: any): any {
    if (!call.hasInput()) {
      return null;
    }
    const input = call.input;
    if ((input.whichExpr() !== Expression_Expr.messageCreation)) {
      return null;
    }
    const cleanupEntry = input.messageCreation.fields.where(((f) => {
      const input = f;
      return (f.name === 'cleanup');
    })).firstOrNull;
    if ((cleanupEntry === null)) {
      return null;
    }
    scope.registerScopeExit(cleanupEntry.value, scope);
  }

  async _tryOperatorOverride(function_: any, input: any): Promise<any> {
    const op = _stdFunctionToOperator[function_];
    if (((op === null) || false /* is_not check */)) {
      return null;
    }
    const left = __no_init__;
    const right = __no_init__;
    if ((function_ === 'index')) {
      left = input['target'];
      right = input['index'];
    } else {
      left = input['left'];
      right = input['right'];
    }
    if ((false /* is_not check */ || !left.containsKey('__type__'))) {
      return null;
    }
    const typeName = left['__type__'];
    const colonIdx = typeName.indexOf(':');
    const modPart = ((colonIdx >= 0) ? typeName.substring(0, colonIdx) : this._currentModule);
    let current = left;
    while ((current !== null)) {
      const curType = current['__type__'];
      if ((curType !== null)) {
        const cColonIdx = curType.indexOf(':');
        const cModPart = ((cColonIdx >= 0) ? curType.substring(0, cColonIdx) : modPart);
        const cTypeName = ((cColonIdx >= 0) ? curType : ((__ball_to_string(cModPart) + ':') + __ball_to_string(curType)));
        const methodKey = ((((__ball_to_string(cModPart) + '.') + __ball_to_string(cTypeName)) + '.') + __ball_to_string(op));
        const method = this._functions[methodKey];
        if ((method !== null)) {
          const methodInput = new Map();
          return this._callFunction(cModPart, method, methodInput);
        }
      }
      const super_ = current['__super__'];
      current = (true /* is check */ ? super_ : null);
    }
  }

  async _callBaseFunction(module: any, function_: any, input: any): Promise<any> {
    if (_stdFunctionToOperator.containsKey(function_)) {
      const override = await this._tryOperatorOverride(function_, input);
      if ((override !== null)) {
        return override;
      }
    }
    for (const handler of this.moduleHandlers) {
      if (handler.handles(module)) {
        const result = await handler.call(function_, input, callFunction);
        this._callCounts[function_] = ((this._callCounts[function_] ?? 0) + 1);
        return result;
      }
    }
    throw new BallRuntimeError((('Unknown base module: "' + __ball_to_string(module)) + '"'));
  }

  _buildStdDispatch(): any {
    return new Map();
  }

  _stdPrint(input: any): any {
    if (true /* is check */) {
      const message = input['message'];
      if ((message !== null)) {
        stdout(__ball_to_string(message));
        return null;
      }
    }
    stdout(__ball_to_string(input));
  }

  _stdIf(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('std.if input must be a message');
    }
    const condition = input['condition'];
    if ((condition === true)) {
      return input['then'];
    }
    return input['else'];
  }

  _stdIndex(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('std.index: expected message');
    }
    const target = input['target'];
    const index = input['index'];
    if ((true /* is check */ && true /* is check */)) {
      return target[index];
    }
    if ((true /* is check */ && true /* is check */)) {
      return target[index];
    }
    if ((true /* is check */ && true /* is check */)) {
      return target[index];
    }
    throw new BallRuntimeError('std.index: unsupported types');
  }

  _stdCascade(input: any): any {
    if (false /* is_not check */) {
      return input;
    }
    return input['target'];
  }

  _stdNullAwareCascade(input: any): any {
    if (false /* is_not check */) {
      return input;
    }
    const target = input['target'];
    if ((target === null)) {
      return null;
    }
    return target;
  }

  async _stdInvoke(input: any): Promise<any> {
    if (false /* is_not check */) {
      throw new BallRuntimeError('std.invoke: expected message');
    }
    const callee = input['callee'];
    if (false /* is_not check */) {
      throw new BallRuntimeError('std.invoke: callee is not callable');
    }
    const args = /* std.cascade */ cascade({ '__type': 'main:Map.from', '__type_args__': '<String, Object?>', 'arg0': input }, [__cascade_self__.remove('callee'), __cascade_self__.remove('__type__')]);
    let result = __no_init__;
    if ((args.length === 1)) {
      result = Function.apply(callee, [args.values.first]);
    } else {
      if (args.isEmpty) {
        result = Function.apply(callee, [null]);
      } else {
        result = Function.apply(callee, [args]);
      }
    }
    if (true /* is check */) {
      result = await result;
    }
    return result;
  }

  _stdNullAwareAccess(input: any): any {
    if (false /* is_not check */) {
      return null;
    }
    const target = input['target'];
    const field = input['field'];
    if ((target === null)) {
      return null;
    }
    if ((true /* is check */ && (field !== null))) {
      return target[field];
    }
  }

  _stdNullAwareCall(input: any): any {
    if (false /* is_not check */) {
      return null;
    }
    const target = input['target'];
    if ((target === null)) {
      return null;
    }
  }

  _stdTypeCheck(input: any): any {
    if (false /* is_not check */) {
      return false;
    }
    const value = input['value'];
    const type = input['type'];
    if ((type === null)) {
      return false;
    }
    return this._typeMatches(value, type);
  }

  _typeMatches(value: any, type: any): any {
    const genericMatch = { '__type': 'main:RegExp', 'arg0': '^(\\w+)<(.+)>$' }.firstMatch(type);
    if ((genericMatch !== null)) {
      const baseType = genericMatch.group(1);
      const typeArgsStr = genericMatch.group(2);
      const typeArgs = this._splitTypeArgs(typeArgsStr);
      if (((baseType === 'List') && true /* is check */)) {
        if ((typeArgs.length === 1)) {
          return value.every(((e) => {
            const input = e;
            return this._typeMatches(e, typeArgs[0]);
          }));
        }
        return true;
      }
      if (((baseType === 'Map') && true /* is check */)) {
        if ((typeArgs.length === 2)) {
          return value.entries.every(((e) => {
            const input = e;
            return (this._typeMatches(e.key, typeArgs[0]) && this._typeMatches(e.value, typeArgs[1]));
          }));
        }
        return true;
      }
      if (((baseType === 'Set') && true /* is check */)) {
        if ((typeArgs.length === 1)) {
          return value.every(((e) => {
            const input = e;
            return this._typeMatches(e, typeArgs[0]);
          }));
        }
        return true;
      }
      if ((true /* is check */ && this._typeNameMatches(value['__type__'], baseType))) {
        const objArgs = value['__type_args__'];
        if ((true /* is check */ && (objArgs.length === typeArgs.length))) {
          for (let i = 0; (i < typeArgs.length); (i++)) {
            if ((objArgs[i] !== typeArgs[i])) {
              return false;
            }
          }
          return true;
        }
      }
      return false;
    }
    return ((type) === '\'int\'' ? (true /* is check */) : ((type) === '\'double\'' ? (true /* is check */) : ((type) === '\'num\'' ? (true /* is check */) : ((type) === '\'String\'' ? (true /* is check */) : ((type) === '\'bool\'' ? (true /* is check */) : ((type) === '\'List\'' ? (true /* is check */) : ((type) === '\'Map\'' ? (true /* is check */) : ((type) === '\'Set\'' ? (true /* is check */) : ((type) === '\'Null\' || \'void\'' ? ((value === null)) : ((type) === '\'Object\' || \'dynamic\'' ? (true) : ((type) === '\'Function\'' ? (true /* is check */) : ((type) === '_' ? (this._objectTypeMatches(value, type)) : undefined))))))))))));
  }

  _objectTypeMatches(value: any, type: any): any {
    if (false /* is_not check */) {
      return false;
    }
    if (this._typeNameMatches(value['__type__'], type)) {
      return true;
    }
    let superObj = value['__super__'];
    while (true /* is check */) {
      if (this._typeNameMatches(superObj['__type__'], type)) {
        return true;
      }
      superObj = superObj['__super__'];
    }
    return false;
  }

  _typeNameMatches(objType: any, checkType: any): any {
    if ((objType === null)) {
      return false;
    }
    if ((objType === checkType)) {
      return true;
    }
    if (objType.endsWith((':' + __ball_to_string(checkType)))) {
      return true;
    }
    if (checkType.endsWith((':' + __ball_to_string(objType)))) {
      return true;
    }
    const objColon = objType.indexOf(':');
    const checkColon = checkType.indexOf(':');
    if (((objColon >= 0) && (checkColon >= 0))) {
      return (objType.substring((objColon + 1)) === checkType.substring((checkColon + 1)));
    }
    return false;
  }

  _splitTypeArgs(str: any): any {
    const input = str;
    const args = [];
    let depth = 0;
    let start = 0;
    for (let i = 0; (i < str.length); (i++)) {
      if ((str[i] === '<')) {
        (depth++);
      }
      if ((str[i] === '>')) {
        (depth--);
      }
      if (((str[i] === ',') && (depth === 0))) {
        args.add(str.substring(start, i).trim());
        start = (i + 1);
      }
    }
    args.add(str.substring(start).trim());
    return args;
  }

  _stdMapCreate(input: any): any {
    if (false /* is_not check */) {
      return new Map();
    }
    const entries = input['entries'];
    if (true /* is check */) {
      const result = new Map();
      for (const entry of entries) {
        if (true /* is check */) {
          result[entry['name']] = entry['value'];
        }
      }
      return result;
    }
    return new Map();
  }

  _stdSetCreate(input: any): any {
    if (false /* is_not check */) {
      return /* std.set_create */ set_create('Object?', []);
    }
    const elements = input['elements'];
    if (true /* is check */) {
      return elements.toSet();
    }
    return /* std.set_create */ set_create('Object?', []);
  }

  _stdRecord(input: any): any {
    if (false /* is_not check */) {
      return input;
    }
    return (input['fields'] ?? input);
  }

  async _stdSwitchExpr(input: any): Promise<any> {
    if (false /* is_not check */) {
      return null;
    }
    const subject = input['subject'];
    const cases = input['cases'];
    if (false /* is_not check */) {
      return null;
    }
    let defaultBody = __no_init__;
    for (const c of cases) {
      if (false /* is_not check */) {
        continue;
      }
      const pattern = c['pattern'];
      const body = c['body'];
      const guard = c['guard'];
      if (((pattern === null) || (pattern === '_'))) {
        defaultBody = body;
        continue;
      }
      const bindings = new Map();
      if (this._matchPattern(subject, pattern, bindings)) {
        if (((guard !== null) && true /* is check */)) {
          let guardResult = guard(bindings);
          if (true /* is check */) {
            guardResult = await guardResult;
          }
          if ((guardResult !== true)) {
            continue;
          }
        }
        if (true /* is check */) {
          let result = body(bindings);
          if (true /* is check */) {
            result = await result;
          }
          return result;
        }
        return body;
      }
    }
    return defaultBody;
  }

  _matchPattern(value: any, pattern: any, bindings: any): any {
    if (((pattern === null) || (pattern === '_'))) {
      return true;
    }
    if (true /* is check */) {
      return this._matchStringPattern(value, pattern, bindings);
    }
    if (true /* is check */) {
      return this._matchStructuredPattern(value, pattern, bindings);
    }
    return ((pattern === value) || (__ball_to_string(pattern) === value?.toString()));
  }

  _matchStringPattern(value: any, pattern: any, bindings: any): any {
    const trimmed = pattern.trim();
    if ((trimmed === '_')) {
      return true;
    }
    const typeBindMatch = { '__type': 'main:RegExp', 'arg0': '^(\\w+)\\s+(\\w+)$' }.firstMatch(trimmed);
    if ((typeBindMatch !== null)) {
      const typeName = typeBindMatch.group(1);
      const varName = typeBindMatch.group(2);
      if (this._matchesTypePattern(value, typeName)) {
        bindings[varName] = value;
        return true;
      }
      return false;
    }
    if ((trimmed === 'null')) {
      return (value === null);
    }
    if ((trimmed === 'true')) {
      return (value === true);
    }
    if ((trimmed === 'false')) {
      return (value === false);
    }
    const relMatch = { '__type': 'main:RegExp', 'arg0': '^(==|!=|>=|<=|>|<)\\s*(.+)$' }.firstMatch(trimmed);
    if (((relMatch !== null) && true /* is check */)) {
      const op = relMatch.group(1);
      const rhsStr = relMatch.group(2).trim();
      const rhs = num.tryParse(rhsStr);
      if ((rhs !== null)) {
        return ((op) === '\'==\'' ? ((value === rhs)) : ((op) === '\'!=\'' ? ((value !== rhs)) : ((op) === '\'>\'' ? ((value > rhs)) : ((op) === '\'<\'' ? ((value < rhs)) : ((op) === '\'>=\'' ? ((value >= rhs)) : ((op) === '\'<=\'' ? ((value <= rhs)) : ((op) === '_' ? (false) : undefined)))))));
      }
    }
    if (this._matchesTypePattern(value, trimmed)) {
      return true;
    }
    if ((trimmed === value?.toString())) {
      return true;
    }
    return false;
  }

  _matchStructuredPattern(value: any, pattern: any, bindings: any): any {
    const kind = pattern['__pattern_kind__'];
  }

  _matchesTypePattern(value: any, pattern: any): any {
    return ((pattern) === '\'int\'' ? (true /* is check */) : ((pattern) === '\'double\'' ? (true /* is check */) : ((pattern) === '\'num\'' ? (true /* is check */) : ((pattern) === '\'String\'' ? (true /* is check */) : ((pattern) === '\'bool\'' ? (true /* is check */) : ((pattern) === '\'List\'' ? (true /* is check */) : ((pattern) === '\'Map\'' ? (true /* is check */) : ((pattern) === '\'Set\'' ? (true /* is check */) : ((pattern) === '\'Null\' || \'null\'' ? ((value === null)) : ((pattern) === '_' ? (false) : undefined))))))))));
  }

  _stdAssert(input: any): any {
    if (false /* is_not check */) {
      return null;
    }
    const condition = input['condition'];
    const message = input['message'];
    if (!this._toBool(condition)) {
      throw new BallRuntimeError(('Assertion failed' + __ball_to_string(((message !== null) ? (': ' + __ball_to_string(message)) : ''))));
    }
  }

  _stdAdd(input: any): any {
    if ((true /* is check */ || true /* is check */)) {
      return (__ball_to_string((left ?? '')) + __ball_to_string((right ?? '')));
    }
    return (this._toNum(left) + this._toNum(right));
  }

  _stdBinary(input: any, op: any): any {
    return op(this._toNum(left), this._toNum(right));
  }

  _stdBinaryInt(input: any, op: any): any {
    return op(this._toInt(left), this._toInt(right));
  }

  _stdBinaryDouble(input: any, op: any): any {
    return op(this._toDouble(left), this._toDouble(right));
  }

  _stdBinaryComp(input: any, op: any): any {
    return op(this._toNum(left), this._toNum(right));
  }

  _stdBinaryBool(input: any, op: any): any {
    return op(this._toBool(left), this._toBool(right));
  }

  _stdBinaryAny(input: any, op: any): any {
    return op(left, right);
  }

  _stdUnaryNum(input: any, op: any): any {
    const value = this._extractUnaryArg(input);
    return op(value);
  }

  _stdNot(input: any): any {
    const value = this._extractUnaryArg(input);
    return !this._toBool(value);
  }

  _stdConcat(input: any): any {
    return (__ball_to_string(left) + __ball_to_string(right));
  }

  _stdLength(input: any): any {
    const value = this._extractUnaryArg(input);
    if (true /* is check */) {
      return value.length;
    }
    if (true /* is check */) {
      return value.length;
    }
    throw new BallRuntimeError(('std.length: unsupported type ' + __ball_to_string(value.runtimeType)));
  }

  _stdConvert(input: any, converter: any): any {
    const value = this._extractUnaryArg(input);
    return converter(value);
  }

  _extractBinaryArgs(input: any): any {
    if (true /* is check */) {
      return /* std.record */ record(input['left'], input['right']);
    }
    throw new BallRuntimeError('Expected message with left/right fields');
  }

  _extractUnaryArg(input: any): any {
    if (true /* is check */) {
      return input['value'];
    }
    return input;
  }

  _extractField(input: any, name: any): any {
    if (true /* is check */) {
      return input[name];
    }
  }

  _stringFieldVal(fields: any, name: any): any {
    const expr = fields[name];
    if ((expr === null)) {
      return null;
    }
    if (((expr.whichExpr() === Expression_Expr.literal) && (expr.literal.whichValue() === Literal_Value.stringValue))) {
      return expr.literal.stringValue;
    }
  }

  _toInt(v: any): any {
    const input = v;
    if (true /* is check */) {
      return v;
    }
    if (true /* is check */) {
      return v.toInt();
    }
    if (true /* is check */) {
      return __ball_parse_int(v);
    }
    throw new BallRuntimeError((('Cannot convert ' + __ball_to_string(v.runtimeType)) + ' to int'));
  }

  _toDouble(v: any): any {
    const input = v;
    if (true /* is check */) {
      return v;
    }
    if (true /* is check */) {
      return v.toDouble();
    }
    if (true /* is check */) {
      return __ball_parse_double(v);
    }
    throw new BallRuntimeError((('Cannot convert ' + __ball_to_string(v.runtimeType)) + ' to double'));
  }

  _toNum(v: any): any {
    const input = v;
    if (true /* is check */) {
      return v;
    }
    throw new BallRuntimeError((('Cannot convert ' + __ball_to_string(v.runtimeType)) + ' to num'));
  }

  _toBool(v: any): any {
    const input = v;
    if (true /* is check */) {
      return v;
    }
    throw new BallRuntimeError((('Cannot convert ' + __ball_to_string(v.runtimeType)) + ' to bool'));
  }

  _stdStringSubstring(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = input['value'];
    const start = this._toInt(input['start']);
    const end = input['end'];
    return ((end !== null) ? value.substring(start, this._toInt(end)) : value.substring(start));
  }

  _stdStringCharAt(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const target = input['target'];
    const index = this._toInt(input['index']);
    return target[index];
  }

  _stdStringCharCodeAt(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const target = input['target'];
    const index = this._toInt(input['index']);
    return target.codeUnitAt(index);
  }

  _stdStringReplace(input: any, all: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = input['value'];
    const from = input['from'];
    const to = input['to'];
    return (all ? value.replaceAll(from, to) : value.replaceFirst(from, to));
  }

  _stdRegexReplace(input: any, all: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = input['value'];
    const from = input['from'];
    const to = input['to'];
    const pattern = { '__type': 'main:RegExp', 'arg0': from };
    return (all ? value.replaceAll(pattern, to) : value.replaceFirst(pattern, to));
  }

  _stdStringRepeat(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = input['value'];
    const count = this._toInt(input['count']);
    return (value * count);
  }

  _stdStringPad(input: any, left: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = input['value'];
    const width = this._toInt(input['width']);
    const padding = (input['padding'] ?? ' ');
    return (left ? value.padLeft(width, padding) : value.padRight(width, padding));
  }

  _stdMathUnary(input: any, op: any): any {
    const value = this._extractUnaryArg(input);
    return op(value);
  }

  _stdMathBinary(input: any, op: any): any {
    return op(this._toDouble(left), this._toDouble(right));
  }

  _stdMathClamp(input: any): any {
    if (false /* is_not check */) {
      throw new BallRuntimeError('Expected message');
    }
    const value = this._toNum(input['value']);
    const min = this._toNum(input['min']);
    const max = this._toNum(input['max']);
    return value.clamp(min, max);
  }

  _jsonEncode(value: any): any {
    const input = value;
    return { '__type': 'main:JsonEncoder', '__const__': true }.convert(this._toJsonSafe(value));
  }

  _jsonDecode(text: any): any {
    const input = text;
    return { '__type': 'main:JsonDecoder', '__const__': true }.convert(text);
  }

  _toJsonSafe(v: any): any {
    const input = v;
    if (((((v === null) || true /* is check */) || true /* is check */) || true /* is check */)) {
      return v;
    }
    if (true /* is check */) {
      return /* std.set_create */ set_create([/* std.collection_for */ collection_for('e', v.entries, /* std.collection_if */ collection_if((true /* is check */ && !e.key.startsWith('__')), { 'key': e.key, 'value': this._toJsonSafe(e.value) }))]);
    }
    if (true /* is check */) {
      return v.map(_toJsonSafe).toList();
    }
    if (true /* is check */) {
      return v.map(_toJsonSafe).toList();
    }
    return __ball_to_string(v);
  }

  _utf8Encode(s: any): any {
    const input = s;
    return utf8.encode(s);
  }

  _utf8Decode(bytes: any): any {
    const input = bytes;
    return utf8.decode(bytes);
  }

  _base64Encode(bytes: any): any {
    const input = bytes;
    return base64.encode(bytes);
  }

  _base64Decode(s: any): any {
    const input = s;
    return base64.decode(s);
  }

  _stdFileRead(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    return File(path).readAsStringSync();
  }

  _stdFileReadBytes(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    return File(path).readAsBytesSync().toList();
  }

  _stdFileWrite(input: any): any {
    const m = input;
    File(m['path']).writeAsStringSync(m['content']);
  }

  _stdFileWriteBytes(input: any): any {
    const m = input;
    File(m['path']).writeAsBytesSync(m['content']);
  }

  _stdFileAppend(input: any): any {
    const m = input;
    File(m['path']).writeAsStringSync(m['content'], io_FileMode.append);
  }

  _stdFileExists(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    return File(path).existsSync();
  }

  _stdFileDelete(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    File(path).deleteSync();
  }

  _stdDirList(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    return Directory(path).listSync().map(((e) => {
      const input = e;
      return e.path;
    })).toList();
  }

  _stdDirCreate(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    Directory(path).createSync(true);
  }

  _stdDirExists(input: any): any {
    const path = (true /* is check */ ? (input['path'] ?? '') : __ball_to_string(input));
    return Directory(path).existsSync();
  }
}

function _sentinel(): any {
  return { '__type': 'main:Object' };
}

function _mathSqrt(v: any): any {
  const input = v;
  return sqrt(v);
}

function _mathPow(a: any, b: any): any {
  return pow(a, b).toDouble();
}

function _mathLog(v: any): any {
  const input = v;
  return log(v);
}

function _mathExp(v: any): any {
  const input = v;
  return exp(v);
}

function _mathSin(v: any): any {
  const input = v;
  return sin(v);
}

function _mathCos(v: any): any {
  const input = v;
  return cos(v);
}

function _mathTan(v: any): any {
  const input = v;
  return tan(v);
}

function _mathAsin(v: any): any {
  const input = v;
  return asin(v);
}

function _mathAcos(v: any): any {
  const input = v;
  return acos(v);
}

function _mathAtan(v: any): any {
  const input = v;
  return atan(v);
}

function _mathAtan2(a: any, b: any): any {
  return atan2(a, b);
}
