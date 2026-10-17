package compiler_test

// Go compiler getter/setter name collision + field-accessor dispatch
// (issue #813, fixture 470_setter_beside_final_field).
//
// `memberImplName` (now `MemberImplName`'s Go sibling) had no setter-vs-getter
// disambiguation, so a class declaring BOTH a getter and a setter of the same
// short name (`main:Scaler.amount`) compiled both to the identical impl func
// name `Scaler__amount` — a duplicate top-level declaration, which `go build`/
// `go run` reject outright (`compileFmt`'s `go/format` pass does not catch
// this: duplicate declarations are a type-check error, not a syntax error, so
// the emitted Go LOOKED fine until actually built).
//
// Two further defects surfaced while isolating this, both silent-wrong-answer
// shapes rather than build failures:
//   - the general per-short-name method dispatcher (`compileDispatcher`) also
//     received a branch for EACH of the getter and the setter under the same
//     owner, so one of the two branches was permanently dead code (an
//     unreachable duplicate `if __t == ... { return ... }`);
//   - `compileFieldAccess` (a property READ) and `emitMutation`'s "field" case
//     (a property WRITE) always lowered straight to `ballrt.FieldGet`/
//     `ballrt.FieldSet` — bypassing a class's own declared getter/setter
//     entirely, so a setter that validates or throws (as 470's does) never ran.
import (
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
)

// TestSetterBesideFinalFieldCompilesWithoutDuplicateSymbols is the build-level
// pin: the getter and setter impls for `main:Scaler.amount` must get DISTINCT
// Go identifiers, and the general dispatcher must carry no duplicated branch
// for a colliding (owner, short-name) pair.
func TestSetterBesideFinalFieldCompilesWithoutDuplicateSymbols(t *testing.T) {
	prog := load(t, conformancePath("470_setter_beside_final_field.ball.json"))
	src := compileFmt(t, prog)

	if strings.Count(src, "func Scaler__amount(") != 1 {
		t.Errorf("getter impl func must be declared exactly once\n---\n%s", src)
	}
	if !strings.Contains(src, "func Scaler__amount__set(") {
		t.Errorf("setter impl func must get its own distinct name\n---\n%s", src)
	}
}

// TestSetterBesideFinalFieldRunsAndDispatchesThroughAccessors is the
// behavioural pin — it RUNS the compiled program and checks the full
// transcript against the golden, which is the only way to prove the setter
// actually fires (validating/throwing), the final field's read bypasses it,
// and a subclass's own same-named PLAIN field shadows the inherited accessor.
func TestSetterBesideFinalFieldRunsAndDispatchesThroughAccessors(t *testing.T) {
	prog := load(t, conformancePath("470_setter_beside_final_field.ball.json"))
	src := compileFmt(t, prog)
	got := goRun(t, src)
	want := readGolden(t, "470_setter_beside_final_field.expected_output.txt")
	if got != want {
		t.Errorf("470: got %q, want %q\n---\n%s", got, want, src)
	}
}

// 470's own "subclass declares its own plain field, shadowing an ancestor's
// accessor" shape (`Plain extends Scaler`, own `amount` field) is exercised
// above by TestSetterBesideFinalFieldRunsAndDispatchesThroughAccessors
// (`plain.amount` prints 7, bypassing Scaler's *10 setter) — a sibling of
// fixture 432_shadowed_getter_setter_write, which exercises the identical
// accessor-shadow rule PLUS an unrelated, pre-existing Go compiler gap (the
// general per-short-name method dispatcher has no superclass fallback at
// all — reproduces identically with zero getters/setters involved, filed as
// #890) that 432's own `a.readX()`/`b.readX()` calls trip over regardless of
// this fix. 432 is not used here for that reason; raising
// GO_COMPILER_FLOOR for it belongs to #890, not to this change.

// TestMultipleClassesShareAPropertyNameDispatchIndependently covers a shape
// NEITHER fixture above does: two classes with NO inheritance relationship
// (so #890 cannot interfere — there is no method call in sight) each
// declaring their own getter/setter pair under the SAME property name. The
// accessor dispatcher generated for that name must carry a branch per class
// and pick the right one by the receiver's own runtime type, never the
// first (or only) branch regardless of receiver.
func TestMultipleClassesShareAPropertyNameDispatchIndependently(t *testing.T) {
	prog, err := compiler.LoadProgramJSON([]byte(`{
  "modules": [
    {
      "name": "std",
      "functions": [{"name": "assign", "isBase": true}, {"name": "multiply", "isBase": true}, {"name": "print", "isBase": true}],
      "typeDefs": [
        {"name": "PrintInput", "descriptor": {"name": "PrintInput", "field": [{"name": "message", "number": 1, "label": "LABEL_OPTIONAL", "type": "TYPE_STRING"}]}},
        {"name": "BinaryInput", "descriptor": {"name": "BinaryInput", "field": [{"name": "left", "number": 1, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64"}, {"name": "right", "number": 2, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64"}]}}
      ]
    },
    {
      "name": "main",
      "typeDefs": [
        {"name": "main:Celsius", "metadata": {"kind": "class", "fields": [{"name": "_c", "type": "int", "initializer": "1"}]}, "descriptor": {"name": "main:Celsius", "field": [{"name": "_c", "number": 1, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64"}]}},
        {"name": "main:Kelvin", "metadata": {"kind": "class", "fields": [{"name": "_k", "type": "int", "initializer": "2"}]}, "descriptor": {"name": "main:Kelvin", "field": [{"name": "_k", "number": 1, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64"}]}}
      ],
      "functions": [
        {"name": "main:Celsius.temp", "outputType": "int", "body": {"reference": {"name": "_c"}}, "metadata": {"kind": "method", "is_getter": true, "expression_body": true}},
        {"name": "main:Celsius.temp", "inputType": "int", "body": {"call": {"module": "std", "function": "assign", "input": {"messageCreation": {"typeName": "", "fields": [
          {"name": "target", "value": {"reference": {"name": "_c"}}},
          {"name": "value", "value": {"call": {"module": "std", "function": "multiply", "input": {"messageCreation": {"typeName": "", "fields": [
            {"name": "left", "value": {"reference": {"name": "value"}}}, {"name": "right", "value": {"literal": {"intValue": "10"}}}
          ]}}}}}
        ]}}}}, "metadata": {"kind": "method", "is_setter": true, "params": [{"name": "value", "type": "int"}]}},
        {"name": "main:Kelvin.temp", "outputType": "int", "body": {"reference": {"name": "_k"}}, "metadata": {"kind": "method", "is_getter": true, "expression_body": true}},
        {"name": "main:Kelvin.temp", "inputType": "int", "body": {"call": {"module": "std", "function": "assign", "input": {"messageCreation": {"typeName": "", "fields": [
          {"name": "target", "value": {"reference": {"name": "_k"}}},
          {"name": "value", "value": {"call": {"module": "std", "function": "multiply", "input": {"messageCreation": {"typeName": "", "fields": [
            {"name": "left", "value": {"reference": {"name": "value"}}}, {"name": "right", "value": {"literal": {"intValue": "100"}}}
          ]}}}}}
        ]}}}}, "metadata": {"kind": "method", "is_setter": true, "params": [{"name": "value", "type": "int"}]}},
        {"name": "main", "outputType": "void", "metadata": {"kind": "function"}, "body": {"block": {"statements": [
          {"let": {"name": "c", "value": {"messageCreation": {"typeName": "main:Celsius"}}}},
          {"let": {"name": "k", "value": {"messageCreation": {"typeName": "main:Kelvin"}}}},
          {"expression": {"call": {"module": "std", "function": "print", "input": {"messageCreation": {"typeName": "PrintInput", "fields": [{"name": "message", "value": {"fieldAccess": {"object": {"reference": {"name": "c"}}, "field": "temp"}}}]}}}}},
          {"expression": {"call": {"module": "std", "function": "print", "input": {"messageCreation": {"typeName": "PrintInput", "fields": [{"name": "message", "value": {"fieldAccess": {"object": {"reference": {"name": "k"}}, "field": "temp"}}}]}}}}},
          {"expression": {"call": {"module": "std", "function": "assign", "input": {"messageCreation": {"typeName": "", "fields": [{"name": "target", "value": {"fieldAccess": {"object": {"reference": {"name": "c"}}, "field": "temp"}}}, {"name": "value", "value": {"literal": {"intValue": "5"}}}]}}}}},
          {"expression": {"call": {"module": "std", "function": "assign", "input": {"messageCreation": {"typeName": "", "fields": [{"name": "target", "value": {"fieldAccess": {"object": {"reference": {"name": "k"}}, "field": "temp"}}}, {"name": "value", "value": {"literal": {"intValue": "9"}}}]}}}}},
          {"expression": {"call": {"module": "std", "function": "print", "input": {"messageCreation": {"typeName": "PrintInput", "fields": [{"name": "message", "value": {"fieldAccess": {"object": {"reference": {"name": "c"}}, "field": "temp"}}}]}}}}},
          {"expression": {"call": {"module": "std", "function": "print", "input": {"messageCreation": {"typeName": "PrintInput", "fields": [{"name": "message", "value": {"fieldAccess": {"object": {"reference": {"name": "k"}}, "field": "temp"}}}]}}}}}
        ]}}}
      ]
    }
  ],
  "entryModule": "main",
  "entryFunction": "main"
}`))
	if err != nil {
		t.Fatalf("decode probe program: %v", err)
	}
	src := compileFmt(t, prog)
	got := goRun(t, src)
	want := "1\n2\n50\n900\n"
	if got != want {
		t.Errorf("got %q, want %q\n---\n%s", got, want, src)
	}
}
