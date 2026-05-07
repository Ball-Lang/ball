/**
 * Ball → TypeScript compiler.
 *
 * Walks a Ball `Program` and emits idiomatic TypeScript via ts-morph.
 * Runs in-process in TS — no Dart subprocess.
 *
 * Mirrors the semantics of the original Dart `ts_compiler.dart`:
 *   - Declarations (functions, classes, enums, typedefs) go through
 *     ts-morph's structure API — indentation / ordering / formatting
 *     handled by the library.
 *   - Expressions / statements are emitted as raw TS source strings
 *     into an internal buffer. ts-morph re-indents them inside each
 *     declaration block.
 */
import { Project, StructureKind, type Scope as _Scope } from "ts-morph";
import type {
  Expression,
  FieldValuePair,
  FunctionCall,
  FunctionDef,
  Literal,
  Module,
  Program,
  Statement,
  Struct,
  TypeDefinition,
} from "./types.ts";
import { TS_RUNTIME_PREAMBLE } from "./preamble.ts";

export interface CompileOptions {
  /** Include the runtime preamble at the top of the output. Default true. */
  includePreamble?: boolean;
  /** Output file path hint (affects ts-morph's internal resolution). */
  fileName?: string;
}

interface CtorParam {
  name: string;
  isThis: boolean;
  isNamed: boolean;
}

export class BallCompiler {
  private readonly program: Program;

  /** Buffer that _emit* functions write into. */
  private out = "";
  private depth = 0;

  /** Catch-bound variables currently in scope — subject to bracket access. */
  private readonly catchVars = new Set<string>();

  /** Fields of the class currently being emitted (method bodies). */
  private currentClassFields: Set<string> = new Set();

  /** Parameters of the currently-emitting method (shadow fields). */
  private currentMethodParams: Set<string> = new Set();

  /** Short method names of the current class (for `this.foo()` routing). */
  private currentClassMethodNames: Set<string> = new Set();

  /** All function names in the entry module (function vs ctor routing). */
  private allFunctionNames: Set<string> = new Set();

  /** typeDefs in the entry module (typeName → definition). */
  private typeDefByName: Map<string, TypeDefinition> = new Map();

  constructor(program: Program) {
    this.program = program;
  }

  /** Compile to TS source. */
  compile(options: CompileOptions = {}): string {
    const { includePreamble = true, fileName = "program.ts" } = options;
    const project = new Project({
      useInMemoryFileSystem: true,
      compilerOptions: { target: 99 /* ESNext */ },
    });
    const sf = project.createSourceFile(fileName, "", { overwrite: true });

    const entryMod = this.program.modules.find(
      (m) => m.name === this.program.entryModule,
    );
    if (!entryMod) {
      throw new Error(
        `Entry module "${this.program.entryModule}" not found`,
      );
    }

    // Seed the function-name + typeDef lookup tables.
    this.allFunctionNames = new Set(entryMod.functions.map((f) => f.name));
    this.typeDefByName = new Map(
      (entryMod.typeDefs ?? []).map((td) => [td.name, td]),
    );

    // Group functions by their enclosing class (if any) — matches the
    // `<typeDef.name>.<member>` naming convention from the encoder.
    const classMembers = new Map<string, FunctionDef[]>();
    const freeFunctions: FunctionDef[] = [];
    for (const fn of entryMod.functions) {
      if (fn.isBase) continue;
      if (fn.name === this.program.entryFunction) continue;
      const enclosing = this.enclosingTypeName(fn.name);
      if (enclosing) {
        const list = classMembers.get(enclosing) ?? [];
        list.push(fn);
        classMembers.set(enclosing, list);
      } else {
        freeFunctions.push(fn);
      }
    }

    // Typedefs → TsTypeAlias.
    for (const ta of entryMod.typeAliases ?? []) {
      sf.addTypeAlias({
        name: ta.name,
        type: this.dartTypeToTs(ta.targetType),
        isExported: true,
      });
    }

    // Classes.
    for (const td of entryMod.typeDefs ?? []) {
      this.emitClass(sf, td, classMembers.get(td.name) ?? []);
    }

    // Top-level variables (kind == 'top_level_variable') emit as
    // `const <name> = <body>;` before free functions.
    for (const fn of freeFunctions.filter(
      (f) => (f.metadata as any)?.kind === "top_level_variable",
    )) {
      const name = sanitize(fn.name);
      const body = fn.body ? this.captureInto(() => {
        this.writeln(`return ${this.expr(fn.body!)};`);
      }) : "undefined";
      sf.addStatements(`const ${name} = (() => { ${body} })();`);
    }

    // Free top-level functions (exclude top-level variables).
    for (const fn of freeFunctions.filter(
      (f) => (f.metadata as any)?.kind !== "top_level_variable",
    )) {
      this.emitFreeFunction(sf, fn);
    }

    // Entry function as `main()` + immediate call.
    const entryFn = entryMod.functions.find(
      (f) => f.name === this.program.entryFunction,
    );
    if (entryFn) {
      this.emitFreeFunction(sf, entryFn, "main");
      sf.addStatements("main();");
    }

    sf.formatText({ indentSize: 2, convertTabsToSpaces: true });
    let body = sf.getFullText();

    // Post-processing: inject missing OOP field binding.
    // The Dart engine binds all fields from `self` into scope so methods
    // can access instance fields by bare name (e.g., `x` instead of
    // `self.x`). The encoder only captured `scope.bind('self', input['self'])`.
    // Inject the full field-binding + super-chain code.
    body = body.replace(
      /scope\.bind\('self', input\['self'\]\);/g,
      `scope.bind('self', input['self']);
      { const __self = input['self'];
        if (typeof __self === 'object' && __self !== null && !Array.isArray(__self)) {
          for (const __k of Object.keys(__self)) {
            if (!__k.startsWith('__')) scope.bind(__k, __self[__k]);
          }
          let __sup = __self['__super__'];
          while (typeof __sup === 'object' && __sup !== null && !Array.isArray(__sup)) {
            for (const __k of Object.keys(__sup)) {
              if (!__k.startsWith('__') && !scope.has(__k)) scope.bind(__k, __sup[__k]);
            }
            __sup = __sup['__super__'];
          }
        }
      }`,
    );

    // Post-processing: inject 'super' and built-in type references into
    // _evalReference. The Dart engine handles these but the encoder missed them.
    body = body.replace(
      /async _evalReference\(ref: any, scope: any\): Promise<any> \{\s*let name = ref\.name;\s*if \(scope\.has\(name\)\)/,
      `async _evalReference(ref: any, scope: any): Promise<any> {
    let name = ref.name;
    if (name === 'super' && scope.has('self')) {
      const __sup_self = scope.lookup('self');
      if (typeof __sup_self === 'object' && __sup_self !== null) {
        return __sup_self['__super__'] ?? __sup_self;
      }
    }
    if (name === 'List' || name === 'Map' || name === 'Set') {
      return {'__class_ref__': name, '__type__': '__builtin_class__'};
    }
    if (scope.has(name))`,
    );

    // Post-processing: inject lazy cascade evaluation into _evalCall.
    // The Dart engine has _evalLazyCascade but the encoder didn't capture it.
    // Add cascade/null_aware_cascade handling in the std function switch.
    body = body.replace(
      /else if \(\(__sw === 'dart_await_for'\)\)/,
      `else if (__sw === 'cascade' || __sw === 'null_aware_cascade') {
          const __cf = this._lazyFields(call);
          const __targetExpr = __cf['target'];
          if (!__targetExpr) return null;
          const __target = await this._evalExpression(__targetExpr, scope);
          if (__sw === 'null_aware_cascade' && __target == null) return null;
          const __cScope = scope.child();
          __cScope.bind('__cascade_self__', __target);
          const __sectionsExpr = __cf['sections'];
          if (__sectionsExpr) {
            if (__sectionsExpr.whichExpr && __sectionsExpr.whichExpr() === 'literal' && __sectionsExpr.literal && __sectionsExpr.literal.whichValue && __sectionsExpr.literal.whichValue() === 'listValue') {
              for (const __sec of __sectionsExpr.literal.listValue.elements) {
                await this._evalExpression(__sec, __cScope);
              }
            } else {
              await this._evalExpression(__sectionsExpr, __cScope);
            }
          }
          return __target;
        }
        else if (__sw === 'dart_await_for')`,
    );

    // Post-processing: fix _stdMapCreate to support both 'entries' and 'entry'
    // fields, and use 'key' instead of 'name' for map keys.
    body = body.replace(
      /let entries = input\['entries'\];/,
      `let entries = input['entries'] ?? input['entry'];`,
    );
    body = body.replace(
      /result\[entry\['name'\]\] = entry\['value'\];/,
      `result[entry['key'] ?? entry['name']] = entry['value'];`,
    );

    // Post-processing: expand the std module check in _evalCall to include
    // std_collections, std_io, etc. so their functions route to _callBaseFunction.
    body = body.replace(
      /if \(\(\(call\.module === 'std'\) \|\| \(call\.module === 'dart_std'\)\)\) \{\s*return this\._callBaseFunction\(call\.module, call\.function, input\);\s*\}/,
      `if (call.module === 'std' || call.module === 'dart_std' || call.module === 'std_collections' || call.module === 'std_io' || call.module === 'std_convert' || call.module === 'std_memory') {
      return this._callBaseFunction(call.module, call.function, input);
    }`,
    );

    // Post-processing: add getter/setter maps to BallEngine.
    // The Dart engine stores getters and setters in separate maps to avoid
    // collisions when they share the same function name.
    body = body.replace(
      /readonly _functions: Map<string, FunctionDefinition> = \{\};/,
      `readonly _functions: Map<string, FunctionDefinition> = {};
  readonly _getters: any = {};
  readonly _setters: any = {};`,
    );
    // In _buildLookupTables, after storing func in _functions, also store
    // in _getters/_setters based on metadata.
    body = body.replace(
      /let key = \(\(__ball_to_string\(module\.name\) \+ '\.'\) \+ __ball_to_string\(func\.name\)\);\s*this\._functions\[key\] = func;/,
      `let key = ((__ball_to_string(module.name) + '.') + __ball_to_string(func.name));
        this._functions[key] = func;
        // Separate getter/setter storage
        if (func.hasMetadata()) {
          const __igf = func.metadata.fields ? func.metadata.fields['is_getter'] : null;
          const __isf = func.metadata.fields ? func.metadata.fields['is_setter'] : null;
          if (__igf && (__igf.boolValue === true || __igf === true)) {
            this._getters[key] = func;
          }
          if (__isf && (__isf.boolValue === true || __isf === true)) {
            this._setters[key] = func;
          }
        }`,
    );
    // Fix _tryGetterDispatch and _trySetterDispatch to use separate maps.
    // Replace ALL occurrences of getterFunc lookup to prefer _getters.
    body = body.replace(
      /let getterFunc = this\._functions\[getterKey\];/g,
      `let getterFunc = this._getters[getterKey] ?? this._functions[getterKey];`,
    );
    // Also fix the fallback lookups in _tryGetterDispatch to check _getters
    body = body.replace(
      /getterFunc = this\._functions\[modPart \+ '\.' \+ __gBareType/g,
      `getterFunc = this._getters[modPart + '.' + __gBareType`,
    );
    // Fix _trySetterDispatch to check _setters map
    body = body.replace(
      /let setterFunc = this\._functions\[setterKey\];/g,
      `let setterFunc = this._setters[setterKey] ?? this._functions[setterKey];`,
    );

    // Post-processing: inject field assignment back to self object.
    // When a method assigns to an instance field (scope.set('x', val)),
    // the change should propagate back to the actual object's field so
    // later field accesses via _evalFieldAccess see the updated value.
    // Replace _Scope.set to also update the self object's field.
    body = body.replace(
      /set\(name: any, value: any\): any \{\s*if \(this\._bindings\.containsKey\(name\)\) \{\s*this\._bindings\[name\] = value;\s*return;\s*\}/,
      `set(name: any, value: any): any {
    if (this._bindings.containsKey(name)) {
      this._bindings[name] = value;
      if (!name.startsWith('__') && this._bindings.containsKey('self')) {
        const __s = this._bindings['self'];
        if (typeof __s === 'object' && __s !== null && !Array.isArray(__s) && name in __s) {
          __s[name] = value;
        }
      }
      return;
    }`,
    );

    // Post-processing: inject constructor dispatch into _evalMessageCreation.
    // The Dart engine calls constructors when typeName matches a registered
    // constructor, but the encoder missed this. Inject it right after the
    // `if (msg.typeName.isNotEmpty) {` check and before `fields['__type__'] = msg.typeName;`.
    body = body.replace(
      /if \(msg\.typeName\.isNotEmpty\) \{\s*fields\['__type__'\] = msg\.typeName;/,
      `if (msg.typeName.isNotEmpty) {
      const __ctorEntry = this._constructors[msg.typeName];
      if (__ctorEntry != null) {
        return this._callFunction(__ctorEntry.module, __ctorEntry.func, fields);
      }
      fields['__type__'] = msg.typeName;`,
    );

    // Post-processing: initialize descriptor fields on created objects.
    // When _evalMessageCreation creates an object from a typeDef, fields
    // defined in the descriptor should be initialized to their default
    // values so they're present as keys for field access.
    body = body.replace(
      /let methods = this\._resolveTypeMethodsWithInheritance\(msg\.typeName\);/,
      `// Initialize descriptor fields with defaults
        if (typeDef.fieldNames && typeDef.fieldNames.length > 0) {
          const __fDefaults = this._getFieldDefaults(msg.typeName);
          for (const __fn of typeDef.fieldNames) {
            if (!(__fn in fields)) {
              fields[__fn] = (__fn in __fDefaults) ? __fDefaults[__fn] : null;
            }
          }
        }
        let methods = this._resolveTypeMethodsWithInheritance(msg.typeName);`,
    );

    // Post-processing: add _getFieldDefaults and _findRawTypeDef methods.
    body = body.replace(
      /(\s+)async _resolveAndCallFunction\(/,
      `$1_rawTypeDefCache: any = {};
  _fieldDefaultsCache: any = {};

$1_findRawTypeDef(typeName: any): any {
    if (this._rawTypeDefCache[typeName] !== undefined) return this._rawTypeDefCache[typeName];
    for (const module of this.program.modules) {
      for (const td of module.typeDefs) {
        if (td.name === typeName || td.name.endsWith(':' + String(typeName))) {
          this._rawTypeDefCache[typeName] = td;
          return td;
        }
      }
    }
    this._rawTypeDefCache[typeName] = null;
    return null;
  }

$1_getFieldDefaults(typeName: any): any {
    if (this._fieldDefaultsCache[typeName]) return this._fieldDefaultsCache[typeName];
    const defaults: any = {};
    const rawTd = this._findRawTypeDef(typeName);
    if (!rawTd || !rawTd.metadata) { this._fieldDefaultsCache[typeName] = defaults; return defaults; }
    // Parse metadata fields array for initializers
    const metaFields = rawTd.metadata.fields ? rawTd.metadata.fields['fields'] : null;
    let fieldArr: any[] = [];
    if (metaFields && metaFields.whichKind && metaFields.whichKind() === 'listValue') {
      for (const v of metaFields.listValue.values) {
        if (v.whichKind && v.whichKind() === 'structValue') {
          const r: any = {};
          const sf = v.structValue.fields;
          for (const k of Object.keys(sf)) {
            const fv = sf[k];
            if (fv && fv.whichKind) {
              const kind = fv.whichKind();
              if (kind === 'stringValue') r[k] = fv.stringValue;
              else if (kind === 'boolValue') r[k] = fv.boolValue;
              else r[k] = fv._raw ?? null;
            } else r[k] = fv;
          }
          fieldArr.push(r);
        }
      }
    } else if (Array.isArray(metaFields)) {
      fieldArr = metaFields;
    }
    for (const fm of fieldArr) {
      if (!fm.name) continue;
      if (fm.initializer && fm.initializer !== 'null') {
        const init = fm.initializer;
        if (init === '[]' || init.startsWith('<')) defaults[fm.name] = [];
        else if (init === '{}') defaults[fm.name] = {};
        else if (init === '0' || init === '0.0') defaults[fm.name] = 0;
        else if (init === 'false') defaults[fm.name] = false;
        else if (init === 'true') defaults[fm.name] = true;
        else if (init === "''" || init === '""') defaults[fm.name] = '';
        else defaults[fm.name] = null;
      }
    }
    this._fieldDefaultsCache[typeName] = defaults;
    return defaults;
  }

$1async _resolveAndCallFunction(`,
    );

    // Post-processing: inject function/method resolution for unresolved
    // typeNames in _evalMessageCreation. After the typeDef check, when
    // no typeDef is found, try resolving as a function call.
    // Find the end of _evalMessageCreation's if(typeName) block and add fallback.
    body = body.replace(
      /return fields;\s*\}\s*\n\s*_findTypeDef/,
      `if (!fields['__type__'] || !this._findTypeDef(msg.typeName)) {
        const __fnKey = this._currentModule + '.' + msg.typeName;
        const __fnMatch = this._functions[__fnKey];
        if (__fnMatch != null && !__fnMatch.isBase && __fnMatch.hasBody()) {
          return this._callFunction(this._currentModule, __fnMatch, fields);
        }
        // Try searching all functions for a matching suffix
        // e.g., typeName="main:_gcd" should match "main.main:Fraction._gcd"
        const __bareType = String(msg.typeName).indexOf(':') >= 0 ? String(msg.typeName).substring(String(msg.typeName).indexOf(':') + 1) : String(msg.typeName);
        for (const __fk of Object.keys(this._functions)) {
          if (__fk.endsWith('.' + __bareType) || __fk.endsWith('.' + msg.typeName)) {
            const __fm = this._functions[__fk];
            if (__fm && !__fm.isBase && __fm.hasBody()) {
              return this._callFunction(this._currentModule, __fm, fields);
            }
          }
        }
      }
      return fields;
    }

  _findTypeDef`,
    );

    // Post-processing: inject constructor instance building.
    // When a function has no body and its metadata says kind='constructor',
    // build an instance object from is_this params instead of returning null.
    body = body.replace(
      /if \(!func\.hasBody\(\)\) \{\s*return null;\s*\}/,
      `if (!func.hasBody()) {
      if (func.hasMetadata()) {
        const __kindF = func.metadata.fields ? func.metadata.fields['kind'] : null;
        if (__kindF && (__kindF.stringValue === 'constructor' || __kindF === 'constructor')) {
          return await this.__buildCtorInstance(moduleName, func, input);
        }
      }
      return null;
    }
    // Also handle constructors with empty or trivial bodies
    if (func.hasMetadata()) {
      const __kindF2 = func.metadata.fields ? func.metadata.fields['kind'] : null;
      if (__kindF2 && (__kindF2.stringValue === 'constructor' || __kindF2 === 'constructor')) {
        // Check if body is empty or notSet
        const __body = func.body;
        const __isNotSet = __body && typeof __body.whichExpr === 'function' && __body.whichExpr() === 'notSet';
        const __isEmptyBlock = __body && __body.block && (!__body.block.statements || __body.block.statements.length === 0) && !__body.block.result;
        if (__isNotSet || __isEmptyBlock || !__body) {
          return await this.__buildCtorInstance(moduleName, func, input);
        }
      }
    }`,
    );

    // Post-processing: inject built-in type method dispatch into _evalCall.
    // When self.__type__ is '__builtin_class__', dispatch to std functions
    // like dart_list_generate, dart_list_filled, etc.
    body = body.replace(
      /return this\._resolveAndCallFunction\(call\.module, call\.function, input\);/,
      `// Built-in type static method dispatch (List.generate, Map.from, etc.)
    if (typeof input === 'object' && input !== null && !Array.isArray(input) && input['self'] != null) {
      const __bs = input['self'];
      if (typeof __bs === 'object' && __bs !== null && __bs['__type__'] === '__builtin_class__') {
        const __cr = __bs['__class_ref__'];
        const __fn = call.function;
        const __stdInput = Object.assign({}, input);
        delete __stdInput['self'];
        delete __stdInput['__type_args__'];
        // Map positional args to named args for known dispatch functions.
        const __argMaps: any = {
          'generate': {arg0: 'count', arg1: 'generator'},
          'filled': {arg0: 'count', arg1: 'value'},
          'from': {arg0: 'list'},
          'of': {arg0: 'list'},
          'fromEntries': {arg0: 'list'},
        };
        const __am = __argMaps[__fn];
        if (__am) {
          for (const [__pk, __nk] of Object.entries(__am)) {
            if (__pk in __stdInput && !(__nk as string in __stdInput)) {
              __stdInput[__nk as string] = __stdInput[__pk];
            }
          }
        }
        const __stdNames: string[] = [];
        if (__cr === 'List') __stdNames.push('dart_list_' + __fn, 'list_' + __fn, __fn);
        else if (__cr === 'Map') {
          __stdNames.push('map_' + __fn, 'dart_map_' + __fn, 'map_from_entries', __fn);
          // Special case: Map.fromEntries - handle directly
          if (__fn === 'fromEntries') {
            const __feList = __stdInput['list'] ?? __stdInput['entries'] ?? __stdInput['arg0'] ?? [];
            if (Array.isArray(__feList)) {
              const __feResult: any = {};
              for (const __fe of __feList) {
                if (typeof __fe === 'object' && __fe !== null) {
                  const __fek = Object.prototype.hasOwnProperty.call(__fe, 'key') ? __fe['key'] : (Object.prototype.hasOwnProperty.call(__fe, 'arg0') ? __fe['arg0'] : '');
                  const __fev = Object.prototype.hasOwnProperty.call(__fe, 'value') ? __fe['value'] : (Object.prototype.hasOwnProperty.call(__fe, 'arg1') ? __fe['arg1'] : undefined);
                  __feResult[String(__fek)] = __fev;
                }
              }
              return __feResult;
            }
          }
        }
        else if (__cr === 'Set') __stdNames.push('set_' + __fn, 'dart_set_' + __fn, __fn);
        for (const __sn of __stdNames) {
          try { return await this._callBaseFunction('std', __sn, __stdInput); } catch (e) {}
          try { return await this._callBaseFunction('dart_std', __sn, __stdInput); } catch (e) {}
          try { return await this._callBaseFunction('std_collections', __sn, __stdInput); } catch (e) {}
        }
      }
    }
    return this._resolveAndCallFunction(call.module, call.function, input);`,
    );

    // Post-processing: inject the __buildCtorInstance method as a new
    // method on BallEngine. We insert it right before the closing of
    // the class by finding a known method pattern.
    const ctorHelperMethod = `
  async __buildCtorInstance(moduleName: any, func: any, input: any): Promise<any> {
    const params = func.hasMetadata() ? this._extractParams(func.metadata) : [];
    const paramsMeta = this.__extractParamsMeta(func.metadata);
    const instance: any = {};
    const dotIdx = func.name.indexOf('.');
    const typeName = dotIdx >= 0 ? func.name.substring(0, dotIdx) : func.name;
    instance['__type__'] = typeName;
    // Resolve all param values.
    const resolvedParams: any = {};
    if (typeof input === 'object' && input !== null && !Array.isArray(input)) {
      for (let i = 0; i < params.length; i++) {
        const p = params[i];
        const isThis = i < paramsMeta.length && paramsMeta[i]['is_this'] === true;
        let val: any;
        if (p in input) { val = input[p]; }
        else if (('arg' + i) in input) { val = input['arg' + i]; }
        else { val = i < paramsMeta.length ? (paramsMeta[i]['default'] ?? null) : null; }
        resolvedParams[p] = val;
        if (isThis) { instance[p] = val; }
      }
    } else if (params.length === 1) {
      resolvedParams[params[0]] = input;
      const isThis = paramsMeta.length > 0 && paramsMeta[0]['is_this'] === true;
      if (isThis) { instance[params[0]] = input; }
    }
    // Process initializers (super calls, field initializations).
    if (func.hasMetadata()) {
      const initsField = func.metadata.fields ? func.metadata.fields['initializers'] : null;
      let inits: any[] = [];
      if (initsField && initsField.whichKind && initsField.whichKind() === 'listValue') {
        inits = initsField.listValue.values.map((v: any) => {
          if (v.whichKind && v.whichKind() === 'structValue') {
            const r: any = {};
            const sf = v.structValue.fields;
            for (const k of Object.keys(sf)) {
              const fv = sf[k];
              if (fv && fv.whichKind) {
                const kind = fv.whichKind();
                if (kind === 'stringValue') r[k] = fv.stringValue;
                else if (kind === 'boolValue') r[k] = fv.boolValue;
                else r[k] = fv._raw ?? null;
              } else { r[k] = fv; }
            }
            return r;
          }
          return {};
        });
      } else if (initsField && Array.isArray(initsField)) {
        inits = initsField;
      } else if (initsField && initsField._raw && Array.isArray(initsField._raw)) {
        inits = initsField._raw;
      }
      for (const init of inits) {
        if (init.kind === 'super') {
          // Call super constructor.
          const typeDef = this._findTypeDef(typeName);
          const superclass = typeDef?.superclass;
          if (superclass && typeof superclass === 'string' && superclass.length > 0) {
            // Parse args from the initializer.
            const argsStr = typeof init.args === 'string' ? init.args : '';
            const superInput: any = {};
            // Simple arg parsing: "(name)" -> {arg0: resolvedParams[name]}
            // "(name, age)" -> {arg0: name, arg1: age}
            const argMatch = argsStr.match(/\\(([^)]*)\\)/);
            if (argMatch) {
              const argNames = argMatch[1].split(',').map((s: string) => s.trim()).filter((s: string) => s);
              for (let i = 0; i < argNames.length; i++) {
                const argName = argNames[i];
                // Strip quotes from string literal args
                let __argVal = resolvedParams[argName];
                if (__argVal === undefined) {
                  if ((argName.startsWith("'") && argName.endsWith("'")) || (argName.startsWith('"') && argName.endsWith('"'))) {
                    __argVal = argName.substring(1, argName.length - 1);
                  } else if (!isNaN(Number(argName))) {
                    __argVal = Number(argName);
                  } else {
                    __argVal = argName;
                  }
                }
                superInput['arg' + i] = __argVal;
              }
            }
            // Try various constructor key patterns for the superclass.
            const __scKeys = [
              superclass + '.new', superclass,
              moduleName + ':' + superclass + '.new', moduleName + ':' + superclass,
            ];
            let superCtor: any = null;
            for (const __sk of __scKeys) {
              if (this._constructors[__sk]) { superCtor = this._constructors[__sk]; break; }
            }
            if (superCtor) {
              const superObj = await this._callFunction(superCtor.module, superCtor.func, superInput);
              if (typeof superObj === 'object' && superObj !== null) {
                // Copy super's non-__ fields into our instance.
                for (const k of Object.keys(superObj)) {
                  if (!k.startsWith('__') && !(k in instance)) instance[k] = superObj[k];
                }
                instance['__super__'] = superObj;
              }
            }
          }
        } else if (init.kind === 'field') {
          // Field initializer: assign a value to a field.
          const fieldName = init.name;
          const valStr = init.value;
          if (fieldName && valStr != null) {
            if (valStr in resolvedParams) {
              instance[fieldName] = resolvedParams[valStr];
            } else {
              // Try evaluating simple expressions like "coords[0]"
              const __idxMatch = String(valStr).match(/^(\\w+)\\[(\\d+)\\]$/);
              if (__idxMatch && __idxMatch[1] in resolvedParams) {
                const __arr = resolvedParams[__idxMatch[1]];
                const __idx = parseInt(__idxMatch[2], 10);
                instance[fieldName] = Array.isArray(__arr) ? __arr[__idx] : __arr;
              } else {
                instance[fieldName] = valStr;
              }
            }
          }
        }
      }
    }
    // Initialize field defaults from typeDef descriptor.
    const typeDef = this._findTypeDef(typeName);
    if (typeDef != null) {
      if (typeDef.fieldNames) {
        for (const fn of typeDef.fieldNames) {
          if (!(fn in instance)) instance[fn] = null;
        }
      }
      if (!instance['__super__'] && typeDef.superclass && typeof typeDef.superclass === 'string' && typeDef.superclass.length > 0) {
        instance['__super__'] = this._buildSuperObject(typeDef.superclass, instance);
      }
      const methods = this._resolveTypeMethodsWithInheritance(typeName);
      if (typeof methods === 'object' && methods !== null && Object.keys(methods).length > 0) {
        instance['__methods__'] = methods;
      }
    }
    return instance;
  }

  __extractParamsMeta(metadata: any): any[] {
    if (!metadata) return [];
    const paramsField = metadata.fields ? metadata.fields['params'] : (metadata['params'] ?? null);
    if (!paramsField) return [];
    let raw: any[];
    if (paramsField.whichKind && paramsField.whichKind() === 'listValue') {
      raw = paramsField.listValue.values.map((v: any) => {
        if (v.whichKind && v.whichKind() === 'structValue') {
          const result: any = {};
          const sf = v.structValue.fields;
          for (const k of Object.keys(sf)) {
            const fv = sf[k];
            if (fv.whichKind) {
              const kind = fv.whichKind();
              if (kind === 'stringValue') result[k] = fv.stringValue;
              else if (kind === 'boolValue') result[k] = fv.boolValue;
              else if (kind === 'numberValue') result[k] = fv.numberValue;
              else result[k] = fv._raw ?? null;
            } else {
              result[k] = fv;
            }
          }
          return result;
        }
        return {};
      });
    } else if (Array.isArray(paramsField)) {
      raw = paramsField;
    } else if (paramsField._raw && Array.isArray(paramsField._raw)) {
      raw = paramsField._raw;
    } else {
      return [];
    }
    return raw;
  }
`;

    // Insert the helper method before the last method of BallEngine.
    // We find `_resolveAndCallFunction` and insert before it.
    body = body.replace(
      /(\s+)async _resolveAndCallFunction\(/,
      `$1${ctorHelperMethod}\n$1async _resolveAndCallFunction(`,
    );

    // ── Post-processing: fix _toNum to handle strings gracefully ────
    // The compiled Dart engine's _toNum throws on strings, but the
    // hand-written TS engine converts them to numbers gracefully.
    body = body.replace(
      /throw new BallRuntimeError\(\(\('Cannot convert ' \+ __ball_to_string\(v\.runtimeType\)\) \+ ' to num'\)\);/,
      `if (v instanceof BallDouble) return v.value;
    if (typeof v === 'string') { const n = Number(v); return isNaN(n) ? 0 : n; }
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;`,
    );

    // ── Post-processing: fix _toDouble similarly ────────────────────
    body = body.replace(
      /throw new BallRuntimeError\(\(\('Cannot convert ' \+ __ball_to_string\(v\.runtimeType\)\) \+ ' to double'\)\);/,
      `if (v instanceof BallDouble) return v;
    if (typeof v === 'string') { const n = Number(v); return isNaN(n) ? new BallDouble(0.0) : new BallDouble(n); }
    if (typeof v === 'boolean') return new BallDouble(v ? 1.0 : 0.0);
    return new BallDouble(0.0);`,
    );

    // _toDouble returns plain numbers for performance.
    // BallDouble is only used by the harness's to_double/int_to_double.

    // ── Post-processing: fix _toInt - make __ball_parse_int more lenient ──
    body = body.replace(
      /throw new BallRuntimeError\(\(\('Cannot convert ' \+ __ball_to_string\(v\.runtimeType\)\) \+ ' to int'\)\);/,
      `if (v instanceof BallDouble) return Math.trunc(v.value);
    if (typeof v === 'string') { const n = parseInt(v, 10); return isNaN(n) ? 0 : n; }
    if (typeof v === 'boolean') return v ? 1 : 0;
    return 0;`,
    );

    // ── Post-processing: fix _evalLazyForIn to handle strings/maps ──
    // The compiled engine only handles arrays; it needs to also iterate
    // over strings (char by char) and over map/object entries.
    body = body.replace(
      /let iterVal = await this\._evalExpression\(iterable, scope\);\s*if \(!?\(Array\.isArray\(iterVal\)\)\) \{\s*throw new BallRuntimeError\('std\.for_in: iterable is not a List'\);\s*\}/,
      `let iterVal = await this._evalExpression(iterable, scope);
    if (typeof iterVal === 'string') {
      iterVal = iterVal.split('');
    } else if (typeof iterVal === 'object' && iterVal !== null && !Array.isArray(iterVal)) {
      if (iterVal instanceof Map) {
        iterVal = [...iterVal.entries()].map(([k, v]: any) => ({key: k, value: v}));
      } else {
        iterVal = Object.entries(iterVal).filter(([k]: any) => !k.startsWith('__')).map(([k, v]: any) => ({key: k, value: v}));
      }
    }
    if (!Array.isArray(iterVal)) {
      iterVal = [];
    }`,
    );

    // ── Post-processing: fix _evalLazySwitch default sentinel ───────
    // The compiled engine uses __no_init__ as sentinel for defaultBody
    // but checks `if ((defaultBody != null))` which is always true for
    // a Symbol. Fix to also check against __no_init__.
    body = body.replace(
      /if \(\(defaultBody != null\)\) \{\s*return this\._evalExpression\(defaultBody, scope\);\s*\}\s*\}/,
      `if (defaultBody != null && defaultBody !== __no_init__) {
      return this._evalExpression(defaultBody, scope);
    }
  }`,
    );

    // ── Post-processing: fix typed catch matching ────────────────────
    // The compiled engine checks e['runtimeType'] for type matching,
    // but JS Error objects don't have runtimeType. Fix to check the
    // error's constructor name and common Dart exception types.
    body = body.replace(
      /let matches = \(\(e instanceof BallException\) \? \(e\['typeName'\] === catchType\) : \(__ball_to_string\(e\['runtimeType'\]\) === catchType\)\);/,
      `let matches = false;
            if (e instanceof BallException) {
              matches = e['typeName'] === catchType;
            } else if (catchType === 'Exception' || catchType === 'Object') {
              matches = true;
            } else if (catchType === 'FormatException') {
              matches = (e instanceof Error && e.message.startsWith('FormatException'));
            } else if (catchType === 'TypeError' || catchType === 'RangeError' || catchType === 'Error') {
              matches = (e instanceof globalThis[catchType]);
            } else if (catchType === 'StateError' || catchType === 'ArgumentError' || catchType === 'UnsupportedError') {
              matches = (e instanceof Error);
            } else {
              matches = (typeof e === 'object' && e !== null && (e['__type__'] === catchType || e['__type'] === catchType));
            }`,
    );

    // ── Post-processing: fix catch variable binding ─────────────────
    // The compiled engine binds the catch variable to the stringified
    // error for non-BallException errors, but it should bind the error
    // object itself (or its message) to match Dart semantics.
    body = body.replace(
      /catchScope\.bind\(variable, \(\(e instanceof BallException\) \? e\['value'\] : __ball_to_string\(e\)\)\);/,
      `catchScope.bind(variable, (e instanceof BallException) ? e['value'] : (e instanceof Error ? e.message : e));`,
    );

    // ── Post-processing: enhance method dispatch in _evalCall ─────
    // When the primary method key lookup fails (e.g., "main.main:Base.greet"),
    // try alternative key formats. The OOP dispatch builds
    // "modPart.typeName.function" but the function may be registered under
    // just "typeName.function" within the module namespace.
    body = body.replace(
      /let method = this\._functions\[methodKey\];\s*if \(\(method != null\)\) \{\s*return this\._callFunction\(modPart, method, input\);\s*\}/,
      `let method = this._functions[methodKey];
          if (method == null) {
            // Try without module prefix: "main.Base.greet"
            const __bType = String(typeName).indexOf(':') >= 0 ? String(typeName).substring(String(typeName).indexOf(':') + 1) : String(typeName);
            method = this._functions[modPart + '.' + __bType + '.' + call.function];
          }
          if (method == null) {
            // Try with module-qualified name: "main.main:Child.greet"
            const __qType = String(typeName).indexOf(':') >= 0 ? String(typeName) : modPart + ':' + String(typeName);
            method = this._functions[modPart + '.' + __qType + '.' + call.function];
          }
          if ((method != null)) {
            return this._callFunction(modPart, method, input);
          }`,
    );

    // Do the same for super method dispatch
    body = body.replace(
      /let superMethod = this\._functions\[superMethodKey\];\s*if \(\(superMethod != null\)\) \{\s*return this\._callFunction\(sModPart, superMethod, input\);\s*\}/,
      `let superMethod = this._functions[superMethodKey];
              if (superMethod == null) {
                const __sbType = String(sTypeName).indexOf(':') >= 0 ? String(sTypeName).substring(String(sTypeName).indexOf(':') + 1) : String(sTypeName);
                superMethod = this._functions[sModPart + '.' + __sbType + '.' + call.function];
              }
              if ((superMethod != null)) {
                return this._callFunction(sModPart, superMethod, input);
              }`,
    );

    // Also fix _tryGetterDispatch to try alternative key format
    // Match only the one inside _tryGetterDispatch (has modPart and fieldName in context)
    body = body.replace(
      /let getterKey = \(\(\(\(__ball_to_string\(modPart\)[^;]+;\s*let getterFunc = this\._functions\[getterKey\];\s*if \(\(\(getterFunc != null\) && this\._isGetter\(getterFunc\)\)\)/,
      (m) => {
        // Add alternative key lookup after the first getterFunc assignment
        return m.replace(
          'let getterFunc = this._functions[getterKey];',
          `let getterFunc = this._functions[getterKey];
    if (getterFunc == null) {
      const __gBareType = String(typeName).indexOf(':') >= 0 ? String(typeName).substring(String(typeName).indexOf(':') + 1) : String(typeName);
      getterFunc = this._functions[modPart + '.' + __gBareType + '.' + fieldName];
      if (getterFunc == null) {
        getterFunc = this._functions[modPart + '.' + modPart + ':' + __gBareType + '.' + fieldName];
      }
    }`,
        );
      },
    );

    // ── Post-processing: fix _resolveAndCallFunction for OOP methods ──
    // When a method call like "greet" with input {self: obj} falls through
    // to _resolveAndCallFunction, it fails because the function is stored as
    // "main.main:Base.greet" not "main.greet". Add a fallback that checks
    // the input for self and dispatches via the type's method table.
    body = body.replace(
      /throw new BallRuntimeError\(\(\('Function "' \+ __ball_to_string\(key\)\) \+ '" not found'\)\);/,
      `// Fallback: try OOP method dispatch via self.__type__
    if (typeof input === 'object' && input !== null && !Array.isArray(input)) {
      const __self = input['self'];
      if (__self != null && typeof __self === 'object' && !Array.isArray(__self)) {
        let __tn = __self['__type__'];
        // Handle built-in class references (List, Map, Set, or user types)
        if (__tn === '__builtin_class__' && __self['__class_ref__']) {
          const __cr = __self['__class_ref__'];
          // Try as a named constructor (e.g., Point.origin)
          const __ctorKeys = [
            __cr + '.' + function_,
            moduleName + ':' + __cr + '.' + function_,
          ];
          for (const __ck of __ctorKeys) {
            const __ctorEntry = this._constructors[__ck];
            if (__ctorEntry) {
              const __ctorInput = Object.assign({}, input);
              delete __ctorInput['self'];
              return this._callFunction(__ctorEntry.module, __ctorEntry.func, __ctorInput);
            }
          }
          // Try as a static method
          const __staticKeys = [
            moduleName + '.' + moduleName + ':' + __cr + '.' + function_,
            moduleName + '.' + __cr + '.' + function_,
          ];
          for (const __sk of __staticKeys) {
            const __sfn = this._functions[__sk];
            if (__sfn) {
              const __sInput = Object.assign({}, input);
              delete __sInput['self'];
              return this._callFunction(moduleName, __sfn, __sInput);
            }
          }
        }
        if (__tn != null && __tn !== '__builtin_class__') {
          const __ci = String(__tn).indexOf(':');
          const __mp = __ci >= 0 ? String(__tn).substring(0, __ci) : moduleName;
          // Try various key formats
          const __bareType = String(__tn).indexOf(':') >= 0 ? String(__tn).substring(String(__tn).indexOf(':') + 1) : String(__tn);
          const __keys = [
            __mp + '.' + __tn + '.' + function_,
            __mp + '.' + __bareType + '.' + function_,
            __mp + '.' + __mp + ':' + __bareType + '.' + function_,
            __mp + '.' + __mp + ':' + __tn + '.' + function_,
          ];
          // Also try via __methods__ dispatch entries
          const __methods = __self['__methods__'];
          if (__methods) {
            // Try dispatch entry (short name)
            const __dEntry = __methods['__dispatch_' + function_];
            if (__dEntry && __dEntry.func) return this._callFunction(__dEntry.module, __dEntry.func, input);
            // Try full name match
            if (__methods[function_] && typeof __methods[function_] === 'function') return __methods[function_](input);
          }
          // Try via super chain
          let __sp = __self['__super__'];
          while (__sp != null && typeof __sp === 'object' && !Array.isArray(__sp)) {
            const __stn = __sp['__type__'];
            if (__stn) {
              const __sci = String(__stn).indexOf(':');
              const __smp = __sci >= 0 ? String(__stn).substring(0, __sci) : __mp;
              __keys.push(__smp + '.' + __stn + '.' + function_);
              __keys.push(__smp + '.' + (String(__stn).indexOf(':') >= 0 ? String(__stn).substring(String(__stn).indexOf(':') + 1) : __stn) + '.' + function_);
            }
            const __sm = __sp['__methods__'];
            if (__sm && __sm[function_]) {
              const __smEntry = __sm[function_];
              if (typeof __smEntry === 'object' && __smEntry.func) {
                return this._callFunction(__smEntry.module, __smEntry.func, input);
              }
            }
            __sp = __sp['__super__'];
          }
          for (const __k of __keys) {
            const __fn = this._functions[__k];
            if (__fn != null) {
              return this._callFunction(__mp, __fn, input);
            }
          }
          // No more keys to try
        }
      }
      // Fallback: try dispatching as a std/std_collections base function
      // This handles method-style calls like sort(), where() on lists/maps
      for (const __stdMod of ['std', 'std_collections', 'dart_std', 'std_io']) {
        try { return await this._callBaseFunction(__stdMod, function_, input); } catch(e) {}
      }
      // Try with list_ or map_ prefix
      const __self2 = input['self'];
      if (__self2 != null) {
        const __prefixes = Array.isArray(__self2) ? ['list_'] : (typeof __self2 === 'string' ? ['string_'] : ['map_']);
        for (const __px of __prefixes) {
          for (const __stdMod of ['std', 'std_collections', 'dart_std']) {
            try { return await this._callBaseFunction(__stdMod, __px + function_, input); } catch(e) {}
          }
        }
      }
    }
    throw new BallRuntimeError((('Function "' + __ball_to_string(key)) + '" not found'));`,
    );

    // ── Post-processing: fix _callBaseFunction for map_fromEntries ──
    // The compiled engine looks for "map_fromEntries" but it's actually
    // "map_from_entries" in the std module.
    body = body.replace(
      /throw new BallRuntimeError\(\(\('Unknown std function: "' \+ __ball_to_string\(function_\)\) \+ '"'\)\);/,
      `// Try camelCase to snake_case conversion before throwing
    const __snakeCase = function_.replace(/([A-Z])/g, '_$1').toLowerCase();
    if (__snakeCase !== function_ && this._dispatch[__snakeCase]) {
      return this._dispatch[__snakeCase](input);
    }
    throw new BallRuntimeError('Unknown std function: "' + __ball_to_string(function_) + '"');`,
    );

    // ── Post-processing: fix for_each handling ──────────────────────
    // Add for_each as alias for for_in in the switch statement
    body = body.replace(
      /else if \(\(__sw === 'for_in'\)\) \{\s*return this\._evalLazyForIn\(call, scope\);\s*\}/,
      `else if (__sw === 'for_in' || __sw === 'for_each') {
          return this._evalLazyForIn(call, scope);
        }`,
    );

    // ── Post-processing: fix _stdBinaryDouble to return BallDouble ──
    // Wrap the result (not the inputs) to preserve double identity.
    body = body.replace(
      /_stdBinaryDouble\(input: any, op: any\): any \{/,
      `_stdBinaryDouble(input: any, op: any): any {
    const __origOp2 = op;
    op = (a: any, b: any) => new BallDouble(__origOp2(a instanceof BallDouble ? a.value : a, b instanceof BallDouble ? b.value : b));`,
    );

    // ── Post-processing: fix doubleValue literals to return BallDouble ──
    // In Dart, doubleValue literals are always doubles (e.g., 3.0).
    // Wrap them in BallDouble so they print as "3.0" not "3".
    body = body.replace(
      /\(lit\.whichValue\(\) === \(Literal_Value\.doubleValue\)\) \? \(lit\.doubleValue\)/,
      `(lit.whichValue() === (Literal_Value.doubleValue)) ? (new BallDouble(typeof lit.doubleValue === 'number' ? lit.doubleValue : Number(lit.doubleValue)))`,
    );

    // ── Post-processing: fix _stdBinary to propagate BallDouble ──────────
    // When BallDouble operands are passed, wrap the result in BallDouble.
    // The issue is that _toNum unwraps BallDouble before passing to op,
    // so we check the RAW args (before _toNum) for BallDouble.
    body = body.replace(
      /return op\(this\._toNum\(left\), this\._toNum\(right\)\);\s*\}/,
      `const __lBD = left instanceof BallDouble;
    const __rBD = right instanceof BallDouble;
    const __result = op(this._toNum(left), this._toNum(right));
    if ((__lBD || __rBD) && typeof __result === 'number') return new BallDouble(__result);
    return __result;
  }`,
    );

    // ── Post-processing: fix _stdIndex for flexible access ─────────────
    // The compiled engine's _stdIndex only handles specific type combos.
    // Add broader fallback: coerce index for objects, handle Maps, BallDouble.
    // Also fix the existing checks to handle BallDouble indices.
    body = body.replace(
      /let target = input\['target'\];\s*let index = input\['index'\];/,
      `let target = input['target'];
    let index = input['index'];
    // Unwrap BallDouble index for array access
    if (index instanceof BallDouble) index = index.value;`,
    );
    body = body.replace(
      /throw new BallRuntimeError\('std\.index: unsupported types'\);/,
      `// Fallback: try flexible index access
    if (typeof target === 'object' && target !== null) {
      if (target instanceof Map) return target.get(index);
      if (!Array.isArray(target)) return target[String(index)];
      return target[Number(index)];
    }
    if (typeof target === 'string') return target.charAt(Number(index));
    return null;`,
    );

    // ── Post-processing: fix _stdPrint to handle BallDouble ──────
    // __ball_to_string already handles BallDouble, but the compiled
    // engine also calls this.stdout(__ball_to_string(...)) directly
    // and may pass BallDouble through. This is already handled by
    // the preamble's __ball_to_string function.

    // BallDouble equality: handled by valueOf() automatically

    // Class name binding is done in the harness via gs.bind()

    // ── Post-processing: fix _applyCompoundOp for string += ──────
    // The Dart engine checks if current or val is a String before
    // calling _numOp for +=. The compiled code always calls _numOp.
    // Replace the += handler to check for strings first.
    body = body.replace(
      /_applyCompoundOp\(op: any, current: any, val: any\): any \{\s*return \(\(op === '\+='\) \? \(this\._numOp\(current, val, \(\(a, b\) => \{\s*return \(a \+ b\);\s*\}\)\)\)/,
      `_applyCompoundOp(op: any, current: any, val: any): any {
    return ((op === '+=') ? ((typeof current === 'string' || typeof val === 'string') ? (String(current ?? '') + String(val ?? '')) : (this._numOp(current, val, ((a, b) => {
      return (a + b);
    }))))`,
    );

    // ── Post-processing: fix _evalMessageCreation repeated field names ──
    // When multiple fields have the same name (e.g., repeated "entry"
    // in map_create), accumulate them into an array.
    body = body.replace(
      /let fields = \{\};\s*for \(const pair of msg\.fields\) \{\s*fields\[pair\.name\] = await this\._evalExpression\(pair\.value, scope\);\s*\}/,
      `let fields = {};
    for (const pair of msg.fields) {
      const __val = await this._evalExpression(pair.value, scope);
      if (pair.name in fields) {
        // Repeated field name: accumulate into array
        if (!Array.isArray(fields[pair.name]) || !fields[pair.name].__repeated) {
          const __arr = [fields[pair.name]];
          __arr.__repeated = true;
          fields[pair.name] = __arr;
        }
        fields[pair.name].push(__val);
      } else {
        fields[pair.name] = __val;
      }
    }`,
    );

    // ── Post-processing: fix object.length in _evalFieldAccess ────────
    // Plain JS objects don't have .length. Fix to use Object.keys().length.
    // Fix the switch-case length handler inside the main object check
    body = body.replace(
      /else if \(\(__sw === 'length'\)\) \{\s*return object\.length;\s*\}/,
      `else if (__sw === 'length') {
          if (Array.isArray(object)) return object.length;
          if (typeof object === 'string') return object.length;
          if (object instanceof Set) return object.size;
          return Object.keys(object).filter((k: string) => !k.startsWith('__')).length;
        }`,
    );
    // Fix the fallback length handler
    body = body.replace(
      /if \(\(typeof object === 'object' && object !== null && !Array\.isArray\(object\)\)\) \{\s*return object\.length;\s*\}/,
      `if ((typeof object === 'object' && object !== null && !Array.isArray(object))) {
          return Object.keys(object).filter((k: string) => !k.startsWith('__')).length;
        }`,
    );
    // Also fix isEmpty and isNotEmpty for objects
    body = body.replace(
      /if \(\(typeof object === 'object' && object !== null && !Array\.isArray\(object\)\)\) \{\s*return object\.isEmpty;\s*\}/,
      `if ((typeof object === 'object' && object !== null && !Array.isArray(object))) {
          return Object.keys(object).filter((k: string) => !k.startsWith('__')).length === 0;
        }`,
    );
    body = body.replace(
      /if \(\(typeof object === 'object' && object !== null && !Array\.isArray\(object\)\)\) \{\s*return object\.isNotEmpty;\s*\}/,
      `if ((typeof object === 'object' && object !== null && !Array.isArray(object))) {
          return Object.keys(object).filter((k: string) => !k.startsWith('__')).length > 0;
        }`,
    );

    // ── Post-processing: fix __methods__ check in _evalFieldAccess ──────
    // When looking up a field from __methods__, invoke getters instead of
    // returning the raw function. Also invoke methods that match toString.
    body = body.replace(
      /let methods = object\['__methods__'\];\s*if \(\(\(typeof methods === 'object' && methods !== null && !Array\.isArray\(methods\)\) && methods\.containsKey\(fieldName\)\)\) \{\s*return methods\[fieldName\];\s*\}/,
      `let methods = object['__methods__'];
      if (((typeof methods === 'object' && methods !== null && !Array.isArray(methods)) && methods.containsKey(fieldName))) {
        const __mVal = methods[fieldName];
        // If it's a getter, invoke it
        if (typeof __mVal === 'function' && __mVal.__isGetter) {
          return __mVal({ 'self': object });
        }
        return __mVal;
      }`,
    );

    // ── Post-processing: fix _resolveTypeMethodsWithInheritance for mixins ──
    // Add mixin support: resolve methods from mixin types too.
    body = body.replace(
      /_resolveTypeMethodsWithInheritance\(typeName: any\): any \{\s*const input = typeName;\s*let methods = \{\};\s*let typeDef = this\._findTypeDef\(typeName\);\s*if \(\(\(\(typeDef != null\) && \(typeDef\.superclass != null\)\) && typeDef\.superclass\.isNotEmpty\)\) \{\s*methods\.addAll\(this\._resolveTypeMethodsWithInheritance\(typeDef\.superclass\)\);\s*\}\s*methods\.addAll\(this\._resolveTypeMethods\(typeName\)\);\s*return methods;\s*\}/,
      `_resolveTypeMethodsWithInheritance(typeName: any): any {
    const input = typeName;
    let methods = {};
    let typeDef = this._findTypeDef(typeName);
    if (typeDef != null) {
      // Resolve superclass methods
      if ((typeDef.superclass != null) && typeDef.superclass.isNotEmpty) {
        methods.addAll(this._resolveTypeMethodsWithInheritance(typeDef.superclass));
      }
      // Resolve mixin methods — use raw typeDef for metadata access
      const __rawTd = this._findRawTypeDef(typeName);
      if (__rawTd && __rawTd.hasMetadata && __rawTd.hasMetadata()) {
        const mixinsField = __rawTd.metadata.fields ? __rawTd.metadata.fields['mixins'] : null;
        let mixinNames: string[] = [];
        if (mixinsField) {
          if (mixinsField.whichKind && mixinsField.whichKind() === 'listValue') {
            for (const v of mixinsField.listValue.values) {
              if (v.whichKind && v.whichKind() === 'stringValue') mixinNames.push(v.stringValue);
              else if (typeof v === 'string') mixinNames.push(v);
              else if (v._raw && typeof v._raw === 'string') mixinNames.push(v._raw);
            }
          } else if (Array.isArray(mixinsField)) {
            mixinNames = mixinsField.map((v: any) => typeof v === 'string' ? v : (v?.stringValue ?? String(v)));
          } else if (mixinsField._raw && Array.isArray(mixinsField._raw)) {
            mixinNames = mixinsField._raw.map((v: any) => typeof v === 'string' ? v : String(v));
          }
        }
        // Also check interfaces
        const ifacesField = __rawTd.metadata.fields ? __rawTd.metadata.fields['interfaces'] : null;
        let ifaceNames: string[] = [];
        if (ifacesField) {
          if (ifacesField.whichKind && ifacesField.whichKind() === 'listValue') {
            for (const v of ifacesField.listValue.values) {
              if (v.whichKind && v.whichKind() === 'stringValue') ifaceNames.push(v.stringValue);
              else if (typeof v === 'string') ifaceNames.push(v);
            }
          } else if (Array.isArray(ifacesField)) {
            ifaceNames = ifacesField.map((v: any) => typeof v === 'string' ? v : String(v));
          }
        }
        const allMixins = [...mixinNames, ...ifaceNames];
        for (const mn of allMixins) {
          // Try various qualified name patterns
          const candidates = [mn, this._currentModule + ':' + mn];
          for (const candidate of candidates) {
            const mixinMethods = this._resolveTypeMethods(candidate);
            if (mixinMethods && Object.keys(mixinMethods).length > 0) {
              methods.addAll(mixinMethods);
              break;
            }
          }
        }
      }
    }
    methods.addAll(this._resolveTypeMethods(typeName));
    return methods;
  }`,
    );

    // ── Post-processing: fix operator override methodInput ─────────────
    // The compiled engine's _tryOperatorOverride builds {self, other}
    // but the method parameter may have a different name (e.g., 'scalar').
    // Add 'arg0' alias so positional binding works.
    body = body.replace(
      /let methodInput = \{ 'self': left, 'other': right \};/,
      `let methodInput = { 'self': left, 'other': right, 'arg0': right };`,
    );

    // ── Post-processing: fix _evalFieldAccess for toString dispatch ──
    // When an object has a custom toString method (in __methods__), it
    // should be used by __ball_to_string. The issue is that the compiled
    // engine's _evalFieldAccess throws for some field accesses on
    // non-objects. Fix: add fallbacks for common Dart properties on
    // numbers and other primitives.
    body = body.replace(
      /throw new BallRuntimeError\(\(\(\('Cannot access field "' \+ __ball_to_string\(fieldName\)\) \+ '" on '\) \+ __ball_to_string\(\(object\?\.runtimeType \?\? 'null'\)\)\)\);/,
      `// Fallback: try JS property access for common cases
    if (object != null && typeof object !== 'undefined') {
      if (fieldName === 'length') {
        if (typeof object === 'string') return object.length;
        if (Array.isArray(object)) return object.length;
        if (typeof object === 'object') return Object.keys(object).filter((k: string) => !k.startsWith('__')).length;
      }
      if (fieldName === 'isEmpty') {
        if (typeof object === 'string') return object.length === 0;
        if (Array.isArray(object)) return object.length === 0;
      }
      if (fieldName === 'isNotEmpty') {
        if (typeof object === 'string') return object.length > 0;
        if (Array.isArray(object)) return object.length > 0;
      }
      if (fieldName === 'abs' && typeof object === 'number') return Math.abs(object);
      if (fieldName === 'sign' && typeof object === 'number') return Math.sign(object);
      if (fieldName === 'isNaN' && typeof object === 'number') return Number.isNaN(object);
      if (fieldName === 'isFinite' && typeof object === 'number') return Number.isFinite(object);
      if (fieldName === 'isNegative' && typeof object === 'number') return object < 0;
      if (fieldName === 'isInfinite' && typeof object === 'number') return !Number.isFinite(object) && !Number.isNaN(object);
      if (fieldName === 'hashCode') return typeof object === 'number' ? object : 0;
      if (fieldName === 'runtimeType') return object?.runtimeType ?? 'Null';
      const __prop = (object as any)[fieldName];
      if (__prop !== undefined) return __prop;
    }
    if (fieldName === 'toString') return () => __ball_to_string(object);
    throw new BallRuntimeError(((('Cannot access field "' + __ball_to_string(fieldName)) + '" on ') + __ball_to_string((object?.runtimeType ?? 'null'))));`,
    );

    // ── Post-processing: fix _evalReference to look up type names ──
    // When a reference like "Point" or "Color" is evaluated, it should
    // resolve to a constructor/type binding. The Dart engine does this
    // by checking the type registry. Add a fallback that creates a
    // type reference if the name matches a known typeDef.
    body = body.replace(
      /if \(name === 'super' && scope\.has\('self'\)\)/,
      `// Check enums first (before typeDefs, to avoid short-circuiting)
    {
      const __hasEnum = Object.prototype.hasOwnProperty.call(this._enumValues, name);
      const __hasEnumPfx = !__hasEnum && Object.prototype.hasOwnProperty.call(this._enumValues, this._currentModule + ':' + name);
      const __enumVals = __hasEnum ? this._enumValues[name] : (__hasEnumPfx ? this._enumValues[this._currentModule + ':' + name] : undefined);
      if (__enumVals != null) {
        return __enumVals;
      }
    }
    // Check scope first — variables shadow typeDefs
    if (scope.has(name)) {
      return scope.lookup(name);
    }
    // Check typeDefs as class references (only if not an enum)
    {
      const __td = this._findTypeDef(name);
      if (__td) {
        return {'__class_ref__': name, '__type__': '__builtin_class__', '__typeDef__': __td};
      }
      // Also try with module prefix
      const __tdPrefixed = this._findTypeDef(this._currentModule + ':' + name);
      if (__tdPrefixed) {
        return {'__class_ref__': name, '__type__': '__builtin_class__', '__typeDef__': __tdPrefixed};
      }
    }
    if (name === 'super' && scope.has('self'))`,
    );

    // ── Post-processing: fix _evalReference function lookup fallback ──
    // When a reference like "filterEven" is evaluated, it should resolve
    // to a callable wrapper if the name matches a function in _functions.
    // The compiled engine doesn't bind functions in scope by default.
    body = body.replace(
      /let getterKey = \(\(__ball_to_string\(this\._currentModule\) \+ '\.'\) \+ __ball_to_string\(name\)\);\s*let getterFunc = this\._getters\[getterKey\] \?\? this\._functions\[getterKey\];\s*if \(\(\(getterFunc != null\) && this\._isGetter\(getterFunc\)\)\) \{\s*return this\._callFunction\(this\._currentModule, getterFunc, null\);\s*\}\s*return scope\.lookup\(name\);\s*\}/,
      `let getterKey = ((__ball_to_string(this._currentModule) + '.') + __ball_to_string(name));
    let getterFunc = this._getters[getterKey] ?? this._functions[getterKey];
    if (((getterFunc != null) && this._isGetter(getterFunc))) {
      return this._callFunction(this._currentModule, getterFunc, null);
    }
    // Fallback: look up functions by name and return as callable
    {
      const __fnKey = this._currentModule + '.' + name;
      const __fn = this._functions[__fnKey];
      if (__fn != null && __fn.hasBody && __fn.hasBody()) {
        return (async (__fnInput) => {
          return this._callFunction(this._currentModule, __fn, __fnInput);
        });
      }
      // Try with module prefix in the name
      const __fnKey2 = this._currentModule + '.' + this._currentModule + ':' + name;
      const __fn2 = this._functions[__fnKey2];
      if (__fn2 != null && __fn2.hasBody && __fn2.hasBody()) {
        return (async (__fnInput) => {
          return this._callFunction(this._currentModule, __fn2, __fnInput);
        });
      }
    }
    // Fallback: check if self has a matching method (getter) in __methods__
    if (scope.has('self')) {
      const __selfObj = scope.lookup('self');
      if (__selfObj && typeof __selfObj === 'object' && !Array.isArray(__selfObj)) {
        const __methods = __selfObj['__methods__'];
        if (__methods) {
          const __mEntry = __methods[name];
          if (typeof __mEntry === 'function') {
            if (__mEntry.__isGetter) {
              return __mEntry({ 'self': __selfObj });
            }
          }
          const __dEntry = __methods['__dispatch_' + name];
          if (__dEntry && __dEntry.func) {
            // Check if it's a getter
            const __igf = __dEntry.func.hasMetadata ? (__dEntry.func.metadata?.fields?.['is_getter']) : null;
            if (__igf && (__igf.boolValue === true || __igf === true)) {
              return this._callFunction(__dEntry.module, __dEntry.func, { 'self': __selfObj });
            }
          }
        }
      }
    }
    return scope.lookup(name);
  }`,
    );

    // ── Post-processing: fix raw _enumValues/constructors/functions lookups ──
    // Plain object property access like obj[name] can trigger Object.prototype
    // getters (e.g., 'values', 'keys', 'entries') installed by the preamble.
    // Fix raw enum lookup in _evalReference to use hasOwnProperty.
    body = body.replace(
      /let enumVals = this\._enumValues\[name\];/,
      `let enumVals = Object.prototype.hasOwnProperty.call(this._enumValues, name) ? this._enumValues[name] : undefined;`,
    );
    // Fix raw constructor lookup to use hasOwnProperty
    body = body.replace(
      /let ctorEntry = this\._constructors\[name\];/,
      `let ctorEntry = Object.prototype.hasOwnProperty.call(this._constructors, name) ? this._constructors[name] : undefined;`,
    );

    // ── Post-processing: fix _evalIncDec for indexed/field expressions ──
    // The compiled engine only handles reference expressions (var++).
    // Add support for index (arr[i]++) and fieldAccess (obj.field++).
    body = body.replace(
      /let val = await this\._evalExpression\(valueExpr, scope\);\s*let isInc = call\.function\.contains\('increment'\);\s*return \(isInc \? \(val \+ 1\) : \(val - 1\)\);\s*\}/,
      `// Handle indexed expressions: count[x]++ => post_increment(value: index(target, index))
    if (valueExpr.whichExpr() === Expression_Expr.call && valueExpr.call.function === 'index' && (valueExpr.call.module === 'std' || valueExpr.call.module === '' || !valueExpr.call.module)) {
      const __iiFields = this._lazyFields(valueExpr.call);
      const __iiTarget = __iiFields['target'];
      const __iiIndex = __iiFields['index'];
      if (__iiTarget && __iiIndex) {
        const __container = await this._evalExpression(__iiTarget, scope);
        const __idx = await this._evalExpression(__iiIndex, scope);
        if (__container != null && __idx != null) {
          const __current = this._toNum(Array.isArray(__container) ? __container[__idx] : __container[String(__idx)]);
          const __isInc2 = call.function.contains('increment');
          const __isPre2 = call.function.startsWith('pre');
          const __updated = __isInc2 ? __current + 1 : __current - 1;
          if (Array.isArray(__container)) __container[__idx] = __updated;
          else __container[String(__idx)] = __updated;
          return __isPre2 ? __updated : __current;
        }
      }
    }
    // Handle field access: obj.field++ => post_increment(value: fieldAccess)
    if (valueExpr.whichExpr() === Expression_Expr.fieldAccess) {
      const __faObj = await this._evalExpression(valueExpr.fieldAccess.object, scope);
      if (__faObj && typeof __faObj === 'object' && !Array.isArray(__faObj)) {
        const __faField = valueExpr.fieldAccess.field_2 ?? valueExpr.fieldAccess.field;
        const __faCurrent = this._toNum(__faObj[__faField]);
        const __faIsInc = call.function.contains('increment');
        const __faIsPre = call.function.startsWith('pre');
        const __faUpdated = __faIsInc ? __faCurrent + 1 : __faCurrent - 1;
        __faObj[__faField] = __faUpdated;
        return __faIsPre ? __faUpdated : __faCurrent;
      }
    }
    let val = await this._evalExpression(valueExpr, scope);
    let isInc = call.function.contains('increment');
    return (isInc ? (val + 1) : (val - 1));
  }`,
    );

    // ── Post-processing: fix _stdMathClamp for static method call pattern ──
    // When math_clamp is called via MathUtils.clamp(v, lo, hi), the encoder
    // maps it as math_clamp(value: MathUtils_ref, min: v, max: lo, arg2: hi).
    // Detect when value is an object (class ref) and remap args.
    body = body.replace(
      /let value = this\._toNum\(input\['value'\]\);\s*let min = this\._toNum\(input\['min'\]\);\s*let max = this\._toNum\(input\['max'\]\);\s*return value\.clamp\(min, max\);/,
      `let __clampV: any, __clampLo: any, __clampHi: any;
    if (input['value'] != null && typeof input['value'] === 'object') {
      // Static method style: value is class ref, actual args are min/max/arg2
      __clampV = this._toNum(input['min']);
      __clampLo = this._toNum(input['max']);
      __clampHi = this._toNum(input['arg2']);
    } else {
      __clampV = this._toNum(input['value'] ?? input);
      __clampLo = this._toNum(input['min'] ?? input['low'] ?? input['lower']);
      __clampHi = this._toNum(input['max'] ?? input['high'] ?? input['upper']);
    }
    return Math.min(Math.max(__clampV, __clampLo), __clampHi);`,
    );

    // ── Post-processing: fix single-param binding for static method calls ──
    // When _callFunction receives {arg0: value} for a single-param function,
    // it should bind the param to arg0's value, not to the whole object.
    body = body.replace(
      /if \(\(\(params\.length === 1\) && !\(\(typeof input === 'object' && input !== null && !Array\.isArray\(input\)\) && input\.containsKey\('self'\)\)\)\) \{\s*scope\.bind\(params\[0\], input\);\s*\}/,
      `if (((params.length === 1) && !((typeof input === 'object' && input !== null && !Array.isArray(input)) && input.containsKey('self')))) {
        // If input is an object with positional arg keys, extract the value
        if ((typeof input === 'object' && input !== null && !Array.isArray(input)) && (input.containsKey('arg0') || input.containsKey(params[0]))) {
          scope.bind(params[0], input.containsKey(params[0]) ? input[params[0]] : input['arg0']);
        } else {
          scope.bind(params[0], input);
        }
      }`,
    );

    // ── Post-processing: fix _initTopLevelVariables to handle static_field ──
    // Static fields (like Logger._cache) should also be initialized as
    // top-level variables. The compiled engine only handles 'top_level_variable'.
    body = body.replace(
      /if \(\(kindValue\?\.stringValue !== 'top_level_variable'\)\)/,
      `if (kindValue?.stringValue !== 'top_level_variable' && kindValue?.stringValue !== 'static_field')`,
    );

    // ── Post-processing: fix static field name binding ──
    // Static fields have qualified names like "main:Logger._cache". When binding
    // to global scope, also bind the short name (e.g., "_cache").
    // Also convert empty Set to Map if outputType says Map.
    body = body.replace(
      /this\._globalScope\.bind\(func\.name, value\);/,
      `// Convert empty Set to Map if outputType says Map
        if (func.outputType && typeof func.outputType === 'string' && func.outputType.startsWith('Map')) {
          if (value instanceof Set && value.size === 0) value = {};
          if (Array.isArray(value) && value.length === 0) value = {};
        }
        this._globalScope.bind(func.name, value);
        // Also bind short name for unqualified access
        const __dotIdx = func.name.lastIndexOf('.');
        if (__dotIdx >= 0) {
          this._globalScope.bind(func.name.substring(__dotIdx + 1), value);
        }`,
    );

    // ── Post-processing: fix _trySetterDispatch key format ──
    // The compiled engine appends '=' to the setter key, but the functions are
    // stored WITHOUT '='. Try both formats.
    body = body.replace(
      /let setterKey = \(\(\(\(\(__ball_to_string\(modPart\) \+ '\.'\) \+ __ball_to_string\(typeName\)\) \+ '\.'\) \+ __ball_to_string\(fieldName\)\) \+ '='\);\s*let setterFunc = this\._setters\[setterKey\] \?\? this\._functions\[setterKey\];/,
      `let setterKey = (((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(fieldName)) + '=');
    let setterKeyNoEq = ((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(fieldName));
    let setterFunc = this._setters[setterKey] ?? this._setters[setterKeyNoEq] ?? this._functions[setterKey] ?? this._functions[setterKeyNoEq];`,
    );
    // Also fix getter key to try module-qualified name
    body = body.replace(
      /let getterKey = \(\(\(\(__ball_to_string\(modPart\) \+ '\.'\) \+ __ball_to_string\(typeName\)\) \+ '\.'\) \+ __ball_to_string\(fieldName\)\);\s*let getterFunc = this\._getters\[getterKey\] \?\? this\._functions\[getterKey\];/,
      `let getterKey = ((((__ball_to_string(modPart) + '.') + __ball_to_string(typeName)) + '.') + __ball_to_string(fieldName));
    let getterFunc = this._getters[getterKey] ?? this._functions[getterKey];
    if (getterFunc == null) {
      // Try with module-qualified type: "main.main:Temperature.celsius"
      const __gqType = String(typeName).indexOf(':') >= 0 ? String(typeName) : modPart + ':' + String(typeName);
      const __gqKey = modPart + '.' + __gqType + '.' + fieldName;
      getterFunc = this._getters[__gqKey] ?? this._functions[__gqKey];
    }`,
    );

    // ── Post-processing: fix _stdAdd to preserve BallDouble ──
    // _stdAdd doesn't check for BallDouble operands. Wrap the result if either
    // operand is BallDouble, matching _stdBinary's behavior.
    body = body.replace(
      /return \(this\._toNum\(left\) \+ this\._toNum\(right\)\);\s*\}\s*\n\s*_stdBinary/,
      `const __ladd = left instanceof BallDouble;
    const __radd = right instanceof BallDouble;
    const __addR = this._toNum(left) + this._toNum(right);
    return (__ladd || __radd) ? new BallDouble(__addR) : __addR;
  }

  _stdBinary`,
    );

    // ── Post-processing: fix map_from_entries built-in handler ──
    // The engine's built-in map_from_entries handler is broken. Replace it with
    // a correct implementation that handles MapEntry objects with arg0/arg1 fields.
    body = body.replace(
      /'map_from_entries': \(\(i\) => \{[\s\S]*?\}\), 'map_merge'/,
      `'map_from_entries': ((i) => {
        const input = i;
        const _own = (o, k) => Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined;
        const list = _own(i, 'list') ?? _own(i, 'entries') ?? _own(i, 'arg0') ?? [];
        if (!Array.isArray(list)) return {};
        const result = {};
        for (const e of list) {
          if (typeof e === 'object' && e !== null) {
            const k = _own(e, 'key') ?? _own(e, 'arg0') ?? _own(e, 'name') ?? '';
            const v = Object.prototype.hasOwnProperty.call(e, 'value') ? e['value'] : (_own(e, 'arg1') ?? undefined);
            result[String(k)] = v;
          }
        }
        return result;
      }), 'map_merge'`,
    );

    // ── Post-processing: fix _evalMessageCreation toString injection ──
    // When an OOP object is created and its type has a toString method,
    // override Object.prototype.toString on the instance so
    // __ball_to_string picks it up.
    body = body.replace(
      /let methods = this\._resolveTypeMethodsWithInheritance\(msg\.typeName\);/,
      `let methods = this._resolveTypeMethodsWithInheritance(msg.typeName);
        // toString injection is handled by _stdPrint's __resolveToString`,
    );

    // ── Post-processing: fix _evalCall for method dispatch on self ──
    // When a call has input.containsKey('self') and the function is not
    // found in the module, try dispatching via the self object's
    // __methods__ table. This handles OOP method calls.
    body = body.replace(
      /if \(input\.containsKey\('self'\)\) \{/,
      `if (typeof input === 'object' && input !== null && !Array.isArray(input) && ('self' in input || input.containsKey?.('self'))) {`,
    );

    // ── Post-processing: fix enum value name property ──────────────
    // Enum instances store their name in the 'name' field but
    // _evalFieldAccess may not find it because the field is stored
    // as a proto default ''. Fix by ensuring enum objects preserve
    // their name field.

    // ── Post-processing: fix _resolveTypeMethods to use short names ──
    // Also fix the class matching: the compiled engine checks metadata.fields['class']
    // but Ball programs encode class membership in the function name prefix
    // (e.g., "main:Fraction.toString"). Fix to also check name prefixes.
    body = body.replace(
      /_resolveTypeMethods\(typeName: any\): any \{\s*const input = typeName;\s*let methods = \{\};\s*for \(const module of this\.program\.modules\) \{\s*for \(const func of module\.functions\) \{\s*if \(func\.hasMetadata\(\)\) \{\s*let className = func\.metadata\.fields\['class'\];\s*if \(\(\(\(\(className != null\) && className\.hasStringValue\(\)\) && \(className\.stringValue === typeName\)\) && func\.hasBody\(\)\)\) \{\s*methods\[func\.name\] = \(async \(input\) => \{\s*return this\._callFunction\(module\.name, func, input\);\s*\}\);\s*\}\s*\}\s*\}\s*\}\s*return methods;\s*\}/,
      `_resolveTypeMethods(typeName: any): any {
    const input = typeName;
    let methods = {};
    for (const module of this.program.modules) {
      for (const func of module.functions) {
        if (!func.hasBody()) continue;
        let matched = false;
        // Check metadata.fields['class'] (original path)
        if (func.hasMetadata()) {
          let className = func.metadata.fields ? func.metadata.fields['class'] : null;
          if (className != null && className.hasStringValue && className.hasStringValue() && className.stringValue === typeName) {
            matched = true;
          }
        }
        // Also match by function name prefix: "mod:Type.method" or "Type.method"
        if (!matched) {
          const fn = func.name;
          const dotIdx = fn.lastIndexOf('.');
          if (dotIdx >= 0) {
            const prefix = fn.substring(0, dotIdx);
            const barePrefix = String(prefix).indexOf(':') >= 0 ? String(prefix).substring(String(prefix).indexOf(':') + 1) : prefix;
            const bareTypeName = String(typeName).indexOf(':') >= 0 ? String(typeName).substring(String(typeName).indexOf(':') + 1) : String(typeName);
            if (prefix === typeName || barePrefix === bareTypeName || prefix === bareTypeName || barePrefix === typeName) {
              matched = true;
            }
          }
        }
        if (matched) {
          // Store the method callable function under the full name
          methods[func.name] = (async (input) => {
            return this._callFunction(module.name, func, input);
          });
          // Store short name entries for method dispatch
          const __lastDot = func.name.lastIndexOf('.');
          if (__lastDot >= 0) {
            const __shortName = func.name.substring(__lastDot + 1);
            // Check if this is a getter or setter
            let __isGetter = false, __isSetter = false;
            if (func.hasMetadata()) {
              const __igf = func.metadata.fields ? func.metadata.fields['is_getter'] : null;
              const __isf = func.metadata.fields ? func.metadata.fields['is_setter'] : null;
              if (__igf && (__igf.boolValue === true || __igf === true)) __isGetter = true;
              if (__isf && (__isf.boolValue === true || __isf === true)) __isSetter = true;
            }
            // Don't overwrite existing entries (first definition wins for overloaded names)
            if (!methods[__shortName] || (!__isGetter && !__isSetter)) {
              methods[__shortName] = (async (input) => {
                return this._callFunction(module.name, func, input);
              });
              // Mark the entry type for dispatch
              methods[__shortName].__isGetter = __isGetter;
              methods[__shortName].__isSetter = __isSetter;
            }
            // Also store dispatch info
            methods['__dispatch_' + __shortName] = { module: module.name, func: func };
          }
        }
      }
    }
    return methods;
  }`,
    );

    // ── Post-processing: fix _stdPrint to call toString on OOP objects ──
    // Replace the entire _stdPrint method to handle OOP toString dispatch.
    body = body.replace(
      /_stdPrint\(input: any\): any \{\s*if \(\(typeof input === 'object' && input !== null && !Array\.isArray\(input\)\)\) \{\s*let message = input\['message'\];\s*if \(\(message != null\)\) \{\s*this\.stdout\(__ball_to_string\(message\)\);\s*return null;\s*\}\s*\}\s*this\.stdout\(__ball_to_string\(input\)\);\s*\}/,
      `async _stdPrint(input: any): Promise<any> {
    const __resolveToString = async (v: any): Promise<any> => {
      if (typeof v === 'object' && v !== null && !Array.isArray(v) && v['__methods__']) {
        // Try the toString method
        const __tsM = v['__methods__']['toString'];
        if (typeof __tsM === 'function') {
          try { return await __tsM({ 'self': v }); } catch(e) {}
        }
        // Try dispatch entry
        const __tsD = v['__methods__']['__dispatch_toString'];
        if (__tsD && typeof __tsD === 'object' && __tsD.func) {
          try { return await this._callFunction(__tsD.module, __tsD.func, { 'self': v }); } catch(e) {}
        }
      }
      return v;
    };
    if ((typeof input === 'object' && input !== null && !Array.isArray(input))) {
      let message = input['message'];
      if ((message != null)) {
        message = await __resolveToString(message);
        this.stdout(__ball_to_string(message));
        return null;
      }
    }
    input = await __resolveToString(input);
    this.stdout(__ball_to_string(input));
  }`,
    );

    // ── Post-processing: fix _evalLambda positional param binding ──────
    // The compiled engine's _evalLambda binds input entries by key name,
    // but when the caller passes positional args (arg0, arg1, ...), the
    // lambda's named params don't get bound. Fix: after binding entries,
    // also bind paramNames[i] = input['arg' + i] for positional args.
    body = body.replace(
      /let paramNames = \(func\.hasMetadata\(\) \? this\._extractParams\(func\.metadata\) : \[\]\);\s*if \(\(\(paramNames\.length === 1\) && !\(\(typeof input === 'object' && input !== null && !Array\.isArray\(input\)\)\)\)\) \{\s*lambdaScope\.bind\(paramNames\.first, input\);\s*\}\s*if \(\(typeof input === 'object' && input !== null && !Array\.isArray\(input\)\)\) \{\s*for \(const entry of input\.entries\) \{\s*if \(\(entry\.key !== '__type__'\)\) \{\s*lambdaScope\.bind\(entry\.key, entry\.value\);\s*\}\s*\}\s*\}/,
      `let paramNames = (func.hasMetadata() ? this._extractParams(func.metadata) : []);
      if (((paramNames.length === 1) && !((typeof input === 'object' && input !== null && !Array.isArray(input))))) {
        lambdaScope.bind(paramNames.first, input);
      }
      if ((typeof input === 'object' && input !== null && !Array.isArray(input))) {
        for (const entry of input.entries) {
          if ((entry.key !== '__type__')) {
            lambdaScope.bind(entry.key, entry.value);
          }
        }
        // Positional arg binding: bind paramNames[i] = input['arg' + i]
        for (let __pi = 0; __pi < paramNames.length; __pi++) {
          const __argKey = 'arg' + __pi;
          if (input.containsKey(__argKey) && !lambdaScope.has(paramNames[__pi])) {
            lambdaScope.bind(paramNames[__pi], input[__argKey]);
          }
        }
      }`,
    );

    // ── Post-processing: fix _evalLazySwitch to support fall-through ───
    // Replace the entire _evalLazySwitch method body with a fixed version
    // that supports fall-through, pattern fields, and quote stripping.
    body = body.replace(
      /async _evalLazySwitch\(call: any, scope: any\): Promise<any> \{[\s\S]*?if \(defaultBody != null && defaultBody !== __no_init__\) \{\s*return this\._evalExpression\(defaultBody, scope\);\s*\}\s*\}/,
      `async _evalLazySwitch(call: any, scope: any): Promise<any> {
    let fields = this._lazyFields(call);
    let subject = fields['subject'];
    let cases = fields['cases'];
    if (((subject == null) || (cases == null))) {
      return null;
    }
    let subjectVal = await this._evalExpression(subject, scope);
    if (((cases.whichExpr() !== Expression_Expr.messageCreation) && (cases.whichExpr() !== Expression_Expr.literal || cases.literal.whichValue() !== Literal_Value.listValue))) {
      return null;
    }
    let caseElements = (cases.whichExpr() === Expression_Expr.literal && cases.literal.listValue) ? cases.literal.listValue.elements : [];
    let defaultBody = __no_init__;
    let __matched = false;
    for (const caseExpr of caseElements) {
      if ((caseExpr.whichExpr() !== Expression_Expr.messageCreation)) {
        continue;
      }
      let cf: any = {};
      for (const f of caseExpr.messageCreation.fields) {
        cf[f.name] = f.value;
      }
      let isDefault = cf['is_default'];
      if (isDefault != null) {
        const __isDef = isDefault.whichExpr && isDefault.whichExpr() === Expression_Expr.literal && isDefault.literal.boolValue;
        if (__isDef) {
          defaultBody = cf['body'];
          if (__matched && cf['body'] != null) {
            return this._evalExpression(cf['body'], scope);
          }
          continue;
        }
      }
      let value = cf['value'] ?? cf['pattern'];
      // Handle pattern_expr (e.g., ConstPattern with enum values)
      let __patternExpr = cf['pattern_expr'];
      if (!__matched && __patternExpr != null) {
        let __pe = await this._evalExpression(__patternExpr, scope);
        let __pv = (__pe && typeof __pe === 'object' && !Array.isArray(__pe) && 'value' in __pe) ? __pe['value'] : __pe;
        // Compare enum-style: by identity, by index, or by name
        if (__pv === subjectVal) { __matched = true; }
        else if (typeof __pv === 'object' && typeof subjectVal === 'object' && __pv !== null && subjectVal !== null) {
          if (__pv['name'] === subjectVal['name'] && __pv['__type__'] === subjectVal['__type__']) { __matched = true; }
          else if (__pv['index'] != null && __pv['index'] === subjectVal['index'] && __pv['__type__'] === subjectVal['__type__']) { __matched = true; }
        }
        if (__matched) {
          let body = cf['body'];
          if (body != null) {
            const __isEmptyBlock2 = body.block && (!body.block.statements || body.block.statements.length === 0) && !body.block.result && !body.block.hasResult?.();
            if (!__isEmptyBlock2) {
              const __switchResult2 = await this._evalExpression(body, scope);
              if (__switchResult2 instanceof _FlowSignal && __switchResult2.kind === 'break' && (__switchResult2.label == null || __switchResult2.label === '')) return null;
              return __switchResult2;
            }
          }
          // Fall through if no body
          value = null; // skip the value check below
        }
      }
      if ((value != null)) {
        let caseVal = await this._evalExpression(value, scope);
        // Strip surrounding quotes from pattern strings (encoder artifact)
        let __cv: any = caseVal;
        if (typeof __cv === 'string' && __cv.length >= 2) {
          if ((__cv.startsWith("'") && __cv.endsWith("'")) || (__cv.startsWith('"') && __cv.endsWith('"'))) {
            __cv = __cv.substring(1, __cv.length - 1);
          }
        }
        if (__matched || __cv == subjectVal || String(__cv) === String(subjectVal)) {
          __matched = true;
          let body = cf['body'];
          // Check if body is a non-empty block or a real expression
          if (body != null) {
            const __isEmptyBlock = body.block && (!body.block.statements || body.block.statements.length === 0) && !body.block.result && !body.block.hasResult?.();
            if (!__isEmptyBlock) {
              const __switchResult = await this._evalExpression(body, scope);
              // Consume unlabeled break (switch break, not loop break)
              if (__switchResult instanceof _FlowSignal && __switchResult.kind === 'break' && (__switchResult.label == null || __switchResult.label === '')) {
                return null;
              }
              return __switchResult;
            }
          }
          // No body or empty body = fall through to next case
        }
      }
    }
    if (defaultBody != null && defaultBody !== __no_init__) {
      const __defResult = await this._evalExpression(defaultBody, scope);
      if (__defResult instanceof _FlowSignal && __defResult.kind === 'break' && (__defResult.label == null || __defResult.label === '')) {
        return null;
      }
      return __defResult;
    }
  }`,
    );

    // ── Post-processing: fix typed catch for BallException ──────────────
    // The compiled engine throws BallException but the catch handler needs
    // to match typed catches against the exception's typeName, not just
    // the JS error type. Fix the catch dispatcher to check BallException.
    body = body.replace(
      /let __eType = \(e instanceof BallException\)/,
      `let __eType = (e && typeof e === 'object' && 'typeName' in e)`,
    );

    // ── Post-processing: fix _callFunction 'input' binding shadowing ──
    // Don't bind 'input' as a variable when the global scope already has
    // a top-level variable named 'input'. This prevents shadowing.
    body = body.replace(
      /if \(\(func\.inputType\.isNotEmpty && \(input != null\)\)\) \{\s*scope\.bind\('input', input\);\s*\}/,
      `if ((func.inputType.isNotEmpty && (input != null))) {
      // Only bind 'input' if it won't shadow a top-level variable named 'input'
      if (!this._globalScope.has('input') || func.name === this.program.entryFunction) {
        scope.bind('input', input);
      }
    }`,
    );

    // ── Post-processing: fix _callFunction to handle multi-param positional binding ──
    // When calling a function with positional args (arg0, arg1, ...),
    // bind them to the function's declared parameter names.
    body = body.replace(
      /let params = this\._extractParams\(func\.metadata\);\s*for \(const entry of input\.entries\) \{\s*scope\.bind\(entry\.key, entry\.value\);\s*\}/,
      `let params = this._extractParams(func.metadata);
      for (const entry of input.entries) {
        scope.bind(entry.key, entry.value);
      }
      // Also bind positional args to declared param names
      for (let __pi = 0; __pi < params.length; __pi++) {
        const __argKey = 'arg' + __pi;
        if (input.containsKey(__argKey) && !scope.has(params[__pi])) {
          scope.bind(params[__pi], input[__argKey]);
        }
      }`,
    );

    // ── Post-processing: fix throw to read __type__ (double underscore) ──
    // The compiled engine's throw handler reads val['__type'] (single underscore)
    // but the messageCreation sets val['__type__'] (double underscore).
    body = body.replace(
      /typeName = \(val\['__type'\] \?\? 'Exception'\);/,
      `typeName = (val['__type__'] ?? val['__type'] ?? 'Exception');
          // Strip module prefix for catch matching: "main:FormatException" -> "FormatException"
          const __typeColonIdx = typeName.indexOf(':');
          if (__typeColonIdx >= 0) typeName = typeName.substring(__typeColonIdx + 1);`,
    );

    // ── Post-processing: fix typed catch matching for user-defined types ──
    // When the thrown value is a user-defined type like "FormatException" or
    // "RangeError" (created via messageCreation), match by __type__ field.
    // Also need to check BallException.value.__type__ for nested type info.
    body = body.replace(
      /if \(e instanceof BallException\) \{\s*matches = e\['typeName'\] === catchType;\s*\}/,
      `if (e instanceof BallException) {
              matches = e['typeName'] === catchType;
              // Also check if the value inside has a matching type
              if (!matches && typeof e['value'] === 'object' && e['value'] !== null) {
                let __valType = e['value']['__type__'] ?? e['value']['__type'] ?? '';
                const __vtci = __valType.indexOf(':');
                if (__vtci >= 0) __valType = __valType.substring(__vtci + 1);
                matches = __valType === catchType;
              }
            }`,
    );

    // ── Post-processing: fix catch variable binding for BallException ──
    // Bind the exception value as-is. If it's a typed exception object,
    // add a 'message' field from arg0 for Dart compatibility.
    body = body.replace(
      /catchScope\.bind\(variable, \(e instanceof BallException\) \? e\['value'\] : \(e instanceof Error \? e\.message : e\)\);/,
      `{
              let __catchVal = e;
              if (e instanceof BallException) {
                __catchVal = e['value'];
                // Add 'message' field from arg0 if it's a typed exception object
                if (typeof __catchVal === 'object' && __catchVal !== null && !('message' in __catchVal) && 'arg0' in __catchVal) {
                  __catchVal['message'] = __catchVal['arg0'];
                }
              } else if (e instanceof Error) {
                __catchVal = e.message;
              }
              catchScope.bind(variable, __catchVal);
            }`,
    );

    // ── Post-processing: fix list_map/list_filter/etc callback field name ──
    // The compiled engine's built-in list_map uses m['callback'] but the Ball
    // programs pass the callback as 'value' or 'function'. Fix to check all.
    // Fix callback resolution: some Ball programs pass the callback as
    // 'value' or 'function' instead of 'callback'. But only apply this
    // to the list_filter and list_map functions (not all uses of cb).
    body = body.replace(
      /let cb = m\['callback'\];\s*let result = \[\];/g,
      `let cb = m['callback'] ?? m['function'] ?? m['value'];
        let result = [];`,
    );

    // ── Post-processing: fix in-place mutation detection in _evalAssign ──
    // The Dart engine detects patterns like assign(target: var, value: list_remove_at(list: var, ...))
    // where the list and target reference the same variable. In this case, the mutation
    // already happened in-place, so we return the removed element without overwriting.
    body = body.replace(
      /let val = await this\._evalExpression\(value, scope\);\s*if \(\(target\.whichExpr\(\) === Expression_Expr\.reference\)\) \{/,
      `// Detect in-place mutation pattern
    if (target.whichExpr() === Expression_Expr.reference && value.whichExpr() === Expression_Expr.call) {
      const __valFn = value.call.function;
      const __valMod = value.call.module;
      if ((__valFn === 'list_remove_at' || __valFn === 'list_pop' || __valFn === 'list_remove_last') && (__valMod === 'std' || __valMod === 'std_collections' || __valMod === '')) {
        const __valFields = this._lazyFields(value.call);
        const __listExpr = __valFields['list'];
        if (__listExpr != null && __listExpr.whichExpr() === Expression_Expr.reference && __listExpr.reference.name === target.reference.name) {
          // In-place mutation: evaluate the call (mutates the list), return the result
          // but don't overwrite the variable
          const __mutResult = await this._evalExpression(value, scope);
          return __mutResult;
        }
      }
    }
    let val = await this._evalExpression(value, scope);
    if ((target.whichExpr() === Expression_Expr.reference)) {`,
    );

    // ── Post-processing: fix empty Set → Map conversion for let statements ──
    // The Dart encoder uses set_create for empty map literals. The Dart engine
    // converts empty Sets to Maps when the let type says 'Map'. Add the same
    // logic to the compiled engine's _evalStatement.
    body = body.replace(
      /let value = await this\._evalExpression\(stmt\.let\.value, scope\);\s*if \(\(value instanceof _FlowSignal\)\) \{\s*return value;\s*\}\s*scope\.bind\(stmt\.let\.name, value\);/,
      `let value = await this._evalExpression(stmt.let.value, scope);
        if ((value instanceof _FlowSignal)) {
          return value;
        }
        // Convert empty Set to Map if type metadata says Map
        if (stmt.let.hasMetadata && stmt.let.hasMetadata()) {
          const __letType = stmt.let.metadata.fields ? stmt.let.metadata.fields['type'] : null;
          const __lt = __letType ? (__letType.stringValue ?? __letType) : null;
          if (typeof __lt === 'string' && __lt.startsWith('Map')) {
            if (value instanceof Set && value.size === 0) value = {};
            if (value === null || value === undefined) value = {};
          }
          // Also convert empty list/set to empty map for var declarations
          if (typeof __lt === 'string' && __lt.startsWith('Map') && Array.isArray(value) && value.length === 0) {
            value = {};
          }
        }
        scope.bind(stmt.let.name, value);`,
    );

    // ── Post-processing: fix .isNotEmpty / .isEmpty on plain objects ───
    // The compiled Dart engine uses `.isNotEmpty` on plain objects returned
    // by _resolveTypeMethods and _resolveTypeMethodsWithInheritance. Plain JS
    // objects don't have isNotEmpty/isEmpty. Fix the specific occurrences.
    body = body.replace(
      /if \(methods\.isNotEmpty\) \{\s*fields\['__methods__'\]/,
      `if (Object.keys(methods).length > 0) {\n          fields['__methods__']`,
    );
    body = body.replace(
      /if \(parentMethods\.isNotEmpty\) \{\s*superFields\['__methods__'\]/,
      `if (Object.keys(parentMethods).length > 0) {\n        superFields['__methods__']`,
    );

    // ── Post-processing: fix labeled loops to pass label to inner loop ──
    // The compiled engine's _evalLabeled just evaluates the body and catches
    // matching signals. It needs to delegate to a labeled loop evaluator that
    // passes the label to the inner for/while loop for proper continue handling.
    body = body.replace(
      /async _evalLabeled\(call: any, scope: any\): Promise<any> \{\s*let fields = this\._lazyFields\(call\);\s*let label = this\._stringFieldVal\(fields, 'label'\);\s*let body = fields\['body'\];\s*if \(\(body == null\)\) \{\s*return null;\s*\}\s*let result = await this\._evalExpression\(body, scope\);\s*if \(\(\(\(result instanceof _FlowSignal\) && \(\(result\.kind === 'break'\) \|\| \(result\.kind === 'continue'\)\)\) && \(result\.label === label\)\)\) \{\s*return null;\s*\}\s*return result;\s*\}/,
      `async _evalLabeled(call: any, scope: any): Promise<any> {
    let fields = this._lazyFields(call);
    let label = this._stringFieldVal(fields, 'label');
    let body = fields['body'];
    if ((body == null)) {
      return null;
    }
    // If the body contains a loop, pass the label to it for proper
    // labeled break/continue handling (running update on continue, etc.)
    if (label != null && label.length > 0) {
      const loopCall = this.__extractLoopFromBody(body);
      if (loopCall != null) {
        const result = await this.__evalLabeledFor(loopCall, label, scope);
        if (result instanceof _FlowSignal && (result.kind === 'break' || result.kind === 'continue') && result.label === label) {
          return null;
        }
        return result;
      }
    }
    let result = await this._evalExpression(body, scope);
    if ((((result instanceof _FlowSignal) && ((result.kind === 'break') || (result.kind === 'continue'))) && (result.label === label))) {
      return null;
    }
    return result;
  }

  __extractLoopFromBody(expr: any): any {
    if (expr.whichExpr() === Expression_Expr.call) {
      const fn = expr.call.function;
      if (fn === 'for' || fn === 'while' || fn === 'for_in' || fn === 'do_while') return expr.call;
    }
    if (expr.whichExpr() === Expression_Expr.block && expr.block.statements.length === 1) {
      const stmt = expr.block.statements[0];
      if (stmt.whichStmt() === Statement_Stmt.expression && stmt.expression.whichExpr() === Expression_Expr.call) {
        const fn = stmt.expression.call.function;
        if (fn === 'for' || fn === 'while' || fn === 'for_in' || fn === 'do_while') return stmt.expression.call;
      }
    }
    return null;
  }

  async __evalLabeledFor(loopCall: any, label: any, scope: any): Promise<any> {
    const fn = loopCall.function;
    if (fn === 'for') return this.__evalLabeledForLoop(loopCall, label, scope);
    if (fn === 'for_in') return this.__evalLabeledForIn(loopCall, label, scope);
    if (fn === 'while') return this.__evalLabeledWhile(loopCall, label, scope);
    if (fn === 'do_while') return this.__evalLabeledDoWhile(loopCall, label, scope);
    return this._evalExpression({call: loopCall}, scope);
  }

  async __evalLabeledForLoop(call: any, label: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const initExpr = fields['init'];
    const condition = fields['condition'];
    const update = fields['update'];
    const body = fields['body'];
    const forScope = scope.child();
    if (initExpr != null) {
      if (initExpr.whichExpr() === Expression_Expr.block) {
        for (const stmt of initExpr.block.statements) {
          await this._evalStatement(stmt, forScope);
        }
      } else if (initExpr.whichExpr() === Expression_Expr.literal && initExpr.literal.hasStringValue()) {
        const s = initExpr.literal.stringValue;
        const match = new RegExp('(?:var|final|int|double|String)\\\\s+(\\\\w+)\\\\s*=\\\\s*(.+)').firstMatch(s);
        if (match != null) {
          const varName = match.group(1);
          const rawVal = match.group(2).trim();
          const parsed = int.tryParse(rawVal) ?? double.tryParse(rawVal) ?? (rawVal === 'true' ? true : rawVal === 'false' ? false : rawVal);
          forScope.bind(varName, parsed);
        }
      } else {
        await this._evalExpression(initExpr, forScope);
      }
    }
    while (true) {
      if (condition != null) {
        const condVal = await this._evalExpression(condition, forScope);
        if (!this._toBool(condVal)) break;
      }
      if (body != null) {
        const result = await this._evalExpression(body, forScope);
        if (result instanceof _FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label === label) {
            if (result.kind === 'break') break;
            if (result.kind === 'continue') {
              if (update != null) await this._evalExpression(update, forScope);
              continue;
            }
          }
          if (result.label != null && result.label.length > 0) return result;
          if (result.kind === 'break') break;
          // unlabeled continue: fall through to update
        }
      }
      if (update != null) await this._evalExpression(update, forScope);
    }
    return null;
  }

  async __evalLabeledForIn(call: any, label: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const variable = this._stringFieldVal(fields, 'variable') ?? 'item';
    const iterable = fields['iterable'];
    const body = fields['body'];
    if (iterable == null || body == null) return null;
    let iterVal = await this._evalExpression(iterable, scope);
    if (typeof iterVal === 'string') iterVal = iterVal.split('');
    else if (typeof iterVal === 'object' && iterVal !== null && !Array.isArray(iterVal)) {
      if (iterVal instanceof Map) iterVal = [...iterVal.entries()].map(([k, v]: any) => ({key: k, value: v}));
      else iterVal = Object.entries(iterVal).filter(([k]: any) => !k.startsWith('__')).map(([k, v]: any) => ({key: k, value: v}));
    }
    if (!Array.isArray(iterVal)) iterVal = [];
    for (const item of iterVal) {
      const loopScope = scope.child();
      loopScope.bind(variable, item);
      const result = await this._evalExpression(body, loopScope);
      if (result instanceof _FlowSignal) {
        if (result.kind === 'return') return result;
        if (result.label === label) {
          if (result.kind === 'break') break;
          if (result.kind === 'continue') continue;
        }
        if (result.label != null && result.label.length > 0) return result;
        if (result.kind === 'break') break;
      }
    }
    return null;
  }

  async __evalLabeledWhile(call: any, label: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const condition = fields['condition'];
    const body = fields['body'];
    while (true) {
      if (condition != null) {
        const condVal = await this._evalExpression(condition, scope);
        if (!this._toBool(condVal)) break;
      }
      if (body != null) {
        const result = await this._evalExpression(body, scope);
        if (result instanceof _FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label === label) {
            if (result.kind === 'break') break;
            if (result.kind === 'continue') continue;
          }
          if (result.label != null && result.label.length > 0) return result;
          if (result.kind === 'break') break;
        }
      }
    }
    return null;
  }

  async __evalLabeledDoWhile(call: any, label: any, scope: any): Promise<any> {
    const fields = this._lazyFields(call);
    const condition = fields['condition'];
    const body = fields['body'];
    do {
      if (body != null) {
        const result = await this._evalExpression(body, scope);
        if (result instanceof _FlowSignal) {
          if (result.kind === 'return') return result;
          if (result.label === label) {
            if (result.kind === 'break') break;
            if (result.kind === 'continue') continue;
          }
          if (result.label != null && result.label.length > 0) return result;
          if (result.kind === 'break') break;
        }
      }
      if (condition != null) {
        const condVal = await this._evalExpression(condition, scope);
        if (!this._toBool(condVal)) break;
      }
    } while (true);
    return null;
  }`,
    );

    // ── Post-processing: fix _evalLazyTry for typed catch ──────────────
    // The compiled engine's catch type matching fails for standard exception
    // types. Enhance the matching logic.
    body = body.replace(
      /if \(\(\(catchType != null\) && catchType\.isNotEmpty\)\)/,
      `if (catchType != null && (typeof catchType === 'string' ? catchType.length > 0 : catchType.isNotEmpty))`,
    );

    return includePreamble ? TS_RUNTIME_PREAMBLE + "\n" + body : body;
  }

  // ───────────────────────── Declarations ────────────────────────────

  private emitFreeFunction(
    sf: ReturnType<Project["createSourceFile"]>,
    fn: FunctionDef,
    forceName?: string,
  ): void {
    const params = extractParams(fn);
    const name = forceName ?? sanitize(fn.name);
    const body = this.captureInto(() => {
      if (params.length === 1 && params[0] !== "input") {
        this.writeln(`const input = ${sanitize(params[0])};`);
      }
      if (fn.body) this.emitStatementOrExpression(fn.body, true);
    });
    const isAsync = functionIsAsync(fn);
    sf.addFunction({
      kind: StructureKind.Function,
      name,
      isAsync,
      parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
      returnType: isAsync ? "Promise<any>" : "any",
      statements: body,
    });
  }

  private emitClass(
    sf: ReturnType<Project["createSourceFile"]>,
    td: TypeDefinition,
    members: FunctionDef[],
  ): void {
    const meta: Struct = td.metadata ?? {};
    const tsName = classTsName(td.name);

    // Fields: prefer metadata.fields (richer) with descriptor fallback.
    const fieldSpecs = Array.isArray(meta["fields"])
      ? (meta["fields"] as unknown[])
      : [];
    const properties: Array<{
      name: string;
      type: string;
      rawDartType: string;
      isStatic: boolean;
      isReadonly: boolean;
      dartInitializer?: string;
    }> = [];
    const fieldNames = new Set<string>();
    for (const raw of fieldSpecs) {
      if (raw == null || typeof raw !== "object") continue;
      const r = raw as Record<string, unknown>;
      const fname = typeof r.name === "string" ? r.name : undefined;
      if (!fname) continue;
      fieldNames.add(fname);
      properties.push({
        name: fname,
        type: typeof r.type === "string" ? this.dartTypeToTs(r.type) : "any",
        rawDartType: typeof r.type === "string" ? r.type : "",
        isStatic: r.is_static === true,
        isReadonly: r.is_final === true,
        dartInitializer: typeof r.initializer === "string" ? r.initializer : undefined,
      });
    }
    if (properties.length === 0 && td.descriptor?.field) {
      for (const f of td.descriptor.field) {
        fieldNames.add(f.name);
        properties.push({ name: f.name, type: "any", rawDartType: "", isStatic: false, isReadonly: false });
      }
    }

    // Method-name set for `this.foo()` routing inside bodies.
    // Exclude static fields — they're emitted as module-level consts
    // and referenced WITHOUT `this.`.
    const methodNames = new Set<string>();
    const staticFieldNames = new Set<string>();
    for (const fn of members) {
      const mMeta: Struct = fn.metadata ?? {};
      if ((mMeta as any).kind === "static_field") {
        staticFieldNames.add(memberShortName(fn.name));
      } else {
        methodNames.add(memberShortName(fn.name));
      }
    }
    const savedClassMethods = this.currentClassMethodNames;
    const deferredStaticFields: string[] = [];
    this.currentClassMethodNames = methodNames;

    const hasExtends = typeof meta["superclass"] === "string";

    const ctors: Array<{ parameters: Array<{ name: string; type: string }>; statements: string }> = [];
    const methods: Array<{
      name: string;
      isAsync: boolean;
      isStatic: boolean;
      parameters: Array<{ name: string; type: string }>;
      returnType: string;
      statements: string;
    }> = [];
    const getters: Array<{ name: string; isStatic: boolean; returnType: string; statements: string }> = [];
    const setters: Array<{
      name: string;
      isStatic: boolean;
      parameters: Array<{ name: string; type: string }>;
      statements: string;
    }> = [];

    for (const fn of members) {
      const mMeta: Struct = fn.metadata ?? {};
      const kind = typeof mMeta["kind"] === "string" ? mMeta["kind"] : "method";
      if (kind === "constructor") {
        // Named ctors become static factory methods; default `.new`
        // becomes the real ctor.
        const lastDot = fn.name.lastIndexOf(".");
        const rawShort = lastDot < 0 ? fn.name : fn.name.slice(lastDot + 1);
        if (rawShort === "new") {
          ctors.push(this.buildCtor(fn, mMeta, fieldNames, hasExtends));
        } else {
          methods.push(
            this.buildMethod(fn, { ...mMeta, is_static: true }, fieldNames),
          );
        }
      } else if (mMeta["is_getter"] === true) {
        getters.push(this.buildGetter(fn, mMeta, fieldNames));
      } else if (mMeta["is_setter"] === true) {
        setters.push(this.buildSetter(fn, mMeta, fieldNames));
      } else if (kind === "static_field") {
        // Static field → module-level const emitted BEFORE the class
        // so it's accessible as a bare name inside instance methods
        // (matching Dart's behavior where static fields are visible
        // without qualification). We capture the initializer body
        // and emit it above the class via a deferred statement.
        const sfName = memberShortName(fn.name);
        const initBody = fn.body ? this.expr(fn.body) : "undefined";
        deferredStaticFields.push(`const ${sfName} = ${initBody};`);
      } else {
        methods.push(this.buildMethod(fn, mMeta, fieldNames));
      }
    }

    this.currentClassMethodNames = savedClassMethods;

    // Inheritance.
    const superName =
      typeof meta["superclass"] === "string" ? meta["superclass"] : undefined;
    const interfaces = Array.isArray(meta["interfaces"])
      ? (meta["interfaces"] as unknown[])
          .filter((i): i is string => typeof i === "string")
      : undefined;
    const tsInterfaces = interfaces
      ?.filter((i) => i !== "Exception")
      .map((i) => this.dartTypeToTs(i));

    // Static fields are emitted as module-level constants before the
    // class so they're accessible without qualification.
    for (const stmt of deferredStaticFields) {
      sf.addStatements(stmt);
    }

    sf.addClass({
      name: tsName,
      isExported: true,
      isAbstract: meta["is_abstract"] === true,
      extends: superName ? this.dartTypeToTs(superName) : undefined,
      implements: tsInterfaces && tsInterfaces.length > 0 ? tsInterfaces : undefined,
      properties: properties.map((p) => ({
        name: p.name,
        type: p.type,
        isStatic: p.isStatic,
        isReadonly: p.isReadonly,
        initializer: dartInitializerToTs(p.dartInitializer, p.type, p.rawDartType),
      })),
      ctors,
      methods,
      getAccessors: getters,
      setAccessors: setters,
    });
  }

  private buildCtor(
    fn: FunctionDef,
    meta: Struct,
    classFields: Set<string>,
    hasExtends: boolean,
  ): { parameters: Array<{ name: string; type: string }>; statements: string } {
    const rawParams = extractCtorParams(meta);
    // Dart constructors may mix positional + named params. When named
    // params exist AND there are also positional params, callers may
    // pass named params as a trailing object `{label: x, value: y}`.
    //
    // Emit ALL params as positional but add a prologue that tries to
    // destructure the LAST arg as a named-params object when there's
    // a mix. This handles both calling conventions:
    //   new Foo('a', {label: 'b'})  → named destructured
    //   new Foo('a', 'b', 'c')     → positional passthrough
    const positionalParams = rawParams.filter((p) => !p.isNamed);
    const namedParams = rawParams.filter((p) => p.isNamed);
    const parameters = rawParams.map((p) => ({ name: sanitize(p.name), type: "any" }));
    const prologueParts: string[] = [];
    if (hasExtends) prologueParts.push("super();");
    // If there are named params AND the last positional+1 arg is an
    // object, destructure named params from it (handles the encoder's
    // MessageCreation calling convention where named args are packed).
    if (positionalParams.length > 0 && namedParams.length > 0) {
      // First named param slot might contain a {named args} object.
      // Detect and destructure if so.
      const firstNamedName = sanitize(namedParams[0].name);
      prologueParts.push(
        `if (typeof ${firstNamedName} === 'object' && ${firstNamedName} !== null && !Array.isArray(${firstNamedName}) && (` +
        namedParams.map((p) => `'${p.name}' in ${firstNamedName}`).join(" || ") +
        `)) { let __n = ${firstNamedName}; ` +
        namedParams.map((p) => `${sanitize(p.name)} = __n.${p.name}`).join("; ") +
        `; }`
      );
    }
    for (const p of rawParams) {
      if (p.isThis || classFields.has(p.name)) {
        prologueParts.push(`this.${p.name} = ${sanitize(p.name)};`);
      }
    }
    const prologue = prologueParts.join("\n");
    const captured = this.withMethodContext(
      new Set(rawParams.map((p) => p.name)),
      classFields,
      () =>
        this.captureInto(() => {
          if (fn.body) this.emitStatementOrExpression(fn.body, false);
        }),
    );
    const body = prologue === "" ? captured : captured === "" ? prologue : `${prologue}\n${captured}`;
    return { parameters, statements: body };
  }

  private buildMethod(fn: FunctionDef, meta: Struct, classFields: Set<string>) {
    const params = extractParams(fn);
    const body = this.withMethodContext(
      new Set(params),
      classFields,
      () =>
        this.captureInto(() => {
          if (params.length === 1 && params[0] !== "input") {
            this.writeln(`const input = ${sanitize(params[0])};`);
          }
          if (fn.body) this.emitStatementOrExpression(fn.body, true);
        }),
    );
    const isAsync = functionIsAsync(fn);
    return {
      name: memberShortName(fn.name),
      isAsync,
      isStatic: meta["is_static"] === true,
      parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
      returnType: isAsync ? "Promise<any>" : "any",
      statements: body,
    };
  }

  private buildGetter(fn: FunctionDef, meta: Struct, classFields: Set<string>) {
    const body = this.withMethodContext(
      new Set<string>(),
      classFields,
      () =>
        this.captureInto(() => {
          if (fn.body) this.emitStatementOrExpression(fn.body, true);
        }),
    );
    return {
      name: memberShortName(fn.name),
      isStatic: meta["is_static"] === true,
      returnType: "any",
      statements: body,
    };
  }

  private buildSetter(fn: FunctionDef, meta: Struct, classFields: Set<string>) {
    const params = extractParams(fn);
    const body = this.withMethodContext(
      new Set(params),
      classFields,
      () =>
        this.captureInto(() => {
          if (fn.body) this.emitStatementOrExpression(fn.body, false);
        }),
    );
    return {
      name: memberShortName(fn.name),
      isStatic: meta["is_static"] === true,
      parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
      statements: body,
    };
  }

  // ───────────────────────── Buffer helpers ──────────────────────────

  private captureInto(body: () => void): string {
    const savedOut = this.out;
    const savedDepth = this.depth;
    this.out = "";
    this.depth = 0;
    try {
      body();
      return this.out.replace(/\s+$/, "");
    } finally {
      this.out = savedOut;
      this.depth = savedDepth;
    }
  }

  private writeln(s: string): void {
    this.out += "  ".repeat(this.depth) + s + "\n";
  }

  private get ind(): string {
    return "  ".repeat(this.depth);
  }

  private withMethodContext<T>(
    params: Set<string>,
    fields: Set<string>,
    fn: () => T,
  ): T {
    const sParams = this.currentMethodParams;
    const sFields = this.currentClassFields;
    this.currentMethodParams = params;
    this.currentClassFields = fields;
    try {
      return fn();
    } finally {
      this.currentMethodParams = sParams;
      this.currentClassFields = sFields;
    }
  }

  // ───────────────────────── Statements ──────────────────────────────

  private emitStatementOrExpression(
    expr: Expression,
    isFunctionBody: boolean,
  ): void {
    // Bare expression used as a function body → emit `return`.
    if (isFunctionBody && !expr.block) {
      this.writeln(`return ${this.expr(expr)};`);
      return;
    }
    if (expr.block) {
      this.emitBlock(expr.block, isFunctionBody);
      return;
    }
    if (expr.call && this.isControlFlow(expr.call)) {
      this.emitControlFlowStatement(expr.call);
      return;
    }
    this.writeln(`${this.expr(expr)};`);
  }

  private emitBlock(block: NonNullable<Expression["block"]>, isFunctionBody: boolean): void {
    for (const s of block.statements ?? []) this.emitStatement(s);
    if (block.result !== undefined && isFunctionBody) {
      const r = block.result;
      // notSet literal → skip.
      const isNotSet =
        r.literal !== undefined &&
        r.literal.intValue === undefined &&
        r.literal.doubleValue === undefined &&
        r.literal.stringValue === undefined &&
        r.literal.boolValue === undefined &&
        r.literal.listValue === undefined &&
        r.literal.bytesValue === undefined;
      if (!isNotSet) this.writeln(`return ${this.expr(r)};`);
    } else if (block.result !== undefined) {
      this.writeln(`${this.expr(block.result)};`);
    }
  }

  private emitStatement(stmt: Statement): void {
    if (stmt.let) {
      const meta: Struct = stmt.let.metadata ?? {};
      const keyword = typeof meta["keyword"] === "string" ? meta["keyword"] : "final";
      // Use `let` for all declarations — we can't reliably determine
      // if a variable is ever reassigned without whole-method analysis,
      // and Dart's `final` guarantee doesn't help when the compiled
      // output re-assigns in patterns the encoder generates (e.g.
      // _tryOperatorOverride's `left = input['left']`).
      const kw = "let";
      const name = sanitize(stmt.let.name);
      if (stmt.let.value !== undefined) {
        this.writeln(`${kw} ${name} = ${this.expr(stmt.let.value)};`);
      } else {
        this.writeln(`${kw} ${name};`);
      }
      return;
    }
    if (stmt.expression) {
      const e = stmt.expression;
      if (e.call && this.isControlFlow(e.call)) {
        this.emitControlFlowStatement(e.call);
        return;
      }
      // Block-expression-as-statement with no result: hoist inner stmts.
      if (e.block && e.block.result === undefined) {
        for (const inner of e.block.statements ?? []) this.emitStatement(inner);
        return;
      }
      this.writeln(`${this.expr(e)};`);
    }
  }

  // ───────────────────────── Control flow ────────────────────────────

  private isControlFlow(call: FunctionCall): boolean {
    const kinds = new Set([
      "if", "for", "for_in", "for_each", "while", "do_while", "try",
      "return", "break", "continue", "labeled", "throw", "rethrow",
      "assign", "switch", "switch_expr",
    ]);
    if (!kinds.has(call.function)) return false;
    // Accept both explicit std module AND empty module (the encoder
    // sometimes omits the module for control-flow operations).
    return isStd(call.module) || !call.module;
  }

  private emitControlFlowStatement(call: FunctionCall): void {
    switch (call.function) {
      case "if":        this.emitIfStmt(call); break;
      case "for":       this.emitForStmt(call); break;
      case "for_in":    this.emitForInStmt(call); break;
      case "for_each":  this.emitForInStmt(call); break;
      case "while":     this.emitWhileStmt(call); break;
      case "do_while":  this.emitDoWhileStmt(call); break;
      case "try":       this.emitTryStmt(call); break;
      case "return": {
        const v = field(call, "value");
        this.writeln(v ? `return ${this.expr(v)};` : "return;");
        break;
      }
      case "break": {
        const label = stringField(call, "label");
        this.writeln(label ? `break ${label};` : "break;");
        break;
      }
      case "continue": {
        const label = stringField(call, "label");
        this.writeln(label ? `continue ${label};` : "continue;");
        break;
      }
      case "labeled": {
        const label = stringField(call, "label");
        this.writeln(`${label}:`);
        const body = field(call, "body");
        if (body) this.emitStatementOrExpression(body, false);
        break;
      }
      case "throw": {
        const v = field(call, "value");
        if (v) {
          const str = this.compileThrowValue(v) ?? this.expr(v);
          this.writeln(`throw ${str};`);
        } else {
          this.writeln("throw null;");
        }
        break;
      }
      case "rethrow":
        this.writeln("throw __ball_active_error;");
        break;
      case "assign":
        this.emitAssignStmt(call);
        break;
      case "switch":
      case "switch_expr": {
        // When a switch appears as a STATEMENT (not expression), emit
        // as an if/else chain so each case can `return` independently
        // without the ternary's default arm causing an early exit.
        const subjectExpr = field(call, "subject");
        const casesField = field(call, "cases");
        if (!subjectExpr || !casesField) {
          this.writeln("/* malformed switch */");
          break;
        }
        const subjectStr = this.expr(subjectExpr);
        this.writeln(`{ const __sw = ${subjectStr};`);
        this.depth++;
        const caseExprs = casesField.literal?.listValue?.elements ?? [];
        let defaultBody: Expression | undefined;
        let first = true;
        // Parse all cases, detecting fall-through (empty body = merge
        // with next case via ||).
        const parsedCases: Array<{ conds: string[]; body?: Expression }> = [];
        const pendingConds: string[] = [];
        for (const ce of caseExprs) {
          if (!ce.messageCreation) continue;
          let pattern: Expression | undefined;
          let body: Expression | undefined;
          for (const fd of ce.messageCreation.fields ?? []) {
            if (fd.name === "pattern") pattern = fd.value;
            if (fd.name === "body") body = fd.value;
          }
          if (!pattern) { defaultBody = body; continue; }
          const patText = patternLiteralText(pattern);
          const cond = patText !== undefined
            ? patternToTsCondition(patText, "__sw")
            : `((__sw) === ${this.expr(pattern)})`;
          if (cond === "true") { defaultBody = body; break; }
          // Empty body = fall-through: accumulate conditions.
          const isEmpty = body && body.block &&
            (body.block.statements ?? []).length === 0 &&
            body.block.result === undefined;
          if (!body || isEmpty) {
            pendingConds.push(cond);
            continue;
          }
          pendingConds.push(cond);
          parsedCases.push({ conds: [...pendingConds], body });
          pendingConds.length = 0;
        }
        for (const pc of parsedCases) {
          const combinedCond = pc.conds.join(" || ");
          const kw = first ? "if" : "else if";
          this.writeln(`${kw} (${combinedCond}) {`);
          this.depth++;
          this.emitStatementOrExpression(pc.body!, false);
          this.depth--;
          this.writeln("}");
          first = false;
        }
        if (defaultBody) {
          if (!first) {
            this.writeln("else {");
            this.depth++;
          }
          this.emitStatementOrExpression(defaultBody, false);
          if (!first) {
            this.depth--;
            this.writeln("}");
          }
        }
        this.depth--;
        this.writeln("}");
        break;
      }
    }
  }

  private emitIfStmt(call: FunctionCall): void {
    const cond = field(call, "condition");
    const then_ = field(call, "then");
    const else_ = field(call, "else");
    this.writeln(`if (${this.expr(cond!)}) {`);
    this.depth++;
    if (then_) this.emitStatementOrExpression(unwrapLambda(then_), false);
    this.depth--;
    if (else_) {
      this.writeln(`} else {`);
      this.depth++;
      this.emitStatementOrExpression(unwrapLambda(else_), false);
      this.depth--;
    }
    this.writeln(`}`);
  }

  private emitForStmt(call: FunctionCall): void {
    const init = field(call, "init");
    const cond = field(call, "condition");
    const update = field(call, "update");
    const body = field(call, "body");
    // The TS encoder emits `variable`/`start` instead of `init` for
    // `for (let i = 0; ...)` loops. Support both conventions.
    const variable = stringField(call, "variable");
    const start = field(call, "start");
    let initStr: string;
    if (variable && start) {
      initStr = `let ${variable} = ${this.expr(start)}`;
    } else if (init && init.literal?.stringValue !== undefined) {
      initStr = translateInitString(init.literal.stringValue);
    } else if (init && init.block) {
      // Block-based init: the encoder now emits LetBinding as a block.
      // Extract the let binding and compile as `let name = value`.
      const stmts = init.block.statements ?? [];
      const parts: string[] = [];
      for (const s of stmts) {
        if (s.let) {
          const name = sanitize(s.let.name);
          if (s.let.value) {
            parts.push(`${name} = ${this.expr(s.let.value)}`);
          } else {
            parts.push(name);
          }
        }
      }
      initStr = parts.length > 0 ? `let ${parts.join(", ")}` : "";
    } else if (init) {
      initStr = this.expr(init);
    } else {
      initStr = "";
    }
    const condStr = cond ? this.expr(unwrapLambda(cond)) : "";
    const updateStr = update ? this.expr(unwrapLambda(update)) : "";
    this.writeln(`for (${initStr}; ${condStr}; ${updateStr}) {`);
    this.depth++;
    if (body) this.emitStatementOrExpression(unwrapLambda(body), false);
    this.depth--;
    this.writeln(`}`);
  }

  private emitForInStmt(call: FunctionCall): void {
    const variable = stringField(call, "variable") ?? "item";
    const iterable = field(call, "iterable")!;
    const body = field(call, "body");
    this.writeln(`for (const ${variable} of ${this.expr(iterable)}) {`);
    this.depth++;
    if (body) this.emitStatementOrExpression(unwrapLambda(body), false);
    this.depth--;
    this.writeln(`}`);
  }

  private emitWhileStmt(call: FunctionCall): void {
    const cond = field(call, "condition");
    const body = field(call, "body");
    this.writeln(`while (${this.expr(unwrapLambda(cond!))}) {`);
    this.depth++;
    if (body) this.emitStatementOrExpression(unwrapLambda(body), false);
    this.depth--;
    this.writeln(`}`);
  }

  private emitDoWhileStmt(call: FunctionCall): void {
    const cond = field(call, "condition");
    const body = field(call, "body");
    this.writeln(`do {`);
    this.depth++;
    if (body) this.emitStatementOrExpression(unwrapLambda(body), false);
    this.depth--;
    this.writeln(`} while (${this.expr(unwrapLambda(cond!))});`);
  }

  private emitTryStmt(call: FunctionCall): void {
    const body = field(call, "body");
    const catches = field(call, "catches");
    // The TS encoder emits a single `catch` field (MessageCreation)
    // instead of a `catches` list. Handle both formats.
    const singleCatch = field(call, "catch");
    const fin = field(call, "finally");

    this.writeln(`try {`);
    this.depth++;
    if (body) this.emitStatementOrExpression(unwrapLambda(body), false);
    this.depth--;

    // Single catch clause from the TS encoder.
    if (singleCatch && singleCatch.messageCreation) {
      const cf = fieldMap(singleCatch.messageCreation.fields ?? []);
      const variable = stringFieldVal(cf, "variable") ?? "e";
      const catchBody = cf.get("body");
      this.writeln(`} catch (${variable}) {`);
      this.depth++;
      if (catchBody) this.emitStatementOrExpression(unwrapLambda(catchBody), false);
      this.depth--;
      if (fin) {
        this.writeln(`} finally {`);
        this.depth++;
        this.emitStatementOrExpression(unwrapLambda(fin), false);
        this.depth--;
      }
      this.writeln(`}`);
      return;
    }

    this.writeln(`} catch (__ball_active_error) {`);
    this.depth++;
    if (catches && catches.literal?.listValue) {
      const clauses = catches.literal.listValue.elements ?? [];
      let first = true;
      let untypedBody: Expression | undefined;
      let untypedVar = "e";
      let untypedStackVar: string | undefined;
      for (const ce of clauses) {
        if (!ce.messageCreation) continue;
        const cf = fieldMap(ce.messageCreation.fields ?? []);
        const type = stringFieldVal(cf, "type");
        const variable = stringFieldVal(cf, "variable") ?? "e";
        const stackVar = stringFieldVal(cf, "stack_trace");
        const cbody = cf.get("body");
        if (!type) {
          untypedBody = cbody;
          untypedVar = variable;
          untypedStackVar = stackVar;
          continue;
        }
        const cond = this.typedCatchCondition(type);
        const keyword = first ? "if" : "else if";
        this.writeln(`${keyword} (${cond}) {`);
        this.depth++;
        this.writeln(`const ${variable} = __ball_active_error;`);
        if (stackVar) {
          this.writeln(
            `const ${stackVar} = (__ball_active_error instanceof Error && __ball_active_error.stack != null ? __ball_active_error.stack : (new Error().stack ?? ''));`,
          );
        }
        const treatAsMap = !this.typeIsUserDefinedClass(`main:${type}`) &&
          !this.typeIsUserDefinedClass(type);
        if (treatAsMap) this.catchVars.add(variable);
        if (cbody) this.emitStatementOrExpression(cbody, false);
        if (treatAsMap) this.catchVars.delete(variable);
        this.depth--;
        this.writeln(`}`);
        first = false;
      }
      if (!first) this.writeln(`else {`);
      if (!first) this.depth++;
      if (untypedBody) {
        this.writeln(`const ${untypedVar} = __ball_active_error;`);
        if (untypedStackVar) {
          this.writeln(
            `const ${untypedStackVar} = (__ball_active_error instanceof Error && __ball_active_error.stack != null ? __ball_active_error.stack : (new Error().stack ?? ''));`,
          );
        }
        this.catchVars.add(untypedVar);
        this.emitStatementOrExpression(untypedBody, false);
        this.catchVars.delete(untypedVar);
      } else {
        this.writeln(`throw __ball_active_error;`);
      }
      if (!first) {
        this.depth--;
        this.writeln(`}`);
      }
    } else {
      this.writeln(`throw __ball_active_error;`);
    }
    this.depth--;

    if (fin) {
      this.writeln(`} finally {`);
      this.depth++;
      this.emitStatementOrExpression(unwrapLambda(fin), false);
      this.depth--;
    }
    this.writeln(`}`);
  }

  private emitAssignStmt(call: FunctionCall): void {
    const target = field(call, "target");
    const value = field(call, "value");
    if (!target || !value) return;
    const op = stringField(call, "op") || "=";
    this.writeln(`${this.expr(target)} ${op} ${this.expr(value)};`);
  }

  private typedCatchCondition(type: string): string {
    const builtins = new Set([
      "Error", "TypeError", "RangeError", "SyntaxError",
      "ReferenceError", "URIError", "EvalError",
    ]);
    if (builtins.has(type)) return `__ball_active_error instanceof ${type}`;
    if (type === "FormatException") {
      return "(__ball_active_error instanceof Error && __ball_active_error.message.startsWith('FormatException'))";
    }
    return `(__ball_active_error instanceof ${type} || (typeof __ball_active_error === 'object' && __ball_active_error !== null && __ball_active_error['__type'] === '${type}'))`;
  }

  // ───────────────────────── Expressions ─────────────────────────────

  private expr(e: Expression): string {
    if (e.call) return this.compileCall(e.call);
    if (e.literal) return this.compileLiteral(e.literal);
    if (e.reference) {
      const name = e.reference.name;
      if (name === "this") return "this";
      // Inside a class method: bare references to fields need this.
      // prefix. Method references also need .bind(this) because Dart
      // tear-offs auto-bind but JS method references do not.
      if (!this.currentMethodParams.has(name)) {
        if (this.currentClassFields.has(name)) {
          return `this.${sanitize(name)}`;
        }
        if (this.currentClassMethodNames.has(name)) {
          return `this.${sanitize(name)}.bind(this)`;
        }
      }
      return sanitize(name);
    }
    if (e.fieldAccess) return this.compileFieldAccess(e.fieldAccess);
    if (e.messageCreation) return this.compileMessageCreation(e.messageCreation);
    if (e.block) return this.compileBlockExpression(e.block);
    if (e.lambda) return this.compileLambda(e.lambda);
    return "null /* notSet */";
  }

  private compileLiteral(lit: Literal): string {
    if (lit.intValue !== undefined) return String(lit.intValue);
    if (lit.doubleValue !== undefined) return String(lit.doubleValue);
    if (lit.stringValue !== undefined) return jsStringLiteral(lit.stringValue);
    if (lit.boolValue !== undefined) return lit.boolValue ? "true" : "false";
    if (lit.listValue) {
      const parts = (lit.listValue.elements ?? []).map((x) => this.expr(x));
      return `[${parts.join(", ")}]`;
    }
    if (lit.bytesValue !== undefined) return "/* bytes */ new Uint8Array()";
    return "null";
  }

  private compileFieldAccess(fa: NonNullable<Expression["fieldAccess"]>): string {
    const obj = this.expr(fa.object);
    const f = fa.field;
    if (f === "length") return `${obj}.length`;
    // Positional record field: `.$1` / `.$2` → [0] / [1].
    const recMatch = /^\$(\d+)$/.exec(f);
    if (recMatch) {
      const idx = parseInt(recMatch[1], 10) - 1;
      return `${obj}[${idx}]`;
    }
    if (
      fa.object.reference !== undefined &&
      this.catchVars.has(fa.object.reference.name)
    ) {
      return `${obj}['${f}']`;
    }
    return `${obj}.${f}`;
  }

  private compileMessageCreation(
    mc: NonNullable<Expression["messageCreation"]>,
  ): string {
    const tn = mc.typeName ?? "";
    const fields = mc.fields ?? [];
    if (tn === "") {
      const entries = fields
        .map((f) => `'${f.name}': ${this.expr(f.value)}`)
        .join(", ");
      return `{${entries}}`;
    }

    // Function call encoded as MessageCreation: `foo()` / `this.foo()`
    // with no explicit receiver. typeName = function qualified name.
    const shortName = memberShortName(tn);
    if (this.allFunctionNames.has(tn)) {
      const args = this.extractPositionalAndNamed(fields);
      if (this.currentClassMethodNames.has(shortName)) {
        return `this.${shortName}(${args})`;
      }
      return `${shortName}(${args})`;
    }
    if (this.currentClassMethodNames.has(shortName)) {
      const args = this.extractPositionalAndNamed(fields);
      return `this.${shortName}(${args})`;
    }

    // User-defined class → `new X(...)`.
    if (this.typeIsUserDefinedClass(tn)) {
      const args = this.extractPositionalAndNamed(fields);
      return `new ${classTsName(tn)}(${args})`;
    }

    // Dart/JS built-in constructors: RegExp, Map, Set, Error, etc.
    // The encoder emits these as MessageCreation with typeName
    // including the module prefix (e.g., 'main:RegExp'). Strip the
    // prefix and emit as native constructors.
    const builtinCtors = new Set([
      "RegExp", "Set", "Error", "TypeError", "RangeError",
      "DateTime", "Duration", "Uri", "BigInt", "Int64",
      "BallDouble",
    ]);
    const shortTn = classTsName(tn);

    // Map / Map.from / Map.of → spread-copy as plain object (not JS Map)
    if (shortTn === "Map" || shortTn === "Map.from" || shortTn === "Map.of") {
      const dataFields = fields.filter(f => f.name !== "__type_args__" && f.name !== "__const__");
      const arg = dataFields.length > 0 ? this.expr(dataFields[0].value) : "{}";
      return `({...${arg}})`;
    }
    // List / List.of / List.from → spread-copy as array
    if (shortTn === "List.of" || shortTn === "List.from") {
      const dataFields = fields.filter(f => f.name !== "__type_args__" && f.name !== "__const__");
      const arg = dataFields.length > 0 ? this.expr(dataFields[0].value) : "[]";
      return `([...${arg}])`;
    }

    if (builtinCtors.has(shortTn)) {
      const args = this.extractPositionalAndNamed(fields);
      return `new ${shortTn}(${args})`;
    }

    // BallValue wrapper types — transparent in TS (no wrapper needed).
    // BallMap(map) → just the map; BallList(list) → just the list; etc.
    const ballValueTransparent = new Set([
      "BallMap", "BallList", "BallInt", "BallString",
      "BallBool", "BallNull", "BallFunction", "BallValue",
    ]);
    if (ballValueTransparent.has(shortTn)) {
      if (fields.length === 0) return "null";
      if (fields.length === 1) return this.expr(fields[0].value);
      return this.expr(fields[0].value);
    }

    // Fallback: tagged object literal.
    const entries = [
      `'__type': '${tn}'`,
      ...fields.map((f) => `'${f.name}': ${this.expr(f.value)}`),
    ].join(", ");
    return `{${entries}}`;
  }

  private extractPositionalAndNamed(fields: FieldValuePair[]): string {
    const positional: string[] = [];
    const named: Array<[string, string]> = [];
    const argRe = /^arg(\d+)$/;
    for (const f of fields) {
      if (f.name === "__type_args__" || f.name === "__const__") continue;
      if (argRe.test(f.name)) {
        positional.push(this.expr(f.value));
      } else {
        named.push([f.name, this.expr(f.value)]);
      }
    }
    const parts = [
      ...positional,
      ...(named.length > 0
        ? [`{ ${named.map(([k, v]) => `${k}: ${v}`).join(", ")} }`]
        : []),
    ];
    return parts.join(", ");
  }

  private typeIsUserDefinedClass(tn: string): boolean {
    return tn !== "" && this.typeDefByName.has(tn);
  }

  private compileBlockExpression(block: NonNullable<Expression["block"]>): string {
    const innerText = this.captureInto(() => {
      this.writeln(""); // leading newline
      for (const s of block.statements ?? []) this.emitStatement(s);
      if (block.result !== undefined) {
        this.writeln(`return ${this.expr(block.result)};`);
      }
    }) + "\n";
    const usesAwait = containsBareKeyword(innerText, "await");
    const usesYield = containsBareKeyword(innerText, "yield");
    if (usesAwait) return `(await (async () => {${innerText}})())`;
    if (usesYield) return `(yield* (function* () {${innerText}})())`;
    return `(() => {${innerText}})()`;
  }

  private compileLambda(fn: FunctionDef): string {
    const params = extractParams(fn);
    const paramList = params.map(sanitize).join(", ");
    const innerText = this.captureInto(() => {
      this.writeln("");
      if (params.length === 1 && params[0] !== "input") {
        this.writeln(`const input = ${sanitize(params[0])};`);
      }
      if (fn.body) this.emitStatementOrExpression(fn.body, true);
    }) + "\n";
    const isAsync = functionIsAsync(fn) || containsBareKeyword(innerText, "await");
    const isGenerator = containsBareKeyword(innerText, "yield");
    if (isGenerator) {
      return `(function* (${paramList}) {${innerText}})`;
    }
    return `(${isAsync ? "async " : ""}(${paramList}) => {${innerText}})`;
  }

  // ───────────────────────── Calls ──────────────────────────────────

  private compileCall(call: FunctionCall): string {
    const emptyModuleStd = new Set([
      "labeled", "paren", "switch_expr", "set_create", "map_create",
      "yield_each", "rethrow", "assert",
    ]);
    if (
      isStd(call.module) ||
      ((call.module === undefined || call.module === "") && emptyModuleStd.has(call.function))
    ) {
      return this.compileStdCall(call);
    }
    const fn = sanitize(call.function);
    // Prefix with this. when the function name is a class method OR
    // a class field holding a callable (like `stdout` which is a
    // void Function(String) field). Both need this. in TS since Dart
    // resolves implicitly.
    const thisPrefix =
      !this.currentMethodParams.has(call.function) &&
      (this.currentClassMethodNames.has(call.function) ||
        this.currentClassFields.has(call.function))
        ? "this."
        : "";
    if (!call.input) return `${thisPrefix}${fn}()`;
    const input = call.input;
    if (input.messageCreation) {
      const fields = input.messageCreation.fields ?? [];
      const selfField = fields.find((f) => f.name === "self");
      if (selfField) {
        const selfStr = this.expr(selfField.value);
        const otherArgs = fields
          .filter((f) => f.name !== "self" && f.name !== "__type_args__")
          .map((f) => this.expr(f.value))
          .join(", ");
        return otherArgs === ""
          ? `${selfStr}.${fn}()`
          : `${selfStr}.${fn}(${otherArgs})`;
      }
      const args = fields.map((f) => this.expr(f.value)).join(", ");
      return `${thisPrefix}${fn}(${args})`;
    }
    return `${thisPrefix}${fn}(${this.expr(input)})`;
  }

  private compileStdCall(call: FunctionCall): string {
    const fn = call.function;
    const f = fieldMap(call.input?.messageCreation?.fields ?? []);
    const fg = (...names: string[]) => {
      for (const n of names) { const v = f.get(n); if (v !== undefined) return v; }
      return undefined;
    };
    const bin = (op: string) => `(${this.expr(fg("left", "value", "arg0")!)} ${op} ${this.expr(fg("right", "other", "arg1", "pattern", "separator")!)})`;
    const un = (op: string) => {
      const inner = this.expr(fg("value", "arg0")!);
      if (op === "-" && inner.startsWith("-")) return `-(${inner})`;
      return `${op}${inner}`;
    };

    switch (fn) {
      // Arithmetic
      case "add":          return bin("+");
      case "subtract":     return bin("-");
      case "multiply":     return bin("*");
      case "divide":       return `Math.trunc(${this.expr(f.get("left")!)} / ${this.expr(f.get("right")!)})`;
      case "divide_double":return bin("/");
      case "modulo":       return `__dart_mod(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "negate":       return un("-");
      // Comparison
      case "equals": {
        // Use loose == when comparing against null so undefined matches
        // too (Dart has no undefined; JS returns undefined for missing
        // map keys, unset fields, etc.)
        const l = f.get("left"), r = f.get("right");
        if (l && r) {
          const le = this.expr(l), re = this.expr(r);
          const op = le === "null" || re === "null" ? "==" : "===";
          return `(${le} ${op} ${re})`;
        }
        return bin("===");
      }
      case "not_equals": {
        const l = f.get("left"), r = f.get("right");
        if (l && r) {
          const le = this.expr(l), re = this.expr(r);
          const op = le === "null" || re === "null" ? "!=" : "!==";
          return `(${le} ${op} ${re})`;
        }
        return bin("!==");
      }
      case "less_than":    return bin("<");
      case "greater_than": return bin(">");
      case "lte":          case "less_than_or_equal":    return bin("<=");
      case "gte":          case "greater_than_or_equal": return bin(">=");
      // Logical
      case "and":          return bin("&&");
      case "or":           return bin("||");
      case "not":          return un("!");
      // Bitwise
      case "bitwise_and":  return bin("&");
      case "bitwise_or":   return bin("|");
      case "bitwise_xor":  return bin("^");
      case "bitwise_not":  return un("~");
      case "left_shift":   case "shift_left":  return bin("<<");
      case "right_shift":  case "shift_right": return bin(">>");
      case "unsigned_right_shift": return bin(">>>");
      case "integer_divide":
        return `Math.trunc(${this.expr(f.get("left")!)} / ${this.expr(f.get("right")!)})`;
      case "concat":       return bin("+");
      case "to_string":    return `__ball_to_string(${this.expr(f.get("value")!)})`;
      case "int_to_string":return `String(${this.expr(f.get("value")!)})`;
      case "double_to_string": return `__ball_double_to_string(${this.expr(f.get("value")!)})`;
      case "string_to_int":return `__ball_parse_int(${this.expr(f.get("value")!)})`;
      case "string_to_double": return `__ball_parse_double(${this.expr(f.get("value")!)})`;
      case "string_length":return `${this.expr(f.get("value")!)}.length`;
      case "string_to_upper": return `${this.wrapIfNeeded(f.get("value")!)}.toUpperCase()`;
      case "string_to_lower": return `${this.wrapIfNeeded(f.get("value")!)}.toLowerCase()`;
      case "string_trim":  return `${this.wrapIfNeeded(f.get("value")!)}.trim()`;
      case "string_trim_start": return `${this.wrapIfNeeded(f.get("value")!)}.trimStart()`;
      case "string_trim_end": return `${this.wrapIfNeeded(f.get("value")!)}.trimEnd()`;
      case "string_contains": return `${this.expr(fg("left", "value", "arg0")!)}.includes(${this.expr(fg("right", "pattern", "arg1")!)})`;
      case "string_starts_with": return `${this.expr(fg("left", "value", "arg0")!)}.startsWith(${this.expr(fg("right", "pattern", "arg1")!)})`;
      case "string_ends_with": return `${this.expr(fg("left", "value", "arg0")!)}.endsWith(${this.expr(fg("right", "pattern", "arg1")!)})`;
      case "string_is_empty": return `(${this.expr(fg("value", "arg0")!)}.length === 0)`;
      case "string_split": return `${this.expr(fg("value", "arg0")!)}.split(${this.expr(fg("separator", "arg1", "right")!)})`;
      case "string_substring": {
        const v = this.expr(fg("value", "arg0")!);
        const s = this.expr(fg("start", "arg1")!);
        const end = f.get("end");
        return end ? `${v}.substring(${s}, ${this.expr(end)})` : `${v}.substring(${s})`;
      }
      case "string_interpolation": {
        const parts = f.get("parts");
        if (parts?.literal?.listValue) {
          const pieces = (parts.literal.listValue.elements ?? [])
            .map((p) => `(${this.expr(p)})`)
            .join(" + ");
          return `(${pieces})`;
        }
        return `''`;
      }
      // Math
      case "math_abs":   return `Math.abs(${this.expr(f.get("value")!)})`;
      case "math_round": return `Math.round(${this.expr(f.get("value")!)})`;
      case "math_floor": return `Math.floor(${this.expr(f.get("value")!)})`;
      case "math_ceil":  return `Math.ceil(${this.expr(f.get("value")!)})`;
      case "math_trunc": return `Math.trunc(${this.expr(f.get("value")!)})`;
      case "math_sqrt":  return `Math.sqrt(${this.expr(f.get("value")!)})`;
      case "math_pow":   return `Math.pow(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "math_min":   return `Math.min(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "math_max":   return `Math.max(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "math_pi":    return "Math.PI";
      case "math_e":     return "Math.E";
      case "print":      return `console.log(__ball_to_string(${this.expr(f.get("message")!)}))`;
      case "index":      return `${this.expr(f.get("target")!)}[${this.expr(f.get("index")!)}]`;
      case "null_coalesce": return `(${this.expr(f.get("left")!)} ?? ${this.expr(f.get("right")!)})`;
      case "null_check": return this.expr(f.get("value")!);
      case "is": {
        const val = f.get("value");
        const typ = f.get("type");
        if (val && typ) {
          const v = this.expr(val);
          const t = typ.literal?.stringValue ?? "";
          return this.emitIsCheck(v, t);
        }
        return `(${this.expr(f.get("value")!)} != null)`;
      }
      case "is_not": {
        const val = f.get("value");
        const typ = f.get("type");
        if (val && typ) {
          const v = this.expr(val);
          const t = typ.literal?.stringValue ?? "";
          return `!(${this.emitIsCheck(v, t)})`;
        }
        return `(${this.expr(f.get("value")!)} == null)`;
      }
      case "as":         return this.expr(f.get("value")!);
      case "if": {
        const cond = this.expr(f.get("condition")!);
        const thenExpr = f.get("then")!;
        const t = this.expr(unwrapLambda(thenExpr));
        const elseE = f.get("else");
        const e = elseE ? this.expr(unwrapLambda(elseE)) : "undefined";
        return `(${cond} ? ${t} : ${e})`;
      }
      case "paren":   return `(${this.expr(f.get("value")!)})`;
      case "assert":  return `console.assert(${this.expr(f.get("condition")!)})`;
      case "assign": {
        const op = stringField(call, "op") || "=";
        return `(${this.expr(f.get("target")!)} ${op} ${this.expr(f.get("value")!)})`;
      }
      case "pre_increment":  return `(++${this.expr(f.get("value")!)})`;
      case "pre_decrement":  return `(--${this.expr(f.get("value")!)})`;
      case "post_increment": return `(${this.expr(f.get("value")!)}++)`;
      case "post_decrement": return `(${this.expr(f.get("value")!)}--)`;
      case "throw": {
        const v = f.get("value");
        if (!v) return "(() => { throw null; })()";
        const str = this.compileThrowValue(v) ?? this.expr(v);
        return `(() => { throw ${str}; })()`;
      }
      case "rethrow": return "(() => { throw __ball_active_error; })()";
      case "await":   return `await ${this.expr(f.get("value")!)}`;
      case "switch":
      case "switch_expr": return this.compileSwitchExpr(call);
      case "return": {
        // In expression position: unwrap to the bare value. When this
        // appears inside a switch-expr case body, the switch handler
        // detects the return and emits `return <ternary>` at statement
        // level.
        const v = f.get("value");
        return v ? this.expr(v) : "undefined";
      }
      case "null_aware_call": {
        const target = f.get("target");
        const method = f.get("method");
        if (!target || !method) return "/* null_aware_call missing */";
        const methodName = method.literal?.stringValue ?? "";
        const inputFields = call.input?.messageCreation?.fields ?? [];
        const otherArgs = inputFields
          .filter((fd) => fd.name !== "target" && fd.name !== "method" && fd.name !== "__type_args__")
          .map((fd) => this.expr(fd.value))
          .join(", ");
        return `${this.expr(target)}?.${methodName}(${otherArgs})`;
      }
      case "null_aware_index": {
        const self_ = f.get("self") ?? f.get("target");
        const idx = f.get("index") ?? f.get("key");
        if (!self_ || !idx) return "/* null_aware_index missing */";
        return `${this.expr(self_)}[${this.expr(idx)}]`;
      }
      case "null_aware_access": {
        const target = f.get("target");
        const fieldE = f.get("field");
        if (!target || !fieldE) return "/* null_aware_access missing */";
        return `${this.expr(target)}?.${fieldE.literal?.stringValue ?? ""}`;
      }
      case "typed_list": {
        const elements = f.get("elements");
        if (elements?.literal?.listValue) {
          const parts = (elements.literal.listValue.elements ?? []).map((x) => this.expr(x));
          return `[${parts.join(", ")}]`;
        }
        if (elements) return this.expr(elements);
        return "[]";
      }
      case "typed_map": {
        const entries = f.get("entries");
        if (!entries) return "new Map()";
        const entryExprs = entries.literal?.listValue?.elements ?? [];
        if (entryExprs.length === 0) return "new Map()";
        const pairs: string[] = [];
        for (const e of entryExprs) {
          if (e.messageCreation) {
            const mc = e.messageCreation;
            const mFields = mc.fields ?? [];
            const k = mFields.find((fd) => fd.name === "key")?.value;
            const v = mFields.find((fd) => fd.name === "value")?.value;
            if (k && v) pairs.push(`[${this.expr(k)}, ${this.expr(v)}]`);
          }
        }
        return `new Map([${pairs.join(", ")}])`;
      }
      case "set_create": {
        const elements: string[] = [];
        const inputFields = call.input?.messageCreation?.fields ?? [];
        for (const fd of inputFields) {
          elements.push(this.expr(fd.value));
        }
        if (elements.length === 0) return "new Set()";
        return `new Set([${elements.join(", ")}])`;
      }
      case "map_create": {
        // map_create can have entries passed as `entry` fields on the
        // input MessageCreation. Each entry is a message with key/value.
        // Emit as plain object {} (not new Map()) — JS Map doesn't
        // support bracket access (m['k'] = v) but the compiled engine
        // uses it throughout.
        const mapEntries: string[] = [];
        const inputFields = call.input?.messageCreation?.fields ?? [];
        for (const fd of inputFields) {
          if (fd.name === "entry" && fd.value.messageCreation) {
            const mc = fd.value.messageCreation;
            const mFields = mc.fields ?? [];
            const kf = mFields.find((f: any) => f.name === "key");
            const vf = mFields.find((f: any) => f.name === "value");
            if (kf && vf) {
              mapEntries.push(`${this.expr(kf.value)}: ${this.expr(vf.value)}`);
            }
          }
        }
        if (mapEntries.length === 0) return "{}";
        return `{${mapEntries.join(", ")}}`;
      }
      case "record": {
        const positional: string[] = [];
        const named: Array<[string, string]> = [];
        const posRe = /^(?:\$|arg)(\d+)$/;
        for (const fd of call.input?.messageCreation?.fields ?? []) {
          if (fd.name === "__type_args__") continue;
          if (posRe.test(fd.name)) {
            positional.push(this.expr(fd.value));
          } else {
            named.push([fd.name, this.expr(fd.value)]);
          }
        }
        if (named.length === 0) return `[${positional.join(", ")}]`;
        if (positional.length === 0) {
          return `{ ${named.map(([k, v]) => `${k}: ${v}`).join(", ")} }`;
        }
        const entries = [
          ...positional.map((v, i) => `"${i}": ${v}`),
          ...named.map(([k, v]) => `${k}: ${v}`),
        ];
        return `{ ${entries.join(", ")} }`;
      }
      case "yield":      return `yield ${this.expr(f.get("value")!)}`;
      case "yield_each": return `yield* ${this.expr(f.get("value")!)}`;
      // Dart-specific std/dart_std functions
      case "cascade": {
        const target = f.get("target") ?? f.get("value");
        const sections = f.get("sections") ?? f.get("operations") ?? f.get("ops");
        if (target) {
          const targetStr = this.expr(target);
          if (sections && sections.literal?.listValue) {
            // Cascade: evaluate target, bind as __cascade_self__, evaluate
            // each section (which references __cascade_self__), return target.
            const sectionExprs = (sections.literal.listValue.elements ?? [])
              .map((e: Expression) => `${this.expr(e)};`)
              .join(" ");
            return `((__cascade_self__) => { ${sectionExprs} return __cascade_self__; })(${targetStr})`;
          }
          if (sections) {
            return `((__cascade_self__) => { ${this.expr(sections)}; return __cascade_self__; })(${targetStr})`;
          }
          return targetStr;
        }
        const allFields = call.input?.messageCreation?.fields ?? [];
        const args = allFields.map((fd) => this.expr(fd.value)).join(", ");
        return `__ball_cascade(${args})`;
      }
      case "null_aware_cascade": {
        const target = f.get("target") ?? f.get("value");
        if (!target) return "null";
        const sections = f.get("sections") ?? f.get("operations") ?? f.get("ops");
        if (sections && sections.literal?.listValue) {
          const targetStr = this.expr(target);
          const sectionExprs = (sections.literal.listValue.elements ?? [])
            .map((e: Expression) => `${this.expr(e)};`)
            .join(" ");
          return `((__cascade_self__) => { if (__cascade_self__ == null) return null; ${sectionExprs} return __cascade_self__; })(${targetStr})`;
        }
        if (sections) {
          return `((__cascade_self__) => { if (__cascade_self__ == null) return null; ${this.expr(sections)}; return __cascade_self__; })(${this.expr(target)})`;
        }
        return this.expr(target);
      }
      case "spread":       return this.expr(f.get("value")!);
      case "null_spread": {
        const v = f.get("value");
        return v ? `(${this.expr(v)} ?? [])` : "[]";
      }
      case "invoke": {
        const callee = f.get("callee");
        const inputFields = call.input?.messageCreation?.fields ?? [];
        const otherArgs = inputFields
          .filter((fd) => fd.name !== "callee" && fd.name !== "__type__" && fd.name !== "__type_args__")
          .map((fd) => this.expr(fd.value));
        if (callee) {
          if (otherArgs.length === 0) return `${this.expr(callee)}()`;
          if (otherArgs.length === 1) return `${this.expr(callee)}(${otherArgs[0]})`;
          return `${this.expr(callee)}(${otherArgs.join(", ")})`;
        }
        return "null";
      }
      case "tear_off": {
        const cb = f.get("callback") ?? f.get("method") ?? f.get("value");
        return cb ? this.expr(cb) : "null";
      }
      case "dart_list_generate": {
        const count = f.get("count") ?? f.get("length");
        const gen = f.get("generator");
        if (count && gen) {
          return `List.generate(${this.expr(count)}, ${this.expr(gen)})`;
        }
        return "[]";
      }
      case "dart_list_filled": {
        const count = f.get("count") ?? f.get("length");
        const value = f.get("value") ?? f.get("fill");
        if (count && value) {
          return `List.filled(${this.expr(count)}, ${this.expr(value)})`;
        }
        return "[]";
      }
      case "to_double": {
        const v = f.get("value");
        return v ? `(+(${this.expr(v)}))` : "0.0";
      }
      case "to_int": {
        const v = f.get("value");
        return v ? `Math.trunc(${this.expr(v)})` : "0";
      }
      case "identical": {
        const l = f.get("left") ?? f.get("a");
        const r = f.get("right") ?? f.get("b");
        if (l && r) return `(${this.expr(l)} === ${this.expr(r)})`;
        return "false";
      }
      case "string_code_unit_at":
      case "string_char_code_at": {
        const v = f.get("value") ?? f.get("string");
        const idx = f.get("index");
        if (v && idx) return `${this.expr(v)}.charCodeAt(${this.expr(idx)})`;
        return "0";
      }
      case "string_from_char_code": {
        const v = f.get("value") ?? f.get("code");
        return v ? `String.fromCharCode(${this.expr(v)})` : "''";
      }
      case "string_char_at": {
        const v = f.get("value") ?? f.get("string");
        const idx = f.get("index");
        if (v && idx) return `${this.expr(v)}[${this.expr(idx)}]`;
        return "''";
      }
      case "string_replace": {
        const v = f.get("value") ?? f.get("string");
        const from = f.get("from") ?? f.get("pattern");
        const to = f.get("to") ?? f.get("replacement");
        if (v && from && to) return `${this.expr(v)}.replace(${this.expr(from)}, ${this.expr(to)})`;
        return "''";
      }
      case "string_replace_all": {
        const v = f.get("value") ?? f.get("string");
        const from = f.get("from") ?? f.get("pattern");
        const to = f.get("to") ?? f.get("replacement");
        if (v && from && to) return `${this.expr(v)}.split(${this.expr(from)}).join(${this.expr(to)})`;
        return "''";
      }
      case "string_repeat": {
        const v = f.get("value");
        const count = f.get("count") ?? f.get("times");
        if (v && count) return `${this.expr(v)}.repeat(${this.expr(count)})`;
        return "''";
      }
      case "string_pad_left": {
        const v = f.get("value");
        const w = f.get("width");
        const p = f.get("padding");
        if (v && w) return `${this.expr(v)}.padStart(${this.expr(w)}${p ? `, ${this.expr(p)}` : ""})`;
        return "''";
      }
      case "string_pad_right": {
        const v = f.get("value");
        const w = f.get("width");
        const p = f.get("padding");
        if (v && w) return `${this.expr(v)}.padEnd(${this.expr(w)}${p ? `, ${this.expr(p)}` : ""})`;
        return "''";
      }
      case "string_index_of": {
        const v = f.get("value") ?? f.get("string");
        const pat = f.get("pattern") ?? f.get("substring");
        const start = f.get("start");
        if (v && pat) {
          if (start) return `${this.expr(v)}.indexOf(${this.expr(pat)}, ${this.expr(start)})`;
          return `${this.expr(v)}.indexOf(${this.expr(pat)})`;
        }
        return "-1";
      }
      case "string_last_index_of": {
        const v = f.get("value") ?? f.get("string");
        const pat = f.get("pattern") ?? f.get("substring");
        if (v && pat) return `${this.expr(v)}.lastIndexOf(${this.expr(pat)})`;
        return "-1";
      }
      case "string_concat": return bin("+");
      // Collection operations (std_collections module)
      case "list_push": {
        const list = f.get("list");
        const value = f.get("value");
        if (list && value) return `[...${this.expr(list)}, ${this.expr(value)}]`;
        return "[]";
      }
      case "list_pop": {
        const list = f.get("list");
        return list ? `${this.expr(list)}.slice(0, -1)` : "[]";
      }
      case "list_length": {
        const list = f.get("list") ?? f.get("value");
        return list ? `${this.expr(list)}.length` : "0";
      }
      case "list_is_empty": {
        const list = f.get("list") ?? f.get("value");
        return list ? `(${this.expr(list)}.length === 0)` : "true";
      }
      case "list_first": {
        const list = f.get("list");
        return list ? `${this.expr(list)}[0]` : "undefined";
      }
      case "list_last": {
        const list = f.get("list");
        return list ? `${this.expr(list)}[${this.expr(list)}.length - 1]` : "undefined";
      }
      case "list_contains": {
        const list = f.get("list");
        const value = f.get("value");
        if (list && value) return `${this.expr(list)}.includes(${this.expr(value)})`;
        return "false";
      }
      case "list_get": {
        const list = f.get("list");
        const idx = f.get("index");
        if (list && idx) return `${this.expr(list)}[${this.expr(idx)}]`;
        return "undefined";
      }
      case "list_set": {
        const list = f.get("list");
        const idx = f.get("index");
        const value = f.get("value");
        if (list && idx && value) return `(${this.expr(list)}[${this.expr(idx)}] = ${this.expr(value)})`;
        return "undefined";
      }
      case "list_index_of": {
        const list = f.get("list");
        const value = f.get("value");
        if (list && value) return `${this.expr(list)}.indexOf(${this.expr(value)})`;
        return "-1";
      }
      case "list_concat": {
        const l = f.get("left") ?? f.get("list");
        const r = f.get("right") ?? f.get("other");
        if (l && r) return `[...${this.expr(l)}, ...${this.expr(r)}]`;
        return "[]";
      }
      case "list_reverse": {
        const list = f.get("list") ?? f.get("value");
        return list ? `[...${this.expr(list)}].reverse()` : "[]";
      }
      case "list_slice": case "list_sublist": {
        const list = f.get("list");
        const start = f.get("start");
        const end = f.get("end");
        if (list && start) {
          if (end) return `${this.expr(list)}.slice(${this.expr(start)}, ${this.expr(end)})`;
          return `${this.expr(list)}.slice(${this.expr(start)})`;
        }
        return "[]";
      }
      case "map_get": {
        const map = f.get("map");
        const key = f.get("key");
        if (map && key) return `${this.expr(map)}[${this.expr(key)}]`;
        return "undefined";
      }
      case "map_set": {
        const map = f.get("map");
        const key = f.get("key");
        const value = f.get("value");
        if (map && key && value) return `(${this.expr(map)}[${this.expr(key)}] = ${this.expr(value)})`;
        return "undefined";
      }
      case "map_contains_key": {
        const map = f.get("map");
        const key = f.get("key");
        if (map && key) return `(${this.expr(key)} in ${this.expr(map)})`;
        return "false";
      }
      case "map_keys": {
        const map = f.get("map") ?? f.get("value");
        return map ? `Object.keys(${this.expr(map)})` : "[]";
      }
      case "map_values": {
        const map = f.get("map") ?? f.get("value");
        return map ? `Object.values(${this.expr(map)})` : "[]";
      }
      case "map_entries": {
        const map = f.get("map") ?? f.get("value");
        return map ? `Object.entries(${this.expr(map)}).map(([k, v]) => ({key: k, value: v}))` : "[]";
      }
      case "map_length": {
        const map = f.get("map") ?? f.get("value");
        return map ? `Object.keys(${this.expr(map)}).length` : "0";
      }
      case "map_is_empty": {
        const map = f.get("map") ?? f.get("value");
        return map ? `(Object.keys(${this.expr(map)}).length === 0)` : "true";
      }
      case "map_delete": case "map_remove": {
        const map = f.get("map");
        const key = f.get("key");
        if (map && key) return `(() => { const __m = ${this.expr(map)}; const __k = ${this.expr(key)}; const __v = __m[__k]; delete __m[__k]; return __v; })()`;
        return "undefined";
      }
      case "map_merge": {
        const l = f.get("left") ?? f.get("map");
        const r = f.get("right") ?? f.get("other");
        if (l && r) return `{...${this.expr(l)}, ...${this.expr(r)}}`;
        return "{}";
      }
      case "map_from_entries": {
        const entries = f.get("entries") ?? f.get("value");
        if (entries) return `Object.fromEntries(${this.expr(entries)}.map((e: any) => [e.key, e.value]))`;
        return "{}";
      }
      case "string_join": {
        const list = f.get("list") ?? f.get("value");
        const sep = f.get("separator");
        if (list && sep) return `${this.expr(list)}.join(${this.expr(sep)})`;
        if (list) return `${this.expr(list)}.join('')`;
        return "''";
      }
      case "set_add": case "set_remove": case "set_contains":
      case "set_union": case "set_intersection": case "set_difference":
      case "set_length": case "set_is_empty": case "set_to_list": {
        const allFields = call.input?.messageCreation?.fields ?? [];
        const args = allFields.map((fd) => this.expr(fd.value)).join(", ");
        return `/* std.${fn} */ ${sanitize(fn)}(${args})`;
      }
      // I/O
      case "print_error": {
        const msg = f.get("message") ?? f.get("value");
        return msg ? `console.error(__ball_to_string(${this.expr(msg)}))` : `console.error('')`;
      }
      case "read_line": return `''`;
      case "exit": {
        const code = f.get("code") ?? f.get("value");
        return code ? `process.exit(${this.expr(code)})` : `process.exit(0)`;
      }
      case "sleep_ms": {
        const ms = f.get("value") ?? f.get("ms");
        return ms ? `await new Promise(r => setTimeout(r, ${this.expr(ms)}))` : `undefined`;
      }
      case "timestamp_ms": return `Date.now()`;
      case "random_int": {
        const max = f.get("max") ?? f.get("value");
        return max ? `Math.floor(Math.random() * ${this.expr(max)})` : "0";
      }
      case "random_double": return `Math.random()`;
      case "int_to_double": {
        const v = f.get("value");
        return v ? `(+(${this.expr(v)}))` : "0.0";
      }
      // JSON
      case "json_encode": {
        const v = f.get("value");
        return v ? `JSON.stringify(${this.expr(v)})` : "''";
      }
      case "json_decode": {
        const v = f.get("value");
        return v ? `JSON.parse(${this.expr(v)})` : "null";
      }
      // Type ops
      case "symbol": case "type_literal": {
        const v = f.get("value") ?? f.get("name");
        return v ? this.expr(v) : "null";
      }
      default: {
        // Emit as inline JS for known collection/utility operations.
        // Otherwise fall back to calling through the engine's base function dispatch.
        const mapArg = f.get("map") ?? f.get("list") ?? f.get("value");
        const keyArg = f.get("key") ?? f.get("index");
        const valArg = f.get("value");
        switch (fn) {
          case "map_put_if_absent": {
            const m = this.expr(f.get("map")!);
            const k = this.expr(f.get("key")!);
            const supplier = f.get("value") ?? f.get("supplier") ?? f.get("arg2");
            return `(${m}[${k}] ??= ${supplier ? `(${this.expr(supplier)})()` : 'null'})`;
          }
          case "map_get": return `${this.expr(f.get("map")!)}[${this.expr(f.get("key")!)}]`;
          case "map_set": return `(${this.expr(f.get("map")!)}[${this.expr(f.get("key")!)}] = ${this.expr(f.get("value")!)})`;
          case "map_delete": return `(delete ${this.expr(f.get("map")!)}[${this.expr(f.get("key")!)}], ${this.expr(f.get("map")!)})`;
          case "map_keys": return `Object.keys(${this.expr(f.get("map")!)})`;
          case "map_values": return `Object.values(${this.expr(f.get("map")!)})`;
          case "map_entries": return `Object.entries(${this.expr(f.get("map")!)}).map(([k,v]) => ({key:k, value:v}))`;
          case "map_length": return `Object.keys(${this.expr(f.get("map")!)}).length`;
          case "map_contains_key": return `(${this.expr(f.get("key")!)} in ${this.expr(f.get("map")!)})`;
          case "map_contains_value": return `Object.values(${this.expr(f.get("map")!)}).includes(${this.expr(f.get("value")!)})`;
          case "list_push": return `(${this.expr(f.get("list")!)}.push(${this.expr(f.get("value")!)}), ${this.expr(f.get("list")!)})`;
          case "list_pop": return `${this.expr(f.get("list")!)}.pop()`;
          case "list_insert": return `(${this.expr(f.get("list")!)}.splice(${this.expr(f.get("index")!)}, 0, ${this.expr(f.get("value")!)}), ${this.expr(f.get("list")!)})`;
          case "list_remove_at": return `${this.expr(f.get("list")!)}.splice(${this.expr(f.get("index")!)}, 1)[0]`;
          case "list_clear": return `(${this.expr(f.get("list")!)}.length = 0, ${this.expr(f.get("list")!)})`;
          case "list_length": return `${this.expr(f.get("list")!)}.length`;
          case "list_filter": return `${this.expr(f.get("list")!)}.filter(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_map": return `${this.expr(f.get("list")!)}.map(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_sort": {
            const l = this.expr(f.get("list")!);
            const cmp = f.get("comparator") ?? f.get("function") ?? f.get("value");
            return cmp ? `[...${l}].sort(${this.expr(cmp)})` : `[...${l}].sort()`;
          }
          case "list_join": {
            const l = this.expr(f.get("list")!);
            const sep = f.get("separator") ?? f.get("value");
            return sep ? `${l}.join(${this.expr(sep)})` : `${l}.join('')`;
          }
          case "list_slice": return `${this.expr(f.get("list")!)}.slice(${this.expr(f.get("start") ?? f.get("index")!)}, ${f.get("end") ? this.expr(f.get("end")!) : ''})`;
          case "list_contains": return `${this.expr(f.get("list")!)}.includes(${this.expr(f.get("value")!)})`;
          case "list_index_of": return `${this.expr(f.get("list")!)}.indexOf(${this.expr(f.get("value")!)})`;
          case "list_any": return `${this.expr(f.get("list")!)}.some(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_all": return `${this.expr(f.get("list")!)}.every(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_to_list": return `[...${this.expr(f.get("list")!)}]`;
          case "list_concat": return `[...${this.expr(f.get("left")!)}, ...${this.expr(f.get("right")!)}]`;
          case "list_reversed": return `[...${this.expr(f.get("list")!)}].reverse()`;
          case "compare_to": {
            const v = this.expr(fg("value", "left", "arg0")!);
            const o = this.expr(fg("other", "right", "arg1")!);
            return `(${v} < ${o} ? -1 : ${v} > ${o} ? 1 : 0)`;
          }
          case "to_string_as_fixed": {
            const v = this.expr(fg("value", "arg0")!);
            const d = this.expr(fg("digits", "arg1", "right")!);
            return `(+(${v})).toFixed(${d})`;
          }
          case "math_clamp": {
            const v = this.expr(fg("value", "arg0")!);
            const lo = this.expr(fg("min", "arg1")!);
            const hi = this.expr(fg("max", "arg2")!);
            return `Math.min(Math.max(${v}, ${lo}), ${hi})`;
          }
          case "string_code_unit_at": {
            const s = this.expr(fg("value", "string", "arg0")!);
            const i = this.expr(fg("index", "arg1")!);
            return `${s}.charCodeAt(${i})`;
          }
          case "string_char_at": {
            const s = this.expr(fg("value", "string", "arg0")!);
            const i = this.expr(fg("index", "arg1")!);
            return `${s}.charAt(${i})`;
          }
          case "string_replace": {
            const s = this.expr(fg("value", "string", "arg0")!);
            const from = this.expr(fg("from", "pattern", "arg1")!);
            const to = this.expr(fg("to", "replacement", "arg2")!);
            return `${s}.split(${from}).join(${to})`;
          }
          case "collection_if": {
            const cond = this.expr(f.get("condition")!);
            const then_ = f.get("then");
            const else_ = f.get("else");
            return else_ ? `(${cond} ? ${this.expr(then_!)} : ${this.expr(else_)})` : `(${cond} ? ${this.expr(then_!)} : undefined)`;
          }
          case "collection_for": {
            const variable = f.get("variable")?.literal?.stringValue ?? "item";
            const iterable = this.expr(f.get("iterable")!);
            const body = this.expr(f.get("body")!);
            return `${iterable}.map((${variable}: any) => ${body})`;
          }
          default: {
            const args = Array.from(f.values()).map((e) => this.expr(e)).join(", ");
            return `/* std.${fn} */ ${sanitize(fn)}(${args})`;
          }
        }
      }
    }
  }

  private emitIsCheck(value: string, type: string): string {
    // Strip generic args: Map<String, Object?> → Map
    const baseType = type.includes("<") ? type.slice(0, type.indexOf("<")).trim() : type.trim();
    // Strip nullable: Map? → Map
    const t = baseType.endsWith("?") ? baseType.slice(0, -1) : baseType;
    switch (t) {
      case "int": return `(typeof ${value} === 'number' && Number.isInteger(${value}))`;
      case "double": case "num": case "number": return `(typeof ${value} === 'number')`;
      case "String": case "string": return `(typeof ${value} === 'string')`;
      case "bool": case "boolean": return `(typeof ${value} === 'boolean')`;
      case "List": case "Iterable": return `Array.isArray(${value})`;
      case "Map": return `(typeof ${value} === 'object' && ${value} !== null && !Array.isArray(${value}))`;
      case "Set": return `(${value} instanceof Set)`;
      case "Null": return `(${value} == null)`;
      case "Function": return `(typeof ${value} === 'function')`;
      case "BallMap": return `false /* BallMap is Map in TS */`;
      case "BallList": return `false /* BallList is List in TS */`;
      case "BallValue": return `(${value} != null)`;
      case "BallInt": return `(typeof ${value} === 'number' && Number.isInteger(${value}))`;
      case "BallDouble": return `(typeof ${value} === 'number' || ${value} instanceof BallDouble)`;
      case "BallString": return `(typeof ${value} === 'string')`;
      case "BallBool": return `(typeof ${value} === 'boolean')`;
      case "BallNull": return `(${value} == null)`;
      case "BallFunction": return `(typeof ${value} === 'function')`;
      default:
        if (this.typeIsUserDefinedClass(`main:${t}`) || this.typeIsUserDefinedClass(t)) {
          return `(${value} instanceof ${classTsName(t)})`;
        }
        return `(${value} != null)`;
    }
  }

  private wrapIfNeeded(e: Expression): string {
    const s = this.expr(e);
    if (s === "") return s;
    const first = s.charCodeAt(0);
    if (first === 0x21 /* ! */ || first === 0x7e /* ~ */ || first === 0x2d /* - */) {
      return `(${s})`;
    }
    return s;
  }

  private compileSwitchExpr(call: FunctionCall): string {
    const subjectExpr = field(call, "subject");
    const casesField = field(call, "cases");
    if (!subjectExpr || !casesField) return "/* malformed switch */ undefined";
    const subjectStr = this.expr(subjectExpr);
    const caseExprs = casesField.literal?.listValue?.elements ?? [];
    let defaultBody: Expression | undefined;
    const branches: Array<{ cond: string; body: string }> = [];
    for (const ce of caseExprs) {
      if (!ce.messageCreation) continue;
      let pattern: Expression | undefined;
      let body: Expression | undefined;
      for (const fd of ce.messageCreation.fields ?? []) {
        if (fd.name === "pattern") pattern = fd.value;
        if (fd.name === "body") body = fd.value;
      }
      if (!body) continue;
      if (!pattern) {
        defaultBody = body;
        continue;
      }
      const patText = patternLiteralText(pattern);
      if (patText === undefined) {
        branches.push({
          cond: `((${subjectStr}) === ${this.expr(pattern)})`,
          body: this.expr(body),
        });
        continue;
      }
      const cond = patternToTsCondition(patText, subjectStr);
      if (cond === "true") {
        defaultBody = body;
        break;
      }
      branches.push({ cond, body: this.expr(body) });
    }
    const tail = defaultBody ? this.expr(defaultBody) : "undefined";
    if (branches.length === 0) return tail;
    let result = tail;
    for (const { cond, body } of [...branches].reverse()) {
      result = `(${cond} ? (${body}) : ${result})`;
    }
    return result;
  }

  private compileThrowValue(v: Expression): string | undefined {
    if (!v.messageCreation) return undefined;
    if (v.messageCreation.typeName) return undefined;
    const entries = (v.messageCreation.fields ?? [])
      .map((fd) => `'${fd.name}': ${this.expr(fd.value)}`)
      .join(", ");
    return `{${entries}}`;
  }

  // ───────────────────────── Helpers ─────────────────────────────────

  private enclosingTypeName(fnName: string): string | undefined {
    let best: string | undefined;
    for (const name of this.typeDefByName.keys()) {
      if (fnName.startsWith(`${name}.`) && (best === undefined || name.length > best.length)) {
        best = name;
      }
    }
    return best;
  }

  private dartTypeToTs(dart: string): string {
    const t = dart.trim();
    if (t === "") return "any";
    if (t.startsWith("(")) return "any";
    if (t.includes(" Function(")) return "any";
    const nonNull = t.endsWith("?") ? t.slice(0, -1) : t;
    const lt = nonNull.indexOf("<");
    if (lt > 0 && nonNull.endsWith(">")) {
      const outer = nonNull.slice(0, lt);
      const inner = nonNull.slice(lt + 1, -1);
      const innerArgs = splitTopLevelCommas(inner).map((x) => this.dartTypeToTs(x));
      switch (outer) {
        case "List":
        case "Iterable":
        case "Set":
          return `Array<${innerArgs.join(", ")}>`;
        case "Map":
          return `Map<${innerArgs.join(", ")}>`;
        case "Future":
          return innerArgs.length === 0 ? "Promise<any>" : `Promise<${innerArgs.join(", ")}>`;
        case "FutureOr": {
          const a = innerArgs.length === 0 ? "any" : innerArgs[0];
          return `${a} | Promise<${a}>`;
        }
        default:
          return `${this.dartTypeToTs(outer)}<${innerArgs.join(", ")}>`;
      }
    }
    switch (nonNull) {
      case "int":
      case "double":
      case "num":
        return "number";
      case "bool":
        return "boolean";
      case "String":
        return "string";
      case "void":
        return "void";
      case "dynamic":
      case "Object":
        return "any";
    }
    if (nonNull.startsWith("main:")) return nonNull.slice(5);
    return nonNull;
  }
}

// ───────────────────────── Free helpers ───────────────────────────────

function extractParams(fn: FunctionDef): string[] {
  const params = fn.metadata?.["params"];
  if (!Array.isArray(params)) return [];
  const out: string[] = [];
  for (const p of params) {
    if (typeof p === "string") {
      out.push(p);
    } else if (p && typeof p === "object" && "name" in p && typeof (p as any).name === "string") {
      out.push((p as any).name);
    }
  }
  return out;
}

function extractCtorParams(meta: Struct): CtorParam[] {
  const raw = meta["params"];
  if (!Array.isArray(raw)) return [];
  const out: CtorParam[] = [];
  for (const p of raw) {
    if (p && typeof p === "object" && "name" in p && typeof (p as any).name === "string") {
      out.push({
        name: (p as any).name,
        isThis: (p as any).is_this === true,
        isNamed: (p as any).is_named === true,
      });
    }
  }
  return out;
}

function functionIsAsync(fn: FunctionDef): boolean {
  return fn.metadata?.["is_async"] === true;
}

function field(call: FunctionCall, name: string): Expression | undefined {
  const fields = call.input?.messageCreation?.fields;
  if (!fields) return undefined;
  for (const f of fields) if (f.name === name) return f.value;
  return undefined;
}

function stringField(call: FunctionCall, name: string): string | undefined {
  const e = field(call, name);
  return e?.literal?.stringValue;
}

function stringFieldVal(
  m: Map<string, Expression>,
  name: string,
): string | undefined {
  return m.get(name)?.literal?.stringValue;
}

const _fieldAliases: Record<string, string[]> = {
  left: ["value", "arg0", "string"],
  right: ["other", "arg1", "pattern", "separator"],
  value: ["arg0", "left"],
  message: ["value", "arg0"],
  separator: ["arg1", "right"],
  pattern: ["arg1", "right"],
  start: ["arg1"],
  end: ["arg2"],
};

class FieldMap extends Map<string, Expression> {
  override get(key: string): Expression | undefined {
    const v = super.get(key);
    if (v !== undefined) return v;
    const alts = _fieldAliases[key];
    if (alts) {
      for (const alt of alts) {
        const av = super.get(alt);
        if (av !== undefined) return av;
      }
    }
    return undefined;
  }
}

function fieldMap(fields: FieldValuePair[]): Map<string, Expression> {
  const m = new FieldMap();
  for (const f of fields) m.set(f.name, f.value);
  return m;
}

function memberShortName(qualified: string): string {
  const dot = qualified.lastIndexOf(".");
  return sanitize(dot < 0 ? qualified : qualified.slice(dot + 1));
}

function classTsName(qualified: string): string {
  const colon = qualified.lastIndexOf(":");
  return colon < 0 ? qualified : qualified.slice(colon + 1);
}

function isStd(module: string | undefined): boolean {
  return module === "std" || module === "dart_std" ||
    module === "std_collections" || module === "std_io" ||
    module === "std_convert" || module === "std_memory";
}

function containsBareKeyword(text: string, kw: string): boolean {
  return new RegExp(`(^|[^A-Za-z0-9_$])${kw}([^A-Za-z0-9_$]|$)`).test(text);
}

function translateInitString(raw: string): string {
  for (const kw of ["var", "final", "int", "double", "String", "bool", "num"]) {
    if (raw.length > kw.length + 1 && raw.slice(0, kw.length) === kw && raw[kw.length] === " ") {
      return `let ${raw.slice(kw.length + 1)}`;
    }
  }
  return `let ${raw}`;
}

function splitTopLevelCommas(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x3c /* < */ || c === 0x28 /* ( */ || c === 0x5b /* [ */) depth++;
    else if (c === 0x3e /* > */ || c === 0x29 /* ) */ || c === 0x5d /* ] */) depth--;
    else if (c === 0x2c /* , */ && depth === 0) {
      out.push(s.slice(start, i).trim());
      start = i + 1;
    }
  }
  if (start < s.length) out.push(s.slice(start).trim());
  return out;
}

function splitTopLevel(text: string, delim: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quote = 0;
  let start = 0;
  for (let i = 0; i <= text.length - delim.length; i++) {
    const c = text.charCodeAt(i);
    if (quote === 0) {
      if (c === 0x28 || c === 0x5b || c === 0x3c) depth++;
      else if (c === 0x29 || c === 0x5d || c === 0x3e) depth--;
      else if (c === 0x27 || c === 0x22) quote = c;
      else if (depth === 0 && text.slice(i, i + delim.length) === delim) {
        out.push(text.slice(start, i).trim());
        start = i + delim.length;
        i += delim.length - 1;
      }
    } else if (c === quote) {
      quote = 0;
    }
  }
  out.push(text.slice(start).trim());
  return out;
}

function patternLiteralText(pat: Expression): string | undefined {
  return pat.literal?.stringValue;
}

function patternToTsCondition(pat: string, subject: string): string {
  const trimmed = pat.trim();
  if (trimmed === "") return "true";
  if (trimmed === "_") return "true";
  const whenMatch = /^_\s+when\s+(.+)$/.exec(trimmed);
  if (whenMatch) return `(${whenMatch[1]})`;
  if (trimmed.includes("||")) {
    const parts = splitTopLevel(trimmed, "||");
    if (parts.length > 1) {
      return `(${parts.map((p) => patternToTsCondition(p, subject)).join(" || ")})`;
    }
  }
  if (/^-?\d+(\.\d+)?$/.test(trimmed)) return `(${subject} === ${trimmed})`;
  if (trimmed === "true" || trimmed === "false" || trimmed === "null") {
    return `(${subject} === ${trimmed})`;
  }
  if (
    (trimmed.startsWith("'") && trimmed.endsWith("'")) ||
    (trimmed.startsWith('"') && trimmed.endsWith('"'))
  ) {
    const inner = trimmed.slice(1, -1);
    return `(${subject} === ${jsStringLiteral(inner)})`;
  }
  return `(${subject} === (${trimmed}))`;
}

function jsStringLiteral(s: string): string {
  let out = "'";
  for (let i = 0; i < s.length; i++) {
    const cu = s.charCodeAt(i);
    if (cu === 0x27) out += "\\'";
    else if (cu === 0x5c) out += "\\\\";
    else if (cu === 0x0a) out += "\\n";
    else if (cu === 0x0d) out += "\\r";
    else if (cu === 0x09) out += "\\t";
    else if (cu >= 0x20 && cu < 0x7f) out += s[i];
    else out += "\\u" + cu.toString(16).padStart(4, "0");
  }
  return out + "'";
}

/** Translate a Dart field initializer string to TS, falling back to
 *  `defaultInitializer` when no explicit initializer is available.
 *
 *  Examples:
 *    `_Scope()`       → `new _Scope()`
 *    `<String, int>{}` → `{}`
 *    `''`              → `''`
 *    `null`            → `null`
 */
function dartInitializerToTs(
  dartInit: string | undefined,
  tsType: string,
  rawDartType?: string,
): string | undefined {
  if (dartInit == null || dartInit === "") {
    return defaultInitializer(tsType, rawDartType);
  }
  const s = dartInit.trim();
  // Already a JS-compatible literal: string, number, bool, null, []
  if (/^(?:null|true|false|'.*'|".*"|-?\d+(?:\.\d+)?|\[\])$/.test(s)) {
    return s;
  }
  // Dart `{}` can mean either an empty Map or an empty Set depending
  // on the declared type. Check the raw Dart type to disambiguate.
  if (s === "{}") {
    const rawTrimmed = (rawDartType ?? "").replace(/\?$/, "").trim();
    if (rawTrimmed.startsWith("Set<") || rawTrimmed === "Set") {
      return "new Set()";
    }
    return "{}";
  }
  // Dart typed empty map `<K, V>{}` → `{}`
  if (/^<[^>]+>\{\}$/.test(s)) return "{}";
  // Dart typed empty list `<T>[]` → `[]`
  if (/^<[^>]+>\[\]$/.test(s)) return "[]";
  // Known Dart library constructors that need special TS translation.
  if (s === "math.Random()" || s === "Random()") {
    // Dart's math.Random → a shim that uses Math.random().
    return "({ nextInt(max: number) { return Math.floor(Math.random() * max); }, nextDouble() { return Math.random(); } })";
  }
  // Constructor call: `ClassName()` or `ClassName(args)` → `new ClassName(args)`
  // Matches: `_Scope()`, `Set([])`, `Map.from(other)`, etc.
  const ctorMatch = s.match(/^([A-Z_][A-Za-z0-9_]*)(\(.*\))$/);
  if (ctorMatch) {
    return `new ${ctorMatch[1]}${ctorMatch[2]}`;
  }
  // Qualified constructor: `pkg.ClassName()` → `new pkg.ClassName()`
  const qualCtorMatch = s.match(/^([a-zA-Z_][a-zA-Z0-9_.]*[A-Z][A-Za-z0-9_]*)(\(.*\))$/);
  if (qualCtorMatch) {
    return `new ${qualCtorMatch[1]}${qualCtorMatch[2]}`;
  }
  // Fall back to default type-based initializer
  return defaultInitializer(tsType, rawDartType);
}

/** Return a default initializer expression for a TS type string so
 *  class fields don't start as `undefined`. Dart fields are implicitly
 *  initialized (Map→{}, List→[], bool→false, etc.); TS fields are not.
 *
 *  Also accepts the raw Dart type string for cases where the TS mapper
 *  lost precision (e.g. `Map<K, V Function(X)>` → `any` because the
 *  function type triggered the early-return). Checking the Dart type
 *  catches these.
 */
function defaultInitializer(type: string, rawDartType?: string): string | undefined {
  const t = type.trim();
  const raw = (rawDartType ?? "").trim();
  // Nullable types (ending in ?) default to null, not the type's
  // default value. Dart's `Set<String>? _allowlist = null` must stay
  // null, not become `new Set()` which breaks null-guard patterns.
  // Nullable types default to null EXCEPT Maps — null-aware access
  // (?.[] / ?.) isn't in the compiled output and null Maps crash
  // on bracket access. Empty {} is safe. Sets and Lists stay null
  // because code like `if (allowlist != null)` uses null to mean
  // "not active" and an empty collection would incorrectly activate
  // the filter.
  if (raw.endsWith("?")) {
    const inner = raw.slice(0, -1).trim();
    if (inner.startsWith("Map<") || inner === "Map") return "{}";
    return "null";
  }
  const d = raw.replace(/\?$/, "");
  // Check both mapped TS type and raw Dart type.
  // Use plain {} instead of new Map() — JS Map doesn't support
  // bracket access (m['k'] = v), but the compiled engine uses it
  // throughout for dispatch tables and caches.
  if (t.startsWith("Map<") || d.startsWith("Map<") || d === "Map") return "{}";
  if (t.startsWith("Array<") || t === "Array" || d.startsWith("List<") || d === "List") return "[]";
  if (t.startsWith("Set<") || t === "Set" || d.startsWith("Set<") || d === "Set") return "new Set()";
  if (t === "number" || d === "int" || d === "double" || d === "num") return "0";
  if (t === "boolean" || d === "bool") return "false";
  if (t === "string" || d === "String") return "''";
  return undefined;
}

/** Unwrap a lambda-wrapped expression: `{lambda: {body: X}}` → `X`.
 *  The TS encoder wraps for/while condition/update/body in lambdas
 *  (matching Ball's convention), but the compiler expects bare
 *  expressions. This helper strips the wrapper when present. */
function unwrapLambda(e: Expression): Expression {
  if (e.lambda && e.lambda.body) return e.lambda.body;
  return e;
}

function sanitize(name: string): string {
  let out = name;
  const colon = out.indexOf(":");
  if (colon >= 0) out = out.slice(colon + 1);
  // Dart operator names (operator []=, operator [], operator ==, etc.) are
  // valid Ball IR names but invalid TS identifiers — rewrite them to a
  // JS-safe form so the emitted class compiles.
  const operatorMap: Record<string, string> = {
    "[]=": "__op_index_assign",
    "[]": "__op_index",
    "==": "__op_eq",
    "!=": "__op_ne",
    "<": "__op_lt",
    "<=": "__op_le",
    ">": "__op_gt",
    ">=": "__op_ge",
    "+": "__op_add",
    "-": "__op_sub",
    "*": "__op_mul",
    "/": "__op_div",
    "~/": "__op_int_div",
    "%": "__op_mod",
    "&": "__op_and",
    "|": "__op_or",
    "^": "__op_xor",
    "<<": "__op_shl",
    ">>": "__op_shr",
    ">>>": "__op_shr_unsigned",
    "~": "__op_bnot",
    "unary-": "__op_neg",
  };
  if (Object.prototype.hasOwnProperty.call(operatorMap, out)) {
    return operatorMap[out];
  }
  out = out.replace(/[.-]/g, "_");
  const reserved = new Set([
    "class", "function", "return", "new", "delete", "var", "let", "const",
    "typeof", "instanceof", "interface", "enum", "export", "import", "yield",
    "package", "private", "protected", "public", "static", "super", "this",
    "true", "false", "null", "undefined",
  ]);
  if (reserved.has(out)) out += "_";
  return out;
}

/** Convenience: compile a Program directly. */
export function compile(program: Program, options?: CompileOptions): string {
  return new BallCompiler(program).compile(options);
}
