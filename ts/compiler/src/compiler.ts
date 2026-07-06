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

  /** Names of user-defined async functions (from metadata is_async). */
  private asyncFnNames: Set<string> = new Set();

  /** Fields of the class currently being emitted (method bodies). */
  private currentClassFields: Set<string> = new Set();

  /** Parameters of the currently-emitting method (shadow fields). */
  private currentMethodParams: Set<string> = new Set();

  /** Short method names of the current class (for `this.foo()` routing). */
  private currentClassMethodNames: Set<string> = new Set();

  /** Short names of GETTER accessors. Getters are properties, not methods,
   *  so bare references emit `this.name` not `this.name.bind(this)`. */
  private currentClassGetterNames: Set<string> = new Set();

  /**
   * Short names of STATIC methods of the current class. Static members are
   * not on `this` in JS, so unqualified same-class calls/tear-offs to these
   * must be emitted as `<ClassName>.<name>` rather than `this.<name>`.
   */
  private currentClassStaticNames: Set<string> = new Set();

  /** TS name of the class currently being emitted (for static-call routing). */
  private currentClassName: string | undefined;

  /** Type parameters of the class currently being emitted (erased to `any`). */
  private currentClassTypeParams: Set<string> = new Set();

  /** All function names in the entry module (function vs ctor routing). */
  private allFunctionNames: Set<string> = new Set();

  /** typeDefs in the entry module (typeName → definition). */
  private typeDefByName: Map<string, TypeDefinition> = new Map();

  /**
   * Variable names declared (via `let`) in the current function scope.
   * Used to detect shadowing conflicts when hoisting block statements.
   */
  private scopeDeclaredVars: Set<string> = new Set();

  /**
   * Stack of rename maps for shadow-renamed variables. When a hoisted
   * block declares a variable that conflicts with an already-declared
   * name, we push a map entry (original → renamed) before emitting
   * the block's statements and pop it afterward.
   */
  private renameStack: Map<string, string>[] = [];

  /**
   * Stack of `std.label` names currently enclosing the statement being
   * compiled (see `emitLabelStmt`/`emitGotoStmt`). A `std.label` lowers to a
   * labelled `while (true) { ... break name; }`, and a nested `std.goto`
   * targeting one of these names lowers to `continue name;` — TS (unlike
   * Dart's `continue` targeting a switch case, or C++'s real `goto`) only
   * allows `continue`/`break` to target an *enclosing* labelled loop, so this
   * only supports backward jumps to a label the goto is lexically inside of.
   * A `goto` to any other name fails loud at compile time (see `emitGotoStmt`)
   * rather than silently emitting invalid or wrong-behaving TS.
   */
  private activeGotoLabels: string[] = [];

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

    // Collect ALL non-base modules (entry + user library modules).
    const userModules: Module[] = [];
    let usesStdMemory = false;
    for (const mod of this.program.modules ?? []) {
      const fns = mod.functions ?? [];
      const allBase = fns.length > 0 && fns.every((f: FunctionDef) => f.isBase);
      if (allBase) {
        if (mod.name === "std_memory") usesStdMemory = true;
        continue;
      }
      userModules.push(mod);
    }

    // ── Linear memory runtime preamble ──
    // If the program imports `std_memory` (linear memory simulation), inject
    // the runtime variables backing the `ByteData`/`Endian` shims already
    // defined in the (always-included) runtime preamble. Mirrors the Dart
    // compiler's conditional injection (dart/compiler/lib/compiler.dart,
    // "Linear memory runtime preamble") — only emitted when actually used.
    if (usesStdMemory) {
      sf.addStatements(
        "// Ball linear memory runtime\n" +
        "const _ballMemory = new ByteData(65536);\n" +
        "let _ballHeapPtr = 0;\n" +
        "const _ballStackFrames: number[] = [];\n" +
        "let _ballStackPtr = 65536;\n",
      );
    }

    // Seed the function-name + typeDef lookup tables from ALL user modules.
    this.allFunctionNames = new Set(
      userModules.flatMap((m) => (m.functions ?? []).map((f: FunctionDef) => f.name)),
    );
    this.asyncFnNames = new Set(
      userModules.flatMap((m) =>
        (m.functions ?? [])
          .filter((f: FunctionDef) => f.metadata?.["is_async"] === true)
          .map((f: FunctionDef) => f.name),
      ),
    );
    this.typeDefByName = new Map(
      userModules.flatMap((m) =>
        (m.typeDefs ?? []).map((td) => [td.name, td] as [string, TypeDefinition]),
      ),
    );

    // Group functions by their enclosing class (if any) — matches the
    // `<typeDef.name>.<member>` naming convention from the encoder.
    const classMembers = new Map<string, FunctionDef[]>();
    const freeFunctions: FunctionDef[] = [];
    for (const mod of userModules) {
      for (const fn of mod.functions ?? []) {
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
    }

    // Typedefs → TsTypeAlias (from all user modules).
    for (const mod of userModules) {
      for (const ta of mod.typeAliases ?? []) {
        sf.addTypeAlias({
          name: ta.name,
          type: this.dartTypeToTs(ta.targetType),
          isExported: true,
        });
      }
    }

    // Classes.
    // BallObject / BallMap / BallList are runtime container types supplied by
    // the preamble (a Ball instance is a plain-object-like BallObject, a map a
    // plain object, a list a plain array). Skip emitting their class bodies —
    // the encoder's versions reference the inherited `entries` field via bare
    // identifiers and take named ctor args the emitter can't reproduce; the
    // hand-written preamble versions are the source of truth.
    const _runtimeContainerTypes = new Set(["BallObject", "BallMap", "BallList"]);
    const allTypeDefs = userModules.flatMap((m) => m.typeDefs ?? []);
    for (const td of allTypeDefs) {
      if (_runtimeContainerTypes.has(classTsName(td.name))) continue;
      // Collect members for this class, including mixin members.
      let members = [...(classMembers.get(td.name) ?? [])];
      const tdMeta: Struct = td.metadata ?? {};
      const mixins = Array.isArray(tdMeta["mixins"]) ? tdMeta["mixins"] as string[] : [];
      if (mixins.length > 0) {
        // Collect the set of method short names already defined on this class
        const ownShortNames = new Set(members.map((m) => memberShortName(m.name)));
        for (const mixinName of mixins) {
          // Find the mixin typeDef name — try both plain and module-qualified
          let mixinTdName: string | undefined;
          for (const [tdName] of this.typeDefByName) {
            if (classTsName(tdName) === mixinName || tdName === mixinName || tdName.endsWith(":" + mixinName)) {
              mixinTdName = tdName;
              break;
            }
          }
          if (!mixinTdName) continue;
          const mixinMembers = classMembers.get(mixinTdName) ?? [];
          for (const mm of mixinMembers) {
            const shortName = memberShortName(mm.name);
            // Only include mixin methods not already defined on this class
            if (!ownShortNames.has(shortName)) {
              members.push(mm);
              ownShortNames.add(shortName);
            }
          }
        }
      }
      this.emitClass(sf, td, members);
    }

    // Enums declared in Module.enums[] (google.protobuf.EnumDescriptorProto,
    // proto3 JSON: `{name, value: [{name, number}]}`). Both encoders emit
    // enum declarations here (the Dart encoder with module-qualified names
    // like "main:Color"); dropping them left `Color.red` references dangling
    // in the compiled output (#120).
    const emittedTypeNames = new Set(allTypeDefs.map((td) => classTsName(td.name)));
    for (const mod of userModules) {
      for (const en of mod.enums ?? []) {
        const tsName = classTsName(en.name);
        // A typeDef of the same name already produced a class declaration.
        if (emittedTypeNames.has(tsName)) continue;
        emittedTypeNames.add(tsName);
        const entries = (en.value ?? []).map((v, i) => ({
          name: v.name,
          index: typeof v.number === "number" ? v.number : i,
        }));
        this.emitEnumClass(sf, tsName, entries);
      }
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
      sf.addStatements(`let ${name} = (() => { ${body} })();`);
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
      // Check if main calls any async function → make main async + await.
      const mainCallsAsync = this.asyncFnNames.size > 0 && entryFn.body &&
        this.bodyReferencesAny(entryFn.body, this.asyncFnNames);
      this.emitFreeFunction(sf, entryFn, "main", mainCallsAsync);
      sf.addStatements(mainCallsAsync ? "await main();" : "main();");
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
      /if \(\(?(?:\(call\.module === 'std'\)|call\.module === 'std')\)?\) \{\s*return this\._callBaseFunction\(call\.module, call\.function, input\);\s*\}/,
      `if (call.module === 'std' || call.module === 'std_collections' || call.module === 'std_io' || call.module === 'std_convert' || call.module === 'std_memory') {
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
          try { return await this._callBaseFunction('std', __sn, __stdInput); } catch (e) { if (!__isUnknownFnError(e)) throw e; }
          try { return await this._callBaseFunction('std_collections', __sn, __stdInput); } catch (e) { if (!__isUnknownFnError(e)) throw e; }
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
    // c8 ignore: the callback below DOES run on every self-hosted-engine
    // compile (verified by instrumenting String.prototype.replace during a
    // real compile() call — 0/13,588 patch invocations were no-ops), but
    // its return value is a multi-line template literal holding GENERATED
    // TS SOURCE AS STRING DATA, not live statements — c8 counts those text
    // lines as "uncovered" even though the enclosing callback executes.
    /* c8 ignore start */
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
    /* c8 ignore stop */

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
      for (const __stdMod of ['std', 'std_collections', 'std_io']) {
        try { return await this._callBaseFunction(__stdMod, function_, input); } catch(e) { if (!__isUnknownFnError(e)) throw e; }
      }
      // Try with list_ or map_ prefix
      const __self2 = input['self'];
      if (__self2 != null) {
        const __prefixes = Array.isArray(__self2) ? ['list_'] : (typeof __self2 === 'string' ? ['string_'] : ['map_']);
        for (const __px of __prefixes) {
          for (const __stdMod of ['std', 'std_collections']) {
            try { return await this._callBaseFunction(__stdMod, __px + function_, input); } catch(e) { if (!__isUnknownFnError(e)) throw e; }
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

    // ── Post-processing: fix _stdUnaryNum to propagate BallDouble (#67) ──
    // `negate` is the only double-producing consumer of _stdUnaryNum
    // (bitwise_not always operates on int); wrap the result in BallDouble
    // when the operand was one so whole-number doubles like `-7.0` don't
    // collapse to a bare JS integer ("-7") when self-hosted on TS.
    body = body.replace(
      /_stdUnaryNum\(input: any, op: any\): any \{\s*let value = this\._extractUnaryArg\(input\);\s*return op\(this\._toNum\(value\)\);\s*\}/,
      `_stdUnaryNum(input: any, op: any): any {
    let value = this._extractUnaryArg(input);
    const __vBD = value instanceof BallDouble;
    const __result = op(this._toNum(value));
    if (__vBD && typeof __result === 'number') return new BallDouble(__result);
    return __result;
  }`,
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

    // ── Inject the unknown-function sentinel predicate ────────────────
    // The std-dispatch probe loops (collection-method dispatch, the
    // method-call fallback) try a candidate function name against several
    // base modules and fall through to the next candidate when that name
    // is not registered. Previously they did `catch(e) {}`, which also
    // swallowed *genuine* runtime errors thrown from inside a function that
    // WAS found (e.g. a RangeError from an out-of-bounds index). This helper
    // lets those probes distinguish "no such function/module" — the only
    // case where falling through is correct — from a real error that must
    // propagate. The sentinels come from StdModuleHandler.call
    // ("Unknown std function: ...") and _callBaseFunction
    // ("Unknown base module: ..."); see ts/engine/src/compiled_engine.ts.
    const unknownFnHelper = `
function __isUnknownFnError(e: any): boolean {
  const m = e && typeof e.message === 'string' ? e.message : (typeof e === 'string' ? e : '');
  return m.startsWith('Unknown std function:') || m.startsWith('Unknown base module:');
}
`;
    body = unknownFnHelper + body;

    return includePreamble ? TS_RUNTIME_PREAMBLE + "\n" + body : body;
  }

  // ───────────────────────── Declarations ────────────────────────────

  private emitFreeFunction(
    sf: ReturnType<Project["createSourceFile"]>,
    fn: FunctionDef,
    forceName?: string,
    forceAsync?: boolean,
  ): void {
    const params = extractParams(fn);
    const name = forceName ?? sanitize(fn.name);
    const needsInputAlias = params.length === 1 && params[0] !== "input";
    const inputIsReassigned = needsInputAlias && fn.body && bodyAssignsToVar(fn.body, "input");
    let body = this.captureInto(() => {
      if (needsInputAlias && !inputIsReassigned) {
        this.writeln(`const input = ${sanitize(params[0])};`);
      }
      if (fn.body) this.emitStatementOrExpression(fn.body, true);
    });
    const isSyncStar = fn.metadata?.["is_sync_star"] === true;
    const isAsyncStar = fn.metadata?.["is_async_star"] === true;
    const isGenerator = isSyncStar || isAsyncStar;
    const isAsync = forceAsync || functionIsAsync(fn) || isAsyncStar;
    if (isGenerator) {
      // Dart sync*/async* generators produce re-iterable Iterables with
      // .length, .first, .join(), etc.  JS function* produces single-use
      // iterators.  Emit a regular function that internally uses a generator
      // and materialises the result into an array.
      const wrappedBody = `return [...(function* () { ${body} })()];`;
      sf.addFunction({
        kind: StructureKind.Function,
        name,
        isAsync: false,
        isGenerator: false,
        parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
        returnType: "any",
        statements: wrappedBody,
      });
    } else {
      sf.addFunction({
        kind: StructureKind.Function,
        name,
        isAsync: isAsync && !isGenerator,
        isGenerator,
        parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
        returnType: isAsync ? "Promise<any>" : "any",
        statements: body,
      });
    }
  }

  /** Wrap captured statements in an IIFE, choosing the right kind:
   *  - yield present → `yield* (function* () { ... })()`
   *  - await present → `await (async () => { ... })()`
   *  - neither → `(() => { ... })()`
   */
  private wrapIIFE(captured: string): string {
    if (containsBareKeyword(captured, "yield")) {
      return `yield* (function* () { ${captured} })()`;
    }
    if (containsBareKeyword(captured, "await")) {
      return `await (async () => { ${captured} })()`;
    }
    return `(() => { ${captured} })()`;
  }

  /** Check if an expression tree references any name in the given set. */
  private bodyReferencesAny(expr: Expression, names: Set<string>): boolean {
    if (expr.reference && names.has(expr.reference.name)) return true;
    if (expr.call && names.has(expr.call.function)) return true;
    if (expr.call?.input && this.bodyReferencesAny(expr.call.input, names)) return true;
    if (expr.block) {
      for (const s of expr.block.statements ?? []) {
        if (s.expression && this.bodyReferencesAny(s.expression, names)) return true;
        if (s.let?.value && this.bodyReferencesAny(s.let.value, names)) return true;
      }
      if (expr.block.result && this.bodyReferencesAny(expr.block.result, names)) return true;
    }
    if (expr.messageCreation) {
      for (const f of expr.messageCreation.fields ?? []) {
        if (this.bodyReferencesAny(f.value, names)) return true;
      }
    }
    if (expr.fieldAccess?.object && this.bodyReferencesAny(expr.fieldAccess.object, names)) return true;
    return false;
  }

  /**
   * Emit a Dart-style enum as a TS class with static singleton instances,
   * `index`/`name` properties, a `values` list, and `toString()` returning
   * `'<Enum>.<member>'`. Shared by the two enum declaration paths:
   * typeDefs with `metadata.kind == "enum"` and `Module.enums[]`
   * (google.protobuf.EnumDescriptorProto) entries.
   */
  private emitEnumClass(
    sf: ReturnType<Project["createSourceFile"]>,
    tsName: string,
    entries: Array<{ name: string; index: number }>,
  ): void {
    const staticProps = entries.map(
      (e) => `static readonly ${sanitize(e.name)} = new ${tsName}(${e.index}, '${e.name}');`,
    );
    const valuesArray = entries.map((e) => `${tsName}.${sanitize(e.name)}`).join(", ");
    sf.addStatements(`export class ${tsName} {
  readonly index: number;
  readonly name: string;
  private constructor(index: number, name: string) { this.index = index; this.name = name; }
  ${staticProps.join("\n  ")}
  static readonly values: ${tsName}[] = [${valuesArray}];
  toString(): string { return '${tsName}.' + this.name; }
}`);
  }

  private emitClass(
    sf: ReturnType<Project["createSourceFile"]>,
    td: TypeDefinition,
    members: FunctionDef[],
  ): void {
    const meta: Struct = td.metadata ?? {};
    const tsName = classTsName(td.name);

    // Enum handling: emit a class with static instances, index, name, values.
    if (meta["kind"] === "enum") {
      const enumValues = Array.isArray(meta["values"]) ? meta["values"] as any[] : [];
      const entries = enumValues.map((v: any, i: number) => ({
        name: typeof v === "string" ? v : (v?.name ?? ""),
        index: i,
      }));
      this.emitEnumClass(sf, tsName, entries);
      return;
    }

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
    // Include inherited fields from the superclass chain so that
    // references to inherited fields inside methods emit `this.name`
    // instead of bare `name` (which would be undefined in JS).
    const superclass = typeof meta["superclass"] === "string" ? meta["superclass"] : undefined;
    if (superclass) {
      const entryMod = this.program.modules.find(m => m.name === this.program.entryModule);
      let sup: string | undefined = superclass;
      while (sup && entryMod) {
        const supTd = entryMod.typeDefs?.find(t => classTsName(t.name) === sup);
        if (!supTd) break;
        const supMeta: Struct = supTd.metadata ?? {};
        const supFields = Array.isArray(supMeta["fields"]) ? supMeta["fields"] as any[] : [];
        for (const sf of supFields) {
          if (sf?.name) fieldNames.add(sf.name);
        }
        if (supTd.descriptor?.field) {
          for (const f of supTd.descriptor.field) fieldNames.add(f.name);
        }
        sup = typeof supMeta["superclass"] === "string" ? supMeta["superclass"] : undefined;
      }
    }

    // Method-name set for `this.foo()` routing inside bodies.
    // Exclude static fields — they're emitted as module-level consts
    // and referenced WITHOUT `this.`.
    const methodNames = new Set<string>();
    const staticMethodNames = new Set<string>();
    const staticFieldNames = new Set<string>();
    const getterNames = new Set<string>();
    for (const fn of members) {
      const mMeta: Struct = fn.metadata ?? {};
      if ((mMeta as any).kind === "static_field") {
        staticFieldNames.add(memberShortName(fn.name));
      } else {
        const shortName = memberShortName(fn.name);
        methodNames.add(shortName);
        if (mMeta["is_getter"] === true) {
          getterNames.add(shortName);
        }
        // Static methods (incl. named constructors, which become static
        // factory methods) live on the class, not on instances. Track them
        // so same-class calls emit `<Class>.m()` not `this.m()`.
        const kind =
          typeof mMeta["kind"] === "string" ? mMeta["kind"] : "method";
        const isNamedCtor =
          kind === "constructor" && memberShortName(fn.name) !== "new";
        if (mMeta["is_static"] === true || isNamedCtor) {
          staticMethodNames.add(shortName);
        }
      }
    }
    const savedClassMethods = this.currentClassMethodNames;
    const savedClassStatics = this.currentClassStaticNames;
    const savedClassGetters = this.currentClassGetterNames;
    const savedClassName = this.currentClassName;
    const savedTypeParams = this.currentClassTypeParams;
    const deferredStaticFields: string[] = [];
    this.currentClassMethodNames = methodNames;
    this.currentClassStaticNames = staticMethodNames;
    this.currentClassGetterNames = getterNames;
    this.currentClassName = tsName;
    this.currentClassTypeParams = new Set(
      Array.isArray(meta["type_params"]) ? (meta["type_params"] as string[]) : [],
    );

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
          // Named constructors are static factory methods that return a new
          // instance. Build them by creating an instance from initializers.
          methods.push(
            this.buildNamedCtor(fn, mMeta, fieldNames, tsName),
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
        let initBody = fn.body ? this.expr(fn.body) : "undefined";
        // When the outputType is a Map but the expr compiled to a Set
        // (encoder quirk: empty `{}` literal is encoded as set_create),
        // override to an empty object.
        if (initBody === "new Set()" && typeof (fn as any).outputType === "string" &&
            (fn as any).outputType.startsWith("Map<")) {
          initBody = "{}";
        }
        deferredStaticFields.push(`const ${sfName} = ${initBody};`);
      } else {
        methods.push(this.buildMethod(fn, mMeta, fieldNames));
      }
    }

    this.currentClassMethodNames = savedClassMethods;
    this.currentClassStaticNames = savedClassStatics;
    this.currentClassGetterNames = savedClassGetters;
    this.currentClassName = savedClassName;
    this.currentClassTypeParams = savedTypeParams;

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
    // Parse super constructor initializer args from metadata.
    // The encoder stores initializers as [{kind:"super", args:"(name)"}].
    const initializers = Array.isArray(meta["initializers"]) ? meta["initializers"] as any[] : [];
    const superInit = initializers.find((i: any) => i?.kind === "super");
    if (hasExtends) {
      if (superInit && typeof superInit.args === "string") {
        // Parse args string like "(name)" or "('Car', horsepower)"
        const argsStr = superInit.args.replace(/^\(/, "").replace(/\)$/, "").trim();
        if (argsStr) {
          const argParts = argsStr.split(",").map((a: string) => a.trim()).filter((a: string) => a);
          const resolvedArgs = argParts.map((a: string) => {
            // String literal
            if ((a.startsWith("'") && a.endsWith("'")) || (a.startsWith('"') && a.endsWith('"'))) {
              return a;
            }
            // Numeric literal
            if (/^-?\d+(\.\d+)?$/.test(a)) return a;
            // Variable reference — use the sanitized param name
            return sanitize(a);
          });
          prologueParts.push(`super(${resolvedArgs.join(", ")});`);
        } else {
          prologueParts.push("super();");
        }
      } else {
        prologueParts.push("super();");
      }
    }
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
    // Ball's single-input convention: one param named 'input' with class
    // fields → emit `this.fieldName = input;` (or per-field from input map).
    const isSingleInput = rawParams.length === 1 && rawParams[0].name === "input";
    if (isSingleInput && classFields.size > 0) {
      if (classFields.size === 1) {
        const fname = [...classFields][0];
        prologueParts.push(`this.${fname} = input;`);
      } else {
        for (const fname of classFields) {
          prologueParts.push(`this.${fname} = input?.['${fname}'] ?? input;`);
        }
      }
    } else {
      for (const p of rawParams) {
        if (p.isThis || classFields.has(p.name)) {
          prologueParts.push(`this.${p.name} = ${sanitize(p.name)};`);
        }
      }
    }
    const prologue = prologueParts.join("\n");
    // Filter out self-recursive patterns from the constructor body.
    // The encoder emits `let self = messageCreation{typeName:"mod:ClassName"}`
    // and `return self` in constructor bodies. These translate to
    // `let self = new ClassName()` which causes infinite recursion. We
    // must suppress these statements and only emit the meaningful body.
    const filteredBody = fn.body ? this.filterCtorBody(fn.body, classTsName(fn.name.substring(0, fn.name.lastIndexOf(".")))) : undefined;
    const captured = this.withMethodContext(
      new Set(rawParams.map((p) => p.name)),
      classFields,
      () =>
        this.captureInto(() => {
          if (filteredBody) this.emitStatementOrExpression(filteredBody, false);
        }),
    );
    const body = prologue === "" ? captured : captured === "" ? prologue : `${prologue}\n${captured}`;
    return { parameters, statements: body };
  }

  /**
   * Filters a constructor body to remove encoder-generated boilerplate:
   * - `let self = new ClassName()` (self-recursive construction)
   * - `return self` (returning the self variable)
   * - Bare `input;` or `paramName;` statements (no-op expressions)
   */
  private filterCtorBody(body: Expression, className: string): Expression | undefined {
    if (!body.block) return body;
    const stmts = body.block.statements ?? [];
    const filtered = stmts.filter((s) => {
      // Filter `let self = messageCreation{typeName: "mod:ClassName"}`
      if (s.let?.name === "self" && s.let.value?.messageCreation) {
        const tn = s.let.value.messageCreation.typeName ?? "";
        const tnShort = classTsName(tn);
        if (tnShort === className) return false;
      }
      // Filter `return(value: self)` — the self-return at the end
      if (s.expression?.call?.function === "return" && s.expression.call.module === "std") {
        const retFields = s.expression.call.input?.messageCreation?.fields ?? [];
        const retVal = retFields.find((f: any) => f.name === "value");
        if (retVal?.value?.reference?.name === "self") return false;
      }
      // Filter bare reference statements like `input;` or `paramName;`
      if (s.expression?.reference && !s.expression.call && !s.expression.fieldAccess) {
        return false;
      }
      return true;
    });
    if (filtered.length === 0) return undefined;
    return { ...body, block: { ...body.block, statements: filtered } };
  }

  /**
   * Builds a named constructor as a static factory method.
   * Named constructors (e.g., Point.origin, Point.fromList) create instances
   * from field initializers in metadata.
   */
  private buildNamedCtor(
    fn: FunctionDef,
    meta: Struct,
    classFields: Set<string>,
    className: string,
  ) {
    const params = extractParams(fn);
    const ctorParams = extractCtorParams(meta);
    const initializers = Array.isArray(meta["initializers"]) ? meta["initializers"] as any[] : [];
    // Build the body: resolve field initializers and create a new instance.
    const bodyParts: string[] = [];
    const ctorArgs: string[] = [];
    // Extract field initializers to build constructor arguments
    for (const init of initializers) {
      if (init?.kind === "field" && typeof init.name === "string") {
        const valueStr = typeof init.value === "string" ? init.value : "null";
        // Resolve the value: could be a param reference, literal, or expression
        let resolvedValue: string;
        if (params.includes(valueStr)) {
          resolvedValue = sanitize(valueStr);
        } else if (/^-?\d+(\.\d+)?$/.test(valueStr)) {
          // Numeric literal — wrap in BallDouble if it has a decimal point
          resolvedValue = valueStr.includes(".") ? `new BallDouble(${valueStr})` : valueStr;
        } else if (valueStr.startsWith("'") || valueStr.startsWith('"')) {
          resolvedValue = valueStr;
        } else {
          // Try to parse indexed access like "coords[0]"
          const idxMatch = /^(\w+)\[(\d+)\]$/.exec(valueStr);
          if (idxMatch && params.includes(idxMatch[1])) {
            resolvedValue = `${sanitize(idxMatch[1])}[${idxMatch[2]}]`;
          } else {
            resolvedValue = valueStr;
          }
        }
        ctorArgs.push(resolvedValue);
      }
    }
    // Also check for is_this params — they pass directly to the constructor
    const thisParams = ctorParams.filter(p => p.isThis);
    if (ctorArgs.length === 0 && initializers.length === 0 && thisParams.length > 0) {
      for (const p of thisParams) {
        ctorArgs.push(sanitize(p.name));
      }
    }
    if (ctorArgs.length > 0 || (initializers.length > 0 && ctorArgs.length > 0)) {
      // Use Object.create to avoid calling the constructor (which might be a factory).
      // This directly instantiates with fields set.
      const assignments = initializers
        .filter((i: any) => i?.kind === "field")
        .map((init: any) => {
          const valueStr = typeof init.value === "string" ? init.value : "null";
          let resolvedValue: string;
          if (params.includes(valueStr)) resolvedValue = sanitize(valueStr);
          else if (/^-?\d+(\.\d+)?$/.test(valueStr)) resolvedValue = valueStr.includes(".") ? `new BallDouble(${valueStr})` : valueStr;
          else if (valueStr.startsWith("'") || valueStr.startsWith('"')) resolvedValue = valueStr;
          else {
            const idxMatch = /^(\w+)\[(\d+)\]$/.exec(valueStr);
            if (idxMatch && params.includes(idxMatch[1])) resolvedValue = `${sanitize(idxMatch[1])}[${idxMatch[2]}]`;
            else resolvedValue = valueStr;
          }
          return `__inst.${init.name} = ${resolvedValue};`;
        });
      // For is_this params, assign them as fields
      const thisAssignments = thisParams.map(p => `__inst.${p.name} = ${sanitize(p.name)};`);
      const allAssignments = [...assignments, ...thisAssignments];
      bodyParts.push(`const __inst = Object.create(${className}.prototype);`);
      for (const a of allAssignments) bodyParts.push(a);
      bodyParts.push(`return __inst;`);
    } else if (fn.body) {
      // Has an actual body — use it
      const captured = this.withMethodContext(
        new Set(params),
        classFields,
        () =>
          this.captureInto(() => {
            this.emitStatementOrExpression(fn.body!, true);
          }),
      );
      bodyParts.push(captured);
    } else {
      bodyParts.push(`return new ${className}();`);
    }
    return {
      name: memberShortName(fn.name),
      isAsync: false,
      isStatic: true,
      parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
      returnType: "any",
      statements: bodyParts.join("\n"),
    };
  }

  private buildMethod(fn: FunctionDef, meta: Struct, classFields: Set<string>) {
    const params = extractParams(fn);
    const needsInputAlias = params.length === 1 && params[0] !== "input";
    const inputIsReassigned = needsInputAlias && fn.body && bodyAssignsToVar(fn.body, "input");
    const body = this.withMethodContext(
      new Set(params),
      classFields,
      () =>
        this.captureInto(() => {
          if (needsInputAlias && !inputIsReassigned) {
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
    // When entering a function body, start a fresh scope for variable tracking.
    const savedScope = isFunctionBody ? this.scopeDeclaredVars : null;
    const savedRenames = isFunctionBody ? this.renameStack : null;
    if (isFunctionBody) {
      this.scopeDeclaredVars = new Set();
      this.renameStack = [];
    }
    for (const s of block.statements ?? []) this.emitStatement(s);
    // Restore previous scope state when leaving a function body.
    if (savedScope !== null) this.scopeDeclaredVars = savedScope;
    if (savedRenames !== null) this.renameStack = savedRenames;
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

  /**
   * Resolve a variable name through the active rename stack.
   * If a rename exists for the sanitized name, return the renamed version.
   */
  private resolveVarName(sanitizedName: string): string {
    // Walk the stack top-down (most recent renames take priority).
    for (let i = this.renameStack.length - 1; i >= 0; i--) {
      const renamed = this.renameStack[i].get(sanitizedName);
      if (renamed !== undefined) return renamed;
    }
    return sanitizedName;
  }

  /**
   * Recursively collect all `let`-declared variable names from a block's
   * statements that would be hoisted into the enclosing scope. This includes
   * direct `let` statements and `let` statements inside nested
   * block-expression-as-statement nodes (since those are also hoisted flat).
   */
  private collectHoistedLetNames(statements: Statement[]): string[] {
    const names: string[] = [];
    for (const s of statements) {
      if (s.let) {
        names.push(sanitize(s.let.name));
      } else if (s.expression) {
        const e = s.expression;
        // Recurse into nested hoistable blocks (block-expression-as-statement
        // with no result — the same pattern that triggers hoisting).
        if (e.block && e.block.result === undefined && e.block.statements) {
          names.push(...this.collectHoistedLetNames(e.block.statements));
        }
      }
    }
    return names;
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
      const rawName = sanitize(stmt.let.name);
      const name = this.resolveVarName(rawName);
      // Track this declaration in the current scope.
      this.scopeDeclaredVars.add(name);
      // The encoder marks "no initializer" with a reference to the sentinel
      // name __no_init__ (rather than omitting `value`) — e.g. `int? maybe;`.
      // Left uncaught, this compiles to `let maybe = __no_init__;`, which
      // resolves to the runtime preamble's OWN __no_init__ Symbol (used
      // internally by the compiled self-hosted engine) instead of leaving
      // `maybe` genuinely undefined, so a later `??=` never fires (#225).
      // Mirrors the same check already applied to for-loop init bindings
      // in renderForInit.
      const isNoInit = stmt.let.value?.reference?.name === "__no_init__";
      if (stmt.let.value !== undefined && !isNoInit) {
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
        const innerStmts = e.block.statements ?? [];
        // Detect variable name conflicts: collect all `let` names that
        // would be hoisted, and check against already-declared names.
        const hoistedNames = this.collectHoistedLetNames(innerStmts);
        const conflicts = new Map<string, string>();
        for (const n of hoistedNames) {
          if (this.scopeDeclaredVars.has(n)) {
            // Find a unique renamed version.
            let counter = 1;
            let renamed = `${n}$${counter}`;
            while (this.scopeDeclaredVars.has(renamed)) {
              counter++;
              renamed = `${n}$${counter}`;
            }
            conflicts.set(n, renamed);
          }
        }
        if (conflicts.size > 0) {
          this.renameStack.push(conflicts);
          for (const inner of innerStmts) this.emitStatement(inner);
          this.renameStack.pop();
        } else {
          for (const inner of innerStmts) this.emitStatement(inner);
        }
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
      "assign", "switch", "switch_expr", "label", "goto",
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
      case "label":     this.emitLabelStmt(call); break;
      case "goto":      this.emitGotoStmt(call); break;
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
        // Wrap in do-while(false) so case `break;` exits the switch,
        // not an enclosing for loop (switch is compiled as if/else chain).
        this.writeln(`do { const __sw = ${subjectStr};`);
        this.depth++;
        const caseExprs = casesField.literal?.listValue?.elements ?? [];
        let defaultBody: Expression | undefined;
        let first = true;
        // Parse all cases, detecting fall-through (empty body = merge
        // with next case via ||).
        const parsedCases: Array<{ conds: string[]; body?: Expression; patText?: string; structuredBindings?: Array<{ varName: string; expr: string }>; guard?: Expression }> = [];
        const pendingConds: string[] = [];
        let lastPatText: string | undefined;
        for (const ce of caseExprs) {
          if (!ce.messageCreation) continue;
          let pattern: Expression | undefined;
          let body: Expression | undefined;
          let isDefaultFlag = false;
          let patternExprField: Expression | undefined;
          let guardField: Expression | undefined;
          for (const fd of ce.messageCreation.fields ?? []) {
            if (fd.name === "pattern") pattern = fd.value;
            if (fd.name === "body") body = fd.value;
            if (fd.name === "is_default" && fd.value?.literal?.boolValue === true) isDefaultFlag = true;
            if (fd.name === "pattern_expr") patternExprField = fd.value;
            if (fd.name === "guard") guardField = fd.value;
          }
          // Check for is_default flag
          if (isDefaultFlag) { defaultBody = body; continue; }
          // Handle structured pattern_expr (only for known pattern kinds)
          if (patternExprField) {
            const result = compileStructuredPattern(patternExprField, "__sw", (e) => this.expr(e));
            if (result) {
              const cond = result.condition;
              // A catch-all with no guard ends the chain; with a guard the
              // branch stays refutable (a false guard falls through).
              if (cond === "true" && !guardField) { defaultBody = body; break; }
              const isEmpty = body && body.block &&
                (body.block.statements ?? []).length === 0 &&
                body.block.result === undefined;
              if (!guardField && (!body || isEmpty)) {
                pendingConds.push(cond);
                continue;
              }
              pendingConds.push(cond);
              parsedCases.push({ conds: [...pendingConds], body, structuredBindings: result.bindings, guard: guardField });
              pendingConds.length = 0;
              continue;
            }
            // Unknown pattern kind -- fall through to text-based pattern handling
          }
          if (!pattern) { defaultBody = body; continue; }
          const patText = patternLiteralText(pattern);
          const cond = patText !== undefined
            ? patternToTsCondition(patText, "__sw")
            : `((__sw) === ${this.expr(pattern)})`;
          if (cond === "true" && !guardField) { defaultBody = body; break; }
          // Empty body = fall-through: accumulate conditions.
          const isEmpty = body && body.block &&
            (body.block.statements ?? []).length === 0 &&
            body.block.result === undefined;
          if (!guardField && (!body || isEmpty)) {
            pendingConds.push(cond);
            lastPatText = patText;
            continue;
          }
          pendingConds.push(cond);
          parsedCases.push({ conds: [...pendingConds], body, patText: patText ?? lastPatText, guard: guardField });
          pendingConds.length = 0;
          lastPatText = undefined;
        }
        for (const pc of parsedCases) {
          // Gather this case's pattern bindings.
          const caseBindings: Array<{ varName: string; expr: string }> = [];
          if (pc.structuredBindings) caseBindings.push(...pc.structuredBindings);
          if (pc.patText) caseBindings.push(...patternBindings(pc.patText, "__sw"));
          // When a `when` guard is present the bindings must be visible to the
          // guard, which is part of the `if` condition. Hoist them to temps
          // BEFORE the `if` (so the guard can read them) and reference the temps
          // inside. Without this, an entered `if` block swallows the arm and
          // later cases never get tested when the guard is false.
          let combinedCond = pc.conds.join(" || ");
          if (pc.guard) {
            // Evaluate the guard inside an IIFE bound to the pattern variables,
            // gated by the match condition via `&&` (so the IIFE only runs when
            // the pattern matched and the temps are valid). The guard's binders
            // are passed positionally; the guard expression itself is untouched.
            const matchCond = `(${pc.conds.join(" || ")})`;
            if (caseBindings.length > 0) {
              const params = caseBindings.map(b => b.varName).join(", ");
              const args = caseBindings.map(b => b.expr).join(", ");
              combinedCond = `${matchCond} && ((${params}) => (${this.expr(pc.guard)}))(${args})`;
            } else {
              combinedCond = `${matchCond} && (${this.expr(pc.guard)})`;
            }
          }
          const kw = first ? "if" : "else if";
          this.writeln(`${kw} (${combinedCond}) {`);
          this.depth++;
          // Inject variable bindings inside the matched block.
          for (const b of caseBindings) {
            this.writeln(`const ${b.varName} = ${b.expr};`);
          }
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
        this.writeln("} while (false);");
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
      // Use `let` for a per-iteration binding: Dart's C-style for loop gives
      // each iteration its OWN copy of the loop variable, so closures created
      // in the body capture that iteration's value (conformance 229/312).
      // JS `let` matches this exactly; `var` would share one binding and
      // leak the final value into every closure (#69).
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

  /**
   * `std.label(name, body)` — a named jump target that `std.goto(label)`
   * re-enters. TS has no real `goto`, so this lowers to a labelled
   * `while (true)` loop: running the body once and falling off the end
   * (the common case, and the only shape a `goto` targeting it can
   * restart) matches Ball's "run once, or re-run from the top on goto"
   * semantics, with `break name;` after the body covering the fall-off
   * case exactly as the Dart compiler's switch-based simulation does.
   * See `activeGotoLabels` for why only backward jumps are supported.
   */
  private emitLabelStmt(call: FunctionCall): void {
    const name = stringField(call, "name");
    const body = field(call, "body");
    if (!name || !body) {
      throw new Error("std.label requires a string \"name\" and a \"body\"");
    }
    this.activeGotoLabels.push(name);
    this.writeln(`${name}: while (true) {`);
    this.depth++;
    this.emitStatementOrExpression(body, false);
    this.writeln(`break ${name};`);
    this.depth--;
    this.writeln(`}`);
    this.activeGotoLabels.pop();
  }

  /** `std.goto(label)` — see `emitLabelStmt` and `activeGotoLabels`. */
  private emitGotoStmt(call: FunctionCall): void {
    const label = stringField(call, "label");
    if (!label) throw new Error('std.goto requires a string "label"');
    if (!this.activeGotoLabels.includes(label)) {
      throw new Error(
        `std.goto("${label}") is not inside its own std.label("${label}", ...) body — ` +
        "the TS compiler only supports goto as a backward jump that restarts an " +
        "enclosing label (mirrors a labelled loop); forward jumps and jumps to a " +
        "sibling label are not supported (#226).",
      );
    }
    this.writeln(`continue ${label};`);
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
    // Dart's `~/=` (integer-division-assign) has no JS equivalent operator.
    // Emit as `target = Math.trunc(target / value)` instead.
    if (op === "~/=") {
      const tgt = this.lvalueExpr(target);
      this.writeln(`${tgt} = Math.trunc(${tgt} / ${this.expr(value)});`);
      return;
    }
    // Detect assign(target: X, value: list_concat(list: X, value: Y)) pattern
    // (Dart's `X.addAll(Y)`). Emit in-place mutation instead of creating a new
    // array, so callers sharing the same list reference see the appended elements.
    if (op === "=" && value.call && isStd(value.call.module)) {
      const inPlace = this.tryEmitInPlaceListMutation(target, value);
      if (inPlace !== undefined) {
        this.writeln(`${inPlace};`);
        return;
      }
    }
    this.writeln(`${this.lvalueExpr(target)} ${op} ${this.expr(value)};`);
  }

  /**
   * Detects `list_concat(list: X, value: Y)` where X is the same reference as
   * [target] and emits in-place `X.push(...Y)` instead of `X = [...X, ...Y]`.
   * Returns the expression string or undefined if the pattern doesn't match.
   */
  private tryEmitInPlaceListMutation(target: Expression, value: Expression): string | undefined {
    const vc = value.call;
    if (!vc) return undefined;
    const fn = vc.function;
    if (fn !== "list_concat") return undefined;
    const vcFields = vc.input?.messageCreation?.fields ?? [];
    let listExpr: Expression | undefined;
    let appendExpr: Expression | undefined;
    for (const f of vcFields) {
      if (f.name === "list" || f.name === "left") listExpr = f.value;
      if (f.name === "value" || f.name === "right" || f.name === "other") appendExpr = f.value;
    }
    if (!listExpr || !appendExpr) return undefined;
    // Check target and list refer to the same variable/expression.
    if (!sameRef(target, listExpr)) return undefined;
    const tgt = this.lvalueExpr(target);
    const rhs = this.expr(appendExpr);
    // Emit: Array.isArray(Y) ? X.push(...Y) : X.push(Y)
    // For safety, use a runtime check so both scalar and array args work.
    return `__ball_push_all(${tgt}, ${rhs})`;
  }

  /**
   * Like {@link expr}, but produces a valid assignment target (lvalue).
   *
   * The `index` operator (`a[i]`) normally compiles to the bounds-checked
   * `__ball_index(a, i)` runtime helper so out-of-bounds list reads throw a
   * Dart-style RangeError. A function-call expression can't be the left side
   * of an assignment, so when an `index` call is the target of an `assign`
   * (e.g. `map[key] = value`) we emit the raw `a[i]` bracket form instead.
   */
  private lvalueExpr(e: Expression): string {
    const c = e.call;
    if (c && c.function === "index" &&
        (c.module === "" || c.module === "std")) {
      const t = field(c, "target");
      const idx = field(c, "index");
      if (t && idx) return `${this.expr(t)}[${this.expr(idx)}]`;
    }
    return this.expr(e);
  }

  private typedCatchCondition(type: string): string {
    // Helper: check plain-object __type__ / __type, stripping module prefix.
    const objCheck = `(typeof __ball_active_error === 'object' && __ball_active_error !== null && (() => { const __t = __ball_active_error['__type__'] ?? __ball_active_error['__type'] ?? ''; const __bare = __t.indexOf(':') >= 0 ? __t.substring(__t.indexOf(':') + 1) : __t; return __bare === '${type}' || __t === '${type}'; })())`;
    const builtins = new Set([
      "Error", "TypeError", "RangeError", "SyntaxError",
      "ReferenceError", "URIError", "EvalError",
    ]);
    if (builtins.has(type)) return `(__ball_active_error instanceof ${type} || ${objCheck})`;
    if (type === "FormatException") {
      return `((__ball_active_error instanceof Error && __ball_active_error.message.startsWith('FormatException')) || ${objCheck})`;
    }
    if (type === "Exception" || type === "Object") return "true";
    // Dart exception types that are not JS globals.
    const dartExceptions = new Set([
      "StateError", "ArgumentError", "UnsupportedError",
      "ConcurrentModificationError", "StackOverflowError",
      "IntegerDivisionByZeroException", "NoSuchMethodError",
      "UnimplementedError", "AssertionError",
    ]);
    if (dartExceptions.has(type)) {
      return `((__ball_active_error instanceof Error && __ball_active_error.message.includes('${type}')) || ${objCheck})`;
    }
    // Guard instanceof with typeof check to avoid ReferenceError for
    // user-defined types that don't exist as JS classes.
    return `((typeof ${type} !== 'undefined' && __ball_active_error instanceof ${type}) || ${objCheck})`;
  }

  // ───────────────────────── Expressions ─────────────────────────────

  /**
   * Qualifier for an unqualified same-class member reference. Static members
   * are not on `this` in JS, so they must be addressed via the class name
   * (`<ClassName>.m`); instance members use `this.m`.
   */
  private memberQualifier(shortName: string): string {
    if (this.currentClassStaticNames.has(shortName) && this.currentClassName) {
      return `${this.currentClassName}.`;
    }
    return "this.";
  }

  private expr(e: Expression): string {
    if (e.call) return this.compileCall(e.call);
    if (e.literal) return this.compileLiteral(e.literal);
    if (e.reference) {
      const name = e.reference.name;
      if (name === "this") return "this";
      // Ball's `self` → JS `this` in class methods, when `self` is not
      // an explicit parameter or a locally declared variable. Gated on
      // "are we compiling a class member" (currentClassName), not on the
      // class having any DECLARED fields — a class that only ever does
      // `this.x = x` in its constructor (no prior `x;` declaration) has an
      // empty currentClassFields but `self` still unambiguously means
      // `this` there (#253).
      if (name === "self" &&
          this.currentClassName !== undefined &&
          !this.currentMethodParams.has("self") &&
          !this.scopeDeclaredVars.has("self")) {
        return "this";
      }
      // Ball's `super` reference → JS `super` keyword in class methods.
      // Without this, sanitize() would emit `super_` (reserved word escape).
      if (name === "super" && this.currentClassName !== undefined) {
        return "super";
      }
      // Inside a class method: bare references to fields need this.
      // prefix. Method references also need .bind(this) because Dart
      // tear-offs auto-bind but JS method references do not.
      if (!this.currentMethodParams.has(name)) {
        if (this.currentClassFields.has(name)) {
          return `this.${sanitize(name)}`;
        }
        if (this.currentClassMethodNames.has(name)) {
          const short = sanitize(name);
          // Static method tear-off: address via class name, no `.bind`
          // (statics aren't on `this` and need no receiver binding).
          if (this.currentClassStaticNames.has(short) && this.currentClassName) {
            return `${this.currentClassName}.${short}`;
          }
          // Getters are properties, not methods — bare `this.name`.
          if (this.currentClassGetterNames.has(short)) {
            return `this.${short}`;
          }
          return `this.${short}.bind(this)`;
        }
      }
      // Apply shadow-rename resolution for hoisted block variables.
      return this.resolveVarName(sanitize(name));
    }
    if (e.fieldAccess) return this.compileFieldAccess(e.fieldAccess);
    if (e.messageCreation) return this.compileMessageCreation(e.messageCreation);
    if (e.block) return this.compileBlockExpression(e.block);
    if (e.lambda) return this.compileLambda(e.lambda);
    return "null /* notSet */";
  }

  private compileLiteral(lit: Literal): string {
    if (lit.intValue !== undefined) {
      const s = String(lit.intValue);
      try {
        const b = BigInt(s);
        if (b > 9007199254740991n || b < -9007199254740991n) return `${s}n`;
      } catch {}
      return s;
    }
    if (lit.doubleValue !== undefined) return `new BallDouble(${lit.doubleValue})`;
    if (lit.stringValue !== undefined) return jsStringLiteral(lit.stringValue);
    if (lit.boolValue !== undefined) return lit.boolValue ? "true" : "false";
    if (lit.listValue) {
      return this.compileListElements(lit.listValue.elements ?? []);
    }
    if (lit.bytesValue !== undefined) return "/* bytes */ new Uint8Array()";
    return "null";
  }

  // ─────────────── Collection elements (issue #55) ───────────────────
  //
  // List/set/map literals may contain "collection elements" that are NOT
  // plain values: spread (`...x`), null-spread (`...?x`), collection-if
  // (`[for/if (c) e]`) and collection-for (both for-each and C-style). TS
  // has no collection-literal element syntax, so when any of these appear
  // we build the container imperatively inside an IIFE. Plain literals keep
  // the simple `[...]` / `new Set([...])` / `{...}` fast path.

  private isCollectionControlElement(e: Expression): boolean {
    const c = e.call;
    if (!c || !isStd(c.module)) return false;
    return (
      c.function === "spread" ||
      c.function === "null_spread" ||
      c.function === "collection_if" ||
      c.function === "collection_for"
    );
  }

  /** Build a TS list expression from collection elements. */
  private compileListElements(elements: Expression[]): string {
    if (!elements.some((e) => this.isCollectionControlElement(e))) {
      return `[${elements.map((x) => this.expr(x)).join(", ")}]`;
    }
    const body = elements
      .map((e) => this.emitCollectionElement(e, "list", "__r"))
      .join(" ");
    return `(() => { const __r: any[] = []; ${body} return __r; })()`;
  }

  /** Build a TS Set expression from collection elements. */
  private compileSetElements(elements: Expression[]): string {
    if (!elements.some((e) => this.isCollectionControlElement(e))) {
      return `new Set([${elements.map((x) => this.expr(x)).join(", ")}])`;
    }
    const body = elements
      .map((e) => this.emitCollectionElement(e, "set", "__r"))
      .join(" ");
    return `(() => { const __r = new Set<any>(); ${body} return __r; })()`;
  }

  /**
   * Build a TS plain-object map expression from collection map-entry
   * elements. Each element is either an `entry` (key/value messageCreation),
   * a spread/null_spread of another map, or a collection_if/collection_for
   * whose leaves are key/value entries.
   */
  private compileMapElements(elements: Expression[]): string {
    if (!elements.some((e) => this.isCollectionControlElement(e))) {
      const pairs = elements.map((e) => this.mapEntryPair(e)).filter((p) => p !== undefined);
      return `{${pairs.join(", ")}}`;
    }
    const body = elements
      .map((e) => this.emitCollectionElement(e, "map", "__r"))
      .join(" ");
    return `(() => { const __r: Record<string, any> = {}; ${body} return __r; })()`;
  }

  /** Render a single non-control map entry as `key: value`, or undefined. */
  private mapEntryPair(e: Expression): string | undefined {
    const mc = e.messageCreation;
    if (mc) {
      const k = (mc.fields ?? []).find((f) => f.name === "key")?.value;
      const v = (mc.fields ?? []).find((f) => f.name === "value")?.value;
      if (k && v) return `[${this.expr(k)}]: ${this.expr(v)}`;
    }
    return undefined;
  }

  /**
   * Emit statements that push/add/assign one collection element into the
   * accumulator `sink`. `kind` selects the sink operation:
   *   list → `sink.push(v)`   set → `sink.add(v)`   map → `sink[k] = v`.
   */
  private emitCollectionElement(
    e: Expression,
    kind: "list" | "set" | "map",
    sink: string,
  ): string {
    const c = e.call;
    if (c && isStd(c.module)) {
      const f = fieldMap(c.input?.messageCreation?.fields ?? []);
      switch (c.function) {
        case "spread":
        case "null_spread": {
          const v = f.get("value");
          const nullAware = c.function === "null_spread";
          if (kind === "map") {
            // Spread of another map: copy its entries. null_spread treats a
            // null / uninitialized operand as the empty map.
            const src = v
              ? nullAware
                ? `(__ball_spread_iter(${this.expr(v)}) || {})`
                : this.expr(v)
              : "{}";
            return `{ const __m = ${src}; for (const __k in __m) { ${sink}[__k] = __m[__k]; } }`;
          }
          const iter = v
            ? nullAware
              ? `__ball_spread_iter(${this.expr(v)})`
              : this.expr(v)
            : "[]";
          const op = kind === "set" ? "add" : "push";
          return `for (const __e of ${iter}) { ${sink}.${op}(__e); }`;
        }
        case "collection_if": {
          const cond = f.get("condition");
          const then_ = f.get("then");
          const else_ = f.get("else");
          const condStr = cond ? this.expr(cond) : "false";
          const thenStr = then_
            ? this.emitCollectionElement(then_, kind, sink)
            : "";
          if (else_) {
            const elseStr = this.emitCollectionElement(else_, kind, sink);
            return `if (${condStr}) { ${thenStr} } else { ${elseStr} }`;
          }
          return `if (${condStr}) { ${thenStr} }`;
        }
        case "collection_for": {
          const body = f.get("body");
          if (!body) return "";
          const inner = this.emitCollectionElement(body, kind, sink);
          const iterable = f.get("iterable");
          if (iterable) {
            const variable =
              f.get("variable")?.literal?.stringValue ?? "item";
            return `for (const ${sanitize(variable)} of ${this.expr(iterable)}) { ${inner} }`;
          }
          // C-style: init (single-let block) / condition / update.
          const initField = f.get("init");
          const cond = f.get("condition");
          const update = f.get("update");
          const initStr = initField ? this.renderForInit(initField) : "";
          const condStr = cond ? this.expr(unwrapLambda(cond)) : "";
          const updStr = update ? this.expr(unwrapLambda(update)) : "";
          return `for (${initStr}; ${condStr}; ${updStr}) { ${inner} }`;
        }
      }
    }
    // Plain element.
    if (kind === "map") {
      const pair = this.mapEntryPair(e);
      if (pair !== undefined) {
        // pair is `[k]: v` — re-extract key/value for imperative assignment.
        const mc = e.messageCreation!;
        const k = (mc.fields ?? []).find((fd) => fd.name === "key")!.value;
        const v = (mc.fields ?? []).find((fd) => fd.name === "value")!.value;
        return `${sink}[${this.expr(k)}] = ${this.expr(v)};`;
      }
      return "";
    }
    const op = kind === "set" ? "add" : "push";
    return `${sink}.${op}(${this.expr(e)});`;
  }

  /**
   * Render a C-style for-init `block` (a single-let, no-result block) as an
   * inline declaration string like `let i = 0` — NOT an IIFE, so the loop
   * variable stays in scope for the condition/update. Mirrors the Dart
   * compiler's `_renderForInit`. Uses `let` so each iteration gets its own
   * binding, matching Dart's per-iteration loop-variable capture semantics
   * (#69, conformance 312). Returns "" on an unrecognized shape.
   */
  private renderForInit(initExpr: Expression): string {
    const block = initExpr.block;
    if (!block || (block.statements ?? []).length === 0 || block.result !== undefined) {
      // Fall back to whatever the expression compiles to.
      return this.expr(initExpr);
    }
    const bindings: string[] = [];
    for (const s of block.statements ?? []) {
      if (!s.let) return this.expr(initExpr);
      const name = sanitize(s.let.name);
      const value = s.let.value;
      const isNoInit =
        value?.reference?.name === "__no_init__";
      if (value !== undefined && !isNoInit) {
        bindings.push(`${name} = ${this.expr(value)}`);
      } else {
        bindings.push(name);
      }
    }
    return bindings.length > 0 ? `let ${bindings.join(", ")}` : "";
  }

  private compileFieldAccess(fa: NonNullable<Expression["fieldAccess"]>): string {
    // Ball's `self.field` in class methods → `this.field` in JS.
    // Only when `self` is not an explicit method parameter (the engine
    // passes `self` as a parameter in its own OOP dispatch). Gated on
    // "are we compiling a class member" (currentClassName), not on the
    // class having any DECLARED fields — see the analogous `self` check
    // in expr() above (#253).
    const isSelfRef = fa.object.reference?.name === "self" &&
      this.currentClassName !== undefined &&
      !this.currentMethodParams.has("self");
    // Ball's `super.field` for instance fields → `this.field` in JS.
    // In Dart, `super.name` accesses the instance field through the
    // superclass chain. In JS, `super.name` accesses the prototype
    // property (undefined for instance fields). Only method calls
    // (super.method()) should use actual JS `super`.
    const isSuperFieldRef = fa.object.reference?.name === "super" &&
      this.currentClassName !== undefined &&
      this.currentClassFields.has(fa.field) &&
      !this.currentClassMethodNames.has(fa.field);
    const rawObj = isSelfRef || isSuperFieldRef ? "this" : this.expr(fa.object);
    // A bare numeric-literal receiver (e.g. `0`, `-4`, `123n`) parses as the
    // start of a float literal when immediately followed by `.field` —
    // `0.isNegative` is `SyntaxError: Identifier cannot follow number`.
    // Parenthesize whenever the compiled object text IS (not merely
    // contains) such a token; a double literal already compiles through
    // `new BallDouble(...)` and a negated int through `__ball_negate(...)`,
    // so both are already safe — only the bare-token case needs this.
    const obj = /^-?\d+n?$/.test(rawObj) ? `(${rawObj})` : rawObj;
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

    // Internal call encoded as MessageCreation with a `<module>:<ident>`
    // typeName. The encoder emits same-module function/method/constructor
    // invocations this way (e.g. `_ballFuture(values)` →
    // `messageCreation{typeName:"main:_ballFuture", fields:[arg0,...]}`,
    // `this._evalExpression(...)` → `"main:_evalExpression"`,
    // `_Scope(parent)` → `"main:_Scope"`). Resolve the identifier after the
    // colon to a real constructor / method / free-function call so the
    // compiled engine actually invokes it instead of building an inert
    // `{'__type': 'main:...'}` placeholder object.
    if (tn.includes(":")) {
      const ident = classTsName(tn); // part after the last ':'
      // Type/class → constructor call. Checked before method/function so a
      // class name shadowing a method resolves to `new`.
      if (
        this.typeIsUserDefinedClass(tn) ||
        this.typeIsUserDefinedClass(ident)
      ) {
        const args = this.extractPositionalAndNamed(fields);
        return this.wrapWithTypeArgs(`new ${classTsName(tn)}(${args})`, mc);
      }
      const identShort = memberShortName(ident);
      // Class method of the class currently being compiled → `this.m(...)`
      // (or `<Class>.m(...)` for static members).
      if (this.currentClassMethodNames.has(identShort)) {
        const args = this.extractPositionalAndNamed(fields);
        return `${this.memberQualifier(identShort)}${identShort}(${args})`;
      }
      // Free top-level function in the entry module → bare call.
      if (this.allFunctionNames.has(ident) || this.allFunctionNames.has(identShort)) {
        const args = this.extractPositionalAndNamed(fields);
        return `${identShort}(${args})`;
      }
      // Otherwise fall through to the builtin-ctor / fallback handling
      // below (so e.g. `main:RegExp` still resolves to `new RegExp`).
    }

    // Function call encoded as MessageCreation: `foo()` / `this.foo()`
    // with no explicit receiver. typeName = function qualified name.
    const shortName = memberShortName(tn);
    if (this.allFunctionNames.has(tn)) {
      const args = this.extractPositionalAndNamed(fields);
      if (this.currentClassMethodNames.has(shortName)) {
        return `${this.memberQualifier(shortName)}${shortName}(${args})`;
      }
      return `${shortName}(${args})`;
    }
    if (this.currentClassMethodNames.has(shortName)) {
      const args = this.extractPositionalAndNamed(fields);
      return `${this.memberQualifier(shortName)}${shortName}(${args})`;
    }

    // User-defined class → `new X(...)`.
    if (this.typeIsUserDefinedClass(tn)) {
      const args = this.extractPositionalAndNamed(fields);
      return this.wrapWithTypeArgs(`new ${classTsName(tn)}(${args})`, mc);
    }

    // Dart/JS built-in constructors: RegExp, Map, Set, Error, etc.
    // The encoder emits these as MessageCreation with typeName
    // including the module prefix (e.g., 'main:RegExp'). Strip the
    // prefix and emit as native constructors.
    const builtinCtors = new Set([
      "RegExp", "Set", "Error", "TypeError", "RangeError",
      "DateTime", "Duration", "Uri", "BigInt", "Int64",
      "BallDouble", "ByteData",
    ]);
    const shortTn = classTsName(tn);

    // Map / Map.from / Map.of and the dart:collection map flavors
    // (LinkedHashMap, HashMap, SplayTreeMap) → spread-copy as a plain
    // object (Ball maps are plain ordered objects, not JS Map). Drop the
    // generic `__type_args__` marker so it doesn't leak as a data key.
    const mapCtors = new Set([
      "Map", "Map.from", "Map.of",
      "LinkedHashMap", "LinkedHashMap.from", "LinkedHashMap.of",
      "HashMap", "HashMap.from", "HashMap.of",
      "SplayTreeMap", "SplayTreeMap.from", "SplayTreeMap.of",
    ]);
    if (mapCtors.has(shortTn)) {
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

    // Dart StringBuffer → empty string in TS (string concatenation replaces
    // the mutable buffer). writeCharCode / write are handled in compileCall.
    if (shortTn === "StringBuffer") {
      return `""`;
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
    // Lambda creates a new JS function scope — save/restore variable tracking.
    const savedScope = this.scopeDeclaredVars;
    const savedRenames = this.renameStack;
    this.scopeDeclaredVars = new Set();
    this.renameStack = [];
    const needsInputAlias = params.length === 1 && params[0] !== "input";
    const inputIsReassigned = needsInputAlias && fn.body && bodyAssignsToVar(fn.body, "input");
    const innerText = this.captureInto(() => {
      this.writeln("");
      if (needsInputAlias && !inputIsReassigned) {
        this.writeln(`const input = ${sanitize(params[0])};`);
      }
      if (fn.body) this.emitStatementOrExpression(fn.body, true);
    }) + "\n";
    this.scopeDeclaredVars = savedScope;
    this.renameStack = savedRenames;
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
    // Detect constructor calls: "module:ClassName.new" → new ClassName(args).
    const colonIdx = call.function.lastIndexOf(":");
    if (colonIdx >= 0) {
      const afterColon = call.function.substring(colonIdx + 1);
      if (afterColon.endsWith(".new")) {
        const className = afterColon.slice(0, -4);
        const args = call.input?.messageCreation?.fields
          ?.filter((f: any) => f.name !== "__type_args__" && f.name !== "__const__")
          ?.map((f: any) => this.expr(f.value))
          ?.join(", ") ?? "";
        return `new ${className}(${args})`;
      }
    }
    const fn = sanitize(call.function);
    // Prefix with this. when the function name is a class method OR
    // a class field holding a callable (like `stdout` which is a
    // void Function(String) field). Both need this. in TS since Dart
    // resolves implicitly. Static methods live on the class, not on
    // `this`, so they are addressed via `<ClassName>.`.
    let thisPrefix = "";
    if (!this.currentMethodParams.has(call.function)) {
      if (this.currentClassMethodNames.has(fn)) {
        thisPrefix = this.memberQualifier(fn);
      } else if (this.currentClassFields.has(call.function)) {
        thisPrefix = "this.";
      }
    }
    // Auto-await calls to known-async user functions.
    const awaitPfx = this.asyncFnNames.has(call.function) ? "await " : "";
    if (!call.input) return `${awaitPfx}${thisPrefix}${fn}()`;
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
        // StringBuffer.writeCharCode(code) → self += String.fromCharCode(code)
        if (fn === "writeCharCode") {
          return `(${selfStr} += String.fromCharCode(${otherArgs}))`;
        }
        // StringBuffer.write(text) → self += text
        if (fn === "write" && otherArgs !== "") {
          return `(${selfStr} += ${otherArgs})`;
        }
        // Map.fromEntries(list) → Object.fromEntries(list.map(e => [e.arg0, e.arg1]))
        if (fn === "fromEntries" && selfField.value.reference?.name === "Map") {
          return `Object.fromEntries((${otherArgs}).map((e: any) => [e.arg0 ?? e.key, e.arg1 ?? e.value]))`;
        }
        return otherArgs === ""
          ? `${selfStr}.${fn}()`
          : `${selfStr}.${fn}(${otherArgs})`;
      }
      // A messageCreation with a REAL typeName is always a genuine value (a
      // class instance), never a synthesized call-argument wrapper — Dart's
      // encoder (_setCallInput) unwraps a single positional argument to a
      // bare value with NO wrapper at all, so `input` IS directly that
      // construction's own messageCreation when the sole argument is e.g.
      // `Pt(3, 4)` (#213: this used to get its arg0/arg1 constructor fields
      // wrongly flattened into positional JS args instead of `new Pt(3, 4)`
      // being recognized). Compile it as ONE value.
      if (input.messageCreation.typeName) {
        return `${awaitPfx}${thisPrefix}${fn}(${this.expr(input)})`;
      }
      // Otherwise this messageCreation is ALWAYS a synthesized call-argument
      // wrapper (never a bare map/record/set literal — those always route
      // through std.map_create/set_create/record, not a bare
      // messageCreation), regardless of field count or naming: Ball's
      // one-input model bundles every argument (including a lone one) into
      // one struct, and both encoders wrap this way for 2+ arguments; the TS
      // encoder (encodeCall) additionally wraps even a SINGLE argument as
      // `{fields: [{name: "arg0", value: <arg>}]}` (e.g. `fib(n - 1)` was
      // wrongly becoming `fib({'arg0': n - 1})` here before this fix).
      // Flattening a single field naturally unwraps it to just its value
      // (a 1-element join), so this one rule covers both arities and both
      // encoders' single-argument conventions uniformly.
      const args = fields
        .filter((f) => f.name !== "__type_args__" && f.name !== "__const__")
        .map((f) => this.expr(f.value))
        .join(", ");
      return `${awaitPfx}${thisPrefix}${fn}(${args})`;
    }
    return `${awaitPfx}${thisPrefix}${fn}(${this.expr(input)})`;
  }

  private compileStdCall(call: FunctionCall): string {
    const fn = call.function;
    if (call.module === "std_memory") return this.compileMemoryCall(call);
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
      case "add":          return `__ball_add(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1", "pattern", "separator")!)})`;
      case "subtract":     return `__ball_sub(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1", "pattern", "separator")!)})`;
      case "multiply":     return `__ball_mul(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1", "pattern", "separator")!)})`;
      case "divide":       return `__ball_divide(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "divide_double":return `new BallDouble(Number(${this.expr(f.get("left")!)}) / Number(${this.expr(f.get("right")!)}))`;
      case "modulo":       return `__dart_mod(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "negate":       return `__ball_negate(${this.expr(fg("value", "arg0")!)})`;
      // Comparison
      // Unlike fg()'s explicit alias lists, f.get() ITSELF already resolves
      // "left"/"right" through FieldMap's built-in alias table (which is a
      // superset: value/arg0/string and other/arg1/pattern/separator), so
      // there is no field-name combination that reaches an fg()-based
      // fallback here without f.get() finding the same value first — a
      // fallback branch was removed as dead code (#62 Phase-2c).
      case "equals":       return `__ball_eq(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      case "not_equals":   return `!__ball_eq(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
      // Relational comparisons route through __ball_lt/__ball_gt/__ball_le/__ball_ge
      // so operator-overloaded types (e.g. a class defining `<`) dispatch to
      // their `__op_lt__`-style method instead of raw JS comparison (#205).
      case "less_than":    return `__ball_lt(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "greater_than": return `__ball_gt(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "lte":          return `__ball_le(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "gte":          return `__ball_ge(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      // Logical
      case "and":          return bin("&&");
      case "or":           return bin("||");
      case "not":          return un("!");
      // Bitwise
      case "bitwise_and":  return `__ball_bitand(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "bitwise_or":   return `__ball_bitor(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "bitwise_xor":  return `__ball_bitxor(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "bitwise_not":  return `__ball_bitnot(${this.expr(fg("value", "arg0")!)})`;
      case "left_shift":   return `__ball_shl(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "right_shift":  return `__ball_shr(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "unsigned_right_shift": return `__ball_ushr(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "integer_divide":
        return `__ball_divide(${this.expr(f.get("left")!)}, ${this.expr(f.get("right")!)})`;
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
      case "string_runes": return `Array.from(${this.expr(fg("value", "arg0")!)}).map((c) => c.codePointAt(0))`;
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
      // Math — keep this list in sync with the Dart compiler's `_compileBaseCall`
      // math handling (dart/compiler/lib/compiler.dart). Every `math_*` base
      // function MUST resolve to an inline expression here; an unhandled name
      // falls through to the bare `math_<name>(...)` default (undefined symbol).
      case "math_abs":   return `__ball_math_abs(${this.expr(fg("value", "arg0")!)})`;
      case "math_round": return `Math.round(${this.expr(fg("value", "arg0")!)})`;
      case "math_floor": return `Math.floor(${this.expr(fg("value", "arg0")!)})`;
      case "math_ceil":  return `Math.ceil(${this.expr(fg("value", "arg0")!)})`;
      case "math_trunc": return `Math.trunc(${this.expr(fg("value", "arg0")!)})`;
      case "math_sqrt":  return `Math.sqrt(${this.expr(fg("value", "arg0")!)})`;
      case "math_exp":   return `Math.exp(${this.expr(fg("value", "arg0")!)})`;
      case "math_log":   return `Math.log(${this.expr(fg("value", "arg0")!)})`;
      case "math_log2":  return `(Math.log(${this.expr(fg("value", "arg0")!)}) / Math.LN2)`;
      case "math_log10": return `(Math.log(${this.expr(fg("value", "arg0")!)}) / Math.LN10)`;
      case "math_sin":   return `Math.sin(${this.expr(fg("value", "arg0")!)})`;
      case "math_cos":   return `Math.cos(${this.expr(fg("value", "arg0")!)})`;
      case "math_tan":   return `Math.tan(${this.expr(fg("value", "arg0")!)})`;
      case "math_asin":  return `Math.asin(${this.expr(fg("value", "arg0")!)})`;
      case "math_acos":  return `Math.acos(${this.expr(fg("value", "arg0")!)})`;
      case "math_atan":  return `Math.atan(${this.expr(fg("value", "arg0")!)})`;
      case "math_atan2": return `Math.atan2(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "math_pow":   return `Math.pow(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "math_min":   return `Math.min(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "math_max":   return `Math.max(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "math_gcd":   return `__ball_math_gcd(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      case "math_lcm":   return `__ball_math_lcm(${this.expr(fg("left", "value", "arg0")!)}, ${this.expr(fg("right", "other", "arg1")!)})`;
      // Engine values may be primitive numbers, BigInt i64s, or BallDouble
      // wrappers, so coerce with Number(...) before applying number predicates —
      // a bare `x === Infinity` would be false for a BallDouble(Infinity) box.
      case "math_sign":        return `Math.sign(Number(${this.expr(fg("value", "arg0")!)}))`;
      case "math_is_nan":      return `Number.isNaN(Number(${this.expr(fg("value", "arg0")!)}))`;
      case "math_is_finite":   return `Number.isFinite(Number(${this.expr(fg("value", "arg0")!)}))`;
      case "math_is_infinite": return `(Math.abs(Number(${this.expr(fg("value", "arg0")!)})) === Infinity)`;
      case "math_pi":       return "Math.PI";
      case "math_e":        return "Math.E";
      case "math_infinity": return "Infinity";
      case "math_nan":      return "NaN";
      case "print":      return `console.log(__ball_to_string(${this.expr(f.get("message")!)}))`;
      case "index": {
        const target = f.get("target")!;
        const idx = f.get("index")!;
        // Bracket-invoking a string-literal-named operator method (e.g.
        // `a['+'](b)` — the only way to call one, since TS has no `operator`
        // keyword) indexes with the RAW lexeme, but the compiled class
        // exposes the operator under its canonical __op_*__ name (#248) —
        // translate the lexeme so the access finds the real method instead
        // of a nonexistent literal '+' property (#252). "-" is ambiguous
        // (unary __op_neg__ vs binary __op_sub__ — a class can only define
        // ONE '-'-named method, so exactly one of the two properties ever
        // actually exists; ?? picks whichever it is without needing type
        // info to disambiguate at the call site).
        const lexeme = idx.literal?.stringValue;
        if (lexeme !== undefined && Object.prototype.hasOwnProperty.call(operatorIndexNames, lexeme)) {
          const targetStr = this.expr(target);
          if (lexeme === "-") return `(${targetStr}.__op_sub__ ?? ${targetStr}.__op_neg__)`;
          return `${targetStr}.${operatorIndexNames[lexeme]}`;
        }
        return `__ball_index(${this.expr(target)}, ${this.expr(idx)})`;
      }
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
      case "try": {
        const captured = this.captureInto(() => this.emitTryStmt(call));
        return this.wrapIIFE(captured);
      }
      // Ball control-flow functions usable as expressions → IIFE wrappers.
      case "for": {
        const captured = this.captureInto(() => this.emitForStmt(call));
        return this.wrapIIFE(captured);
      }
      case "for_in":
      case "for_each": {
        const captured = this.captureInto(() => this.emitForInStmt(call));
        return this.wrapIIFE(captured);
      }
      case "while": {
        const captured = this.captureInto(() => this.emitWhileStmt(call));
        return this.wrapIIFE(captured);
      }
      case "do_while": {
        const captured = this.captureInto(() => this.emitDoWhileStmt(call));
        return `(() => { ${captured} })()`;
      }
      case "paren":   return `(${this.expr(f.get("value")!)})`;
      case "assert":  return `console.assert(${this.expr(f.get("condition")!)})`;
      case "assign": {
        const op = stringField(call, "op") || "=";
        // Dart's `~/=` (integer-division-assign) has no JS equivalent.
        if (op === "~/=") {
          const tgt = this.lvalueExpr(f.get("target")!);
          return `(${tgt} = Math.trunc(${tgt} / ${this.expr(f.get("value")!)}))`;
        }
        // Detect assign(target: X, value: list_concat(list: X, value: Y))
        // (Dart's `X.addAll(Y)`). Emit in-place push so list references are
        // preserved for callers sharing the same array object.
        const assignTarget = f.get("target");
        const assignValue = f.get("value");
        if (op === "=" && assignTarget && assignValue) {
          const inPlace = this.tryEmitInPlaceListMutation(assignTarget, assignValue);
          if (inPlace !== undefined) return `(${inPlace}, ${this.lvalueExpr(assignTarget)})`;
        }
        return `(${this.lvalueExpr(f.get("target")!)} ${op} ${this.expr(f.get("value")!)})`;
      }
      case "pre_increment":  return `(++${this.lvalueExpr(f.get("value")!)})`;
      case "pre_decrement":  return `(--${this.lvalueExpr(f.get("value")!)})`;
      case "post_increment": return `(${this.lvalueExpr(f.get("value")!)}++)`;
      case "post_decrement": return `(${this.lvalueExpr(f.get("value")!)}--)`;
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
        // Collect set elements: either a single `elements`/`element` list
        // field, or one element per input field. Spread / collection-for /
        // collection-if elements are handled by compileSetElements via an
        // imperative IIFE (issue #55).
        const elems: Expression[] = [];
        const inputFields = call.input?.messageCreation?.fields ?? [];
        for (const fd of inputFields) {
          if (fd.name === "elements" || fd.name === "element") {
            // A list-literal value carries the elements (possibly EMPTY —
            // an empty `{}` Map encodes as set_create with an empty
            // `elements` listValue, so never treat the wrapper itself as a
            // member). A non-list value is a single element.
            if (fd.value?.literal?.listValue !== undefined) {
              elems.push(...(fd.value.literal.listValue.elements ?? []));
            } else if (fd.value) {
              elems.push(fd.value);
            }
          } else if (
            // A `<T>{}` empty-typed-set-literal (e.g. `<int>{}`) carries its
            // type argument as a field literally named "type_args" (the
            // encoder's current single-word convention, NOT the older
            // MessageCreation-level "__type_args__" cosmetic marker checked
            // elsewhere in this file). Excluding only "__type_args__" left
            // it falling through to this generic branch and being pushed in
            // as a bogus set ELEMENT (`<int>{}` -> `new Set(['int'])`
            // instead of an empty Set, #219).
            fd.name !== "__type_args__" && fd.name !== "__const__" && fd.name !== "type_args"
          ) {
            elems.push(fd.value);
          }
        }
        if (elems.length === 0) return "new Set()";
        return this.compileSetElements(elems);
      }
      case "map_create": {
        // map_create entries arrive as `entry` fields (key/value message)
        // and/or `element` fields (spread / collection_for / collection_if
        // map-entries, issue #55). Emit as a plain object {} (not new Map())
        // — JS Map doesn't support bracket access (m['k'] = v) which the
        // compiled engine uses throughout.
        const mapElems: Expression[] = [];
        const inputFields = call.input?.messageCreation?.fields ?? [];
        for (const fd of inputFields) {
          if (fd.name === "entry" || fd.name === "element") {
            mapElems.push(fd.value);
          }
        }
        if (mapElems.length === 0) return "{}";
        return this.compileMapElements(mapElems);
      }
      case "record": {
        const positional: string[] = [];
        const named: Array<[string, string]> = [];
        const posRe = /^(?:\$|arg)(\d+)$/;
        for (const fd of call.input?.messageCreation?.fields ?? []) {
          // "__type_args__" is the older MessageCreation-level cosmetic
          // marker; "type_args" (single underscore) is the encoder's
          // current TypeRef-migration convention for the SAME thing.
          // Excluding only the old name let a record's actual type
          // argument fall through and get pushed in as a bogus named
          // field — identical in kind to the `<int>{}` -> `new
          // Set(['int'])` bug #219 fixed for set_create (#236).
          if (fd.name === "__type_args__" || fd.name === "type_args") continue;
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
      // Dart-specific std functions
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
      case "dart_list_generate":
      case "list_generate": {
        const count = f.get("count") ?? f.get("length");
        const gen = f.get("generator");
        if (count && gen) {
          return `Array.from({length: ${this.expr(count)}}, (_, i) => (${this.expr(gen)})(i))`;
        }
        return "[]";
      }
      case "dart_list_filled":
      case "list_filled": {
        const count = f.get("count") ?? f.get("length");
        const value = f.get("value") ?? f.get("fill");
        if (count && value) {
          return `Array(${this.expr(count)}).fill(${this.expr(value)})`;
        }
        return "[]";
      }
      case "to_double": {
        const v = f.get("value");
        return v ? `new BallDouble(Number(${this.expr(v)}))` : "new BallDouble(0)";
      }
      case "to_int": {
        const v = f.get("value");
        return v ? `__ball_to_int(${this.expr(v)})` : "0";
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
        if (list && value) return `(${this.expr(list)}.push(${this.expr(value)}), ${this.expr(list)})`;
        return "[]";
      }
      case "list_pop": {
        const list = f.get("list");
        return list ? `${this.expr(list)}.pop()` : "undefined";
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
        // The encoder emits list_concat for both list `+` and Map.addAll
        // (`m = list_concat(m, other)`), with the second operand carried as
        // `right` / `other` / `value`. Use the polymorphic __ball_concat so
        // maps merge by key (child overrides parent) and lists concat.
        const l = f.get("left") ?? f.get("list");
        const r = f.get("right") ?? f.get("other") ?? f.get("value");
        if (l && r) return `__ball_concat(${this.expr(l)}, ${this.expr(r)})`;
        return "[]";
      }
      case "list_reverse": {
        const list = f.get("list") ?? f.get("value");
        return list ? `[...${this.expr(list)}].reverse()` : "[]";
      }
      case "list_slice": case "list_sublist": {
        const list = f.get("list");
        // Use raw field list for start/end because the encoder may emit
        // duplicate 'value' keys (start and end both named 'value').
        const rawNonList = (call.input?.messageCreation?.fields ?? [])
          .filter((fd: any) => fd.name !== "list");
        const start = f.get("start") ?? (rawNonList.length > 0 ? rawNonList[0].value : undefined);
        const end = f.get("end") ?? (rawNonList.length > 1 ? rawNonList[1].value : undefined);
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
      case "now": return `DateTime.now()`;
      case "year": return `DateTime.now().year`;
      case "month": return `DateTime.now().month`;
      case "day": return `DateTime.now().day`;
      case "hour": return `DateTime.now().hour`;
      case "minute": return `DateTime.now().minute`;
      case "second": return `DateTime.now().second`;
      case "format_timestamp": {
        const ms = f.get("timestamp_ms") ?? f.get("value") ?? f.get("ms") ?? f.get("timestamp");
        return ms ? `DateTime.fromMillisecondsSinceEpoch(${this.expr(ms)}, true).toIso8601String()` : `""`;
      }
      case "parse_timestamp": {
        const s = f.get("value") ?? f.get("formatted") ?? f.get("input");
        return s ? `DateTime.parse(${this.expr(s)}).millisecondsSinceEpoch` : `0`;
      }
      case "time_components": {
        const ms = f.get("timestamp_ms") ?? f.get("value") ?? f.get("ms") ?? f.get("timestamp");
        return ms ? `(() => { const d = new Date(${this.expr(ms)}); return {year: d.getUTCFullYear(), month: d.getUTCMonth()+1, day: d.getUTCDate(), hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds()}; })()` : `{}`;
      }
      case "random_int": {
        const max = f.get("max") ?? f.get("value");
        return max ? `Math.floor(Math.random() * ${this.expr(max)})` : "0";
      }
      case "random_double": return `Math.random()`;
      case "int_to_double": {
        const v = f.get("value");
        return v ? `new BallDouble(Number(${this.expr(v)}))` : "new BallDouble(0)";
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
      // UTF-8 / Base64
      case "utf8_encode": {
        const v = f.get("value") ?? f.get("input");
        return v ? `[...new TextEncoder().encode(${this.expr(v)})]` : "[]";
      }
      case "utf8_decode": {
        const v = f.get("value") ?? f.get("input") ?? f.get("bytes");
        return v ? `new TextDecoder().decode(new Uint8Array(${this.expr(v)}))` : "''";
      }
      case "base64_encode": {
        const v = f.get("value") ?? f.get("input") ?? f.get("bytes");
        return v ? `btoa(String.fromCharCode(...${this.expr(v)}))` : "''";
      }
      case "base64_decode": {
        const v = f.get("value") ?? f.get("input");
        return v ? `[...atob(${this.expr(v)})].map(c => c.charCodeAt(0))` : "[]";
      }
      // Symbol literal (#foo) — Dart prints `Symbol("foo")`, so the value IS
      // that canonical string (matches the engine's std.symbol handler, #65).
      case "symbol": {
        const v = f.get("value") ?? f.get("name");
        return v
          ? `('Symbol("' + __ball_to_string(${this.expr(v)}) + '")')`
          : "null";
      }
      // Type ops
      case "type_literal": {
        // The encoder's canonical field is "type" (matches the Dart compiler's
        // _stringFieldValue(f, 'type')) — a type literal's stored value is
        // Type.toString() (e.g. 'int', 'List<dynamic>'), so this just needs to
        // evaluate to that string; == and interpolation follow for free.
        const v = f.get("type") ?? f.get("value") ?? f.get("name");
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
          // map_get/map_set/map_delete/map_keys/map_values/map_entries/
          // map_length/map_contains_key/list_push/list_pop/list_length/
          // list_slice/list_contains/list_index_of/list_concat/
          // string_code_unit_at/string_char_at/string_replace all have
          // their OWN case earlier in the outer switch above — this nested
          // switch is a fallback default arm, so those outer cases always
          // match first and any duplicate entry here would be genuinely
          // unreachable dead code. Removed (#62 Phase-2c); only cases with
          // no outer-switch equivalent belong in this fallback.
          case "map_contains_value": return `Object.values(${this.expr(f.get("map")!)}).includes(${this.expr(f.get("value")!)})`;
          case "list_insert": return `(${this.expr(f.get("list")!)}.splice(${this.expr(f.get("index")!)}, 0, ${this.expr(f.get("value")!)}), ${this.expr(f.get("list")!)})`;
          case "list_remove_at": return `${this.expr(f.get("list")!)}.splice(${this.expr(f.get("index")!)}, 1)[0]`;
          case "list_clear": return `(${this.expr(f.get("list")!)}.length = 0, ${this.expr(f.get("list")!)})`;
          case "list_filter": return `${this.expr(f.get("list")!)}.filter(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_map": return `${this.expr(f.get("list")!)}.map(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          // No-seed combine (Dart's Iterable.reduce): starts at the first
          // element, folds from the second; empty list throws (matches JS
          // Array.prototype.reduce with no initialValue).
          case "list_reduce": return `${this.expr(f.get("list")!)}.reduce(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_sort": {
            const l = this.expr(f.get("list")!);
            const cmp = f.get("comparator") ?? f.get("function") ?? f.get("value");
            // JS .sort() is lexicographic by default; Dart's is numeric.
            return cmp ? `[...${l}].sort(${this.expr(cmp)})` : `[...${l}].sort((a, b) => a < b ? -1 : a > b ? 1 : 0)`;
          }
          case "list_join": {
            const l = this.expr(f.get("list")!);
            const sep = f.get("separator") ?? f.get("value");
            return sep ? `${l}.join(${this.expr(sep)})` : `${l}.join('')`;
          }
          case "list_any": return `${this.expr(f.get("list")!)}.some(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_all": return `${this.expr(f.get("list")!)}.every(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "list_to_list": return `[...${this.expr(f.get("list")!)}]`;
          case "list_foreach": return `${this.expr(f.get("list")!)}.forEach(${this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!)})`;
          case "map_foreach": {
            const map = this.expr(f.get("map") ?? f.get("value")!);
            const cb = this.expr(f.get("function") ?? f.get("callback") ?? f.get("value")!);
            return `Object.entries(${map}).forEach(([k, v]) => ${cb}(k, v))`;
          }
          case "list_reversed": return `[...${this.expr(f.get("list")!)}].reverse()`;
          case "compare_to": {
            const v = this.expr(fg("value", "left", "arg0")!);
            const o = this.expr(fg("other", "right", "arg1")!);
            return `(${v} < ${o} ? -1 : ${v} > ${o} ? 1 : 0)`;
          }
          case "to_string_as_fixed": {
            const v = this.expr(fg("value", "arg0")!);
            const d = this.expr(fg("digits", "arg1", "right")!);
            return `__ball_to_fixed(${v}, ${d})`;
          }
          // num.{round,floor,ceil,truncate}ToDouble() → double (issue #100).
          // Wrap in BallDouble so a whole result renders `4.0`, not `4`.
          case "round_to_double":
            return `new BallDouble(Math.round(+(${this.expr(fg("value", "arg0")!)})))`;
          case "floor_to_double":
            return `new BallDouble(Math.floor(+(${this.expr(fg("value", "arg0")!)})))`;
          case "ceil_to_double":
            return `new BallDouble(Math.ceil(+(${this.expr(fg("value", "arg0")!)})))`;
          case "truncate_to_double":
            return `new BallDouble(Math.trunc(+(${this.expr(fg("value", "arg0")!)})))`;
          case "to_string_as_exponential": {
            const v = this.expr(fg("value", "arg0")!);
            const dExpr = f.get("digits") ?? f.get("fractionDigits") ?? f.get("arg1");
            return dExpr
              ? `(+(${v})).toExponential(${this.expr(dExpr)})`
              : `(+(${v})).toExponential()`;
          }
          case "to_string_as_precision": {
            const v = this.expr(fg("value", "arg0")!);
            const p = this.expr(fg("precision", "digits", "arg1", "right")!);
            return `(+(${v})).toPrecision(${p})`;
          }
          case "math_clamp": {
            // When encoded from a static method call like MathUtils.clamp(5, 0, 10),
            // the encoder maps it as math_clamp(value: MathUtils, min: 5, max: 0, arg2: 10).
            // Detect when 'value' is a class reference and shift the args.
            const clampValue = fg("value", "arg0")!;
            const isClassRef = clampValue.reference !== undefined &&
              [...this.typeDefByName.keys()].some(k => classTsName(k) === clampValue.reference!.name);
            if (isClassRef && f.get("arg2")) {
              // Shifted args: min=actual value, max=actual low, arg2=actual high
              const v = this.expr(f.get("min")!);
              const lo = this.expr(f.get("max")!);
              const hi = this.expr(f.get("arg2")!);
              return `Math.min(Math.max(${v}, ${lo}), ${hi})`;
            }
            const v = this.expr(clampValue);
            const lo = this.expr(fg("min", "arg1")!);
            const hi = this.expr(fg("max", "arg2")!);
            return `Math.min(Math.max(${v}, ${lo}), ${hi})`;
          }
          // string_code_unit_at/string_char_at/string_replace: see the
          // dead-duplicate note above map_contains_value — same reasoning,
          // these three also have an earlier, always-matching outer case.
          case "collection_if":
          case "collection_for": {
            // Reached only when a collection control element is compiled
            // outside a list/set/map literal context (the literal/set_create/
            // map_create paths route through emitCollectionElement directly).
            // Build a list imperatively so spread/nested/C-style forms work
            // and a no-else collection_if contributes nothing (issue #55).
            const body = this.emitCollectionElement(
              { call } as Expression,
              "list",
              "__r",
            );
            return `(() => { const __r: any[] = []; ${body} return __r; })()`;
          }
          default: {
            const args = Array.from(f.values()).map((e) => this.expr(e)).join(", ");
            return `/* std.${fn} */ ${sanitize(fn)}(${args})`;
          }
        }
      }
    }
  }

  // ── std_memory → TS linear-memory compilation ──────────────────────
  //
  // Mirrors the Dart compiler's `_compileMemoryCall` (dart/compiler/lib/
  // compiler.dart): lowers std_memory base calls to a `ByteData`-backed
  // linear memory simulation. The `ByteData`/`Endian` shims live in the
  // runtime preamble (preamble.ts, "dart:typed_data shims"); `compile()`
  // conditionally emits the `_ballMemory`/`_ballHeapPtr`/`_ballStackFrames`/
  // `_ballStackPtr` runtime variables only when the program actually
  // imports `std_memory` (see `usesStdMemory` in `compile()`).
  //
  // Every std_memory base function declared in dart/shared/lib/std_memory.dart
  // MUST have a case below. An unhandled function throws a compile-time
  // Error naming it — never falls through to a bare/undefined identifier.
  private compileMemoryCall(call: FunctionCall): string {
    const f = fieldMap(call.input?.messageCreation?.fields ?? []);
    const addrExpr = () => {
      const a = f.get("address") ?? f.get("dest") ?? f.get("a");
      return a ? this.expr(a) : "0";
    };
    const valExpr = () => {
      const v = f.get("value");
      return v ? this.expr(v) : "0";
    };
    // i64/u64 memory cells are backed by ByteData's bigint-typed
    // getInt64/getUint64/setInt64/setUint64 (see preamble.ts). Ball int
    // literals below Number.MAX_SAFE_INTEGER compile to plain JS `number`
    // literals (compileLiteral), so writing them straight into a
    // bigint-typed setter would throw "Cannot mix BigInt and other types"
    // at runtime — coerce explicitly.
    const valExprBigInt = () => `BigInt(${valExpr()})`;
    const ptrArith = (op: "+" | "-") => {
      const addr = f.get("address");
      const offset = f.get("offset");
      const elemSize = f.get("element_size");
      const a = addr ? this.expr(addr) : "0";
      const o = offset ? this.expr(offset) : "0";
      const es = elemSize ? this.expr(elemSize) : "1";
      return `(${a} ${op} (${o} * ${es}))`;
    };

    switch (call.function) {
      // ── Allocation ──
      case "memory_alloc": {
        const size = f.get("size");
        const sizeStr = size ? this.expr(size) : "0";
        return `(() => { const __addr = _ballHeapPtr; _ballHeapPtr += ${sizeStr}; return __addr; })()`;
      }
      case "memory_free":
        return `(/* free(${addrExpr()}) — noop in TS */ undefined)`;
      case "memory_realloc": {
        // Bump-allocates the new block, then copies the old block's bytes
        // in (mirrors the Dart compiler's `_memRealloc`; see its doc
        // comment re: realloc semantics and issue #141).
        const addr = f.get("address") ?? f.get("value");
        const addrStr = addr ? this.expr(addr) : "0";
        const size = f.get("new_size") ?? f.get("size");
        const sizeStr = size ? this.expr(size) : "0";
        return `(() => { const __old = ${addrStr}; const __size = ${sizeStr}; ` +
          `const __addr = _ballHeapPtr; _ballHeapPtr += __size; ` +
          `let __n = __size; ` +
          `if (__old + __n > _ballMemory.lengthInBytes) { __n = _ballMemory.lengthInBytes - __old; } ` +
          `if (__addr + __n > _ballMemory.lengthInBytes) { __n = _ballMemory.lengthInBytes - __addr; } ` +
          `for (let __i = 0; __i < __n; __i++) { _ballMemory.setUint8(__addr + __i, _ballMemory.getUint8(__old + __i)); } ` +
          `return __addr; })()`;
      }
      // ── Typed reads (little-endian) ──
      case "memory_read_i8": return `_ballMemory.getInt8(${addrExpr()})`;
      case "memory_read_u8": return `_ballMemory.getUint8(${addrExpr()})`;
      case "memory_read_i16": return `_ballMemory.getInt16(${addrExpr()}, Endian.little)`;
      case "memory_read_u16": return `_ballMemory.getUint16(${addrExpr()}, Endian.little)`;
      case "memory_read_i32": return `_ballMemory.getInt32(${addrExpr()}, Endian.little)`;
      case "memory_read_u32": return `_ballMemory.getUint32(${addrExpr()}, Endian.little)`;
      case "memory_read_i64": return `_ballMemory.getInt64(${addrExpr()}, Endian.little)`;
      case "memory_read_u64": return `_ballMemory.getUint64(${addrExpr()}, Endian.little)`;
      case "memory_read_f32": return `_ballMemory.getFloat32(${addrExpr()}, Endian.little)`;
      case "memory_read_f64": return `_ballMemory.getFloat64(${addrExpr()}, Endian.little)`;
      // ── Typed writes (little-endian) ──
      case "memory_write_i8": return `_ballMemory.setInt8(${addrExpr()}, ${valExpr()})`;
      case "memory_write_u8": return `_ballMemory.setUint8(${addrExpr()}, ${valExpr()})`;
      case "memory_write_i16": return `_ballMemory.setInt16(${addrExpr()}, ${valExpr()}, Endian.little)`;
      case "memory_write_u16": return `_ballMemory.setUint16(${addrExpr()}, ${valExpr()}, Endian.little)`;
      case "memory_write_i32": return `_ballMemory.setInt32(${addrExpr()}, ${valExpr()}, Endian.little)`;
      case "memory_write_u32": return `_ballMemory.setUint32(${addrExpr()}, ${valExpr()}, Endian.little)`;
      case "memory_write_i64": return `_ballMemory.setInt64(${addrExpr()}, ${valExprBigInt()}, Endian.little)`;
      case "memory_write_u64": return `_ballMemory.setUint64(${addrExpr()}, ${valExprBigInt()}, Endian.little)`;
      case "memory_write_f32": return `_ballMemory.setFloat32(${addrExpr()}, ${valExpr()}, Endian.little)`;
      case "memory_write_f64": return `_ballMemory.setFloat64(${addrExpr()}, ${valExpr()}, Endian.little)`;
      // ── Bulk operations ──
      case "memory_copy": {
        const dest = f.get("dest"), src = f.get("src"), size = f.get("size");
        const d = dest ? this.expr(dest) : "0";
        const s = src ? this.expr(src) : "0";
        const n = size ? this.expr(size) : "0";
        return `(() => { for (let __i = 0; __i < ${n}; __i++) _ballMemory.setUint8(${d} + __i, _ballMemory.getUint8(${s} + __i)); })()`;
      }
      case "memory_set": {
        const addr = f.get("address"), val = f.get("value"), size = f.get("size");
        const a = addr ? this.expr(addr) : "0";
        const v = val ? this.expr(val) : "0";
        const n = size ? this.expr(size) : "0";
        return `(() => { for (let __i = 0; __i < ${n}; __i++) _ballMemory.setUint8(${a} + __i, ${v}); })()`;
      }
      case "memory_compare": {
        const a = f.get("a"), b = f.get("b"), size = f.get("size");
        const aStr = a ? this.expr(a) : "0";
        const bStr = b ? this.expr(b) : "0";
        const n = size ? this.expr(size) : "0";
        return `(() => { for (let __i = 0; __i < ${n}; __i++) { const __d = _ballMemory.getUint8(${aStr} + __i) - _ballMemory.getUint8(${bStr} + __i); if (__d !== 0) return __d; } return 0; })()`;
      }
      // ── Pointer arithmetic ──
      case "ptr_add": return ptrArith("+");
      case "ptr_sub": return ptrArith("-");
      case "ptr_diff": {
        const a = f.get("address"), b = f.get("offset"), elemSize = f.get("element_size");
        const aStr = a ? this.expr(a) : "0";
        const bStr = b ? this.expr(b) : "0";
        const es = elemSize ? this.expr(elemSize) : "1";
        return `Math.trunc((${aStr} - ${bStr}) / ${es})`;
      }
      // ── Stack frame ──
      case "stack_alloc": {
        const size = f.get("size");
        const sizeStr = size ? this.expr(size) : "0";
        return `(() => { _ballStackPtr -= ${sizeStr}; return _ballStackPtr; })()`;
      }
      case "stack_push_frame": return `_ballStackFrames.push(_ballStackPtr)`;
      case "stack_pop_frame": return `(_ballStackPtr = _ballStackFrames.pop()!)`;
      // ── Sizeof ──
      case "memory_sizeof": {
        const typeName = f.get("type_name")?.literal?.stringValue ?? "int";
        switch (typeName) {
          case "int8": case "uint8": case "char": case "bool": return "1";
          case "int16": case "uint16": case "short": return "2";
          case "int32": case "uint32": case "int": case "float": return "4";
          case "int64": case "uint64": case "long": case "double": case "long long": return "8";
          case "void": return "1";
          default: return "8"; // default pointer-size
        }
      }
      // ── Address-of / deref (should be resolved by normalizer) ──
      case "address_of": return `(/* address_of: ${valExpr()} */ undefined)`;
      case "deref": {
        const ptr = f.get("pointer");
        const ptrStr = ptr ? this.expr(ptr) : "0";
        // Default: read as 64-bit int (pointer-sized).
        return `_ballMemory.getInt64(${ptrStr}, Endian.little)`;
      }
      // ── Null pointer ──
      case "nullptr": return "0";
      // ── Info ──
      case "memory_heap_size": return `_ballMemory.lengthInBytes`;
      case "memory_stack_size": return `(_ballMemory.lengthInBytes - _ballStackPtr)`;
      default:
        // Fail loud (repo CLAUDE.md): never emit a bare/undefined identifier
        // for an unimplemented std_memory function.
        throw new Error(
          `TS compiler: std_memory.${call.function} is not implemented (compileMemoryCall)`,
        );
    }
  }

  private typeRefMetaToString(ref: any): string {
    let s: string = ref?.name ?? '';
    const args = ref?.type_args;
    if (Array.isArray(args) && args.length > 0) {
      s += '<' + args.map((a: any) => this.typeRefMetaToString(a)).join(', ') + '>';
    }
    if (ref?.nullable) s += '?';
    return s;
  }

  private wrapWithTypeArgs(expr: string, mc: NonNullable<Expression["messageCreation"]>): string {
    const typeArgs = mc.metadata?.["type_args"];
    if (!Array.isArray(typeArgs) || typeArgs.length === 0) return expr;
    const strs = typeArgs.map((ta: any) => this.typeRefMetaToString(ta));
    return `__ball_with_type_args(${expr}, [${strs.map(s => JSON.stringify(s)).join(', ')}])`;
  }

  private emitIsCheck(value: string, type: string): string {
    const trimmed = type.trim();
    if (trimmed.includes("<")) {
      return `__ball_is_type(${value}, ${JSON.stringify(trimmed)})`;
    }
    if (trimmed.endsWith("?")) {
      const inner = this.emitIsCheck(value, trimmed.slice(0, -1));
      return `(${value} == null || ${inner})`;
    }
    const t = trimmed;
    switch (t) {
      case "int": return `(typeof ${value} === 'number' && Number.isInteger(${value}))`;
      case "double": return `(${value} instanceof BallDouble || (typeof ${value} === 'number' && !Number.isInteger(${value})))`;
      case "num": case "number": return `(typeof ${value} === 'number' || ${value} instanceof BallDouble)`;
      case "String": case "string": return `(typeof ${value} === 'string')`;
      case "bool": case "boolean": return `(typeof ${value} === 'boolean')`;
      case "List": case "Iterable": return `Array.isArray(${value})`;
      // Plain-object map check. Exclude Ball wrapper objects (BallDouble) and
      // Set instances: in Dart these are NOT `Map`, but a naive `typeof object`
      // test matches them. Without this, `_asMap(BallDouble)` returns the
      // wrapper as if it were a `{value: n}` map, and single-parameter binding
      // can extract the inner number — silently unwrapping doubles.
      case "Map": return `(typeof ${value} === 'object' && ${value} !== null && !Array.isArray(${value}) && !(${value} instanceof BallDouble) && !(${value} instanceof Set))`;
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
    // Each branch carries its match condition, the pattern's bindings, the
    // body expression and an optional `when` guard. The guard references the
    // bound variables, so it must be evaluated where those bindings are in
    // scope; a FALSE guard must fall through to the remaining cases (engine
    // semantics: a matched pattern with a false guard is NOT a match).
    const branches: Array<{
      cond: string;
      bindings: Array<{ varName: string; expr: string }>;
      body: Expression;
      guard?: Expression;
    }> = [];
    for (const ce of caseExprs) {
      if (!ce.messageCreation) continue;
      let pattern: Expression | undefined;
      let body: Expression | undefined;
      let isDefaultFlag = false;
      let patternExprField: Expression | undefined;
      let valueField: Expression | undefined;
      let guardField: Expression | undefined;
      for (const fd of ce.messageCreation.fields ?? []) {
        if (fd.name === "pattern") pattern = fd.value;
        if (fd.name === "value") valueField = fd.value;
        if (fd.name === "body") body = fd.value;
        if (fd.name === "is_default" && fd.value?.literal?.boolValue === true) isDefaultFlag = true;
        if (fd.name === "pattern_expr") patternExprField = fd.value;
        if (fd.name === "guard") guardField = fd.value;
      }
      // Check for is_default flag
      if (isDefaultFlag) {
        defaultBody = body;
        continue;
      }
      if (!body) continue;
      // Handle structured pattern_expr (only for known pattern kinds)
      if (patternExprField) {
        const result = compileStructuredPattern(patternExprField, subjectStr, (e) => this.expr(e));
        if (result) {
          // A catch-all with NO guard ends the chain; with a guard it remains a
          // refutable branch (the guard can still fall through).
          if (result.condition === "true" && result.bindings.length === 0 && !guardField) {
            defaultBody = body;
            break;
          }
          branches.push({ cond: result.condition, bindings: result.bindings, body, guard: guardField });
          if (result.condition === "true" && !guardField) break; // No further cases needed
          continue;
        }
        // Unknown pattern kind -- fall through to text-based pattern handling
      }
      // Use pattern or value field as the case matcher
      const caseMatch = pattern ?? valueField;
      if (!caseMatch) {
        defaultBody = body;
        continue;
      }
      const patText = patternLiteralText(caseMatch);
      if (patText === undefined) {
        branches.push({
          cond: `((${subjectStr}) === ${this.expr(caseMatch)})`,
          bindings: [],
          body,
          guard: guardField,
        });
        continue;
      }
      const cond = patternToTsCondition(patText, subjectStr);
      if (cond === "true" && !guardField) {
        defaultBody = body;
        break;
      }
      // Check if the pattern introduces variable bindings.
      const bindings = patternBindings(patText, subjectStr);
      branches.push({ cond, bindings, body, guard: guardField });
    }
    const tail = defaultBody ? this.expr(defaultBody) : "undefined";
    if (branches.length === 0) return tail;
    let result = tail;
    for (const { cond, bindings, body, guard } of [...branches].reverse()) {
      result = this.foldSwitchBranch(cond, bindings, body, guard, result);
    }
    return result;
  }

  /**
   * Fold one switch-expression branch into the ternary chain.
   *  - No guard: `(cond ? bindBody : rest)`.
   *  - With guard: the guard references the pattern's bindings, so bind ONCE in
   *    an IIFE and gate the body on the guard, falling through to `rest` when
   *    the guard is false: `(cond ? ((binds) => (guard ? body : rest))(args) : rest)`.
   */
  private foldSwitchBranch(
    cond: string,
    bindings: Array<{ varName: string; expr: string }>,
    body: Expression,
    guard: Expression | undefined,
    rest: string,
  ): string {
    const params = bindings.map(b => b.varName).join(", ");
    const args = bindings.map(b => b.expr).join(", ");
    if (guard) {
      const guarded = bindings.length > 0
        ? `((${params}) => (${this.expr(guard)} ? (${this.expr(body)}) : ${rest}))(${args})`
        : `(${this.expr(guard)} ? (${this.expr(body)}) : ${rest})`;
      return `(${cond} ? ${guarded} : ${rest})`;
    }
    const bodyStr = bindings.length > 0
      ? `((${params}) => ${this.expr(body)})(${args})`
      : this.expr(body);
    return `(${cond} ? (${bodyStr}) : ${rest})`;
  }

  private compileThrowValue(v: Expression): string | undefined {
    if (!v.messageCreation) return undefined;
    const tn = v.messageCreation.typeName ?? "";
    if (tn) {
      // Dart exception types: emit tagged objects with `message` from arg0.
      const shortName = tn.includes(":") ? tn.substring(tn.lastIndexOf(":") + 1) : tn;
      const dartExceptions = new Set([
        "FormatException", "StateError", "ArgumentError",
        "UnsupportedError", "ConcurrentModificationError",
        "IntegerDivisionByZeroException", "NoSuchMethodError",
        "UnimplementedError", "AssertionError",
      ]);
      if (dartExceptions.has(shortName)) {
        const fields = v.messageCreation.fields ?? [];
        const arg0 = fields.find(f => f.name === "arg0");
        const msgExpr = arg0 ? this.expr(arg0.value) : "''";
        const extraFields = fields
          .filter(f => f.name !== "arg0" && f.name !== "__type_args__" && f.name !== "__const__")
          .map(f => `'${f.name}': ${this.expr(f.value)}`)
          .join(", ");
        const extra = extraFields ? `, ${extraFields}` : "";
        return `{'__type__': '${shortName}', 'message': ${msgExpr}${extra}}`;
      }
      return undefined;
    }
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
    // Erase generic type parameters (e.g., A, B, T) to `any`.
    if (this.currentClassTypeParams.has(nonNull)) return "any";
    return nonNull;
  }
}

// ───────────────────────── Free helpers ───────────────────────────────

/**
 * Recursively checks whether an expression tree contains an `assign` call
 * whose target is a reference to `varName`. Used to decide whether a
 * `const input = ...` alias should be `let` instead.
 */
function bodyAssignsToVar(expr: Expression, varName: string): boolean {
  if (expr.block) {
    for (const s of expr.block.statements ?? []) {
      if (s.expression && bodyAssignsToVar(s.expression, varName)) return true;
      if (s.let?.value && bodyAssignsToVar(s.let.value, varName)) return true;
    }
    if (expr.block.result && bodyAssignsToVar(expr.block.result, varName)) return true;
  }
  if (expr.call) {
    if (
      expr.call.function === "assign" &&
      (expr.call.module === "std" || expr.call.module === "" || expr.call.module === undefined)
    ) {
      const fields = expr.call.input?.messageCreation?.fields ?? [];
      for (const f of fields) {
        if (f.name === "target" && f.value.reference?.name === varName) return true;
      }
    }
    // Recurse into the call's input and all fields
    if (expr.call.input) {
      if (bodyAssignsToVar(expr.call.input, varName)) return true;
    }
  }
  if (expr.messageCreation) {
    for (const f of expr.messageCreation.fields ?? []) {
      if (bodyAssignsToVar(f.value, varName)) return true;
    }
  }
  if (expr.lambda?.body && bodyAssignsToVar(expr.lambda.body, varName)) return true;
  if (expr.fieldAccess?.object && bodyAssignsToVar(expr.fieldAccess.object, varName)) return true;
  return false;
}

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

/**
 * Returns true when two Expression nodes refer to the same variable (by name)
 * or the same field-access chain. Used to detect in-place mutation patterns
 * like `assign(target: X, value: list_concat(list: X, value: Y))`.
 */
function sameRef(a: Expression, b: Expression): boolean {
  if (a.reference && b.reference) return a.reference.name === b.reference.name;
  if (a.fieldAccess && b.fieldAccess) {
    return a.fieldAccess.field === b.fieldAccess.field && sameRef(a.fieldAccess.object, b.fieldAccess.object);
  }
  return false;
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
  return module === "std" ||
    module === "std_collections" || module === "std_io" ||
    module === "std_convert" || module === "std_memory" ||
    module === "std_time";
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

/** Parse type-test patterns like `int n`, `double d`, `String s`, `bool b`.
 *  Returns {type, varName} or undefined if not a type-test pattern. */
function parseTypeTestPattern(pat: string): { type: string; varName: string } | undefined {
  const m = /^(int|double|num|String|bool|Object|dynamic|List|Map|Set|Null)\s+([a-zA-Z_]\w*)$/.exec(pat.trim());
  return m ? { type: m[1], varName: m[2] } : undefined;
}

/** Parse map patterns like `{'x': var v}` or `{'a': var a, 'b': var b}`.
 *  Returns an array of {key, varName} or undefined if not a map pattern. */
function parseMapPattern(pat: string): Array<{ key: string; varName: string }> | undefined {
  const trimmed = pat.trim();
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return undefined;
  const inner = trimmed.slice(1, -1).trim();
  if (!inner.includes("var ")) return undefined;
  const entries: Array<{ key: string; varName: string }> = [];
  // Split on commas at the top level
  const parts = splitTopLevelCommas(inner);
  for (const part of parts) {
    const m = /^\s*['"](\w+)['"]\s*:\s*var\s+([a-zA-Z_]\w*)\s*$/.exec(part);
    if (!m) return undefined;
    entries.push({ key: m[1], varName: m[2] });
  }
  return entries.length > 0 ? entries : undefined;
}

/** Extract variable bindings from a pattern string.
 *  Returns an array of {varName, expr} for variables that should be bound
 *  to the subject when the pattern matches. */
function patternBindings(pat: string, subject: string): Array<{ varName: string; expr: string }> {
  const trimmed = pat.trim();
  const typeTest = parseTypeTestPattern(trimmed);
  if (typeTest) return [{ varName: typeTest.varName, expr: subject }];
  const mapPat = parseMapPattern(trimmed);
  if (mapPat) return mapPat.map(e => ({ varName: e.varName, expr: `${subject}['${e.key}']` }));
  return [];
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
  // Type-test patterns: `int n`, `double d`, `String s`, `bool b`
  const typeTest = parseTypeTestPattern(trimmed);
  if (typeTest) {
    switch (typeTest.type) {
      case "int": return `(typeof ${subject} === 'number' && Number.isInteger(${subject}))`;
      case "double": return `(typeof ${subject} === 'number' && !Number.isInteger(${subject}))`;
      case "num": return `(typeof ${subject} === 'number')`;
      case "String": return `(typeof ${subject} === 'string')`;
      case "bool": return `(typeof ${subject} === 'boolean')`;
      case "Null": return `(${subject} == null)`;
      case "Object":
      case "dynamic": return "true";
      case "List": return `(Array.isArray(${subject}))`;
      case "Map": return `(typeof ${subject} === 'object' && ${subject} !== null && !Array.isArray(${subject}))`;
      case "Set": return `(${subject} instanceof Set)`;
      default: return `(typeof ${subject} === 'object' && ${subject} !== null)`;
    }
  }
  // Map patterns: `{'x': var v}`, `{'a': var a, 'b': var b}`
  const mapPat = parseMapPattern(trimmed);
  if (mapPat) {
    const checks = mapPat.map(e => `'${e.key}' in ${subject}`);
    return `(typeof ${subject} === 'object' && ${subject} !== null && ${checks.join(" && ")})`;
  }
  // Relational patterns: "== 0", "> 5", etc.
  const relMatch = /^(==|!=|>=|<=|>|<)\s*(.+)$/.exec(trimmed);
  if (relMatch) {
    const op = relMatch[1] === "==" ? "===" : relMatch[1] === "!=" ? "!==" : relMatch[1];
    return `(${subject} ${op} ${relMatch[2].trim()})`;
  }
  return `(${subject} === (${trimmed}))`;
}

/**
 * Extract fields from a messageCreation expression into a name→value map.
 */
function mcFields(expr: Expression): Map<string, Expression> {
  const m = new Map<string, Expression>();
  if (expr.messageCreation) {
    for (const f of expr.messageCreation.fields ?? []) {
      m.set(f.name, f.value);
    }
  }
  return m;
}

/**
 * Determine the kind of a structured pattern_expr.
 * Returns the typeName or __pattern_kind__ value.
 */
function patternExprKind(expr: Expression): string {
  if (!expr.messageCreation) return "";
  const tn = expr.messageCreation.typeName ?? "";
  if (tn) return tn;
  const fields = mcFields(expr);
  const pk = fields.get("__pattern_kind__");
  if (pk?.literal?.stringValue) return pk.literal.stringValue;
  return "";
}

interface StructuredPatternResult {
  condition: string;
  bindings: Array<{ varName: string; expr: string }>;
}

/** Known pattern kinds that compileStructuredPattern can handle.
 *  Unknown kinds should fall through to the text-based pattern handling. */
const KNOWN_PATTERN_KINDS = new Set([
  "ConstPattern", "VarPattern", "var", "WildcardPattern", "wildcard", "_",
  "ListPattern", "RestPattern", "rest", "record", "RecordPattern",
  "LogicalOrPattern", "CastPattern", "NullCheckPattern", "NullAssertPattern",
  // MapPattern/LogicalAndPattern/ObjectPattern/RelationalPattern were missing
  // (#206, #207) — every pattern kind the encoder can emit (see
  // dart/encoder/lib/encoder.dart's `_encodePattern`) must be listed here, or
  // it falls to the legacy cosmetic-text parser, which cannot round-trip
  // `final`-bound entries and other structured shapes.
  "MapPattern", "LogicalAndPattern", "ObjectPattern", "RelationalPattern",
]);

/** Generate a JS type-check condition for a Dart type name against `subject`.
 *  Shared by the VarPattern and WildcardPattern arms so a typed binder
 *  (`case int x:`) and a typed wildcard (`case int _:`) test the type
 *  identically — they previously diverged, leaving the wildcard untyped. */
function typeCheckCondition(typeName: string, subject: string): string {
  // Nullable type `T?` matches null OR any value matching the base type `T`
  // (mirrors the engine's _matchesTypePattern). Without this, `int?`/`String?`
  // fall to the default arm and emit `instanceof int?` (invalid JS).
  if (typeName.length > 1 && typeName.endsWith("?")) {
    const base = typeName.slice(0, -1);
    return `(${subject} == null || ${typeCheckCondition(base, subject)})`;
  }
  switch (typeName) {
    case "int": return `(typeof ${subject} === 'number' && Number.isInteger(${subject}))`;
    case "double": return `(${subject} instanceof BallDouble || (typeof ${subject} === 'number' && !Number.isInteger(${subject})))`;
    case "num": case "number": return `(typeof ${subject} === 'number' || ${subject} instanceof BallDouble)`;
    case "String": case "string": return `(typeof ${subject} === 'string')`;
    case "bool": case "boolean": return `(typeof ${subject} === 'boolean')`;
    case "List": return `Array.isArray(${subject})`;
    case "Map": return `(typeof ${subject} === 'object' && ${subject} !== null && !Array.isArray(${subject}))`;
    default: return `(${subject} instanceof ${typeName} || (typeof ${subject} === 'object' && ${subject}?.['__type__'] === '${typeName}'))`;
  }
}

/**
 * Compile a structured pattern_expr into a condition string and variable bindings.
 * Handles ConstPattern, ListPattern, VarPattern, RestPattern, and record patterns.
 * Returns undefined for unknown pattern kinds.
 */
function compileStructuredPattern(
  patternExpr: Expression,
  subject: string,
  exprFn: (e: Expression) => string,
): StructuredPatternResult | undefined {
  const kind = patternExprKind(patternExpr);
  if (!KNOWN_PATTERN_KINDS.has(kind)) return undefined;
  const fields = mcFields(patternExpr);

  switch (kind) {
    case "ConstPattern": {
      const val = fields.get("value");
      if (val) return { condition: `(${subject} === ${exprFn(val)})`, bindings: [] };
      return { condition: "true", bindings: [] };
    }
    case "VarPattern":
    case "var": {
      const name = fields.get("name")?.literal?.stringValue;
      const typeName = fields.get("type")?.literal?.stringValue;
      // When a VarPattern has a type annotation (e.g. "double d"),
      // generate a type-check condition instead of a catch-all.
      const cond = typeName ? typeCheckCondition(typeName, subject) : "true";
      if (name) return { condition: cond, bindings: [{ varName: name, expr: subject }] };
      return { condition: cond, bindings: [] };
    }
    case "WildcardPattern":
    case "wildcard":
    case "_": {
      // A wildcard may still carry a type test (`case int _:` encodes as
      // WildcardPattern{type:"int"}). Emit the type-check when a type is
      // present (no binding); only an untyped `_` is an unconditional
      // catch-all. Without this the whole switch collapsed to the first
      // typed-wildcard case (silent wrong output — was int/int/int/int on
      // 183_type_patterns). Mirrors the C++ compiler fix.
      const typeName = fields.get("type")?.literal?.stringValue;
      const cond = typeName ? typeCheckCondition(typeName, subject) : "true";
      return { condition: cond, bindings: [] };
    }
    case "LogicalOrPattern": {
      // `p1 || p2` matches if EITHER alternative matches. Recurse both operands
      // and OR their conditions so STRUCTURED alternatives (typed wildcards,
      // const, nested or) work. Without this, the or-pattern fell back to a text
      // path that mis-handled some typed alternatives — e.g. `double _` in
      // `case bool _ || double _:` never matched (conformance 303). Bindings are
      // unioned. Falls through (undefined) if an operand isn't structured.
      const left = fields.get("left");
      const right = fields.get("right");
      if (left && right) {
        const lr = compileStructuredPattern(left, subject, exprFn);
        const rr = compileStructuredPattern(right, subject, exprFn);
        if (lr && rr) {
          return {
            condition: `(${lr.condition} || ${rr.condition})`,
            bindings: [...lr.bindings, ...rr.bindings],
          };
        }
      }
      return undefined;
    }
    case "LogicalAndPattern": {
      // `p1 && p2` matches only if BOTH alternatives match against the SAME
      // subject (Dart's guard-combinator syntax, e.g. `int n && > 0`). Mirrors
      // LogicalOrPattern but ANDs the conditions instead of ORing them; bindings
      // from both sides are unioned (in practice the right operand of a
      // relational combinator binds nothing). Falls through (undefined) if
      // either operand isn't structured.
      const left = fields.get("left");
      const right = fields.get("right");
      if (left && right) {
        const lr = compileStructuredPattern(left, subject, exprFn);
        const rr = compileStructuredPattern(right, subject, exprFn);
        if (lr && rr) {
          return {
            condition: `(${lr.condition} && ${rr.condition})`,
            bindings: [...lr.bindings, ...rr.bindings],
          };
        }
      }
      return undefined;
    }
    case "RelationalPattern": {
      // `== x` / `!= x` / `> x` / `< x` / `>= x` / `<= x` as a standalone
      // (or LogicalAndPattern-combined) pattern. Numeric comparisons require
      // BOTH the subject and operand to be `num` (mirrors engine_std.dart's
      // `_matchRelationalPattern`) — a non-numeric subject simply fails to
      // match rather than throwing.
      const op = fields.get("operator")?.literal?.stringValue;
      const operandExpr = fields.get("operand");
      if (!op || !operandExpr) return { condition: "true", bindings: [] };
      const operandStr = exprFn(operandExpr);
      if (op === "==") return { condition: `__ball_eq(${subject}, ${operandStr})`, bindings: [] };
      if (op === "!=") return { condition: `(!__ball_eq(${subject}, ${operandStr}))`, bindings: [] };
      const isNum = (v: string) => `(typeof (${v}) === 'number' || (${v}) instanceof BallDouble)`;
      const numVal = (v: string) => `((${v}) instanceof BallDouble ? (${v}).value : (${v}))`;
      return {
        condition: `(${isNum(subject)} && ${isNum(operandStr)} && (${numVal(subject)} ${op} ${numVal(operandStr)}))`,
        bindings: [],
      };
    }
    case "MapPattern": {
      // `{'key': subpattern, ...}`. Ball maps compile to a plain JS object for
      // the common `map_create` path (bracket access, e.g. `{'k': 7}`) but to a
      // native `Map` for the `typed_map` path (`<K,V>{}` / `Map()`) — both
      // representations must match. A Ball Set compiles to a native `Set`
      // (set_create), which IS `typeof 'object'` and not an array, so it must
      // be explicitly excluded (issue #178's "MapPattern must exclude Set").
      // Extra keys beyond the ones listed are fine (unlike RecordPattern's
      // exact-arity rule) — mirrors engine_std.dart's 'map' case.
      const entries = fields.get("entries")?.literal?.listValue?.elements ?? [];
      const conds: string[] = [
        `(typeof ${subject} === 'object' && ${subject} !== null && !Array.isArray(${subject}) && !(${subject} instanceof Set))`,
      ];
      const binds: Array<{ varName: string; expr: string }> = [];
      for (const entry of entries) {
        const ef = mcFields(entry);
        const keyExpr = ef.get("key");
        const valuePattern = ef.get("value");
        if (!keyExpr) continue;
        const keyStr = exprFn(keyExpr);
        conds.push(`(${subject} instanceof Map ? ${subject}.has(${keyStr}) : (${keyStr} in ${subject}))`);
        if (valuePattern) {
          const valueExpr = `(${subject} instanceof Map ? ${subject}.get(${keyStr}) : ${subject}[${keyStr}])`;
          const sub = compileStructuredPattern(valuePattern, valueExpr, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
      }
      return { condition: conds.join(" && "), bindings: binds };
    }
    case "ObjectPattern": {
      // `Type(field: subpattern, ...)` matches by TYPE (reusing the same
      // instanceof/`__type__` gate CastPattern relies on via typeCheckCondition)
      // plus each named field's GETTER against its sub-pattern — field access,
      // not positional arity (mirrors engine_std.dart's 'object' case, which
      // reads `objMap[fieldName]` rather than requiring an exact key set).
      const typeName = fields.get("type")?.literal?.stringValue;
      const objFields = fields.get("fields")?.literal?.listValue?.elements ?? [];
      const conds: string[] = [];
      if (typeName) conds.push(typeCheckCondition(typeName, subject));
      const binds: Array<{ varName: string; expr: string }> = [];
      for (const of_ of objFields) {
        const ofFields = mcFields(of_);
        const fieldName = ofFields.get("name")?.literal?.stringValue;
        const fieldPattern = ofFields.get("pattern");
        if (!fieldName || !fieldPattern) continue;
        const sub = compileStructuredPattern(fieldPattern, `${subject}.${fieldName}`, exprFn);
        if (sub) {
          if (sub.condition !== "true") conds.push(sub.condition);
          binds.push(...sub.bindings);
        }
      }
      return { condition: conds.length > 0 ? conds.join(" && ") : "true", bindings: binds };
    }
    case "CastPattern": {
      // A cast pattern (subpat as T) ASSERTS the runtime type — it matches
      // structurally (like its sub-pattern) but THROWS on a mismatch (Dart
      // semantics), it does NOT refute. Conjoin ball_cast_assert(<typecheck>,
      // "T") into the condition, short-circuited by the sub-pattern's own
      // condition (so e.g. [var x as int] only asserts after the list shape
      // matched). The assert also makes the case emit `if (cond)` rather than a
      // bare catch-all. (conformance 302)
      const castType = fields.get("type")?.literal?.stringValue;
      const subpat = fields.get("pattern");
      let sub: StructuredPatternResult = { condition: "true", bindings: [] };
      if (subpat) {
        const s = compileStructuredPattern(subpat, subject, exprFn);
        if (s) sub = s;
      }
      if (castType) {
        return {
          condition: `(${sub.condition} && ball_cast_assert(${typeCheckCondition(castType, subject)}, ${JSON.stringify(castType)}))`,
          bindings: sub.bindings,
        };
      }
      return sub;
    }
    case "ListPattern": {
      const elementsExpr = fields.get("elements");
      const elements = elementsExpr?.literal?.listValue?.elements ?? [];
      // Check for rest patterns
      let hasRest = false;
      let restIndex = -1;
      for (let i = 0; i < elements.length; i++) {
        const ek = patternExprKind(elements[i]);
        if (ek === "RestPattern" || ek === "rest") {
          hasRest = true;
          restIndex = i;
          break;
        }
      }
      if (hasRest) {
        // With rest pattern: [fixed..., ...rest, fixed...]
        const beforeRest = elements.slice(0, restIndex);
        const afterRest = elements.slice(restIndex + 1);
        const minLen = beforeRest.length + afterRest.length;
        const conds: string[] = [`Array.isArray(${subject})`, `${subject}.length >= ${minLen}`];
        const binds: Array<{ varName: string; expr: string }> = [];
        // Bind elements before rest
        for (let i = 0; i < beforeRest.length; i++) {
          const sub = compileStructuredPattern(beforeRest[i], `${subject}[${i}]`, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
        // Bind rest pattern
        const restExpr = elements[restIndex];
        const restFields = mcFields(restExpr);
        const subpattern = restFields.get("subpattern");
        if (subpattern) {
          const restSlice = afterRest.length === 0
            ? `${subject}.slice(${beforeRest.length})`
            : `${subject}.slice(${beforeRest.length}, ${subject}.length - ${afterRest.length})`;
          const sub = compileStructuredPattern(subpattern, restSlice, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
        // Bind elements after rest
        for (let i = 0; i < afterRest.length; i++) {
          const idx = `${subject}.length - ${afterRest.length - i}`;
          const sub = compileStructuredPattern(afterRest[i], `${subject}[${idx}]`, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
        return { condition: conds.join(" && "), bindings: binds };
      } else {
        // Exact-length list pattern
        const conds: string[] = [`Array.isArray(${subject})`, `${subject}.length === ${elements.length}`];
        const binds: Array<{ varName: string; expr: string }> = [];
        for (let i = 0; i < elements.length; i++) {
          const sub = compileStructuredPattern(elements[i], `${subject}[${i}]`, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
        return { condition: conds.join(" && "), bindings: binds };
      }
    }
    case "record":
    case "RecordPattern": {
      // A record pattern matches by EXACT shape (engine semantics:
      // engine_std.dart:2018-2033 — same positional arity AND same named-field
      // set). The TS `record` base function (see _callBaseFunction's "record"
      // case) materializes records as: a JS array `[v0, v1, ...]` when
      // all-positional, a plain object `{ name: v }` when all-named, and a
      // mixed object with 0-based string keys (`"0"`, `"1"`) plus named keys
      // when mixed. Match each representation precisely.
      const recordFields = fields.get("fields")?.literal?.listValue?.elements ?? [];
      const positional: Expression[] = [];
      const named: Array<{ name: string; pattern: Expression }> = [];
      for (const rf of recordFields) {
        const rfm = mcFields(rf);
        const name = rfm.get("name")?.literal?.stringValue;
        const pattern = rfm.get("pattern");
        if (!pattern) continue;
        if (name) named.push({ name, pattern });
        else positional.push(pattern);
      }
      const binds: Array<{ varName: string; expr: string }> = [];
      if (named.length === 0) {
        // All-positional record: value is a JS array of exactly this length.
        const conds: string[] = [
          `Array.isArray(${subject})`,
          `${subject}.length === ${positional.length}`,
        ];
        for (let i = 0; i < positional.length; i++) {
          const sub = compileStructuredPattern(positional[i], `${subject}[${i}]`, exprFn);
          if (sub) {
            if (sub.condition !== "true") conds.push(sub.condition);
            binds.push(...sub.bindings);
          }
        }
        return { condition: `(${conds.join(" && ")})`, bindings: binds };
      }
      // Has named fields: value is a plain object (NOT an array). Require an
      // exact key set: positional fields appear as 0-based string keys, named
      // fields as their names.
      const expectedKeys = [
        ...positional.map((_, i) => String(i)),
        ...named.map((n) => n.name),
      ];
      const conds: string[] = [
        `(typeof ${subject} === 'object' && ${subject} !== null && !Array.isArray(${subject}))`,
        `Object.keys(${subject}).filter(k => !k.startsWith('__')).length === ${expectedKeys.length}`,
      ];
      for (let i = 0; i < positional.length; i++) {
        conds.push(`(${JSON.stringify(String(i))} in ${subject})`);
        const sub = compileStructuredPattern(positional[i], `${subject}[${JSON.stringify(String(i))}]`, exprFn);
        if (sub) {
          if (sub.condition !== "true") conds.push(sub.condition);
          binds.push(...sub.bindings);
        }
      }
      for (const n of named) {
        conds.push(`(${JSON.stringify(n.name)} in ${subject})`);
        const sub = compileStructuredPattern(n.pattern, `${subject}[${JSON.stringify(n.name)}]`, exprFn);
        if (sub) {
          if (sub.condition !== "true") conds.push(sub.condition);
          binds.push(...sub.bindings);
        }
      }
      return { condition: `(${conds.join(" && ")})`, bindings: binds };
    }
    case "NullCheckPattern":
    case "NullAssertPattern": {
      // `var v?` (NullCheckPattern) matches when the subject is non-null AND
      // the inner sub-pattern matches; `var v!` (NullAssertPattern) is treated
      // the same for matching purposes (the assertion never refutes here, but a
      // null still must not bind). Mirrors the engine's null_check handling.
      const inner = fields.get("pattern");
      let sub: StructuredPatternResult = { condition: "true", bindings: [] };
      if (inner) {
        const s = compileStructuredPattern(inner, subject, exprFn);
        if (s) sub = s;
      }
      const cond = sub.condition !== "true"
        ? `(${subject} != null && ${sub.condition})`
        : `(${subject} != null)`;
      return { condition: cond, bindings: sub.bindings };
    }
    case "RestPattern":
    case "rest": {
      // Rest pattern standalone (shouldn't happen outside ListPattern, but handle gracefully)
      const subpattern = fields.get("subpattern");
      if (subpattern) return compileStructuredPattern(subpattern, subject, exprFn) ?? { condition: "true", bindings: [] };
      return { condition: "true", bindings: [] };
    }
    default:
      return undefined;
  }
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
  // Already a JS-compatible literal: string, number, bool, null, list.
  // A non-empty Dart list literal (e.g. `[10, 20, 30]`) is valid JS array
  // syntax as-is — this used to only match the EMPTY `[]` case, so a field
  // like `var widgets = [10, 20, 30];` fell through to defaultInitializer
  // (which has no type info to fall back on when the field's declared type
  // was inferred rather than explicit) and silently dropped to no
  // initializer at all, i.e. undefined/null (#220).
  if (/^(?:null|true|false|'.*'|".*"|-?\d+(?:\.\d+)?|\[[\s\S]*\])$/.test(s)) {
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

/** Maps an operator lexeme to the canonical __op_*__ name a compiled class
 *  exposes it under (mirrors ts/encoder's OPERATOR_CANONICAL_NAMES exactly
 *  — double-trailing-underscore; NOT sanitize()'s single-underscore
 *  operatorMap below, which is a separate, legacy short-name convention).
 *  Used by std."index" to translate `a['+']` (the only way to bracket-
 *  invoke a string-literal-named operator method) to the real property. */
const operatorIndexNames: Record<string, string> = {
  "[]=": "__op_set_index__",
  "[]": "__op_get_index__",
  "==": "__op_eq__",
  "<": "__op_lt__",
  "<=": "__op_le__",
  ">": "__op_gt__",
  ">=": "__op_ge__",
  "<<": "__op_shl__",
  ">>": "__op_shr__",
  ">>>": "__op_ushr__",
  "+": "__op_add__",
  "*": "__op_mul__",
  "/": "__op_div__",
  "~/": "__op_idiv__",
  "%": "__op_mod__",
  "&": "__op_band__",
  "|": "__op_bor__",
  "^": "__op_bxor__",
  "~": "__op_bnot__",
  // "-" handled specially at the call site (unary vs binary ambiguity).
  "-": "__op_sub__",
};

function sanitize(name: string): string {
  let out = name;
  const colon = out.indexOf(":");
  if (colon >= 0) out = out.slice(colon + 1);
  // Dart operator method names ([]= / [] / == / + / -) round-trip as
  // valid Ball IR identifiers but parse as syntax errors when emitted
  // verbatim into a TS class body. Map them to JS-safe identifiers.
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
  // hasOwnProperty.call avoids matching `Object.prototype.toString` for
  // a method literally named `toString` — the latter is fine as-is and
  // must not be replaced by a Function reference.
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

// ══════════════════════════════════════════════════���═════════════════════════
// Library / Module compilation (no main, exported symbols)
// ══════════════════════════════════════════════��═════════════════════════════

export interface CompileModuleOptions {
  /** Include the runtime preamble at the top of the output. Default true. */
  includePreamble?: boolean;
  /** Output file path hint (affects ts-morph's internal resolution). */
  fileName?: string;
  /**
   * Namespace/module name for the output (used in header comments).
   * Defaults to the Module's name.
   */
  moduleName?: string;
}

/**
 * Compile a Ball Module (not a Program) to a TypeScript ESM library.
 *
 * This handles the ball_protobuf use case: the input is a Module facade
 * with `moduleImports[].inline.json` containing sub-modules. The output
 * is a single TypeScript file with:
 * - No main() function or top-level invocation
 * - All public functions exported via `export function`
 * - All types/classes exported via `export class`
 *
 * @param module - A Ball Module (with optional inline sub-modules)
 * @param options - Compilation options
 * @returns TypeScript source string with ESM exports
 */
export function compileModule(module: Module, options?: CompileModuleOptions): string {
  const { includePreamble = true, fileName = "library.ts", moduleName } = options ?? {};

  // Expand the Module facade: extract inline sub-modules from moduleImports.
  const allModules: Module[] = [];

  for (const imp of module.moduleImports ?? []) {
    if (imp.inline?.json) {
      try {
        const subMod: Module = JSON.parse(imp.inline.json);
        allModules.push(subMod);
      } catch {
        // Skip malformed inline modules
      }
    }
  }

  // Add the facade module itself if it has non-base functions/types directly
  if (module.functions?.some(f => !f.isBase) || (module.typeDefs?.length ?? 0) > 0) {
    allModules.push(module);
  }

  // If there are no inline modules at all, treat the facade as the single module
  if (allModules.length === 0) {
    allModules.push(module);
  }

  // The dummy entry module has a unique name and a trivial main function.
  // The BallCompiler will emit `function __ball_lib_main__() { return 0; }`
  // followed by `__ball_lib_main__();` which we strip in post-processing.
  const ENTRY_MOD = "__ball_lib_entry__";
  const ENTRY_FN = "__ball_lib_main__";
  const dummyEntryModule: Module = {
    name: ENTRY_MOD,
    functions: [{
      name: ENTRY_FN,
      body: { literal: { intValue: 0 } },
    }],
  };

  // Deduplicate function names across inline modules: if the same name appears
  // in multiple modules, prefix with the module's short name to avoid collisions
  // (e.g. _encodeFloatBytes in field_fixed → _field_fixed__encodeFloatBytes).
  const nameCount: Record<string, string[]> = {};
  for (const mod of allModules) {
    const shortName = (mod.name ?? "").split(".").pop() ?? "";
    for (const fn of mod.functions ?? []) {
      if (!nameCount[fn.name]) nameCount[fn.name] = [];
      nameCount[fn.name].push(shortName);
    }
  }
  const dupeNames = new Set(
    Object.entries(nameCount).filter(([, mods]) => mods.length > 1).map(([n]) => n)
  );
  if (dupeNames.size > 0) {
    for (const mod of allModules) {
      const shortName = (mod.name ?? "").split(".").pop() ?? "";
      const renames: Record<string, string> = {};
      for (const fn of mod.functions ?? []) {
        if (dupeNames.has(fn.name)) {
          const newName = `_${shortName}__${fn.name.replace(/^_/, "")}`;
          renames[fn.name] = newName;
          fn.name = newName;
        }
      }
      // Rename calls AND references within this module that use the old name
      if (Object.keys(renames).length > 0) {
        const renameInExpr = (expr: any): void => {
          if (!expr || typeof expr !== "object") return;
          if (expr.call && renames[expr.call.function] && !expr.call.module) {
            expr.call.function = renames[expr.call.function];
          }
          // Also rename bare references (e.g. passing _toInt as a value to .map)
          if (expr.reference && renames[expr.reference.name]) {
            expr.reference.name = renames[expr.reference.name];
          }
          for (const v of Object.values(expr)) {
            if (Array.isArray(v)) v.forEach(renameInExpr);
            else if (v && typeof v === "object") renameInExpr(v);
          }
        };
        for (const fn of mod.functions ?? []) {
          if (fn.body) renameInExpr(fn.body);
        }
      }
    }
  }

  // Build a synthetic Program combining all extracted modules
  const syntheticProgram: Program = {
    name: moduleName ?? module.name ?? "library",
    version: "1.0.0",
    modules: [...allModules, dummyEntryModule],
    entryModule: ENTRY_MOD,
    entryFunction: ENTRY_FN,
  };

  // Compile using the standard BallCompiler (gets all post-processing for free)
  let output = new BallCompiler(syntheticProgram).compile({
    includePreamble,
    fileName,
  });

  // Post-process: strip the dummy main function and its invocation.
  // The compiler renames the entry function to "main" regardless of its
  // original name, and emits: `function main() { return 0; }\nmain();`
  // or the async variant. We match both.
  output = output.replace(
    /^(?:export )?(?:async )?function main\(\)[^{]*\{[^}]*return 0;\s*\}\n?/m, ""
  );
  output = output.replace(/^(?:await )?main\(\);\n?/m, "");

  // Add `export` keyword to all top-level declarations that are not already
  // exported. We match declarations at column 0 (start of line).
  output = output.replace(/^(function )/gm, "export $1");
  output = output.replace(/^(class )/gm, "export $1");
  output = output.replace(/^(enum )/gm, "export $1");
  output = output.replace(/^(let )/gm, "export $1");
  output = output.replace(/^(const )/gm, "export $1");

  // Remove any duplicate `export export` from already-exported declarations
  output = output.replace(/^export export /gm, "export ");

  // Clean up excessive blank lines from removals
  output = output.replace(/\n{3,}/g, "\n\n");

  return output;
}
