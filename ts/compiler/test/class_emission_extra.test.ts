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
  test("inherits field names through the superclass chain via descriptor.field (no metadata.fields on the super)", () => {
    // Animal carries ITS fields only via descriptor.field (no metadata.fields
    // at all) — exercises the inherited-field-lookup fallback distinct from
    // the "own class" descriptor.field fallback covered by the next test.
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Animal",
          descriptor: {
            name: "main:Animal",
            field: [{ name: "name", type: "TYPE_STRING" }],
          },
          metadata: { kind: "class" },
        },
        {
          name: "main:Cat",
          metadata: { kind: "class", superclass: "Animal" },
        },
      ],
      functions: [
        { name: "main:Animal.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        { name: "main:Cat.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        {
          name: "main:Cat.speak",
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

  test("parses a super(...) initializer arg that's a string literal", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Vehicle", metadata: { kind: "class", fields: [{ name: "make", type: "String" }] } },
        { name: "main:Car", metadata: { kind: "class", superclass: "Vehicle" } },
      ],
      functions: [
        { name: "main:Vehicle.new", metadata: { kind: "constructor", params: [{ name: "make" }] } },
        {
          name: "main:Car.new",
          metadata: {
            kind: "constructor",
            params: [],
            initializers: [{ kind: "super", args: "('Toyota')" }],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const ctorMatch = /class Car[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Car constructor found");
    assert.match(ctorMatch![2], /super\('Toyota'\);/);
  });

  test("falls back to a bare super() when the super(...) initializer has no args", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Vehicle", metadata: { kind: "class" } },
        { name: "main:Car", metadata: { kind: "class", superclass: "Vehicle" } },
      ],
      functions: [
        { name: "main:Vehicle.new", metadata: { kind: "constructor", params: [] } },
        {
          name: "main:Car.new",
          metadata: {
            kind: "constructor",
            params: [],
            initializers: [{ kind: "super", args: "()" }],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const ctorMatch = /class Car[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Car constructor found");
    assert.match(ctorMatch![2], /^\s*super\(\);/m);
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

  test("a PLAIN parameter that merely shares a field's name never writes that field (#539/#564)", () => {
    // `class Foo { int x = 5; int y = 7; Foo(int x) { print(x); } }` — `x` is
    // an ordinary local, so `Foo(9).x` is 5 in Dart. `buildCtor` used to emit
    // `this.x = x;` for any param whose name merely appeared in the class's
    // field set (`p.isThis || classFields.has(p.name)`) — the byte-identical
    // defect the Dart ENGINE carried until #563. `Baz(this.v)` in the same
    // fixture is the positive control: a real `this.`-formal must still write.
    const program: Program = {
      name: "plain_param_shadows_field_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [
            {
              name: "main:Foo",
              metadata: {
                kind: "class",
                fields: [
                  { name: "x", type: "int", initializer: "5" },
                  { name: "y", type: "int", initializer: "7" },
                ],
              },
            },
            { name: "main:Baz", metadata: { kind: "class", fields: [{ name: "v", type: "int", initializer: "7" }] } },
          ],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    { let: { name: "f", value: { messageCreation: { typeName: "main:Foo", fields: [{ name: "arg0", value: { literal: { intValue: 9 } } }] } } } },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "f" } }, field: "x" } } }] } } } } },
                    { let: { name: "b", value: { messageCreation: { typeName: "main:Baz", fields: [{ name: "arg0", value: { literal: { intValue: 3 } } }] } } } },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "b" } }, field: "v" } } }] } } } } },
                  ],
                },
              },
            },
            {
              name: "main:Foo.new",
              metadata: { kind: "constructor", params: [{ name: "x", type: "int" }] },
              body: {
                call: {
                  module: "std",
                  function: "print",
                  input: { messageCreation: { fields: [{ name: "message", value: { reference: { name: "x" } } }] } },
                },
              },
            },
            { name: "main:Baz.new", metadata: { kind: "constructor", params: [{ name: "v", type: "int", is_this: true }] } },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    const fooCtor = /class Foo \{[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n  \}/.exec(ts);
    assert.ok(fooCtor, "Foo constructor found");
    assert.doesNotMatch(fooCtor![2], /this\.x = x;/, "a plain colliding param must not clobber the field");
    // The positive control: a real `this.`-formal still writes its field.
    assert.match(ts, /this\.v = v;/);
    // `9` from Foo's body, then the untouched `x` default, then Baz's `this.v`.
    assert.equal(runCompiled(program), "9\n5\n3");
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

  test("a named constructor's field initializer can reference a param, a string literal, or an indexed param", () => {
    // `factory Point.fromArgs(int x, List<int> coords) : this.x = x, this.label
    // = 'origin', this.z = coords[0];` — exercises all three non-numeric
    // initializer-value resolution branches in the same ctorArgs-building pass.
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Point3",
          metadata: {
            kind: "class",
            fields: [
              { name: "x", type: "int" },
              { name: "label", type: "String" },
              { name: "z", type: "int" },
            ],
          },
        },
      ],
      functions: [
        { name: "main:Point3.new", metadata: { kind: "constructor", params: [{ name: "x" }, { name: "label" }, { name: "z" }] } },
        {
          name: "main:Point3.fromArgs",
          metadata: {
            kind: "constructor",
            params: [{ name: "x" }, { name: "coords" }],
            initializers: [
              { kind: "field", name: "x", value: "x" },
              { kind: "field", name: "label", value: "'origin'" },
              { kind: "field", name: "z", value: "coords[0]" },
            ],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /static fromArgs\s*\(/);
    assert.match(ts, /__inst\.x = x;/);
    assert.match(ts, /__inst\.label = 'origin';/);
    assert.match(ts, /__inst\.z = coords\[0\];/);
  });

  test("a named constructor with is_this params (and no field initializers) assigns them directly", () => {
    // `factory Box.of(this.value) => Box._(value);`-style: no explicit field
    // initializers, but ctor params are marked is_this — they become the
    // Object.create field assignments directly.
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Box", metadata: { kind: "class", fields: [{ name: "value", type: "int" }] } },
      ],
      functions: [
        { name: "main:Box.new", metadata: { kind: "constructor", params: [{ name: "value", is_this: true }] } },
        {
          name: "main:Box.of",
          metadata: {
            kind: "constructor",
            params: [{ name: "value", is_this: true }],
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /static of\s*\(/);
    assert.match(ts, /Object\.create\(Box\.prototype\)/);
    assert.match(ts, /__inst\.value = value;/);
  });

  test("a BODY-ONLY named constructor constructs a real instance seeded with the class's field defaults (#564)", () => {
    // `Registry.empty() { print('made'); }` — a named constructor with no
    // initializer list and no `this.`-formals, only a body. It used to compile
    // to a bare `static empty(): any { return console.log(...); }` that never
    // constructed anything: `this` inside the body was the CLASS, and the
    // method returned whatever the body evaluated to (`undefined`).
    //
    // The previous version of this test asserted only that `console.log`
    // appeared inside the emitted `static empty()` body and called that "the
    // real ctor body was emitted, not an Object.create" — encoding the bug as
    // the intended contract. Emitted TEXT can never show that a factory fails
    // to construct anything, so this RUNS the compiled output.
    const program: Program = {
      name: "named_ctor_body_only_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [
            { name: "main:Registry", metadata: { kind: "class", fields: [{ name: "count", type: "int", initializer: "5" }] } },
          ],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "r",
                        value: {
                          call: {
                            function: "empty",
                            input: { messageCreation: { fields: [{ name: "self", value: { reference: { name: "Registry" } } }] } },
                          },
                        },
                      },
                    },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "r" } }, field: "count" } } }] } } } } },
                  ],
                },
              },
            },
            { name: "main:Registry.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Registry.empty",
              outputType: "main:Registry",
              metadata: { kind: "constructor", params: [] },
              body: {
                call: {
                  module: "std",
                  function: "print",
                  input: { messageCreation: { fields: [{ name: "message", value: { literal: { stringValue: "made" } } }] } },
                },
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /static empty\s*\(/);
    // A real instance, seeded with the declared default, with the body run
    // against it — not a static method that returns the body's own value.
    assert.match(ts, /Object\.create\(Registry\.prototype\)/);
    assert.match(ts, /__inst\.count = 5;/);
    assert.match(ts, /\(function\s*\(\)\s*\{[\s\S]*?console\.log[\s\S]*?\}\)\.call\(__inst\);/);
    assert.match(ts, /return __inst;/);
    // The proof emitted text alone cannot give: the factory's return value is
    // a real Registry whose untouched field carries its declared default.
    assert.equal(runCompiled(program), "made\n5");
  });

  test("the Object.create path seeds a field the initializer list never touches with its declared default (#564)", () => {
    // Mirrors conformance 453's `class Init { int v = 7; int w = 11;
    // Init.viaList(int n) : v = n; }` — `w` is declared with a default the
    // named constructor never mentions. `Object.create(C.prototype)`
    // deliberately skips the real constructor, and that also skips every
    // inline field initializer, so `w` used to stay `undefined` forever.
    const program: Program = {
      name: "named_ctor_untouched_field_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [
            {
              name: "main:Init",
              metadata: {
                kind: "class",
                fields: [
                  { name: "v", type: "int", initializer: "7" },
                  { name: "w", type: "int", initializer: "11" },
                ],
              },
            },
          ],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "i",
                        value: {
                          call: {
                            function: "viaList",
                            input: {
                              messageCreation: {
                                fields: [
                                  { name: "self", value: { reference: { name: "Init" } } },
                                  { name: "arg0", value: { literal: { intValue: 3 } } },
                                ],
                              },
                            },
                          },
                        },
                      },
                    },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "i" } }, field: "v" } } }] } } } } },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "i" } }, field: "w" } } }] } } } } },
                  ],
                },
              },
            },
            { name: "main:Init.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Init.viaList",
              outputType: "main:Init",
              metadata: {
                kind: "constructor",
                params: [{ name: "n", type: "int" }],
                initializers: [{ kind: "field", name: "v", value: "n" }],
              },
            },
          ],
        },
      ],
    };
    const ts = compile(program, { includePreamble: false });
    // Defaults are seeded first (Dart runs inline field initializers before
    // the initializer list), then the ctor-specific write overwrites `v`.
    assert.ok(ts.indexOf("__inst.v = 7;") >= 0, "the initialized field is seeded with its default");
    assert.ok(ts.indexOf("__inst.v = 7;") < ts.indexOf("__inst.v = n;"), "field defaults precede the initializer-list write");
    assert.match(ts, /__inst\.w = 11;/);
    assert.ok(ts.indexOf("__inst.w = 11;") < ts.indexOf("return __inst;"), "the untouched field is seeded before the instance is returned");
    assert.equal(runCompiled(program), "3\n11");
  });

  // #499/#489 follow-up: a constructor may have BOTH an initializer list (or
  // `this.`-params) AND a body. Dart runs the list first, then the body. The
  // Object.create branch used to drop `fn.body` entirely, and buildCtor never
  // emitted the initializer list at all — both silent, and both invisible to
  // the TS ENGINE (which interprets and never reaches these builders).
  test("a named constructor with BOTH an initializer list and a body runs the body against the new instance", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Seed", metadata: { kind: "class", fields: [{ name: "value", type: "int" }] } },
      ],
      functions: [
        { name: "main:Seed.new", metadata: { kind: "constructor", params: [{ name: "value", is_this: true }] } },
        {
          name: "main:Seed.seeded",
          metadata: {
            kind: "constructor",
            params: [{ name: "start" }],
            initializers: [{ kind: "field", name: "value", value: "start" }],
          },
          // `value = value + 1;` — reads and writes the field the initializer
          // list just set, so it only works if the body runs with `__inst`
          // as its receiver AFTER the initializers.
          body: {
            call: {
              module: "std",
              function: "assign",
              input: {
                messageCreation: {
                  fields: [
                    { name: "target", value: { reference: { name: "value" } } },
                    {
                      name: "value",
                      value: {
                        call: {
                          module: "std",
                          function: "add",
                          input: {
                            messageCreation: {
                              fields: [
                                { name: "left", value: { reference: { name: "value" } } },
                                { name: "right", value: { literal: { intValue: 1 } } },
                              ],
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /Object\.create\(Seed\.prototype\)/);
    assert.match(ts, /__inst\.value = start;/);
    // A real `function`, never an arrow — the body needs `__inst` as `this`.
    assert.match(ts, /\(function\s*\(\)\s*\{[\s\S]*?\}\)\.call\(__inst\);/);
    assert.match(ts, /this\.value = __ball_add\(this\.value, 1\)/);
  });

  test("an UNNAMED constructor emits its initializer list into the prologue, before its body", () => {
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Tag",
          metadata: {
            kind: "class",
            fields: [
              { name: "x", type: "int" },
              { name: "label", type: "String" },
            ],
          },
        },
      ],
      functions: [
        {
          name: "main:Tag.new",
          metadata: {
            kind: "constructor",
            params: [{ name: "a" }],
            initializers: [
              { kind: "field", name: "x", value: "a" },
              { kind: "field", name: "label", value: "'pt'" },
            ],
          },
          body: {
            call: {
              module: "std",
              function: "print",
              input: { messageCreation: { fields: [{ name: "message", value: { literal: { stringValue: "built" } } }] } },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /this\.x = a;/);
    assert.match(ts, /this\.label = 'pt';/);
    // The initializer list precedes the body, exactly as Dart orders them.
    assert.ok(ts.indexOf("this.label = 'pt';") < ts.indexOf("console.log"));
  });

  test("a named FACTORY constructor still runs its body as the method and returns the body's value (#564)", () => {
    // `factory Registry.shared() => Registry.tagged(2);` — a factory returns
    // some other object by definition, so it is the one body-bearing named
    // constructor that must NOT synthesize an instance of its own class. The
    // #564 fix turns every OTHER body-only named ctor into a constructing one,
    // so this pins the carve-out: without the `is_factory` check the factory's
    // return value would be discarded in favour of a blank `Object.create`.
    const program: Program = {
      name: "named_factory_ctor_test",
      entryModule: "main",
      entryFunction: "main",
      modules: [
        {
          name: "main",
          typeDefs: [
            { name: "main:Registry", metadata: { kind: "class", fields: [{ name: "count", type: "int", initializer: "5" }] } },
          ],
          functions: [
            {
              name: "main",
              body: {
                block: {
                  statements: [
                    {
                      let: {
                        name: "r",
                        value: {
                          call: {
                            function: "shared",
                            input: { messageCreation: { fields: [{ name: "self", value: { reference: { name: "Registry" } } }] } },
                          },
                        },
                      },
                    },
                    { expression: { call: { module: "std", function: "print", input: { messageCreation: { fields: [{ name: "message", value: { fieldAccess: { object: { reference: { name: "r" } }, field: "count" } } }] } } } } },
                  ],
                },
              },
            },
            { name: "main:Registry.new", metadata: { kind: "constructor", params: [] } },
            {
              name: "main:Registry.tagged",
              outputType: "main:Registry",
              metadata: {
                kind: "constructor",
                params: [{ name: "n", type: "int" }],
                initializers: [{ kind: "field", name: "count", value: "n" }],
              },
            },
            {
              name: "main:Registry.shared",
              outputType: "main:Registry",
              metadata: { kind: "constructor", is_factory: true, params: [] },
              body: {
                call: {
                  function: "tagged",
                  input: {
                    messageCreation: {
                      fields: [
                        { name: "self", value: { reference: { name: "Registry" } } },
                        { name: "arg0", value: { literal: { intValue: 2 } } },
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
    const shared = /static shared\s*\([^)]*\)\s*:\s*any\s*\{([\s\S]*?)\n  \}/.exec(ts);
    assert.ok(shared, "shared() factory found");
    assert.doesNotMatch(shared![1], /Object\.create/, "a factory synthesizes no instance of its own class");
    assert.match(shared![1], /return Registry\.tagged\(2\);/);
    assert.equal(runCompiled(program), "2");
  });

  test("a named constructor with no initializers, no is_this params, and no body falls back to `return new Class()`", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Marker", metadata: { kind: "class", fields: [] } },
      ],
      functions: [
        { name: "main:Marker.new", metadata: { kind: "constructor", params: [] } },
        {
          name: "main:Marker.instance",
          metadata: { kind: "constructor", params: [] },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /static instance\s*\([^)]*\)\s*:\s*any\s*\{\s*return new Marker\(\);\s*\}/);
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

  test("filters a bare no-op reference statement (e.g. a lone `input;`) out of a ctor body", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:Holder", metadata: { kind: "class", fields: [{ name: "value", type: "int" }] } },
      ],
      functions: [
        {
          name: "main:Holder.new",
          metadata: { kind: "constructor", params: [{ name: "input" }] },
          body: {
            block: {
              statements: [
                // A bare no-op reference statement (encoder boilerplate) —
                // must be filtered rather than emitted as `input;`.
                { expression: { reference: { name: "input" } } },
                {
                  expression: {
                    call: {
                      module: "std",
                      function: "assign",
                      input: {
                        messageCreation: {
                          fields: [
                            { name: "target", value: { fieldAccess: { object: { reference: { name: "self" } }, field: "value" } } },
                            { name: "value", value: { literal: { intValue: 7 } } },
                          ],
                        },
                      },
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
    const ctorMatch = /class Holder[\s\S]*?constructor\(([^)]*)\)\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(ctorMatch, "Holder constructor found");
    assert.doesNotMatch(ctorMatch![2], /^\s*input;\s*$/m, "bare `input;` statement was filtered out");
    assert.match(ctorMatch![2], /this\.value = 7;/);
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
              // `Vec2(this.x)` — a real `this.`-formal. It used to be spelled
              // as a PLAIN `{ name: "x" }` here and still stored the field,
              // because `buildCtor` wrote any param whose name merely appeared
              // in the class's field set; that permissive write is the
              // #539/#564 defect and is gone, so the IR now says what the
              // encoder actually emits for a field-initializing formal.
              metadata: { kind: "constructor", params: [{ name: "x", is_this: true }] },
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

describe("compiler — a method-local shadows a same-named class member (#501 family)", () => {
  // In Dart a method-local shadows every class member, so a bare reference to
  // it must compile to the LOCAL and never to `this.<name>`. Two things had to
  // be true for that, and neither was:
  //
  //  1. `expr()`'s reference branch consulted only `currentMethodParams`, so a
  //     declared local named after a field or getter still took the
  //     `this.<name>` branch;
  //  2. `emitBlock` restored the enclosing scope BEFORE compiling a function
  //     body's tail `result` expression, so even with (1) fixed the `return x;`
  //     of `{ int x = 99; return x; }` was compiled against a scope in which
  //     `x` had never been declared.
  //
  // The failure is a SILENT WRONG ANSWER — `this.x` is a perfectly valid
  // property read — which is why it survived until conformance
  // 433_shadowed_field_self_write_and_local drove it end to end.
  test("a local named after a getter is read as the local, not as this.<name>", () => {
    const program = programWithClasses({
      typeDefs: [{ name: "main:A", metadata: { kind: "class" } }],
      functions: [
        {
          name: "main:A.x",
          metadata: { kind: "method", is_getter: true },
          body: { literal: { intValue: 1 } },
        },
        {
          name: "main:A.localOverGetter",
          metadata: { kind: "method" },
          body: {
            block: {
              statements: [{ let: { name: "x", value: { literal: { intValue: 99 } } } }],
              result: { reference: { name: "x" } },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const m = /localOverGetter\s*\([^)]*\)\s*:\s*any\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(m, "localOverGetter() method found");
    assert.match(m![1], /let x = 99;/);
    assert.match(m![1], /return x;/);
    assert.doesNotMatch(m![1], /return this\.x;/);
  });

  test("a local named after a field is read as the local, and the field is untouched", () => {
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:B",
          descriptor: { name: "main:B", field: [{ name: "x", type: "TYPE_INT64" }] },
          metadata: { kind: "class", fields: [{ name: "x", type: "int", initializer: "5" }] },
        },
      ],
      functions: [
        { name: "main:B.new", metadata: { kind: "constructor", params: [{ name: "input" }] } },
        {
          name: "main:B.shadowLocal",
          metadata: { kind: "method" },
          body: {
            block: {
              statements: [{ let: { name: "x", value: { literal: { intValue: 99 } } } }],
              result: { reference: { name: "x" } },
            },
          },
        },
        {
          name: "main:B.readField",
          metadata: { kind: "method" },
          body: { reference: { name: "x" } },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    const local = /shadowLocal\s*\([^)]*\)\s*:\s*any\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(local, "shadowLocal() method found");
    assert.match(local![1], /return x;/);
    assert.doesNotMatch(local![1], /this\.x/);
    // The field read in a method with NO local of that name still resolves to
    // the member — the fix must not disable field resolution generally.
    const field = /readField\s*\([^)]*\)\s*:\s*any\s*\{([\s\S]*?)\n\s*\}/.exec(ts);
    assert.ok(field, "readField() method found");
    assert.match(field![1], /return this\.x;/);
  });
});

describe("compiler - constructor tear-offs (#531)", () => {
  // The Dart encoder emits `Box.new(7)` as a GENERIC self-carrying method
  // call - {function: "new", input: {self: Reference("Box"), arg0: 7}} -
  // never as the `main:Box.new` Call that compileCall handles up front. The
  // generic path emitted `Box.new_(7)` (`new` is not a legal TS member name),
  // a static method no emitted class declares.
  const tearOff = (receiver: string, args: any[]) => ({
    call: {
      function: "new",
      input: {
        messageCreation: {
          fields: [
            { name: "self", value: { reference: { name: receiver } } },
            ...args.map((v, i) => ({ name: `arg${i}`, value: v })),
          ],
        },
      },
    },
  });

  test("a user-class tear-off constructs, exactly like the direct form", () => {
    const program = programWithClasses({
      typeDefs: [
        {
          name: "main:Box",
          descriptor: { name: "Box", field: [{ name: "v", type: "TYPE_INT64" }] },
          metadata: { kind: "class" },
        },
      ],
      functions: [
        {
          name: "main:Box.new",
          metadata: { kind: "constructor", params: [{ name: "v", is_this: true }] },
        },
        {
          name: "makeBox",
          body: tearOff("Box", [{ literal: { intValue: 7 } }]),
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /new Box\(7\)/);
    assert.doesNotMatch(ts, /Box\.new_\(/);
  });

  test("a built-in exception tear-off yields the same tagged object as direct construction", () => {
    const program = programWithClasses({
      functions: [
        {
          name: "boom",
          body: tearOff("FormatException", [{ literal: { stringValue: "bad input" } }]),
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    // Identical to what `throw FormatException('bad input')` emits, so the
    // typed-catch guard matches either spelling.
    assert.match(ts, /\{\s*'__type__': 'FormatException',\s*'message': 'bad input'\s*\}/);
    assert.doesNotMatch(ts, /FormatException\.new_\(/);
  });

  test("an ordinary static-method call on a class is untouched", () => {
    const program = programWithClasses({
      typeDefs: [
        { name: "main:MathU", descriptor: { name: "MathU" }, metadata: { kind: "class" } },
      ],
      functions: [
        { name: "main:MathU.square", metadata: { kind: "method", is_static: true }, body: { literal: { intValue: 1 } } },
        {
          name: "useSquare",
          body: {
            call: {
              function: "square",
              input: {
                messageCreation: {
                  fields: [
                    { name: "self", value: { reference: { name: "MathU" } } },
                    { name: "arg0", value: { literal: { intValue: 3 } } },
                  ],
                },
              },
            },
          },
        },
      ],
    });
    const ts = compile(program, { includePreamble: false });
    assert.match(ts, /MathU\.square\(3\)/);
  });
});
