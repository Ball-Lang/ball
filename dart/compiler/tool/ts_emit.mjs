#!/usr/bin/env node
/**
 * Ball → TypeScript structural emitter.
 *
 * Reads an "emit plan" JSON document from stdin, passes it to ts-morph,
 * and writes the resulting .ts source to stdout.
 *
 * Plan schema (stable contract between ts_compiler.dart and this script):
 *
 *   {
 *     "path": "foo.ts",        // synthetic file path (controls imports resolution only)
 *     "statements": [Statement]
 *   }
 *
 *   Statement =
 *     | { kind: "Import",    moduleSpecifier, namedImports?, defaultImport?, namespaceImport? }
 *     | { kind: "Function",  name, isAsync?, isExported?, typeParameters?, parameters: [P], returnType?, body }
 *     | { kind: "Class",     name, isExported?, isAbstract?, typeParameters?, extends?, implements?, properties?, ctors?, methods?, getters?, setters? }
 *     | { kind: "Enum",      name, isExported?, members: [{name, value?}] }
 *     | { kind: "Interface", name, isExported?, typeParameters?, extends?, properties?, methods? }
 *     | { kind: "TypeAlias", name, type, isExported?, typeParameters? }
 *     | { kind: "Raw",       text }          // escape hatch: emitted verbatim
 *
 *   P = { name, type?, hasDefault?, defaultValue?, isOptional?, isRest? }
 *
 *   Method / Ctor / GetAccessor / SetAccessor shape (bodies are raw TS text):
 *     { name, isAsync?, isStatic?, typeParameters?, parameters, returnType?, body, scope?, isAbstract? }
 *
 *   Property shape:
 *     { name, type?, isStatic?, isReadonly?, isOptional?, initializer?, scope? }
 *
 *   body is a raw TS source string; it is inserted verbatim into the generated
 *   block (ts-morph's writer-function fallback). This keeps the scope of this
 *   script modest — it only handles declarations and signatures; expression
 *   lowering stays on the Dart side.
 *
 * Exit codes:
 *   0: success
 *   1: plan JSON failed to parse
 *   2: ts-morph rejected a structure
 */

import { Project, StructureKind, Scope } from "ts-morph";
import { readFile } from "node:fs/promises";

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

/** CLI flags:
 *    --plan-file <path>    read plan JSON from file instead of stdin
 *                          (used by Dart sync caller; Process.runSync
 *                           can't pipe stdin portably on Windows)
 */
function parseArgs(argv) {
  const out = { planFile: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--plan-file" && i + 1 < argv.length) {
      out.planFile = argv[i + 1];
      i++;
    }
  }
  return out;
}

function scopeOf(s) {
  if (!s) return undefined;
  switch (s) {
    case "public": return Scope.Public;
    case "private": return Scope.Private;
    case "protected": return Scope.Protected;
    default: return undefined;
  }
}

function buildParameter(p) {
  return {
    name: p.name,
    type: p.type,
    hasQuestionToken: p.isOptional === true,
    isRestParameter: p.isRest === true,
    initializer: p.hasDefault ? (p.defaultValue ?? "undefined") : undefined,
  };
}

function buildTypeParameters(list) {
  if (!list || list.length === 0) return undefined;
  return list.map(tp => typeof tp === "string" ? tp : ({
    name: tp.name,
    constraint: tp.constraint,
    default: tp.default,
  }));
}

function buildProperty(p) {
  return {
    kind: StructureKind.Property,
    name: p.name,
    type: p.type,
    isStatic: p.isStatic === true,
    isReadonly: p.isReadonly === true,
    hasQuestionToken: p.isOptional === true,
    initializer: p.initializer,
    scope: scopeOf(p.scope),
  };
}

function buildBody(body) {
  // body is a raw TS source string. ts-morph accepts a writer function;
  // we just write it verbatim. A missing body means an abstract method.
  if (body == null) return undefined;
  return writer => writer.write(body);
}

function buildMethod(m) {
  return {
    kind: StructureKind.Method,
    name: m.name,
    isAsync: m.isAsync === true,
    isStatic: m.isStatic === true,
    isAbstract: m.isAbstract === true,
    parameters: (m.parameters ?? []).map(buildParameter),
    returnType: m.returnType,
    typeParameters: buildTypeParameters(m.typeParameters),
    scope: scopeOf(m.scope),
    statements: m.body != null ? m.body : undefined,
  };
}

function buildCtor(c) {
  return {
    kind: StructureKind.Constructor,
    parameters: (c.parameters ?? []).map(buildParameter),
    statements: c.body != null ? c.body : undefined,
    scope: scopeOf(c.scope),
  };
}

function buildGetAccessor(g) {
  return {
    kind: StructureKind.GetAccessor,
    name: g.name,
    returnType: g.returnType,
    statements: g.body != null ? g.body : undefined,
    isStatic: g.isStatic === true,
    scope: scopeOf(g.scope),
  };
}

function buildSetAccessor(s) {
  return {
    kind: StructureKind.SetAccessor,
    name: s.name,
    parameters: (s.parameters ?? []).map(buildParameter),
    statements: s.body != null ? s.body : undefined,
    isStatic: s.isStatic === true,
    scope: scopeOf(s.scope),
  };
}

function addStatement(sourceFile, stmt) {
  switch (stmt.kind) {
    case "Import":
      sourceFile.addImportDeclaration({
        moduleSpecifier: stmt.moduleSpecifier,
        namedImports: stmt.namedImports,
        defaultImport: stmt.defaultImport,
        namespaceImport: stmt.namespaceImport,
      });
      break;

    case "Function":
      sourceFile.addFunction({
        name: stmt.name,
        isAsync: stmt.isAsync === true,
        isExported: stmt.isExported === true,
        isGenerator: stmt.isGenerator === true,
        parameters: (stmt.parameters ?? []).map(buildParameter),
        returnType: stmt.returnType,
        typeParameters: buildTypeParameters(stmt.typeParameters),
        statements: stmt.body,
      });
      break;

    case "Class":
      sourceFile.addClass({
        name: stmt.name,
        isExported: stmt.isExported === true,
        isAbstract: stmt.isAbstract === true,
        typeParameters: buildTypeParameters(stmt.typeParameters),
        extends: stmt.extends,
        implements: stmt.implements,
        properties: (stmt.properties ?? []).map(buildProperty),
        ctors: (stmt.ctors ?? []).map(buildCtor),
        methods: (stmt.methods ?? []).map(buildMethod),
        getAccessors: (stmt.getters ?? []).map(buildGetAccessor),
        setAccessors: (stmt.setters ?? []).map(buildSetAccessor),
      });
      break;

    case "Enum":
      sourceFile.addEnum({
        name: stmt.name,
        isExported: stmt.isExported === true,
        members: (stmt.members ?? []).map(m => ({
          name: m.name,
          initializer: m.value !== undefined
            ? (typeof m.value === "string" ? JSON.stringify(m.value) : String(m.value))
            : undefined,
        })),
      });
      break;

    case "Interface":
      sourceFile.addInterface({
        name: stmt.name,
        isExported: stmt.isExported === true,
        typeParameters: buildTypeParameters(stmt.typeParameters),
        extends: stmt.extends,
        properties: stmt.properties,
        methods: stmt.methods,
      });
      break;

    case "TypeAlias":
      sourceFile.addTypeAlias({
        name: stmt.name,
        type: stmt.type,
        isExported: stmt.isExported === true,
        typeParameters: buildTypeParameters(stmt.typeParameters),
      });
      break;

    case "Raw":
      sourceFile.addStatements(stmt.text);
      break;

    default:
      throw new Error(`Unknown statement kind: ${stmt.kind}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let planText;
  try {
    planText = args.planFile
      ? await readFile(args.planFile, "utf8")
      : await readStdin();
  } catch (e) {
    process.stderr.write(`ts_emit: failed to read plan: ${e.message}\n`);
    process.exit(1);
  }
  let plan;
  try {
    plan = JSON.parse(planText);
  } catch (e) {
    process.stderr.write(`ts_emit: invalid plan JSON: ${e.message}\n`);
    process.exit(1);
  }

  const project = new Project({
    useInMemoryFileSystem: true,
    compilerOptions: { target: 99 /* ESNext */ },
  });
  const path = plan.path ?? "out.ts";
  const sourceFile = project.createSourceFile(path, "", { overwrite: true });

  try {
    for (const stmt of plan.statements ?? []) {
      addStatement(sourceFile, stmt);
    }
  } catch (e) {
    process.stderr.write(`ts_emit: ts-morph rejected a structure: ${e.message}\n`);
    process.exit(2);
  }

  sourceFile.formatText({
    indentSize: 2,
    convertTabsToSpaces: true,
    insertSpaceAfterCommaDelimiter: true,
    insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis: false,
  });

  process.stdout.write(sourceFile.getFullText());
}

main().catch(err => {
  process.stderr.write(`ts_emit: unhandled error: ${err.stack || err}\n`);
  process.exit(3);
});
