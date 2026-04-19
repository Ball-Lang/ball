/**
 * Ball protobuf shapes consumed by the TS compiler.
 *
 * Matches the proto3 JSON form emitted by the Dart encoder's
 * `Program.toProto3Json()` (see `proto/ball/v1/ball.proto`). Keep
 * these in sync with the shapes in `@ball-lang/engine/src/index.ts`.
 */

export interface Program {
  name?: string;
  version?: string;
  modules: Module[];
  entryModule: string;
  entryFunction: string;
}

export interface Module {
  name: string;
  functions: FunctionDef[];
  typeDefs?: TypeDefinition[];
  typeAliases?: TypeAlias[];
  enums?: EnumDef[];
  moduleImports?: ModuleImport[];
  metadata?: Struct;
}

export interface ModuleImport {
  name: string;
}

export interface FunctionDef {
  name: string;
  isBase?: boolean;
  body?: Expression;
  outputType?: string;
  metadata?: Struct;
}

export interface TypeDefinition {
  name: string;
  descriptor?: DescriptorProto;
  description?: string;
  metadata?: Struct;
}

export interface TypeAlias {
  name: string;
  targetType: string;
  metadata?: Struct;
}

export interface EnumDef {
  name: string;
  values: EnumValue[];
}

export interface EnumValue {
  name: string;
  intValue?: string | number;
}

export interface DescriptorProto {
  name: string;
  field?: FieldDescriptor[];
}

export interface FieldDescriptor {
  name: string;
  number?: number;
  type?: string;
  label?: string;
}

export interface Expression {
  call?: FunctionCall;
  literal?: Literal;
  reference?: { name: string };
  fieldAccess?: { object: Expression; field: string };
  messageCreation?: MessageCreation;
  block?: Block;
  lambda?: Lambda;
}

export interface FunctionCall {
  module?: string;
  function: string;
  input?: Expression;
}

export interface Literal {
  intValue?: string | number;
  doubleValue?: number;
  stringValue?: string;
  boolValue?: boolean;
  listValue?: { elements: Expression[] };
  bytesValue?: string;
}

export interface MessageCreation {
  typeName?: string;
  fields: FieldValuePair[];
}

export interface FieldValuePair {
  name: string;
  value: Expression;
}

export interface Block {
  statements: Statement[];
  result?: Expression;
}

export interface Statement {
  let?: { name: string; value?: Expression; metadata?: Struct };
  expression?: Expression;
}

export interface Lambda extends FunctionDef {
  // A Lambda is just an inline FunctionDef (body + metadata.params).
}

// ── Struct (google.protobuf.Struct JSON form) ─────────────────────────────
//
// In proto3 JSON, Struct serializes as a plain object (no `fields` wrapper).
// Use Struct as the metadata bag type throughout.
export type Struct = Record<string, unknown>;
