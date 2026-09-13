using Ball.Shared;
using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// <c>std_collections.list_find</c>'s no-match contract (issue #597).
///
/// <para><b>The bug this file was written against.</b> <c>BaseCall.cs</c>'s
/// <c>CompileCollectionsCall</c> had NO <c>list_find</c> case at all, so it fell
/// through to <c>_ =&gt; Unsupported(call)</c> — which does not refuse at compile
/// time, it EMITS a call to <c>BallRuntime.UnsupportedBaseCall(...)</c>. The
/// program therefore compiled clean (exit 0) and then died at RUN time with an
/// unhandled native <c>BallRuntimeException</c>. Worse than a wrong answer: a
/// <c>BallRuntimeException</c> is not a <see cref="BallThrow"/>, and the compiled
/// <c>try</c> only catches <c>BallThrow</c>, so the exception sailed straight
/// past the program's OWN <c>on StateError catch</c> and killed the process.
/// This is the target the C# ENCODER already emits for — <c>Methods.cs</c> routes
/// <c>.First(pred)</c> to <c>list_find</c>, and real LINQ <c>First</c> throws
/// <c>InvalidOperationException</c> on no match.</para>
///
/// <para><b>Why nothing caught it.</b> The corpus had no fixture that observed
/// <c>list_find</c>'s NO-MATCH branch at all (the Dart encoder cannot emit the
/// call from any Dart source, so <c>generate_conformance</c> could never reach
/// it and <c>check_encoder_completeness</c> had nothing to flag), and the #545
/// declared-outputType gate checks a base function's return TYPE on a HIT, never
/// what it does when it finds nothing.</para>
///
/// <para>These tests compile and RUN, rather than asserting on emitted source
/// shape alone: a shape assertion would not have distinguished "throws
/// StateError" from "throws something uncatchable".</para>
/// </summary>
public class ListFindContractTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    /// <summary><c>list_find([1,2,3], (input) =&gt; input &gt; threshold)</c>.</summary>
    private static Expression Find(long threshold) =>
        Call("std_collections", "list_find", Msg(
            ("list", ListLit(Int(1), Int(2), Int(3))),
            ("callback", Lambda(Bin("greater_than", Ref("input"), Int(threshold))))));

    [Fact]
    public void ListFind_IsCompiled_NotLeftAsAnUnsupportedRuntimeThrow()
    {
        var source = CSharpCompiler.Compile(Program(Block(new[] { Expr(Print(Find(2))) })));

        Assert.Contains("BallRuntime.ListFind(", source, StringComparison.Ordinal);
        Assert.DoesNotContain("UnsupportedBaseCall(\"std_collections\", \"list_find\")", source, StringComparison.Ordinal);
    }

    [Fact]
    public void AHit_ReturnsTheMatchingElement()
    {
        Assert.Equal("3\n", Run(Program(Block(new[] { Expr(Print(Find(2))) }))));
    }

    [Fact]
    public void AMiss_ThrowsATypedStateError_NotANativeRuntimeFault()
    {
        var program = Program(Block(new[] { Expr(Print(Find(100))) }));

        var ex = Assert.Throws<BallThrow>(() => Run(program));
        Assert.Equal("StateError", ex.TypeName);
        Assert.Equal("No element", ex.Message);
    }

    [Fact]
    public void AMiss_IsCaughtByTheProgramsOwnTry()
    {
        // The whole point of throwing a BallThrow rather than a
        // BallRuntimeException: the compiled `catch (BallThrow …)` must see it,
        // so the source program's own handler runs instead of the process dying.
        var output = Run(Program(Block(new[]
        {
            Expr(Call("std", "try", Msg(
                ("body", Print(Find(100))),
                ("catches", ListLit(Msg(
                    ("type", Str("StateError")),
                    ("variable", Str("e")),
                    ("body", Print(Str("caught StateError"))))))))),
        })));

        Assert.Equal("caught StateError\n", output);
    }

    [Fact]
    public void AnEmptyList_ThrowsToo()
    {
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_find", Msg(
                ("list", ListLit()),
                ("callback", Lambda(Bin("greater_than", Ref("input"), Int(0)))))))),
        }));

        var ex = Assert.Throws<BallThrow>(() => Run(program));
        Assert.Equal("StateError", ex.TypeName);
    }
}
