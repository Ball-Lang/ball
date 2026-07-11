using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// Lazy-evaluation regression tests (issue #381, invariant #4): control flow
/// must NOT eagerly evaluate every branch/operand. Each program puts a
/// side effect (a <c>print</c>) or an <em>observable fault</em> (an integer
/// divide-by-zero) in the branch/operand that must NOT run — so if the
/// compiler ever regressed to eager evaluation, the test would see the extra
/// output or the thrown exception.
/// </summary>
public class LazyControlFlowTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    [Fact]
    public void If_RunsOnlyTheTakenBranch_BothBranchesSideEffecting()
    {
        // if (1 > 0) print("taken") else print("untaken")
        // Both arms print; only "taken" must appear.
        var program = Program(Block(new[]
        {
            Expr(Call("std", "if", Msg(
                ("condition", Bin("greater_than", Int(1), Int(0))),
                ("then", Print(Str("taken"))),
                ("else", Print(Str("untaken")))))),
        }));

        Assert.Equal("taken\n", Run(program));
    }

    [Fact]
    public void If_UntakenBranchCodeNeverRuns_NoDivideByZero()
    {
        // if (1 > 0) print("safe") else print( (1 ~/ 0) )
        // The untaken else divides by zero; a lazy `if` never evaluates it, so
        // no exception is thrown and only "safe" prints.
        var program = Program(Block(new[]
        {
            Expr(Call("std", "if", Msg(
                ("condition", Bin("greater_than", Int(1), Int(0))),
                ("then", Print(Str("safe"))),
                ("else", Print(Bin("divide", Int(1), Int(0))))))),
        }));

        Assert.Equal("safe\n", Run(program));
    }

    [Fact]
    public void And_ShortCircuits_RightOperandNeverEvaluated()
    {
        // and(false, (1 ~/ 0) > 0)  →  false, and the divide-by-zero right
        // operand is never reached (native &&).
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std", "and", Msg(
                ("left", Bin("less_than", Int(1), Int(0))),
                ("right", Bin("greater_than", Bin("divide", Int(1), Int(0)), Int(0))))))),
        }));

        Assert.Equal("false\n", Run(program));
    }

    [Fact]
    public void Or_ShortCircuits_RightOperandNeverEvaluated()
    {
        // or(true, (1 ~/ 0) > 0)  →  true, right operand never reached.
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std", "or", Msg(
                ("left", Bin("greater_than", Int(1), Int(0))),
                ("right", Bin("greater_than", Bin("divide", Int(1), Int(0)), Int(0))))))),
        }));

        Assert.Equal("true\n", Run(program));
    }

    [Fact]
    public void NullCoalesce_RightOperandEvaluatedOnlyWhenLeftIsNull()
    {
        // (5 ?? (1 ~/ 0))  →  5, and the divide-by-zero right side never runs.
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std", "null_coalesce", Msg(
                ("left", Int(5)),
                ("right", Bin("divide", Int(1), Int(0))))))),
        }));

        Assert.Equal("5\n", Run(program));
    }
}
