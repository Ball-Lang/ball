using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// A list literal must <b>splice</b> its <c>std.spread</c> / <c>collection_if</c>
/// / <c>collection_for</c> elements, not nest them as a single value. The
/// missing splice made the self-hosted engine's own <c>_ballSetOf([...items,
/// v])</c> produce <c>{[...], v}</c> — breaking every internal set/list append
/// (`set.add`, `list.addAll`, `set.union`; issue #383). Mirrors the reference
/// engines' <c>_addCollectionElement</c> and <c>ball-compiler</c>'s
/// <c>compile_list_literal</c>.
/// </summary>
public class ListLiteralSpliceTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    private static Expression Spread(Expression value) =>
        Call("std", "spread", Msg(("value", value)));

    [Fact]
    public void Spread_Splices_Into_The_Backing()
    {
        // final a = [1, 2, 3]; final b = [4, 5]; print([...a, ...b, 6]);
        var output = Run(Program(Block(new[]
        {
            Let("a", ListLit(Int(1), Int(2), Int(3))),
            Let("b", ListLit(Int(4), Int(5))),
            Expr(Print(ListLit(Spread(Ref("a")), Spread(Ref("b")), Int(6)))),
            Expr(Print(ListLit(Int(0), Spread(Ref("a"))))),
        })));

        Assert.Equal("[1, 2, 3, 4, 5, 6]\n[0, 1, 2, 3]\n", output);
    }

    [Fact]
    public void Nested_Spread_Uses_Unique_Temporaries()
    {
        // print([...[...a, 4]]) — the inner splice must not shadow the outer.
        var output = Run(Program(Block(new[]
        {
            Let("a", ListLit(Int(1), Int(2), Int(3))),
            Expr(Print(ListLit(Spread(ListLit(Spread(Ref("a")), Int(4)))))),
        })));

        Assert.Equal("[1, 2, 3, 4]\n", output);
    }

    [Fact]
    public void CollectionIf_Emits_Its_Taken_Branch()
    {
        // print([if (true) 1 else 2, if (false) 9 else 8, 3]);
        var output = Run(Program(Block(new[]
        {
            Expr(Print(ListLit(
                Call("std", "collection_if", Msg(("condition", Bool(true)), ("then", Int(1)), ("else", Int(2)))),
                Call("std", "collection_if", Msg(("condition", Bool(false)), ("then", Int(9)), ("else", Int(8)))),
                Int(3)))),
        })));

        Assert.Equal("[1, 8, 3]\n", output);
    }
}
