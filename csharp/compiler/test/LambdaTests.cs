using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// Lambdas + closures (issue #381 acceptance): an anonymous function is a
/// first-class <see cref="Ball.Shared.BallFunction"/> value, invoked through
/// <see cref="Ball.Shared.BallRuntime.CallFunction"/>; a lambda that references
/// an enclosing local captures it (C# closures capture by reference, giving
/// Ball's shared-capture semantics for free).
/// </summary>
public class LambdaTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    [Fact]
    public void Lambda_StoredAndCalled()
    {
        // var f = (input) => input + 1;  print(f(41));
        var program = Program(Block(new[]
        {
            Let("f", Lambda(Bin("add", Ref("input"), Int(1)))),
            Expr(Print(Call("main", "f", Int(41)))),
        }));

        Assert.Equal("42\n", Run(program));
    }

    [Fact]
    public void Closure_CapturesEnclosingLocal()
    {
        // var offset = 100;  var addOffset = (input) => input + offset;  print(addOffset(5));
        var program = Program(Block(new[]
        {
            Let("offset", Int(100)),
            Let("addOffset", Lambda(Bin("add", Ref("input"), Ref("offset")))),
            Expr(Print(Call("main", "addOffset", Int(5)))),
        }));

        Assert.Equal("105\n", Run(program));
    }

    [Fact]
    public void Closure_ObservesLaterMutationOfCapturedLocal()
    {
        // C# closures capture by reference, so a lambda built before the
        // captured variable is reassigned sees the new value at call time —
        // the shared-capture semantics the self-hosted engine relies on.
        var program = Program(Block(new[]
        {
            Let("counter", Int(1)),
            Let("read", Lambda(Ref("counter"))),
            Expr(Call("std", "assign", Msg(("target", Ref("counter")), ("value", Int(9))))),
            Expr(Print(Call("main", "read", Int(0)))),
        }));

        Assert.Equal("9\n", Run(program));
    }
}
