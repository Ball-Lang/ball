// Fixture project, file 1 of 3 (issue #492, W12-C slice 1).
//
// The callee `program.cs` calls across a file boundary. A syntax-only
// `CSharpEncoder.Encode` rebuilds its symbol table from ONE file, so this
// declaration is invisible to the caller's encode — taxonomy bucket (d).
// `EncodeProject` builds one Roslyn `CSharpCompilation` over the whole
// directory, so `GetSymbolInfo` at the call site returns this very method,
// carrying its declaring file, its static-ness, and its real parameter name
// (`value` — not a positional `arg0` fallback).
namespace Demo;

public static class MathHelper
{
    public static int Square(int value)
    {
        return value * value;
    }

    // Two parameters on purpose: a 2+-argument call packs its input as a
    // `MessageCreation` keyed by the CALLEE's declared parameter names, and the
    // positional `arg0`/`arg1` fallback is what a call with no resolvable callee
    // falls back to. `IMethodSymbol.Parameters` is where the real names come from.
    public static int Scale(int value, int factor)
    {
        return value * factor;
    }
}
