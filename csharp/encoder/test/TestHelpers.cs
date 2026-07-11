using System.Linq;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>Shared helpers for driving <see cref="CSharpEncoder.Encode"/> through its public
/// API and drilling into the resulting <see cref="Program"/> tree for structural assertions.
/// Every test wraps a snippet in a real, parseable C# source (usually top-level statements),
/// since <see cref="CSharpEncoder.Encode"/> always requires a genuine <c>Main</c> entry point —
/// this exercises the encoder exactly the way a real caller would, rather than reaching for
/// internal-only entry points.</summary>
internal static class TestHelpers
{
    internal static Program EncodeProgram(string source) => CSharpEncoder.Encode(source);

    internal static Module MainModule(Program program) => program.Modules.Single(m => m.Name == "main");

    internal static FunctionDefinition MainFunction(Program program) =>
        MainModule(program).Functions.Single(f => f.Name == "Main");

    /// <summary>Encode top-level-statement <paramref name="source"/> and return the whole
    /// <c>Main</c> function's body statements.</summary>
    internal static Google.Protobuf.Collections.RepeatedField<Statement> MainStatements(string source) =>
        MainFunction(EncodeProgram(source)).Body.Block.Statements;

    /// <summary>Encode top-level-statement <paramref name="source"/> and return the value
    /// expression of the <paramref name="index"/>'th statement, unwrapping whichever of
    /// <c>Let</c>/<c>Expression</c> that statement is.</summary>
    internal static Expression NthValueExpr(string source, int index)
    {
        var stmt = MainStatements(source)[index];
        return stmt.StmtCase == Statement.StmtOneofCase.Let ? stmt.Let.Value : stmt.Expression;
    }
}
