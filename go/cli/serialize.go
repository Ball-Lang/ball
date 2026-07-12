package cli

import (
	"encoding/json"

	ballv1 "github.com/ball-lang/ball/go/shared/gen/ball/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// programToJSON renders an encoded ball.v1.Program to pretty-printed proto3
// JSON, wrapped in the cosmetic "@type" google.protobuf.Any envelope every Ball
// pipeline's .ball.json carries. Mirrors go/encoder/cmd/ballgoenc so `ball
// encode`'s JSON output is a drop-in .ball.json any loader accepts.
func programToJSON(prog *ballv1.Program) ([]byte, *cliError) {
	body, err := protojson.MarshalOptions{Indent: "  "}.Marshal(prog)
	if err != nil {
		return nil, runtimeErr("failed to serialize proto3-JSON: %v", err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return nil, runtimeErr("failed to reparse proto3-JSON: %v", err)
	}
	enveloped := map[string]json.RawMessage{
		"@type": json.RawMessage(`"type.googleapis.com/ball.v1.Program"`),
	}
	for k, v := range fields {
		enveloped[k] = v
	}
	out, err := json.MarshalIndent(enveloped, "", "  ")
	if err != nil {
		return nil, runtimeErr("failed to format JSON: %v", err)
	}
	return append(out, '\n'), nil
}

// programToBinary marshals an encoded ball.v1.Program to the Any-wrapped binary
// form the Go pipeline treats as its canonical .ball.bin/.ball.pb (see
// go/engine's FromBinary, which prefers the Any-wrapped shape). decodeBinaryProgram
// reads it back through the same Any-first path.
func programToBinary(prog *ballv1.Program) ([]byte, *cliError) {
	envelope, err := anypb.New(prog)
	if err != nil {
		return nil, runtimeErr("failed to build Any envelope: %v", err)
	}
	data, err := proto.Marshal(envelope)
	if err != nil {
		return nil, runtimeErr("failed to serialize binary protobuf: %v", err)
	}
	return data, nil
}
