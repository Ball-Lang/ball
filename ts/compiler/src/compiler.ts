/**
 * Ball → TypeScript compiler.
 *
 * Walks a Ball `Program` and emits idiomatic TypeScript via ts-morph.
 * Runs in-process in TS — no Dart subprocess, no stdin/stdout IPC.
 *
 * Architecture mirrors the Dart compiler's split:
 *   - Declarations (classes, functions, enums, typedefs) go through
 *     ts-morph's structure API so indentation / formatting / ordering
 *     is handled by the library.
 *   - Expression / statement emission produces raw TS source strings
 *     which are passed as `body: <string>` to ts-morph. ts-morph
 *     re-indents them inside the declaration block.
 *
 * Feature coverage is grown incrementally. Call `BallCompiler.compile()`
 * and check the output against the Dart reference compiler's output —
 * the two should converge.
 */
import { Project, StructureKind } from "ts-morph";
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
} from "./types.ts";
import { TS_RUNTIME_PREAMBLE } from "./preamble.ts";

export interface CompileOptions {
  /** Include the runtime preamble at the top of the output. Default true. */
  includePreamble?: boolean;
  /** Output file path hint (affects ts-morph's internal resolution). */
  fileName?: string;
}

export class BallCompiler {
  private readonly program: Program;

  constructor(program: Program) {
    this.program = program;
  }

  /** Compile the program to TS source. Entry point. */
  compile(options: CompileOptions = {}): string {
    const { includePreamble = true, fileName = "program.ts" } = options;
    const project = new Project({
      useInMemoryFileSystem: true,
      compilerOptions: { target: 99 /* ESNext */ },
    });
    const sourceFile = project.createSourceFile(fileName, "", {
      overwrite: true,
    });

    const entryMod = this.program.modules.find(
      (m) => m.name === this.program.entryModule,
    );
    if (!entryMod) {
      throw new Error(
        `Entry module "${this.program.entryModule}" not found in program`,
      );
    }

    // Emit top-level functions (non-base, non-entry).
    for (const fn of entryMod.functions) {
      if (fn.isBase) continue;
      if (fn.name === this.program.entryFunction) continue;
      this.emitFreeFunction(sourceFile, fn);
    }

    // Emit entry as `main` with an immediate call at end.
    const entryFn = entryMod.functions.find(
      (f) => f.name === this.program.entryFunction,
    );
    if (entryFn) {
      this.emitFreeFunction(sourceFile, entryFn, "main");
      sourceFile.addStatements("main();");
    }

    sourceFile.formatText({
      indentSize: 2,
      convertTabsToSpaces: true,
    });
    const body = sourceFile.getFullText();
    return includePreamble ? TS_RUNTIME_PREAMBLE + "\n" + body : body;
  }

  // ─────────────────────────── Declarations ───────────────────────────

  private emitFreeFunction(
    sf: ReturnType<Project["createSourceFile"]>,
    fn: FunctionDef,
    forceName?: string,
  ): void {
    const params = extractParams(fn);
    const name = forceName ?? sanitize(fn.name);
    const isAsync = readBool(fn.metadata, "is_async");
    const body = this.captureBody(fn, params);
    sf.addFunction({
      kind: StructureKind.Function,
      name,
      isAsync,
      parameters: params.map((p) => ({ name: sanitize(p), type: "any" })),
      returnType: isAsync ? "Promise<any>" : "any",
      statements: body,
    });
  }

  // Capture a function body as a raw TS source string.
  private captureBody(fn: FunctionDef, params: string[]): string {
    const parts: string[] = [];
    // Legacy alias: Ball programs may reference `input` by name.
    if (params.length === 1 && params[0] !== "input") {
      parts.push(`const input = ${sanitize(params[0])};`);
    }
    if (fn.body) {
      parts.push(this.emitStatementOrExpression(fn.body, true));
    }
    return parts.join("\n");
  }

  // ─────────────────────────── Statements / Expressions ──────────────

  private emitStatementOrExpression(
    expr: Expression,
    isFunctionBody: boolean,
  ): string {
    if (expr.block) {
      return this.emitBlock(expr.block, isFunctionBody);
    }
    if (isFunctionBody) {
      return `return ${this.emitExpr(expr)};`;
    }
    return `${this.emitExpr(expr)};`;
  }

  private emitBlock(block: NonNullable<Expression["block"]>, isFunctionBody: boolean): string {
    const lines: string[] = [];
    for (const stmt of block.statements) {
      lines.push(this.emitStatement(stmt));
    }
    if (block.result && isFunctionBody) {
      const r = block.result;
      // Skip empty-set literals (notSet).
      const isEmpty = r.literal !== undefined &&
        r.literal.intValue === undefined &&
        r.literal.doubleValue === undefined &&
        r.literal.stringValue === undefined &&
        r.literal.boolValue === undefined &&
        r.literal.listValue === undefined;
      if (!isEmpty) {
        lines.push(`return ${this.emitExpr(r)};`);
      }
    } else if (block.result) {
      lines.push(`${this.emitExpr(block.result)};`);
    }
    return lines.join("\n");
  }

  private emitStatement(stmt: Statement): string {
    if (stmt.let) {
      const kw = readString(stmt.let.metadata, "keyword") === "var"
        ? "let"
        : "const";
      const name = sanitize(stmt.let.name);
      if (stmt.let.value !== undefined) {
        return `${kw} ${name} = ${this.emitExpr(stmt.let.value)};`;
      }
      return `${kw} ${name};`;
    }
    if (stmt.expression) {
      const e = stmt.expression;
      // Block-expression-as-statement with no result: hoist inner stmts.
      if (e.block && e.block.result === undefined) {
        return e.block.statements.map((s) => this.emitStatement(s)).join("\n");
      }
      return `${this.emitExpr(e)};`;
    }
    return "";
  }

  private emitExpr(expr: Expression): string {
    if (expr.literal) return this.emitLiteral(expr.literal);
    if (expr.reference) return sanitize(expr.reference.name);
    if (expr.fieldAccess) {
      const obj = this.emitExpr(expr.fieldAccess.object);
      return `${obj}.${expr.fieldAccess.field}`;
    }
    if (expr.call) return this.emitCall(expr.call);
    if (expr.messageCreation) return this.emitMessageCreation(expr.messageCreation);
    return "null /* unhandled expr */";
  }

  private emitLiteral(lit: Literal): string {
    if (lit.intValue !== undefined) return String(lit.intValue);
    if (lit.doubleValue !== undefined) return String(lit.doubleValue);
    if (lit.stringValue !== undefined) {
      return jsStringLiteral(lit.stringValue);
    }
    if (lit.boolValue !== undefined) {
      return lit.boolValue ? "true" : "false";
    }
    if (lit.listValue) {
      return `[${lit.listValue.elements.map((e) => this.emitExpr(e)).join(", ")}]`;
    }
    return "null";
  }

  private emitCall(call: FunctionCall): string {
    // std dispatch for known base functions.
    if (call.module === "std" || call.module === "dart_std") {
      return this.emitStdCall(call);
    }
    const fn = sanitize(call.function);
    if (!call.input) return `${fn}()`;
    if (call.input.messageCreation) {
      const fields = call.input.messageCreation.fields;
      const args = fields.map((f) => this.emitExpr(f.value)).join(", ");
      return `${fn}(${args})`;
    }
    return `${fn}(${this.emitExpr(call.input)})`;
  }

  private emitMessageCreation(
    mc: NonNullable<Expression["messageCreation"]>,
  ): string {
    // Anonymous arg bag → inline object literal.
    if (!mc.typeName) {
      const entries = mc.fields
        .map((f) => `'${f.name}': ${this.emitExpr(f.value)}`)
        .join(", ");
      return `{${entries}}`;
    }
    return `new ${sanitize(mc.typeName)}(${mc.fields
      .map((f) => this.emitExpr(f.value))
      .join(", ")})`;
  }

  private emitStdCall(call: FunctionCall): string {
    const fn = call.function;
    const f = fieldMap(call.input);

    // Minimum std set needed for hello world. More handlers are added
    // in subsequent iterations.
    switch (fn) {
      case "print": {
        const msg = f.get("message");
        if (!msg) return "console.log()";
        return `console.log(__ball_to_string(${this.emitExpr(msg)}))`;
      }
      case "add":
        return `(${this.emitExpr(f.get("left")!)} + ${this.emitExpr(f.get("right")!)})`;
      case "concat":
        return `(${this.emitExpr(f.get("left")!)} + ${this.emitExpr(f.get("right")!)})`;
      case "to_string":
        return `__ball_to_string(${this.emitExpr(f.get("value")!)})`;
      default:
        return `/* std.${fn} */ ${sanitize(fn)}(${Array.from(f.values()).map((e) => this.emitExpr(e)).join(", ")})`;
    }
  }
}

// ─────────────────────────── Helpers ───────────────────────────────

function extractParams(fn: FunctionDef): string[] {
  const params = fn.metadata?.["params"];
  if (!Array.isArray(params)) return [];
  const out: string[] = [];
  for (const p of params) {
    if (p && typeof p === "object" && "name" in p && typeof (p as any).name === "string") {
      out.push((p as any).name);
    }
  }
  return out;
}

function readBool(meta: Struct | undefined, key: string): boolean {
  const v = meta?.[key];
  return v === true;
}

function readString(meta: Struct | undefined, key: string): string | undefined {
  const v = meta?.[key];
  return typeof v === "string" ? v : undefined;
}

function fieldMap(input?: Expression): Map<string, Expression> {
  const out = new Map<string, Expression>();
  if (!input?.messageCreation) return out;
  for (const f of input.messageCreation.fields) out.set(f.name, f.value);
  return out;
}

function jsStringLiteral(s: string): string {
  return "'" + s
    .replace(/\\/g, "\\\\")
    .replace(/'/g, "\\'")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t") + "'";
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
