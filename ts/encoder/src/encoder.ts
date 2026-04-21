import ts from "typescript";
import type {
  Program, Module, FunctionDef, Expression, Statement,
  FieldValuePair, TypeDefinition, TypeAlias, EnumDef,
  DescriptorProto, Struct,
} from "./types.ts";

export interface EncodeOptions {
  moduleName?: string;
  entryFunction?: string;
  strict?: boolean;
}

type StdRef = { module: string; function: string };

const BINARY_OPS: Record<number, StdRef> = {
  [ts.SyntaxKind.PlusToken]:                  { module: "std", function: "add" },
  [ts.SyntaxKind.MinusToken]:                 { module: "std", function: "subtract" },
  [ts.SyntaxKind.AsteriskToken]:              { module: "std", function: "multiply" },
  [ts.SyntaxKind.SlashToken]:                 { module: "std", function: "divide_double" },
  [ts.SyntaxKind.PercentToken]:               { module: "std", function: "modulo" },
  [ts.SyntaxKind.AmpersandToken]:             { module: "std", function: "bitwise_and" },
  [ts.SyntaxKind.BarToken]:                   { module: "std", function: "bitwise_or" },
  [ts.SyntaxKind.CaretToken]:                 { module: "std", function: "bitwise_xor" },
  [ts.SyntaxKind.LessThanLessThanToken]:      { module: "std", function: "shift_left" },
  [ts.SyntaxKind.GreaterThanGreaterThanToken]:{ module: "std", function: "shift_right" },
  [ts.SyntaxKind.EqualsEqualsEqualsToken]:    { module: "std", function: "equals" },
  [ts.SyntaxKind.ExclamationEqualsEqualsToken]:{ module: "std", function: "not_equals" },
  [ts.SyntaxKind.EqualsEqualsToken]:          { module: "std", function: "equals" },
  [ts.SyntaxKind.ExclamationEqualsToken]:     { module: "std", function: "not_equals" },
  [ts.SyntaxKind.LessThanToken]:              { module: "std", function: "less_than" },
  [ts.SyntaxKind.GreaterThanToken]:           { module: "std", function: "greater_than" },
  [ts.SyntaxKind.LessThanEqualsToken]:        { module: "std", function: "less_than_or_equal" },
  [ts.SyntaxKind.GreaterThanEqualsToken]:     { module: "std", function: "greater_than_or_equal" },
  [ts.SyntaxKind.AmpersandAmpersandToken]:    { module: "std", function: "and" },
  [ts.SyntaxKind.BarBarToken]:                { module: "std", function: "or" },
  [ts.SyntaxKind.QuestionQuestionToken]:      { module: "std", function: "null_coalesce" },
  [ts.SyntaxKind.InstanceOfKeyword]:          { module: "std", function: "is" },
};

const COMPOUND_OPS: Record<number, string> = {
  [ts.SyntaxKind.PlusEqualsToken]: "+=",
  [ts.SyntaxKind.MinusEqualsToken]: "-=",
  [ts.SyntaxKind.AsteriskEqualsToken]: "*=",
  [ts.SyntaxKind.SlashEqualsToken]: "/=",
  [ts.SyntaxKind.PercentEqualsToken]: "%=",
  [ts.SyntaxKind.AmpersandEqualsToken]: "&=",
  [ts.SyntaxKind.BarEqualsToken]: "|=",
  [ts.SyntaxKind.CaretEqualsToken]: "^=",
  [ts.SyntaxKind.LessThanLessThanEqualsToken]: "<<=",
  [ts.SyntaxKind.GreaterThanGreaterThanEqualsToken]: ">>=",
  [ts.SyntaxKind.QuestionQuestionEqualsToken]: "??=",
};

export class TsEncoder {
  private stdFunctions = new Set<string>();
  private warnings: string[] = [];

  encode(source: string, options: EncodeOptions = {}): Program {
    const modName = options.moduleName ?? "main";
    const entryFn = options.entryFunction ?? "main";

    const sourceFile = ts.createSourceFile(
      "input.ts", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS
    );

    const functions: FunctionDef[] = [];
    const typeDefs: TypeDefinition[] = [];
    const typeAliases: TypeAlias[] = [];
    const enums: EnumDef[] = [];

    for (const stmt of sourceFile.statements) {
      if (ts.isFunctionDeclaration(stmt) && stmt.name) {
        functions.push(this.encodeFunction(stmt));
      } else if (ts.isClassDeclaration(stmt) && stmt.name) {
        this.encodeClass(stmt, functions, typeDefs);
      } else if (ts.isInterfaceDeclaration(stmt)) {
        typeDefs.push(this.encodeInterface(stmt));
      } else if (ts.isTypeAliasDeclaration(stmt)) {
        typeAliases.push(this.encodeTypeAlias(stmt));
      } else if (ts.isEnumDeclaration(stmt)) {
        enums.push(this.encodeEnum(stmt));
      } else if (ts.isVariableStatement(stmt)) {
        for (const decl of stmt.declarationList.declarations) {
          if (ts.isIdentifier(decl.name)) {
            functions.push({
              name: decl.name.text,
              body: decl.initializer ? this.encodeExpr(decl.initializer) : { literal: { stringValue: "" } },
              metadata: { kind: "top_level_variable" },
            });
          } else if (ts.isObjectBindingPattern(decl.name) && decl.initializer) {
            for (const element of decl.name.elements) {
              const propName = element.propertyName
                ? (ts.isIdentifier(element.propertyName) ? element.propertyName.text : element.propertyName.getText())
                : (ts.isIdentifier(element.name) ? element.name.text : element.name.getText());
              const varName = ts.isIdentifier(element.name) ? element.name.text : element.name.getText();
              functions.push({
                name: varName,
                body: { fieldAccess: { object: this.encodeExpr(decl.initializer!), field: propName } },
                metadata: { kind: "top_level_variable", destructured: true },
              });
            }
          } else if (ts.isArrayBindingPattern(decl.name) && decl.initializer) {
            for (let i = 0; i < decl.name.elements.length; i++) {
              const element = decl.name.elements[i];
              if (ts.isOmittedExpression(element)) continue;
              const varName = ts.isIdentifier(element.name) ? element.name.text : element.name.getText();
              functions.push({
                name: varName,
                body: this.stdCall("index", [
                  { name: "target", value: this.encodeExpr(decl.initializer!) },
                  { name: "index", value: { literal: { intValue: `${i}` } } },
                ]),
                metadata: { kind: "top_level_variable", destructured: true },
              });
            }
          }
        }
      } else if (ts.isExpressionStatement(stmt)) {
        functions.push({
          name: `__top_${functions.length}`,
          body: this.encodeExpr(stmt.expression),
        });
      }
    }

    const stdModule = this.buildStdModule();
    const modules: Module[] = [stdModule];

    const userModule: Module = {
      name: modName,
      functions,
      ...(typeDefs.length > 0 ? { typeDefs } : {}),
      ...(typeAliases.length > 0 ? { typeAliases } : {}),
      ...(enums.length > 0 ? { enums } : {}),
    };
    modules.push(userModule);

    return {
      name: modName,
      version: "1.0.0",
      modules,
      entryModule: modName,
      entryFunction: entryFn,
    };
  }

  private encodeFunction(node: ts.FunctionDeclaration | ts.FunctionExpression | ts.MethodDeclaration): FunctionDef {
    const name = node.name ? (ts.isIdentifier(node.name) ? node.name.text : node.name.getText()) : "";
    const params = node.parameters.map(p =>
      ts.isIdentifier(p.name) ? p.name.text : p.name.getText()
    );

    const metadata: Struct = {};
    if (params.length > 0) metadata["params"] = params;
    if (node.type) metadata["returnType"] = node.type.getText();

    // Async functions
    if (node.modifiers?.some(m => m.kind === ts.SyntaxKind.AsyncKeyword)) {
      metadata["is_async"] = true;
    }

    // Rest parameters
    const lastParam = node.parameters[node.parameters.length - 1];
    if (lastParam?.dotDotDotToken) {
      metadata["rest_param"] = ts.isIdentifier(lastParam.name) ? lastParam.name.text : lastParam.name.getText();
    }

    // Default parameter values
    const defaults: Record<string, unknown> = {};
    for (const p of node.parameters) {
      if (p.initializer && ts.isIdentifier(p.name)) {
        defaults[p.name.text] = p.initializer.getText();
      }
    }
    if (Object.keys(defaults).length > 0) metadata["param_defaults"] = defaults;

    const body = node.body ? this.encodeBody(node.body) : undefined;

    const fn: FunctionDef = { name };
    if (body) fn.body = body;
    if (Object.keys(metadata).length > 0) fn.metadata = metadata;
    if (node.type) fn.outputType = node.type.getText();

    return fn;
  }

  private encodeBody(body: ts.Block | ts.Expression | ts.ConciseBody): Expression {
    if (ts.isBlock(body)) {
      return this.encodeBlock(body);
    }
    return this.encodeExpr(body as ts.Expression);
  }

  private encodeBlock(block: ts.Block): Expression {
    const stmts: Statement[] = [];
    for (const s of block.statements) {
      stmts.push(...this.encodeStatement(s));
    }
    return { block: { statements: stmts } };
  }

  private encodeStatement(node: ts.Statement): Statement[] {
    if (ts.isVariableStatement(node)) {
      const results: Statement[] = [];
      for (const decl of node.declarationList.declarations) {
        if (ts.isObjectBindingPattern(decl.name) && decl.initializer) {
          // Object destructuring: const { a, b } = obj
          const source = this.encodeExpr(decl.initializer);
          for (const element of decl.name.elements) {
            const propName = element.propertyName
              ? (ts.isIdentifier(element.propertyName) ? element.propertyName.text : element.propertyName.getText())
              : (ts.isIdentifier(element.name) ? element.name.text : element.name.getText());
            const varName = ts.isIdentifier(element.name) ? element.name.text : element.name.getText();
            let value: Expression = { fieldAccess: { object: source, field: propName } };
            if (element.initializer) {
              value = this.stdCall("null_coalesce", [
                { name: "left", value },
                { name: "right", value: this.encodeExpr(element.initializer) },
              ]);
            }
            results.push({ let: { name: varName, value } });
          }
        } else if (ts.isArrayBindingPattern(decl.name) && decl.initializer) {
          // Array destructuring: const [x, y] = arr
          const source = this.encodeExpr(decl.initializer);
          for (let i = 0; i < decl.name.elements.length; i++) {
            const element = decl.name.elements[i];
            if (ts.isOmittedExpression(element)) continue;
            const varName = ts.isIdentifier(element.name) ? element.name.text : element.name.getText();
            let value: Expression = this.stdCall("index", [
              { name: "target", value: source },
              { name: "index", value: { literal: { intValue: `${i}` } } },
            ]);
            if (element.initializer) {
              value = this.stdCall("null_coalesce", [
                { name: "left", value },
                { name: "right", value: this.encodeExpr(element.initializer) },
              ]);
            }
            results.push({ let: { name: varName, value } });
          }
        } else {
          results.push({
            let: {
              name: ts.isIdentifier(decl.name) ? decl.name.text : decl.name.getText(),
              value: decl.initializer ? this.encodeExpr(decl.initializer) : undefined,
            },
          });
        }
      }
      return results;
    }
    if (ts.isExpressionStatement(node)) {
      return [{ expression: this.encodeExpr(node.expression) }];
    }
    if (ts.isReturnStatement(node)) {
      return [{ expression: this.stdCall("return", node.expression
        ? [{ name: "value", value: this.encodeExpr(node.expression) }]
        : []) }];
    }
    if (ts.isIfStatement(node)) {
      return [{ expression: this.encodeIf(node) }];
    }
    if (ts.isForStatement(node)) {
      return [{ expression: this.encodeFor(node) }];
    }
    if (ts.isForOfStatement(node) || ts.isForInStatement(node)) {
      return [{ expression: this.encodeForOf(node) }];
    }
    if (ts.isWhileStatement(node)) {
      return [{ expression: this.encodeWhile(node) }];
    }
    if (ts.isDoStatement(node)) {
      return [{ expression: this.encodeDoWhile(node) }];
    }
    if (ts.isTryStatement(node)) {
      return [{ expression: this.encodeTry(node) }];
    }
    if (ts.isThrowStatement(node)) {
      return [{ expression: this.stdCall("throw", [
        { name: "value", value: this.encodeExpr(node.expression) },
      ]) }];
    }
    if (ts.isBreakStatement(node)) {
      const fields: FieldValuePair[] = [];
      if (node.label) fields.push({ name: "label", value: { literal: { stringValue: node.label.text } } });
      return [{ expression: this.stdCall("break", fields) }];
    }
    if (ts.isContinueStatement(node)) {
      const fields: FieldValuePair[] = [];
      if (node.label) fields.push({ name: "label", value: { literal: { stringValue: node.label.text } } });
      return [{ expression: this.stdCall("continue", fields) }];
    }
    if (ts.isLabeledStatement(node)) {
      return [{ expression: this.stdCall("labeled", [
        { name: "label", value: { literal: { stringValue: node.label.text } } },
        { name: "body", value: this.encodeBody(
          ts.isBlock(node.statement) ? node.statement : ts.factory.createBlock([node.statement])
        ) },
      ]) }];
    }
    if (ts.isSwitchStatement(node)) {
      return [{ expression: this.encodeSwitch(node) }];
    }
    if (ts.isBlock(node)) {
      return [{ expression: this.encodeBlock(node) }];
    }
    this.warn(`Unhandled statement kind: ${ts.SyntaxKind[node.kind]}`);
    return [{ expression: { literal: { stringValue: `/* unhandled: ${ts.SyntaxKind[node.kind]} */` } } }];
  }

  private encodeExpr(node: ts.Expression): Expression {
    if (ts.isNumericLiteral(node)) {
      const text = node.text;
      if (text.includes(".") || text.includes("e") || text.includes("E")) {
        return { literal: { doubleValue: parseFloat(text) } };
      }
      return { literal: { intValue: text } };
    }
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      return { literal: { stringValue: node.text } };
    }
    if (node.kind === ts.SyntaxKind.TrueKeyword) {
      return { literal: { boolValue: true } };
    }
    if (node.kind === ts.SyntaxKind.FalseKeyword) {
      return { literal: { boolValue: false } };
    }
    if (node.kind === ts.SyntaxKind.NullKeyword || node.kind === ts.SyntaxKind.UndefinedKeyword) {
      return { literal: { stringValue: "" } };
    }
    if (ts.isIdentifier(node)) {
      return { reference: { name: node.text } };
    }
    if (ts.isBinaryExpression(node)) {
      return this.encodeBinary(node);
    }
    if (ts.isPrefixUnaryExpression(node)) {
      return this.encodePrefixUnary(node);
    }
    if (ts.isPostfixUnaryExpression(node)) {
      return this.encodePostfixUnary(node);
    }
    if (ts.isCallExpression(node)) {
      return this.encodeCall(node);
    }
    if (ts.isPropertyAccessExpression(node)) {
      if (node.questionDotToken) {
        return this.stdCall("optional_access", [
          { name: "object", value: this.encodeExpr(node.expression) },
          { name: "field", value: { literal: { stringValue: node.name.text } } },
        ], "ts_std");
      }
      return { fieldAccess: { object: this.encodeExpr(node.expression), field: node.name.text } };
    }
    if (ts.isElementAccessExpression(node)) {
      if (node.questionDotToken) {
        return this.stdCall("optional_access", [
          { name: "object", value: this.encodeExpr(node.expression) },
          { name: "field", value: this.encodeExpr(node.argumentExpression) },
        ], "ts_std");
      }
      return this.stdCall("index", [
        { name: "target", value: this.encodeExpr(node.expression) },
        { name: "index", value: this.encodeExpr(node.argumentExpression) },
      ]);
    }
    if (ts.isParenthesizedExpression(node)) {
      return this.encodeExpr(node.expression);
    }
    if (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) {
      return this.encodeLambda(node);
    }
    if (ts.isArrayLiteralExpression(node)) {
      return {
        literal: {
          listValue: { elements: node.elements.map(e => this.encodeExpr(e)) },
        },
      };
    }
    if (ts.isObjectLiteralExpression(node)) {
      const fields: FieldValuePair[] = [];
      for (const prop of node.properties) {
        if (ts.isPropertyAssignment(prop)) {
          if (ts.isComputedPropertyName(prop.name)) {
            // Computed property: { [key]: value }
            fields.push({
              name: "__computed",
              value: this.stdCall("computed_property", [
                { name: "key", value: this.encodeExpr(prop.name.expression) },
                { name: "value", value: this.encodeExpr(prop.initializer) },
              ], "ts_std"),
            });
          } else {
            const propName = ts.isIdentifier(prop.name)
              ? prop.name.text
              : ts.isStringLiteral(prop.name) ? prop.name.text : prop.name.getText();
            fields.push({ name: propName, value: this.encodeExpr(prop.initializer) });
          }
        } else if (ts.isShorthandPropertyAssignment(prop)) {
          fields.push({ name: prop.name.text, value: { reference: { name: prop.name.text } } });
        } else if (ts.isSpreadAssignment(prop)) {
          fields.push({
            name: "__spread",
            value: this.stdCall("spread", [
              { name: "value", value: this.encodeExpr(prop.expression) },
            ], "ts_std"),
          });
        }
      }
      return { messageCreation: { typeName: "", fields } };
    }
    if (ts.isConditionalExpression(node)) {
      return this.stdCall("if", [
        { name: "condition", value: this.encodeExpr(node.condition) },
        { name: "then", value: { lambda: { name: "", body: this.encodeExpr(node.whenTrue) } } },
        { name: "else", value: { lambda: { name: "", body: this.encodeExpr(node.whenFalse) } } },
      ]);
    }
    if (ts.isTemplateExpression(node)) {
      return this.encodeTemplate(node);
    }
    if (ts.isNewExpression(node)) {
      return this.encodeNew(node);
    }
    if (ts.isTypeOfExpression(node)) {
      return this.stdCall("type_of", [
        { name: "value", value: this.encodeExpr(node.expression) },
      ]);
    }
    if (ts.isAsExpression(node) || ts.isTypeAssertionExpression(node)) {
      return this.encodeExpr(node.expression);
    }
    if (ts.isNonNullExpression(node)) {
      return this.stdCall("null_check", [
        { name: "value", value: this.encodeExpr(node.expression) },
      ]);
    }
    if (ts.isAwaitExpression(node)) {
      return this.stdCall("await", [
        { name: "value", value: this.encodeExpr(node.expression) },
      ]);
    }
    if (ts.isSpreadElement(node)) {
      return this.stdCall("spread", [
        { name: "value", value: this.encodeExpr(node.expression) },
      ], "ts_std");
    }
    if (ts.isVoidExpression(node)) {
      return { literal: { stringValue: "" } };
    }
    if (ts.isTaggedTemplateExpression(node)) {
      return this.encodeTaggedTemplate(node);
    }
    this.warn(`Unhandled expression kind: ${ts.SyntaxKind[node.kind]}`);
    return { literal: { stringValue: `/* unhandled: ${ts.SyntaxKind[node.kind]} */` } };
  }

  private encodeBinary(node: ts.BinaryExpression): Expression {
    const op = node.operatorToken.kind;

    if (op === ts.SyntaxKind.EqualsToken) {
      return this.stdCall("assign", [
        { name: "target", value: this.encodeExpr(node.left) },
        { name: "value", value: this.encodeExpr(node.right) },
      ]);
    }

    const compound = COMPOUND_OPS[op];
    if (compound) {
      return this.stdCall("assign", [
        { name: "target", value: this.encodeExpr(node.left) },
        { name: "value", value: this.encodeExpr(node.right) },
        { name: "op", value: { literal: { stringValue: compound } } },
      ]);
    }

    if (op === ts.SyntaxKind.PlusToken && this.looksLikeStringConcat(node)) {
      return this.stdCall("concat", [
        { name: "left", value: this.encodeExpr(node.left) },
        { name: "right", value: this.encodeExpr(node.right) },
      ]);
    }

    const stdRef = BINARY_OPS[op];
    if (stdRef) {
      return this.stdCall(stdRef.function, [
        { name: "left", value: this.encodeExpr(node.left) },
        { name: "right", value: this.encodeExpr(node.right) },
      ], stdRef.module);
    }

    if (op === ts.SyntaxKind.InKeyword) {
      return this.stdCall("contains_key", [
        { name: "map", value: this.encodeExpr(node.right) },
        { name: "key", value: this.encodeExpr(node.left) },
      ], "std_collections");
    }

    this.warn(`Unhandled binary operator: ${ts.SyntaxKind[op]}`);
    return { literal: { stringValue: `/* binary: ${ts.SyntaxKind[op]} */` } };
  }

  private looksLikeStringConcat(node: ts.BinaryExpression): boolean {
    return ts.isStringLiteral(node.left) || ts.isStringLiteral(node.right) ||
           ts.isTemplateExpression(node.left) || ts.isNoSubstitutionTemplateLiteral(node.left);
  }

  private encodePrefixUnary(node: ts.PrefixUnaryExpression): Expression {
    const op = node.operator;
    if (op === ts.SyntaxKind.MinusToken) {
      return this.stdCall("negate", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    if (op === ts.SyntaxKind.ExclamationToken) {
      return this.stdCall("not", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    if (op === ts.SyntaxKind.TildeToken) {
      return this.stdCall("bitwise_not", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    if (op === ts.SyntaxKind.PlusPlusToken) {
      return this.stdCall("pre_increment", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    if (op === ts.SyntaxKind.MinusMinusToken) {
      return this.stdCall("pre_decrement", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    this.warn(`Unhandled prefix operator: ${ts.SyntaxKind[op]}`);
    return this.encodeExpr(node.operand);
  }

  private encodePostfixUnary(node: ts.PostfixUnaryExpression): Expression {
    if (node.operator === ts.SyntaxKind.PlusPlusToken) {
      return this.stdCall("post_increment", [
        { name: "value", value: this.encodeExpr(node.operand) },
      ]);
    }
    return this.stdCall("post_decrement", [
      { name: "value", value: this.encodeExpr(node.operand) },
    ]);
  }

  private encodeCall(node: ts.CallExpression): Expression {
    const args = node.arguments.map((a, i) => ({
      name: `arg${i}`,
      value: this.encodeExpr(a),
    }));

    if (ts.isPropertyAccessExpression(node.expression)) {
      const obj = this.encodeExpr(node.expression.expression);
      const method = node.expression.name.text;

      // Optional chaining call: obj?.method()
      if (node.expression.questionDotToken || node.questionDotToken) {
        return this.stdCall("optional_call", [
          { name: "object", value: obj },
          { name: "method", value: { literal: { stringValue: method } } },
          ...args,
        ], "ts_std");
      }

      return {
        call: {
          function: method,
          input: {
            messageCreation: {
              typeName: "",
              fields: [{ name: "self", value: obj }, ...args],
            },
          },
        },
      };
    }

    if (ts.isIdentifier(node.expression)) {
      const fnName = node.expression.text;
      return {
        call: {
          module: "",
          function: fnName,
          input: args.length > 0 ? {
            messageCreation: { typeName: "", fields: args },
          } : undefined,
        },
      };
    }

    return {
      call: {
        function: "__invoke",
        input: {
          messageCreation: {
            typeName: "",
            fields: [
              { name: "callee", value: this.encodeExpr(node.expression) },
              ...args,
            ],
          },
        },
      },
    };
  }

  private encodeLambda(node: ts.ArrowFunction | ts.FunctionExpression): Expression {
    const params = node.parameters.map(p =>
      ts.isIdentifier(p.name) ? p.name.text : p.name.getText()
    );
    const body = node.body ? this.encodeBody(
      ts.isBlock(node.body) ? node.body : node.body
    ) : undefined;

    const metadata: Struct = {};
    if (params.length > 0) metadata["params"] = params;
    if (node.modifiers?.some(m => m.kind === ts.SyntaxKind.AsyncKeyword)) {
      metadata["is_async"] = true;
    }

    // Rest parameters
    const lastParam = node.parameters[node.parameters.length - 1];
    if (lastParam?.dotDotDotToken) {
      metadata["rest_param"] = ts.isIdentifier(lastParam.name) ? lastParam.name.text : lastParam.name.getText();
    }

    // Default parameter values
    const defaults: Record<string, unknown> = {};
    for (const p of node.parameters) {
      if (p.initializer && ts.isIdentifier(p.name)) {
        defaults[p.name.text] = p.initializer.getText();
      }
    }
    if (Object.keys(defaults).length > 0) metadata["param_defaults"] = defaults;

    // Destructured parameters
    const destructured: Record<string, string> = {};
    for (const p of node.parameters) {
      if (ts.isObjectBindingPattern(p.name) || ts.isArrayBindingPattern(p.name)) {
        const idx = node.parameters.indexOf(p);
        destructured[`param${idx}`] = p.name.getText();
      }
    }
    if (Object.keys(destructured).length > 0) metadata["destructured_params"] = destructured;

    return {
      lambda: {
        name: "",
        body,
        ...(Object.keys(metadata).length > 0 ? { metadata } : {}),
      },
    };
  }

  private encodeIf(node: ts.IfStatement): Expression {
    const fields: FieldValuePair[] = [
      { name: "condition", value: this.encodeExpr(node.expression) },
      { name: "then", value: { lambda: { name: "", body: this.encodeBody(
        ts.isBlock(node.thenStatement) ? node.thenStatement : ts.factory.createBlock([node.thenStatement])
      ) } } },
    ];
    if (node.elseStatement) {
      if (ts.isIfStatement(node.elseStatement)) {
        fields.push({ name: "else", value: { lambda: { name: "", body: this.encodeIf(node.elseStatement) } } });
      } else {
        fields.push({ name: "else", value: { lambda: { name: "", body: this.encodeBody(
          ts.isBlock(node.elseStatement) ? node.elseStatement : ts.factory.createBlock([node.elseStatement])
        ) } } });
      }
    }
    return this.stdCall("if", fields);
  }

  private encodeFor(node: ts.ForStatement): Expression {
    const fields: FieldValuePair[] = [];
    if (node.initializer) {
      if (ts.isVariableDeclarationList(node.initializer)) {
        const decls = node.initializer.declarations;
        if (decls.length > 0) {
          const d = decls[0];
          fields.push({ name: "variable", value: { literal: { stringValue: ts.isIdentifier(d.name) ? d.name.text : d.name.getText() } } });
          if (d.initializer) fields.push({ name: "start", value: this.encodeExpr(d.initializer) });
        }
      } else {
        fields.push({ name: "init", value: { lambda: { name: "", body: this.encodeExpr(node.initializer) } } });
      }
    }
    if (node.condition) {
      fields.push({ name: "condition", value: { lambda: { name: "", body: this.encodeExpr(node.condition) } } });
    }
    if (node.incrementor) {
      fields.push({ name: "update", value: { lambda: { name: "", body: this.encodeExpr(node.incrementor) } } });
    }
    fields.push({ name: "body", value: { lambda: { name: "", body: this.encodeBody(
      ts.isBlock(node.statement) ? node.statement : ts.factory.createBlock([node.statement])
    ) } } });
    return this.stdCall("for", fields);
  }

  private encodeForOf(node: ts.ForOfStatement | ts.ForInStatement): Expression {
    let varName = "";
    if (ts.isVariableDeclarationList(node.initializer)) {
      const d = node.initializer.declarations[0];
      varName = ts.isIdentifier(d.name) ? d.name.text : d.name.getText();
    }
    const fnName = ts.isForInStatement(node) ? "for_in" : "for_each";
    return this.stdCall(fnName, [
      { name: "variable", value: { literal: { stringValue: varName } } },
      { name: "iterable", value: this.encodeExpr(node.expression) },
      { name: "body", value: { lambda: { name: "", body: this.encodeBody(
        ts.isBlock(node.statement) ? node.statement : ts.factory.createBlock([node.statement])
      ) } } },
    ]);
  }

  private encodeWhile(node: ts.WhileStatement): Expression {
    return this.stdCall("while", [
      { name: "condition", value: { lambda: { name: "", body: this.encodeExpr(node.expression) } } },
      { name: "body", value: { lambda: { name: "", body: this.encodeBody(
        ts.isBlock(node.statement) ? node.statement : ts.factory.createBlock([node.statement])
      ) } } },
    ]);
  }

  private encodeDoWhile(node: ts.DoStatement): Expression {
    return this.stdCall("do_while", [
      { name: "condition", value: { lambda: { name: "", body: this.encodeExpr(node.expression) } } },
      { name: "body", value: { lambda: { name: "", body: this.encodeBody(
        ts.isBlock(node.statement) ? node.statement : ts.factory.createBlock([node.statement])
      ) } } },
    ]);
  }

  private encodeTry(node: ts.TryStatement): Expression {
    const fields: FieldValuePair[] = [
      { name: "body", value: { lambda: { name: "", body: this.encodeBlock(node.tryBlock) } } },
    ];
    if (node.catchClause) {
      const cc = node.catchClause;
      const catchFields: FieldValuePair[] = [];
      if (cc.variableDeclaration && ts.isIdentifier(cc.variableDeclaration.name)) {
        catchFields.push({ name: "variable", value: { literal: { stringValue: cc.variableDeclaration.name.text } } });
      }
      catchFields.push({ name: "body", value: { lambda: { name: "", body: this.encodeBlock(cc.block) } } });
      fields.push({
        name: "catch",
        value: { messageCreation: { typeName: "", fields: catchFields } },
      });
    }
    if (node.finallyBlock) {
      fields.push({ name: "finally", value: { lambda: { name: "", body: this.encodeBlock(node.finallyBlock) } } });
    }
    return this.stdCall("try", fields);
  }

  private encodeSwitch(node: ts.SwitchStatement): Expression {
    const cases: Expression[] = [];
    for (const clause of node.caseBlock.clauses) {
      const caseFields: FieldValuePair[] = [];
      if (ts.isCaseClause(clause)) {
        caseFields.push({ name: "value", value: this.encodeExpr(clause.expression) });
      } else {
        caseFields.push({ name: "isDefault", value: { literal: { boolValue: true } } });
      }
      const stmts: Statement[] = [];
      for (const s of clause.statements) {
        stmts.push(...this.encodeStatement(s));
      }
      caseFields.push({ name: "body", value: { lambda: { name: "", body: { block: { statements: stmts } } } } });
      cases.push({ messageCreation: { typeName: "", fields: caseFields } });
    }
    return this.stdCall("switch", [
      { name: "value", value: this.encodeExpr(node.expression) },
      { name: "cases", value: { literal: { listValue: { elements: cases } } } },
    ]);
  }

  private encodeTemplate(node: ts.TemplateExpression): Expression {
    let result: Expression = { literal: { stringValue: node.head.text } };
    for (const span of node.templateSpans) {
      const part = this.stdCall("to_string", [
        { name: "value", value: this.encodeExpr(span.expression) },
      ]);
      result = this.stdCall("concat", [
        { name: "left", value: result },
        { name: "right", value: part },
      ]);
      if (span.literal.text) {
        result = this.stdCall("concat", [
          { name: "left", value: result },
          { name: "right", value: { literal: { stringValue: span.literal.text } } },
        ]);
      }
    }
    return result;
  }

  private encodeNew(node: ts.NewExpression): Expression {
    const typeName = node.expression.getText();
    const args = (node.arguments ?? []).map((a, i) => ({
      name: `arg${i}`,
      value: this.encodeExpr(a),
    }));
    return {
      messageCreation: {
        typeName,
        fields: args,
      },
    };
  }

  private encodeClass(
    node: ts.ClassDeclaration,
    functions: FunctionDef[],
    typeDefs: TypeDefinition[],
  ): void {
    const className = node.name!.text;

    const descriptor: DescriptorProto = { name: className, field: [] };
    const metadata: Struct = { kind: "class" };

    if (node.heritageClauses) {
      for (const hc of node.heritageClauses) {
        if (hc.token === ts.SyntaxKind.ExtendsKeyword && hc.types.length > 0) {
          metadata["superclass"] = hc.types[0].expression.getText();
        }
        if (hc.token === ts.SyntaxKind.ImplementsKeyword) {
          metadata["interfaces"] = hc.types.map(t => t.expression.getText());
        }
      }
    }

    const fieldInitializers: Record<string, string> = {};
    let fieldNum = 1;
    for (const member of node.members) {
      if (ts.isPropertyDeclaration(member) && ts.isIdentifier(member.name)) {
        const fieldMeta: Record<string, unknown> = {};
        if (member.initializer) {
          fieldInitializers[member.name.text] = member.initializer.getText();
          fieldMeta["initializer"] = member.initializer.getText();
        }
        const isStatic = member.modifiers?.some(m => m.kind === ts.SyntaxKind.StaticKeyword);
        if (isStatic) fieldMeta["is_static"] = true;
        descriptor.field!.push({
          name: member.name.text,
          number: fieldNum++,
          type: member.type ? member.type.getText() : "any",
          ...(Object.keys(fieldMeta).length > 0 ? { label: JSON.stringify(fieldMeta) } : {}),
        });
      }
      if (ts.isMethodDeclaration(member) && ts.isIdentifier(member.name)) {
        const fn = this.encodeFunction(member);
        fn.name = `${className}.${fn.name}`;
        const isStatic = member.modifiers?.some(m => m.kind === ts.SyntaxKind.StaticKeyword);
        if (isStatic) {
          if (!fn.metadata) fn.metadata = {};
          fn.metadata["is_static"] = true;
        }
        functions.push(fn);
      }
      if (ts.isConstructorDeclaration(member)) {
        const fn = this.encodeFunction(member as any);
        fn.name = `${className}.constructor`;
        functions.push(fn);
      }
    }
    if (Object.keys(fieldInitializers).length > 0) {
      metadata["field_initializers"] = fieldInitializers;
    }

    typeDefs.push({ name: className, descriptor, metadata });
  }

  private encodeInterface(node: ts.InterfaceDeclaration): TypeDefinition {
    const descriptor: DescriptorProto = { name: node.name.text, field: [] };
    let fieldNum = 1;
    for (const member of node.members) {
      if (ts.isPropertySignature(member) && ts.isIdentifier(member.name)) {
        descriptor.field!.push({
          name: member.name.text,
          number: fieldNum++,
          type: member.type ? member.type.getText() : "any",
        });
      }
    }
    return { name: node.name.text, descriptor, metadata: { kind: "interface" } };
  }

  private encodeTypeAlias(node: ts.TypeAliasDeclaration): TypeAlias {
    return {
      name: node.name.text,
      targetType: node.type.getText(),
    };
  }

  private encodeEnum(node: ts.EnumDeclaration): EnumDef {
    return {
      name: node.name.text,
      values: node.members.map((m, i) => ({
        name: ts.isIdentifier(m.name) ? m.name.text : m.name.getText(),
        intValue: m.initializer && ts.isNumericLiteral(m.initializer)
          ? parseInt(m.initializer.text) : i,
      })),
    };
  }

  private encodeTaggedTemplate(node: ts.TaggedTemplateExpression): Expression {
    const tag = this.encodeExpr(node.tag);
    const parts: Expression[] = [];
    const exprs: Expression[] = [];

    if (ts.isNoSubstitutionTemplateLiteral(node.template)) {
      parts.push({ literal: { stringValue: node.template.text } });
    } else {
      parts.push({ literal: { stringValue: node.template.head.text } });
      for (const span of node.template.templateSpans) {
        exprs.push(this.encodeExpr(span.expression));
        parts.push({ literal: { stringValue: span.literal.text } });
      }
    }

    return this.stdCall("tagged_template", [
      { name: "tag", value: tag },
      { name: "strings", value: { literal: { listValue: { elements: parts } } } },
      { name: "expressions", value: { literal: { listValue: { elements: exprs } } } },
    ], "ts_std");
  }

  private stdCall(fn: string, fields: FieldValuePair[], module = "std"): Expression {
    this.stdFunctions.add(`${module}:${fn}`);
    return {
      call: {
        module,
        function: fn,
        input: fields.length > 0 ? {
          messageCreation: { typeName: "", fields },
        } : undefined,
      },
    };
  }

  private buildStdModule(): Module {
    const functions: FunctionDef[] = [];
    for (const ref of this.stdFunctions) {
      const [, fn] = ref.split(":");
      functions.push({ name: fn, isBase: true });
    }
    functions.sort((a, b) => a.name.localeCompare(b.name));
    return { name: "std", functions };
  }

  private warn(msg: string): void {
    this.warnings.push(msg);
  }

  getWarnings(): string[] {
    return [...this.warnings];
  }
}

export function encode(source: string, options: EncodeOptions = {}): Program {
  return new TsEncoder().encode(source, options);
}
