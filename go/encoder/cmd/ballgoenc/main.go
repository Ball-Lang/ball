// Command ballgoenc encodes a Go source file into a Ball program (.ball.json).
//
// Usage:
//
//	ballgoenc <input.go> [-o output.ball.json]
//
// This is the Phase-3 encoder front-end (Go → Ball), the inverse of ballgoc
// (Ball → Go). The full `ball` CLI (run/compile/encode/check) is a later phase;
// this thin command exists so the encoder can be exercised from the shell and by
// tooling. Its output round-trips back through ballgoc.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/ball-lang/ball/go/encoder"
	"google.golang.org/protobuf/encoding/protojson"
)

func main() {
	out := flag.String("o", "", "output .ball.json file (default: stdout)")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: ballgoenc <input.go> [-o output.ball.json]")
		os.Exit(2)
	}

	src, err := os.ReadFile(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		os.Exit(3)
	}

	prog, err := encoder.Encode(string(src))
	if err != nil {
		fmt.Fprintln(os.Stderr, "encode:", err)
		os.Exit(2)
	}

	body, err := protojson.MarshalOptions{Indent: "  "}.Marshal(prog)
	if err != nil {
		fmt.Fprintln(os.Stderr, "marshal:", err)
		os.Exit(3)
	}
	// Wrap in the google.protobuf.Any envelope the committed .ball.json fixtures
	// use (a leading "@type" alongside the program fields), so the output is a
	// drop-in .ball.json every loader accepts.
	body = withTypeEnvelope(body)

	if *out == "" {
		os.Stdout.Write(body)
		fmt.Println()
		return
	}
	if err := os.WriteFile(*out, body, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		os.Exit(3)
	}
}

// withTypeEnvelope prepends the "@type" discriminator to a protojson-encoded
// Program object. Loaders (the Go compiler's LoadProgramJSON, the Dart/TS
// unwrapBallFile) strip it before decoding.
func withTypeEnvelope(body []byte) []byte {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return body // already valid JSON without an envelope; return as-is
	}
	ordered := map[string]json.RawMessage{"@type": json.RawMessage(`"type.googleapis.com/ball.v1.Program"`)}
	for k, v := range fields {
		ordered[k] = v
	}
	out, err := json.MarshalIndent(ordered, "", "  ")
	if err != nil {
		return body
	}
	return out
}
