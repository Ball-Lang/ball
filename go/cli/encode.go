package cli

import (
	"flag"
	"io"
	"os"

	encoder "github.com/ball-lang/ball/go/encoder"
)

// cmdEncode implements `ball encode <source.go> [-lib] [-o out] [-format
// json|binary]`: read a Go source file, encode it into a ball.v1.Program via
// go/encoder, and write it to -o or stdout in the chosen format (JSON is the
// default, @type-enveloped; binary is the Any-wrapped canonical form).
//
// Without -lib the source must declare a `func main()` entry point. With -lib
// (issue #537) it need not: the file is encoded through encoder.EncodeLibrary,
// which produces a Program with an empty entry_function that `ball check`
// deliberately rejects as non-runnable. The flag is single-dash `-lib` because
// Go's flag package is single-dash and this CLI already uses -o/-format; the
// Rust CLI spells the same thing `--lib` and the C# CLI `--library` (see
// go/cli/AGENTS.md).
//
// The encoder fails loud: source it cannot represent (an unsupported construct
// outside its documented scope — see go/encoder/AGENTS.md) is returned as an
// error, surfaced here as a parseErr (exit 2), never a placeholder program.
func cmdEncode(args []string, w io.Writer) *cliError {
	const usage = "ball encode <source.go> [-lib] [-o out] [-format json|binary]"
	fs := flag.NewFlagSet("encode", flag.ContinueOnError)
	out := fs.String("o", "", "write the encoded program here instead of stdout")
	format := fs.String("format", "json", "output format: json | binary")
	lib := fs.Bool("lib", false,
		"encode a library file (no func main() required); the result has an empty entry_function and `ball check` rejects it as non-runnable")
	positionals, cerr := parseCommand(fs, "encode", usage, args)
	if cerr != nil {
		return cerr
	}
	if len(positionals) != 1 {
		return parseErr("encode: expected exactly one Go source path (usage: %s)", usage)
	}
	if *format != "json" && *format != "binary" {
		return parseErr("encode: unknown -format %q (want json or binary)", *format)
	}

	source, err := os.ReadFile(positionals[0])
	if err != nil {
		return ioErr("could not read %s: %v", positionals[0], err)
	}

	encode := encoder.Encode
	if *lib {
		encode = encoder.EncodeLibrary
	}
	prog, encErr := encode(string(source))
	if encErr != nil {
		return parseErr("encode: %v", encErr)
	}

	switch *format {
	case "binary":
		data, serr := programToBinary(prog)
		if serr != nil {
			return serr
		}
		return writeOut(w, *out, data)
	default:
		data, serr := programToJSON(prog)
		if serr != nil {
			return serr
		}
		return writeOut(w, *out, data)
	}
}
