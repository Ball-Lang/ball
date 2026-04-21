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
  metadata?: Struct;
}

export interface FunctionDef {
  name: string;
  isBase?: boolean;
  body?: Expression;
  inputType?: string;
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
  lambda?: FunctionDef;
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

export type Struct = Record<string, unknown>;
