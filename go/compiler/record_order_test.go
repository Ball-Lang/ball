package compiler_test

import (
	"strings"
	"testing"

	"github.com/ball-lang/ball/go/compiler"
)

// A record whose field names are deliberately NOT in alphabetical, reverse
// alphabetical, or length order, so no accidental ordering can look like source
// order. Four fields means Go's randomized map iteration reproduces the declared
// order with probability 1/24 per compile.
const recordOrderProgram = `{
  "name": "record_order",
  "version": "1.0.0",
  "entryModule": "main",
  "entryFunction": "main",
  "modules": [
    {
      "name": "std",
      "functions": [
        {"name": "record", "isBase": true},
        {"name": "print", "isBase": true}
      ]
    },
    {
      "name": "main",
      "functions": [
        {
          "name": "main",
          "body": {
            "call": {
              "module": "std",
              "function": "print",
              "input": {
                "messageCreation": {
                  "fields": [
                    {
                      "name": "message",
                      "value": {
                        "call": {
                          "module": "std",
                          "function": "record",
                          "input": {
                            "messageCreation": {
                              "fields": [
                                {"name": "zeta",  "value": {"literal": {"intValue": "1"}}},
                                {"name": "alpha", "value": {"literal": {"intValue": "2"}}},
                                {"name": "mid",   "value": {"literal": {"intValue": "3"}}},
                                {"name": "beta",  "value": {"literal": {"intValue": "4"}}}
                              ]
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            }
          }
        }
      ]
    }
  ]
}`

// declaredOrder is the order recordOrderProgram writes the record's fields in.
var declaredOrder = []string{"zeta", "alpha", "mid", "beta"}

// setKeys extracts the keys of the emitted `__r.Set("<key>", …)` lines, in
// emission order.
func setKeys(src string) []string {
	var keys []string
	for _, line := range strings.Split(src, "\n") {
		line = strings.TrimSpace(line)
		const prefix = `__r.Set("`
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		rest := line[len(prefix):]
		if i := strings.Index(rest, `"`); i >= 0 {
			keys = append(keys, rest[:i])
		}
	}
	return keys
}

// A record's fields must be emitted in the encoder's SOURCE order, not in Go map
// order — the order dart/compiler's _compileRecord and rust/compiler's
// compile_record preserve, and the order the insertion-ordered ballrt.Map then
// reports when the record is iterated or printed.
//
// Two things rode on this (issue #586): the compiled output is a COMMITTED
// artifact that ci.yml's `Ball Artifact Freshness` job regenerates and diffs, so
// it has to be byte-stable; and the record's runtime field order is observable
// (printing a record, destructuring a positional one — 207_record_pattern_
// destructure's `(10, 20)` came out `20,10` whenever Go happened to iterate
// `$2` first).
func TestRecordFieldsCompileInSourceOrder(t *testing.T) {
	prog, err := compiler.LoadProgramJSON([]byte(recordOrderProgram))
	if err != nil {
		t.Fatalf("load program: %v", err)
	}

	first := ""
	for i := 0; i < 20; i++ {
		src, cerr := compiler.Compile(prog)
		if cerr != nil {
			t.Fatalf("compile (iteration %d): %v", i, cerr)
		}

		keys := setKeys(src)
		if len(keys) != len(declaredOrder) {
			t.Fatalf("iteration %d emitted %d record fields (%v), want %d",
				i, len(keys), keys, len(declaredOrder))
		}
		for j, want := range declaredOrder {
			if keys[j] != want {
				t.Fatalf("iteration %d: record field %d is %q, want %q (emitted order %v, declared %v)",
					i, j, keys[j], want, keys, declaredOrder)
			}
		}

		// Reproducibility: the whole emitted program, not just the record, must
		// be byte-identical across compiles of the same input.
		if i == 0 {
			first = src
		} else if src != first {
			t.Fatalf("iteration %d produced different output than iteration 0 — "+
				"the Ball → Go compiler is not deterministic", i)
		}
	}
	if first == "" {
		t.Fatal("no compilation ran")
	}
}

// The end-to-end half: the compiled program prints the record, and the printed
// field order is the source order. A structural assertion alone could not see a
// runtime map that reordered the fields after construction.
func TestRecordPrintsFieldsInSourceOrder(t *testing.T) {
	prog, err := compiler.LoadProgramJSON([]byte(recordOrderProgram))
	if err != nil {
		t.Fatalf("load program: %v", err)
	}
	out := goRun(t, compileFmt(t, prog))

	// Every declared name must appear, in the declared order.
	pos := -1
	for _, name := range declaredOrder {
		i := strings.Index(out, name)
		if i < 0 {
			t.Fatalf("printed record %q does not mention field %q", strings.TrimSpace(out), name)
		}
		if i <= pos {
			t.Fatalf("printed record %q does not list fields in source order %v",
				strings.TrimSpace(out), declaredOrder)
		}
		pos = i
	}
}
