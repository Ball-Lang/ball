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
    const body = sf.getFullText();
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
        initializer: defaultInitializer(p.type, p.rawDartType),
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
      "RegExp", "Map", "Set", "Error", "TypeError", "RangeError",
      "DateTime", "Duration", "Uri", "BigInt", "Int64",
    ]);
    const shortTn = classTsName(tn);
    if (builtinCtors.has(shortTn)) {
      const args = this.extractPositionalAndNamed(fields);
      return `new ${shortTn}(${args})`;
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
    const bin = (op: string) => `(${this.expr(f.get("left")!)} ${op} ${this.expr(f.get("right")!)})`;
    const un = (op: string) => {
      const inner = this.expr(f.get("value")!);
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
      case "string_contains": return `${this.expr(f.get("left")!)}.includes(${this.expr(f.get("right")!)})`;
      case "string_starts_with": return `${this.expr(f.get("left")!)}.startsWith(${this.expr(f.get("right")!)})`;
      case "string_ends_with": return `${this.expr(f.get("left")!)}.endsWith(${this.expr(f.get("right")!)})`;
      case "string_is_empty": return `(${this.expr(f.get("value")!)}.length === 0)`;
      case "string_split": return `${this.expr(f.get("value")!)}.split(${this.expr(f.get("separator")!)})`;
      case "string_substring": {
        const v = this.expr(f.get("value")!);
        const s = this.expr(f.get("start")!);
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
      default: {
        const args = Array.from(f.values()).map((e) => this.expr(e)).join(", ");
        return `/* std.${fn} */ ${sanitize(fn)}(${args})`;
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

function fieldMap(fields: FieldValuePair[]): Map<string, Expression> {
  const m = new Map<string, Expression>();
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
  return module === "std" || module === "dart_std";
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
