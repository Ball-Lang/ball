/**
 * Coverage for class/constructor emission details (compiler.ts's
 * `emitClass`/`buildCtor`/`buildNamedCtor`/`filterCtorBody`/`buildSetter`,
 * ~lines 2454-2946) that the mixin/pattern/generator fixtures don't
 * exercise on their own: the `descriptor.field` fallback when
 * `metadata.fields` is absent, inherited-field lookup through a superclass
 * chain, a superclass constructor call with parsed args, named-parameter
 * destructuring, named-constructor field initializers, constructor-body
 * self-recursion filtering, and setters.
 *
 * Run: node --experimental-strip-types --test test/*.test.ts
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { execSync } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compile } from "../src/index.ts";
import type { Program } from "../src/index.ts";

/** Compile WITH the preamble, execute via node, return trimmed stdout. */
function runCompiled(program: Program): string {
  const ts = compile(program);
  const tmpPath = join(tmpdir(), `ball_class_extra_${process.pid}_${Date.now()}.ts`);
  writeFileSync(tmpPath, ts);
  try {
    return execSync(`node --experimental-strip-types "${tmpPath}"`, { encoding: "utf8" }).trim();
  } finally {
    try { unlinkSync(tmpPath); } catch { /* ignore */ }
  }
}

function programWithClasses(mod: Partial<Program["modules"][number]>): Program {
  return {
    name: "class_extra_test",
    entryModule: "main",
    entryFunction: "main",
    modules: [
      {
        name: "main",
        functions: [
          { name: "main", body: { literal: { intValue: 0 } } },
          ...(mod.functions ?? []),
        ],
        typeDefs: mod.typeDefs,
      },
    ],
  };
}

describe("compiler — emitClass field fallback + inheritance", () => {
  test("falls back to descriptor.field when metadata.fields is absent", () => {
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Point",
          descriptor: {
            name: "main:Point",
            field: [
              { name: "x", type: "TYPE_INT64" },
              { name: "y", type: "TYPE_INT64" },
            ],
          },
          metadata: { kind: "class" },
        },
      ],
      functions: [
        {
          name: "main:Point.new",
          metadata: { kind: "constructor", params: [{ name: "input" }] },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /class Point/);
    assert.match(ts, /\bx\b[\s\S]*\by\b/);
  });

  test("inherits field names through the superclass chain for bare-field references in methods", () => {
    // Animal has field `name`; Dog extends Animal (no own fields) and a
    // method that references the inherited `name` bare — must emit
    // `this.name`, not a bare (undefined) `name`.
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Animal",
          metadata: { kind: "class", fields: [{ name: "name", type: "String" }] },
        },
        {
          name: "main:Dog",
          metadata: { kind: "class", superclass: "Animal" },
        },
      ],
      functions: [
        {
          name: "main:Animal.new",
          metadata: { kind: "constructor", params: [{ name: "input" }] },
        },
        {
          name: "main:Dog.new",
          metadata: { kind: "constructor", params: [{ name: "input" }] },
        },
        {
          name: "main:Dog.speak",
          metadata: { kind: "method" },
          body: { reference: { name: "name" } },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const speakMatch = /speak\s*\([^)]*\)\s*:\s*any\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(speakMatch, "speak() method found");
    assert.match(speakMatch![1], /this\.name/);
  });
});

describe("compiler — buildCtor: superclass constructor args + named-param destructuring", () => {
  test("parses super(...) initializer args and calls the superclass constructor", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Vehicle", metadata: { kind: "class", fields: [{ name: "make", type: "String" }] } },
        { name: "main:Car", metadata: { kind: "class", superclass: "Vehicle", fields: [{ name: "doors", type: "int" }] } },
      ],
      functions: [
        { name: "main:Vehicle.new", metadata: { kind: "constructor", params: [{ name: "make" }] } },
        {
          name: "main:Car.new",
          metadata: {
            kind: "constructor",
            params: [{ name: "make" }, { name: "doors" }],
            initializers: [{ kind: "super", args: "(make)" }],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /class Car extends Vehicle/);
    const ctorMatch = /class Car[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Car constructor found");
    assert.match(ctorMatch![2], /super\(make\);/);
  });

  test("destructures a trailing named-args object when the ctor mixes positional and named params", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Widget", metadata: { kind: "class", fields: [{ name: "id", type: "String" }, { name: "label", type: "String" }] } },
      ],
      functions: [
        {
          name: "main:Widget.new",
          metadata: {
            kind: "constructor",
            params: [{ name: "id" }, { name: "label", is_named: true }],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const ctorMatch = /class Widget[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Widget constructor found");
    assert.match(ctorMatch![2], /'label' in label/, "detects+destructures the named-args object");
  });
});

describe("compiler — buildNamedCtor (named constructors as static factories)", () => {
  test("a named constructor builds an instance from field initializers", () => {
    // `factory Point.origin() : x = 0, y = 0;` style — encoded as a
    // named ctor (`main:Point.origin`) with field initializers.
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Point", metadata: { kind: "class", fields: [{ name: "x", type: "int" }, { name: "y", type: "int" }] } },
      ],
      functions: [
        { name: "main:Point.new", metadata: { kind: "constructor", params: [{ name: "x" }, { name: "y" }] } },
        {
          name: "main:Point.origin",
          metadata: {
            kind: "constructor",
            params: [],
            initializers: [
              { kind: "field", name: "x", value: "0" },
              { kind: "field", name: "y", value: "0" },
            ],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    // Named ctor becomes a static factory method returning a new instance
    // built from the parsed field initializers (x=0, y=0).
    assert.match(ts, /static origin\s*\(/);
    assert.match(ts, /Object\.create\(Point\.prototype\)/);
    assert.match(ts, /__inst\.x = 0/);
    assert.match(ts, /__inst\.y = 0/);
  });
});

describe("compiler — filterCtorBody (self-recursive boilerplate removal)", () => {
  test("removes an encoder-emitted `let self = new ClassName()` / `return self` pair from a ctor body", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Counter", metadata: { kind: "class", fields: [{ name: "count", type: "int" }] } },
      ],
      functions: [
        {
          name: "main:Counter.new",
          metadata: { kind: "constructor", params: [{ name: "input" }] },
          body: {
            block: {
              statements: [
                {
                  let: {
                    name: "self",
                    value: { messageCreation: { typeName: "main:Counter", fields: [] } },
                  },
                },
                {
                  expression: {
                    call: {
                      module: "std",
                      function: "return",
                      input: { messageCreation: { fields: [{ name: "value", value: { reference: { name: "self" } } }] } },
                    },
                  },
                },
              ],
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const ctorMatch = /class Counter[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Counter constructor found");
    // Neither the self-recursive `new Counter()` construction nor a
    // `return self;` (invalid in a JS constructor) should survive.
    assert.doesNotMatch(ctorMatch![2], /new Counter\(\)/);
    assert.doesNotMatch(ctorMatch![2], /return self/);
  });
});

describe("compiler — emitClass: static_field member (module-level const)", () => {
  test("a static field member becomes a module-level const emitted before the class", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Counters", metadata: { kind: "class", fields: [] } },
      ],
      functions: [
        { name: "main:Counters.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        {
          name: "main:Counters.total",
          metadata: { kind: "static_field" },
          body: { literal: { intValue: 0 } },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    // Emitted above the class (bare name, no `static` keyword, no `this.`)
    // so instance methods can reference it unqualified, per Dart semantics.
    assert.match(ts, /const total = 0;/);
    assert.ok(ts.indexOf("const total = 0;") < ts.indexOf("class Counters"));
  });

  test("overrides an empty-Set initializer to `{}` when outputType says Map (encoder quirk)", () => {
    // An empty `{}` map literal encodes as std.set_create with no elements;
    // when the static field's declared outputType is a Map, the compiler
    // must correct the compiled `new Set()` to an empty object.
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Registry", metadata: { kind: "class", fields: [] } },
      ],
      functions: [
        { name: "main:Registry.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        {
          name: "main:Registry.cache",
          metadata: { kind: "static_field" },
          outputType: "Map<String, int>",
          body: {
            call: {
              module: "std",
              function: "set_create",
              input: {
                messageCreation: {
                  fields: [
                    { name: "elements", value: { literal: { listValue: { elements: [] } } } },
                  ],
                },
              },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /const cache = \{\};/);
    assert.doesNotMatch(ts, /const cache = new Set\(\);/);
  });
});

describe("compiler — buildSetter", () => {
  test("emits a `set` accessor that writes an instance field", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Box", metadata: { kind: "class", fields: [{ name: "value", type: "int" }] } },
      ],
      functions: [
        { name: "main:Box.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        {
          name: "main:Box.value",
          metadata: { kind: "method", is_setter: true, params: [{ name: "v" }] },
          body: {
            call: {
              module: "std",
              function: "assign",
              input: {
                messageCreation: {
                  fields: [
                    { name: "target", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "value" } } },
                    { name: "value", value: { reference: { name: "v" } } },
                  ],
                },
              },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /set value\(v: any\)/);
  });
});

describe("compiler — self->this substitution for a class with NO declared fields (#253)", () => {
  test("a constructor that only does self.x = x (no prior field declaration) compiles to this.x, not a leaked `self`", () => {
    // typeDefs carries NO `fields` metadata at all — currentClassFields is
    // empty for this class, but `self` inside its constructor/methods must
    // still mean `this` (gated on "are we compiling a class member", not
    // on the class having any declared fields).
    const program: Program = {
      name: "undeclared_field_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [{ name: "main:Point", metadata: { kind: "class" } }],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    { let: { name: "p", value: { messageCreation: { typeName: "main:Point", fields: [{ name: "arg0", value: { literal: { intValue: 1 } } }, { name: "arg1", value: { literal: { intValue: 2 } } }] } } } },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { call: { function: "toStr", input: { messageCreation: { fields: [{ name: "self", value: { reference: { name: "p" } } }] } } } } }] } } } } },
                  ],
                },
              },
            },
            {
              name: "main:Point.new",
              metadata: { kind: "constructor", params: [{ name: "x" }, { name: "y" }] },
              body: {
                block: {
                  statements: [
                    { expression: { call: { module: "std", function: "assign", input: { messageCreation: { fields: [{ name: "target", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "x" } } }, { name: "value", value: { reference: { name: "x" } } }] } } } } },
                    { expression: { call: { module: "std", function: "assign", input: { messageCreation: { fields: [{ name: "target", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "y" } } }, { name: "value", value: { reference: { name: "y" } } }] } } } } },
                  ],
                },
              },
            },
            {
              name: "main:Point.toStr",
              metadata: { kind: "method" },
              body: {
                call: {
                  module: "std",
                  function: "add",
                  input: {
                    messageCreation: {
                      fields: [
                        { name: "left", value: { call: { module: "std", function: "add", input: { messageCreation: { fields: [
                          { name: "left", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "x" } } },
                          { name: "right", value: { literal: { stringValue: "," } } },
                        ] } } } } },
                        { name: "right", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "y" } } },
                      ],
                    },
                  },
                },
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /this\.x = x;/);
    assert.match(ts, /this\.y = y;/);
    assert.doesNotMatch(ts, /\bself\.[xy]\b/, "no leaked bare `self.` field access");
    assert.equal(runCompiled(program), "1,2");
  });
});

describe("compiler — bracket-invoking a string-literal operator method (#252)", () => {
  test("index(target, '+') then invoke resolves the canonical __op_add__ method and executes it", () => {
    // Mirrors what ts/encoder now produces for `a['+'](b)`: an "index" call
    // (target, the raw '+' lexeme) wrapped in an "invoke" call (the index
    // result as callee, plus args). Before #252, "index" indexed the raw
    // lexeme literally (a nonexistent '+' property) and the encoder's old
    // "__invoke" name/missing module meant this never even reached
    // compileStdCall's "invoke" dispatch.
    const program: Program = {
      name: "operator_invoke_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [{ name: "main:Vec2", metadata: { kind: "class", fields: [{ name: "x", type: "int" }] } }],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    { let: { name: "a", value: { messageCreation: { typeName: "main:Vec2", fields: [{ name: "arg0", value: { literal: { intValue: 1 } } }] } } } },
                    { let: { name: "b", value: { messageCreation: { typeName: "main:Vec2", fields: [{ name: "arg0", value: { literal: { intValue: 2 } } }] } } } },
                    {
                      let: {
                        name: "c",
                        value: {
                          call: {
                            module: "std",
                            function: "invoke",
                            input: {
                              messageCreation: {
                                fields: [
                                  { name: "callee", value: { call: { module: "std", function: "index", input: { messageCreation: { fields: [
                                    { name: "target", value: { reference: { name: "a" } } },
                                    { name: "index", value: { literal: { stringValue: "+" } } },
                                  ] } } } } },
                                  { name: "arg0", value: { reference: { name: "b" } } },
                                ],
                              },
                            },
                          },
                        },
                      },
                    },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "c" } }, field: "x" } } }] } } } } },
                  ],
                },
              },
            },
            {
              name: "main:Vec2.new",
              metadata: { kind: "constructor", params: [{ name: "x" }] },
            },
            {
              name: "main:Vec2.__op_add__",
              metadata: { kind: "method", is_operator: true, operator: "+", params: [{ name: "other" }] },
              body: { messageCreation: { typeName: "main:Vec2", fields: [
                { name: "arg0", value: { call: { module: "std", function: "add", input: { messageCreation: { fields: [
                  { name: "left", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "x" } } },
                  { name: "right", value: { fieldAccess: { object: { reference: { name: "other" } }, field: "x" } } },
                ] } } } } },
              ] } },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /a\.__op_add__/, "bracket-index on a string operator lexeme resolves to the canonical method");
    assert.equal(runCompiled(program), "3");
  });
});
