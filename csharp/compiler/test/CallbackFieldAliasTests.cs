using Ball.V1;
using Google.Protobuf.WellKnownTypes;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// The higher-order <c>std_collections</c> calls must read their callback from
/// <b>either</b> spelling of the field: the DECLARED one (<c>callback</c> — the
/// name <c>ListCallbackInput</c> actually gives field 2, in
/// <c>StdModuleBuilders.BuildStdCollectionsModule</c>) or the one the Dart
/// encoder happens to emit (<c>value</c>, its generic positional-argument key).
///
/// <para><b>The bug this file was written against.</b> Before this fix
/// <c>BaseCall.cs</c> read <c>FieldOrNull(f, "value")</c> for
/// <c>list_map</c>/<c>list_filter</c>/<c>list_all</c>/<c>list_any</c>/
/// <c>list_sort</c> — the Dart-encoder spelling only. <c>FieldOrNull</c> falls
/// back to <c>BallValue.Null</c> on a miss, so a program carrying the DECLARED
/// <c>callback</c> key compiled clean and then died at run time with
/// <c>BallRuntimeException: ball runtime: value is not callable: Null</c> (and,
/// for <c>list_sort</c>, did not even fail — it silently sorted in natural
/// order, dropping the comparator). Every other reference target already
/// aliased both spellings — <c>dart/compiler/lib/compiler.dart</c>'s <c>_cb()</c>
/// (<c>callback ?? function ?? value</c>), <c>rust/compiler/src/base_call.rs</c>'s
/// <c>callback_call</c>, <c>go/compiler/base_call.go</c>'s
/// <c>c.arg(f, "value", "callback")</c>, <c>ts/compiler</c> and
/// <c>cpp/compiler</c> — C# was the sole outlier, and it is the C# ENCODER
/// (<c>csharp/encoder/src/Methods.cs</c>, which correctly emits the declared
/// <c>callback</c> name) whose output it could not execute.
/// </para>
///
/// <para><b>Why nothing caught it.</b> Every compiled-and-run test in this suite
/// hand-builds its tree with the Dart spelling, and the C# encoder's own tests
/// assert on proto SHAPE (<c>LambdasStringsAndNullConditionalTests</c> checks
/// only that the field is named <c>callback</c>) without ever compiling and
/// running the result. No CI leg compiles+runs C#-encoder output, so the two
/// halves of the C# pipeline had never been executed end to end over a LINQ
/// construct.</para>
/// </summary>
public class CallbackFieldAliasTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    /// <summary><c>[1,2,3].map((v) =&gt; v * 2).join(",")</c> — once per spelling.</summary>
    [Theory]
    [InlineData("callback")]
    [InlineData("value")]
    public void ListMap_ReadsTheCallbackUnderEitherFieldName(string key)
    {
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_join", Msg(
                ("list", Call("std_collections", "list_map", Msg(
                    ("list", ListLit(Int(1), Int(2), Int(3))),
                    (key, Lambda(Bin("multiply", Ref("input"), Int(2))))))),
                ("separator", Str(",")))))),
        }));

        Assert.Equal("2,4,6\n", Run(program));
    }

    /// <summary><c>[1,2,3].where((v) =&gt; v &gt; 1).join(",")</c> — once per spelling.</summary>
    [Theory]
    [InlineData("callback")]
    [InlineData("value")]
    public void ListFilter_ReadsThePredicateUnderEitherFieldName(string key)
    {
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_join", Msg(
                ("list", Call("std_collections", "list_filter", Msg(
                    ("list", ListLit(Int(1), Int(2), Int(3))),
                    (key, Lambda(Bin("greater_than", Ref("input"), Int(1))))))),
                ("separator", Str(",")))))),
        }));

        Assert.Equal("2,3\n", Run(program));
    }

    [Theory]
    [InlineData("callback")]
    [InlineData("value")]
    public void ListAny_ReadsThePredicateUnderEitherFieldName(string key)
    {
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_any", Msg(
                ("list", ListLit(Int(1), Int(2), Int(3))),
                (key, Lambda(Bin("greater_than", Ref("input"), Int(2)))))))),
        }));

        Assert.Equal("true\n", Run(program));
    }

    [Theory]
    [InlineData("callback")]
    [InlineData("value")]
    public void ListAll_ReadsThePredicateUnderEitherFieldName(string key)
    {
        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_all", Msg(
                ("list", ListLit(Int(1), Int(2), Int(3))),
                (key, Lambda(Bin("greater_than", Ref("input"), Int(2)))))))),
        }));

        Assert.Equal("false\n", Run(program));
    }

    /// <summary>
    /// <c>list_sort</c> is the arm where a dropped callback did NOT crash:
    /// <c>BallStd.ListSort</c> falls back to its natural <c>Compare</c> when the
    /// argument is not a <c>BallFunction</c>, so a lost comparator silently
    /// sorted ASCENDING. A DESCENDING comparator is therefore the only way to
    /// observe it — the silent-wrong-output half of the same defect.
    /// </summary>
    [Theory]
    [InlineData("callback")]
    [InlineData("value")]
    public void ListSort_ReadsTheComparatorUnderEitherFieldName(string key)
    {
        var descending = TwoParamLambda(
            "a",
            "b",
            Bin("subtract", Ref("b"), Ref("a")));

        var program = Program(Block(new[]
        {
            Expr(Print(Call("std_collections", "list_join", Msg(
                ("list", Call("std_collections", "list_sort", Msg(
                    ("list", ListLit(Int(1), Int(3), Int(2))),
                    (key, descending)))),
                ("separator", Str(",")))))),
        }));

        Assert.Equal("3,2,1\n", Run(program));
    }

    /// <summary>An anonymous lambda with two named parameters, carrying the
    /// <c>params</c> metadata every encoder emits for a multi-parameter lambda
    /// (<c>Builders.ParamsMetadata</c>); <c>BallStd.ListSort</c> invokes it with a
    /// positional <c>{arg0, arg1}</c> input.</summary>
    private static Expression TwoParamLambda(string first, string second, Expression body)
    {
        var paramList = Value.ForList(
            Value.ForStruct(new Struct { Fields = { ["name"] = Value.ForString(first) } }),
            Value.ForStruct(new Struct { Fields = { ["name"] = Value.ForString(second) } }));
        return new Expression
        {
            Lambda = new FunctionDefinition
            {
                Body = body,
                Metadata = new Struct { Fields = { ["params"] = paramList } },
            },
        };
    }
}
