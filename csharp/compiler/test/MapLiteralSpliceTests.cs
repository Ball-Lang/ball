using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// A map literal must <b>splice</b> its <c>element</c> comprehension parts
/// (<c>std.spread</c> / <c>collection_if</c> / <c>collection_for</c>), not drop
/// them — the map analog of <see cref="ListLiteralSpliceTests"/>. The missing
/// splice silently emptied every internal comprehension map the self-hosted
/// engine builds (e.g. <c>_toJsonSafe</c>'s <c>{ for (e in m.entries) … }</c>,
/// which broke <c>jsonEncode</c>; issue #383). Mirrors the reference engine's
/// <c>_evalLazyMapCreate</c>.
/// </summary>
public class MapLiteralSpliceTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    private static Expression Entry(string key, Expression value) =>
        Msg(("key", Str(key)), ("value", value));

    private static Expression EntryOf(Expression key, Expression value) =>
        Msg(("key", key), ("value", value));

    private static Expression MapLit(params (string Field, Expression Value)[] fields) =>
        Call("std", "map_create", Msg(fields));

    [Fact]
    public void SpreadMergesAnotherMap()
    {
        // final m = {'a': 1, 'b': 2}; print({...m, 'c': 3});
        var output = Run(Program(Block(new[]
        {
            Let("m", MapLit(("entry", Entry("a", Int(1))), ("entry", Entry("b", Int(2))))),
            Expr(Print(MapLit(
                ("element", Call("std", "spread", Msg(("value", Ref("m"))))),
                ("entry", Entry("c", Int(3)))))),
        })));

        Assert.Equal("{a: 1, b: 2, c: 3}\n", output);
    }

    [Fact]
    public void CollectionIfEmitsOnlyTakenEntries()
    {
        // print({if (true) 'x': 1, if (false) 'y': 9, 'z': 3});
        var output = Run(Program(Block(new[]
        {
            Expr(Print(MapLit(
                ("element", Call("std", "collection_if", Msg(("condition", Bool(true)), ("then", Entry("x", Int(1)))))),
                ("element", Call("std", "collection_if", Msg(("condition", Bool(false)), ("then", Entry("y", Int(9)))))),
                ("entry", Entry("z", Int(3)))))),
        })));

        Assert.Equal("{x: 1, z: 3}\n", output);
    }

    [Fact]
    public void CollectionForSplicesOneEntryPerIteration()
    {
        // print({for (final k in ['a', 'b']) k: 1});
        var forElement = Call("std", "collection_for", Msg(
            ("variable", Str("k")),
            ("iterable", ListLit(Str("a"), Str("b"))),
            ("body", EntryOf(Ref("k"), Int(1)))));
        var output = Run(Program(Block(new[]
        {
            Expr(Print(MapLit(("element", forElement)))),
        })));

        Assert.Equal("{a: 1, b: 1}\n", output);
    }
}
