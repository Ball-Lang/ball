using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// Typed <c>on &lt;Type&gt; catch</c> clause SELECTION (issue #615).
///
/// <para><b>The bug this file was written against.</b>
/// <c>BaseCall.cs</c>'s <c>CompileTryStatement</c> read <c>catches[0]</c> and
/// emitted it as an unconditional <c>catch (BallThrow __ballEx)</c>, dropping
/// every later clause and ignoring each clause's <c>type</c> field entirely. So
/// <c>throw StateError('boom')</c> ran an <c>on ArgumentError catch</c> body —
/// silently wrong output, never an error — and a <c>try</c> whose clauses ALL
/// miss swallowed the exception instead of propagating it to an enclosing
/// <c>try</c>. Its own doc comment recorded the gap
/// ("Dispatches only the first catch clause"), which is how #615 was filed: off
/// the prose, not off any CI signal.</para>
///
/// <para><b>Why nothing caught it.</b> The corpus fixture that exercises the
/// shape (<c>146_nested_try_catch_types</c>) is only compiled through this
/// compiler by <c>engine/conformance --leg=compiler</c>, the
/// <c>csharp-compiler</c> row in <c>conformance-matrix.yml</c>. That row is a PR
/// gate since #619 — but it is a <b>ratchet</b> on a passing count
/// (<c>CSHARP_COMPILER_FLOOR</c>), and 146 had been failing on it, inside the
/// floor and therefore green, for as long as the leg has existed. A ratchet
/// cannot name the fixture that is failing; these tests fail for THIS
/// shape.</para>
///
/// <para>These tests compile and RUN: a shape assertion alone could not tell
/// "selects the right clause" from "runs the first clause, which happens to
/// print the same thing".</para>
/// </summary>
public class CatchClauseDispatchTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    /// <summary><c>throw &lt;typeName&gt;(message)</c> — the shape the Dart encoder emits.</summary>
    private static Expression Throw(string typeName, string message) =>
        Call("std", "throw", Msg(("value", new Expression
        {
            MessageCreation = new MessageCreation
            {
                TypeName = "main:" + typeName,
                Fields = { new FieldValuePair { Name = "arg0", Value = Str(message) } },
            },
        })));

    private static Expression Clause(string? type, Expression body)
    {
        var fields = new List<(string, Expression)>();
        if (type is not null)
        {
            fields.Add(("type", Str(type)));
        }

        fields.Add(("variable", Str("e")));
        fields.Add(("body", body));
        return Msg([.. fields]);
    }

    private static Expression Try(Expression body, params Expression[] catches) =>
        Call("std", "try", Msg(("body", body), ("catches", ListLit(catches))));

    [Fact]
    public void OnlyTheMatchingTypedClauseRuns()
    {
        var output = Run(Program(Block([Expr(Try(
            Throw("StateError", "boom"),
            Clause("ArgumentError", Print(Str("wrong"))),
            Clause("StateError", Print(Str("right"))),
            Clause(null, Print(Str("fallback")))))])));

        Assert.Equal("right\n", output);
    }

    [Fact]
    public void NoTypedClauseMatches_TheUntypedFallbackRuns()
    {
        var output = Run(Program(Block([Expr(Try(
            Throw("ArgumentError", "nope"),
            Clause("FormatException", Print(Str("wrong: format"))),
            Clause("StateError", Print(Str("wrong: state"))),
            Clause(null, Print(Str("fallback")))))])));

        Assert.Equal("fallback\n", output);
    }

    [Fact]
    public void NoClauseMatchesAndNoUntypedClause_PropagatesToTheOuterTry()
    {
        // A first-clause-always compiler runs the inner ArgumentError body here.
        var output = Run(Program(Block([Expr(Try(
            Try(
                Throw("StateError", "inner"),
                Clause("ArgumentError", Print(Str("wrong: inner clause ran")))),
            Clause("StateError", Print(Str("right: outer caught it")))))])));

        Assert.Equal("right: outer caught it\n", output);
    }

    [Fact]
    public void TheBoundVariableReadsMessageFromThePositionalConstructorArgument()
    {
        // The encoder stores `StateError('boom')`'s argument as `arg0`; Dart
        // source reads it back as `e.message`. std.throw renames it (the
        // reference engine's engine_std.dart does exactly this), so a compiled
        // `e.message` is 'boom' rather than null.
        var output = Run(Program(Block([Expr(Try(
            Throw("StateError", "boom"),
            Clause("StateError", Print(new Expression
            {
                FieldAccess = new FieldAccess { Object = Ref("e"), Field = "message" },
            }))))])));

        Assert.Equal("boom\n", output);
    }

    [Fact]
    public void EveryClauseIsEmittedWithItsOwnTypeGuard()
    {
        var source = CSharpCompiler.Compile(Program(Block([Expr(Try(
            Throw("StateError", "boom"),
            Clause("ArgumentError", Print(Str("wrong"))),
            Clause("StateError", Print(Str("right")))))])));

        Assert.Contains("BallRuntime.CatchMatches(__ballEx, \"ArgumentError\")", source, StringComparison.Ordinal);
        Assert.Contains("BallRuntime.CatchMatches(__ballEx, \"StateError\")", source, StringComparison.Ordinal);
        // No untyped clause: an unmatched throw must re-raise, not be swallowed.
        Assert.Contains("throw;", source, StringComparison.Ordinal);
    }
}
