package compiler

import (
	"encoding/json"
	"fmt"
	"os"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

// LoadProgramJSON decodes a Ball program from its proto3-JSON form (a
// `.ball.json` file's bytes).
//
// The committed `.ball.json` fixtures wrap the program in a
// `google.protobuf.Any` envelope — a top-level `"@type":
// "type.googleapis.com/ball.v1.Program"` key alongside the program fields. That
// key is not part of the `Program` message, so it is stripped before decoding
// (mirroring the TS/Dart pipelines' `unwrapBallFile`). protojson is configured
// to ignore any other unknown fields for forward compatibility.
func LoadProgramJSON(data []byte) (*ballv1.Program, error) {
	// Strip the Any-envelope "@type" discriminator if present.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parse ball json: %w", err)
	}
	delete(raw, "@type")
	stripped, err := json.Marshal(raw)
	if err != nil {
		return nil, fmt.Errorf("re-marshal ball json: %w", err)
	}

	prog := &ballv1.Program{}
	opts := protojson.UnmarshalOptions{DiscardUnknown: true}
	if err := opts.Unmarshal(stripped, prog); err != nil {
		return nil, fmt.Errorf("decode ball program: %w", err)
	}
	return prog, nil
}

// LoadProgramFile reads and decodes a `.ball.json` file.
func LoadProgramFile(path string) (*ballv1.Program, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return LoadProgramJSON(data)
}

// LoadProgramBinary decodes a Ball program from binary protobuf wire bytes
// (a `.ball.bin` / `.ball.pb` file).
func LoadProgramBinary(data []byte) (*ballv1.Program, error) {
	prog := &ballv1.Program{}
	if err := proto.Unmarshal(data, prog); err != nil {
		return nil, fmt.Errorf("decode ball program (binary): %w", err)
	}
	return prog, nil
}
