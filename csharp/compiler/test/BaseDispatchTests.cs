using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// Coverage of the base-function dispatch categories the Phase-4 acceptance
/// criteria enumerate (issue #381): arithmetic, comparison, logic, print,
/// <c>if</c>, <c>for</c>, <c>while</c>, <c>for_each</c>, assign, index, try,
/// return, break, continue, throw — each exercised by a compiled-and-run
/// program asserting on real stdout.
/// </summary>
public class BaseDispatchTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    private static string RunMain(params Statement[] statements) =>
        Run(Program(Block(statements)));

    [Fact]
    public void Arithmetic_IntAndDouble()
    {
        var output = RunMain(
            Expr(Print(Bin("add", Int(2), Int(3)))),
            Expr(Print(Bin("subtract", Int(10), Int(4)))),
            Expr(Print(Bin("multiply", Int(6), Int(7)))),
            Expr(Print(Bin("divide", Int(17), Int(5)))),
            Expr(Print(Bin("modulo", Int(17), Int(5)))),
            Expr(Print(Bin("divide_double", Int(3), Int(2)))));

        Assert.Equal("5\n6\n42\n3\n2\n1.5\n", output);
    }

    [Fact]
    public void Comparison()
    {
        var output = RunMain(
            Expr(Print(Bin("less_than", Int(1), Int(2)))),
            Expr(Print(Bin("greater_than", Int(1), Int(2)))),
            Expr(Print(Bin("equals", Int(2), Int(2)))),
            Expr(Print(Bin("lte", Int(2), Int(2)))),
            Expr(Print(Bin("not_equals", Int(2), Int(3)))));

        Assert.Equal("true\nfalse\ntrue\ntrue\ntrue\n", output);
    }

    [Fact]
    public void Logic_Not_And_Or()
    {
        var output = RunMain(
            Expr(Print(Call("std", "not", Msg(("value", Bool(false)))))),
            Expr(Print(Call("std", "and", Msg(("left", Bool(true)), ("right", Bool(true)))))),
            Expr(Print(Call("std", "or", Msg(("left", Bool(false)), ("right", Bool(true)))))));

        Assert.Equal("true\ntrue\ntrue\n", output);
    }

    [Fact]
    public void If_Else_Statement()
    {
        var output = RunMain(
            Expr(Call("std", "if", Msg(
                ("condition", Bin("greater_than", Int(5), Int(3))),
                ("then", Print(Str("bigger"))),
                ("else", Print(Str("smaller")))))));

        Assert.Equal("bigger\n", output);
    }

    [Fact]
    public void For_Loop_CStyle()
    {
        // for (i = 0; i < 3; i++) print(i)
        var output = RunMain(
            Expr(Call("std", "for", Msg(
                ("init", Block(new[] { Let("i", Int(0)) })),
                ("condition", Bin("less_than", Ref("i"), Int(3))),
                ("update", Call("std", "post_increment", Msg(("value", Ref("i"))))),
                ("body", Print(Ref("i")))))));

        Assert.Equal("0\n1\n2\n", output);
    }

    [Fact]
    public void While_Loop_WithAssign()
    {
        // x = 0; while (x < 3) { print(x); x += 1; }
        var output = RunMain(
            Let("x", Int(0)),
            Expr(Call("std", "while", Msg(
                ("condition", Bin("less_than", Ref("x"), Int(3))),
                ("body", Block(new[]
                {
                    Expr(Print(Ref("x"))),
                    Expr(Call("std", "assign", Msg(
                        ("target", Ref("x")),
                        ("value", Int(1)),
                        ("op", Str("+="))))),
                }))))));

        Assert.Equal("0\n1\n2\n", output);
    }

    [Fact]
    public void ForEach_ForIn_OverList()
    {
        // for (e in [10, 20, 30]) print(e)
        var output = RunMain(
            Expr(Call("std", "for_in", Msg(
                ("variable", Str("e")),
                ("iterable", ListLit(Int(10), Int(20), Int(30))),
                ("body", Print(Ref("e")))))));

        Assert.Equal("10\n20\n30\n", output);
    }

    [Fact]
    public void Assign_SimpleAndCompound()
    {
        var output = RunMain(
            Let("x", Int(10)),
            Expr(Call("std", "assign", Msg(("target", Ref("x")), ("value", Int(42))))),
            Expr(Print(Ref("x"))),
            Expr(Call("std", "assign", Msg(("target", Ref("x")), ("value", Int(8)), ("op", Str("-="))))),
            Expr(Print(Ref("x"))));

        Assert.Equal("42\n34\n", output);
    }

    [Fact]
    public void Index_IntoListLiteral()
    {
        var output = RunMain(
            Expr(Print(Call("std", "index", Msg(
                ("target", ListLit(Int(7), Int(8), Int(9))),
                ("index", Int(1)))))));

        Assert.Equal("8\n", output);
    }

    [Fact]
    public void Break_And_Continue_InLoop()
    {
        // for (i = 0; i < 10; i++) { if (i == 2) continue; if (i == 4) break; print(i); }
        var body = Block(new[]
        {
            Expr(Call("std", "if", Msg(
                ("condition", Bin("equals", Ref("i"), Int(2))),
                ("then", Call("std", "continue", Msg()))))),
            Expr(Call("std", "if", Msg(
                ("condition", Bin("equals", Ref("i"), Int(4))),
                ("then", Call("std", "break", Msg()))))),
            Expr(Print(Ref("i"))),
        });
        var output = RunMain(
            Expr(Call("std", "for", Msg(
                ("init", Block(new[] { Let("i", Int(0)) })),
                ("condition", Bin("less_than", Ref("i"), Int(10))),
                ("update", Call("std", "post_increment", Msg(("value", Ref("i"))))),
                ("body", body)))));

        Assert.Equal("0\n1\n3\n", output);
    }

    [Fact]
    public void Return_EarlyFromFunction()
    {
        // int classify(n) { if (n > 0) return "pos"; return "nonpos"; }
        var classify = Func("classify", "n", Block(
            new[]
            {
                Expr(Call("std", "if", Msg(
                    ("condition", Bin("greater_than", Ref("n"), Int(0))),
                    ("then", Call("std", "return", Msg(("value", Str("pos")))))))),
            },
            result: Str("nonpos")));

        var program = Program(
            Block(new[]
            {
                Expr(Print(Call("main", "classify", Int(5)))),
                Expr(Print(Call("main", "classify", Int(-5)))),
            }),
            classify);

        Assert.Equal("pos\nnonpos\n", Run(program));
    }

    [Fact]
    public void Throw_And_Try_Catch()
    {
        // try { throw "boom"; } catch (e) { print(e); }
        var output = RunMain(
            Expr(Call("std", "try", Msg(
                ("body", Call("std", "throw", Msg(("value", Str("boom"))))),
                ("catches", ListLit(Msg(
                    ("variable", Str("e")),
                    ("body", Print(Ref("e"))))))))));

        Assert.Equal("boom\n", output);
    }

    [Fact]
    public void Try_Finally_AlwaysRuns()
    {
        var output = RunMain(
            Expr(Call("std", "try", Msg(
                ("body", Print(Str("body"))),
                ("catches", ListLit()),
                ("finally", Print(Str("cleanup")))))));

        Assert.Equal("body\ncleanup\n", output);
    }

    [Fact]
    public void String_Operations()
    {
        var output = RunMain(
            Expr(Print(Bin("string_concat", Str("foo"), Str("bar")))),
            Expr(Print(Call("std", "string_to_upper", Msg(("value", Str("hi")))))),
            Expr(Print(Call("std", "string_length", Msg(("value", Str("hello")))))));

        Assert.Equal("foobar\nHI\n5\n", output);
    }

    [Fact]
    public void Recursion_Fibonacci_ViaBuiltProgram()
    {
        // Sanity check that a recursive user function (direct call) works
        // outside the on-disk fixture too.
        var fib = Func("fib", "n", Block(
            new[]
            {
                Expr(Call("std", "if", Msg(
                    ("condition", Bin("less_than", Ref("n"), Int(2))),
                    ("then", Call("std", "return", Msg(("value", Ref("n")))))))),
            },
            result: Bin(
                "add",
                Call("main", "fib", Bin("subtract", Ref("n"), Int(1))),
                Call("main", "fib", Bin("subtract", Ref("n"), Int(2))))));

        var program = Program(
            Block(new[] { Expr(Print(Call("main", "fib", Int(10)))) }),
            fib);

        Assert.Equal("55\n", Run(program));
    }
}
