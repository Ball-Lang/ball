using System;
using System.Linq;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// The compiler's OBJECT MODEL emissions — the four shapes <c>Ball.Compiler</c> lowers a Ball
/// object to, none of which is "one <c>std</c> base call whose positional arguments fill named
/// input fields" and so none of which <c>encoder/src/RuntimeHelpers.cs</c>'s table can express
/// (issue #689, continuing the <c>FieldGet</c>/<c>ArgGet</c> arms of
/// <see cref="RuntimeNodeHelperTests"/>):
/// <list type="number">
///   <item><c>(BallValue)new BallMessage("main:Point", new BallMap { ["x"] = … })</c> — the
///   emission of a TYPED <c>message_creation</c> node
///   (<c>compiler/src/CSharpCompiler.cs</c>'s <c>CompileMessageCreation</c>);</item>
///   <item><c>(BallValue)new BallMap { ["self"] = … }</c> — the emission of an UNTYPED one
///   (same method, the <c>mc.TypeName.Length == 0</c> arm): a base call's named arguments, and
///   every instance-method call's <c>{self, …}</c> input;</item>
///   <item><c>(BallValue)new BallList(new BallValue[] { … })</c> — the emission of a Ball list
///   literal (<c>CompileListLiteral</c>);</item>
///   <item><c>BallRuntime.FieldSet(obj, "x", v)</c> and <c>BallRuntime.MessageTypeName(obj)</c> —
///   a field WRITE and the receiver-type probe every emitted method dispatcher opens with
///   (<c>compiler/src/Accessors.cs</c>, <c>compiler/src/TypeEmit.cs</c>).</item>
/// </list>
///
/// <para>Together they are the first blocker for every class-shaped fixture in the
/// <c>csharp-roundtrip</c> matrix row: with <c>FieldGet</c>/<c>ArgGet</c> landed, compiling
/// <c>tests/conformance/101_simple_class.ball.json</c> to C# still yields
/// <c>BallRuntime.MessageTypeName</c>, <c>new BallMessage(…)</c>, <c>new BallMap { … }</c> and
/// <c>BallRuntime.FieldSet</c> in the same 60-line program, and the encoder refused all four.</para>
///
/// <para>Every assertion below pins an EXACT inverse of one compiler line, plus the fail-loud
/// boundary that keeps it from guessing (issue #55 doctrine): a Ball <c>message_creation</c>
/// names its fields and its type, so a computed key or a computed type name is an error, never a
/// guess. The whole-corpus proof is the matrix row's floor;
/// <see cref="ReferenceEngineExecutionTests"/> is the executable half, since a shape assertion
/// cannot see whether the tree it asserts actually RUNS.</para>
/// </summary>
public class CompilerObjectModelTests
{
    private static string Wrap(string body) => $$"""
        using Ball.Shared;
        using static Ball.Shared.BallValue;
        internal static class BallProgram
        {
            public static void Main(string[] args)
            {
        {{body}}
            }
        }
        """;

    /// <summary>The single argument of the first <c>std.print</c> in <c>Main</c>.</summary>
    private static Expression FirstPrintedArgument(string body)
    {
        var program = CSharpEncoder.Encode(Wrap(body));
        var main = program.Modules.Single(m => m.Name == "main").Functions.Single(f => f.Name == "Main");
        var call = main.Body.Block.Statements[0].Expression.Call;
        Assert.Equal("std", call.Module);
        Assert.Equal("print", call.Function);
        return call.Input.MessageCreation.Fields.Single(f => f.Name == "message").Value;
    }

    /// <summary>The first statement of <c>Main</c>, as an expression (a bare statement, not a
    /// <c>print</c> argument) — a field WRITE is a statement, not a value the program prints.</summary>
    private static Expression FirstStatementExpression(string body)
    {
        var program = CSharpEncoder.Encode(Wrap(body));
        var main = program.Modules.Single(m => m.Name == "main").Functions.Single(f => f.Name == "Main");
        return main.Body.Block.Statements[0].Expression;
    }

    // ── BallMessage: a typed message_creation ────────────────────────────

    /// <summary><c>new BallMessage("main:Point", new BallMap { ["x"] = 3, ["y"] = 4 })</c> is
    /// exactly how <c>CompileMessageCreation</c> emits <c>message_creation Point{x: 3, y: 4}</c>,
    /// so it must encode back to that node — type name and field names intact.</summary>
    [Fact]
    public void BallMessageConstructionEncodesAsATypedMessageCreation()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print((BallValue)new BallMessage(\"main:Point\", new BallMap { [\"x\"] = Int(3L), [\"y\"] = Int(4L) }));");

        Assert.Equal(Expression.ExprOneofCase.MessageCreation, arg.ExprCase);
        Assert.Equal("main:Point", arg.MessageCreation.TypeName);
        Assert.Equal(new[] { "x", "y" }, arg.MessageCreation.Fields.Select(f => f.Name).ToArray());
        Assert.Equal(3L, arg.MessageCreation.Fields[0].Value.Literal.IntValue);
        Assert.Equal(4L, arg.MessageCreation.Fields[1].Value.Literal.IntValue);
    }

    /// <summary>A field-less instance: <c>new BallMessage("main:Empty", new BallMap())</c>.</summary>
    [Fact]
    public void BallMessageConstructionWithNoFieldsEncodesAsAnEmptyTypedMessageCreation()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print((BallValue)new BallMessage(\"main:Empty\", new BallMap()));");

        Assert.Equal(Expression.ExprOneofCase.MessageCreation, arg.ExprCase);
        Assert.Equal("main:Empty", arg.MessageCreation.TypeName);
        Assert.Empty(arg.MessageCreation.Fields);
    }

    /// <summary>A Ball <c>message_creation</c> NAMES its type; it cannot compute one. A
    /// non-literal type operand must fail loud rather than be guessed at.</summary>
    [Fact]
    public void BallMessageWithAComputedTypeNameFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var t = "main:Point";
                    BallRuntime.Print((BallValue)new BallMessage(t, new BallMap()));
        """)));

        Assert.Contains("BallMessage", ex.Message, StringComparison.Ordinal);
        Assert.Contains("string-literal type name", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>The fields operand must be a <c>new BallMap { … }</c> whose keys are literally
    /// spelled — a runtime map (the enum-namespace emission's <c>__ns</c>) carries no field
    /// NAMES for a <c>message_creation</c> to declare, so it is an error, not a guess.</summary>
    [Fact]
    public void BallMessageWithARuntimeFieldsOperandFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var ns = new BallMap();
                    BallRuntime.Print((BallValue)new BallMessage("main:Point", ns));
        """)));

        Assert.Contains("BallMessage", ex.Message, StringComparison.Ordinal);
        Assert.Contains("new BallMap", ex.Message, StringComparison.Ordinal);
    }

    // ── BallMap: an untyped message_creation ─────────────────────────────

    /// <summary><c>new BallMap { ["self"] = p }</c> is <c>CompileMessageCreation</c>'s emission of
    /// an UNTYPED <c>message_creation</c> — the shape every instance-method call site packs its
    /// receiver into — so it inverts to exactly that node, not to a collection call. (A genuine
    /// Ball map literal compiles to <c>BallRuntime.MapCreate(…)</c>, a different shape, so there
    /// is no ambiguity to resolve here.)</summary>
    [Fact]
    public void BallMapConstructionEncodesAsAnUntypedMessageCreation()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print((BallValue)new BallMap { [\"self\"] = Int(1L), [\"arg0\"] = Int(2L) });");

        Assert.Equal(Expression.ExprOneofCase.MessageCreation, arg.ExprCase);
        Assert.Equal(string.Empty, arg.MessageCreation.TypeName);
        Assert.Equal(new[] { "self", "arg0" }, arg.MessageCreation.Fields.Select(f => f.Name).ToArray());
    }

    /// <summary><c>new BallMap()</c> — the empty-input emission.</summary>
    [Fact]
    public void EmptyBallMapConstructionEncodesAsAnEmptyUntypedMessageCreation()
    {
        var arg = FirstPrintedArgument("        BallRuntime.Print((BallValue)new BallMap());");

        Assert.Equal(Expression.ExprOneofCase.MessageCreation, arg.ExprCase);
        Assert.Equal(string.Empty, arg.MessageCreation.TypeName);
        Assert.Empty(arg.MessageCreation.Fields);
    }

    /// <summary>A <c>message_creation</c> field is a NAME. A computed key must fail loud.</summary>
    [Fact]
    public void BallMapWithAComputedKeyFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var k = "self";
                    BallRuntime.Print((BallValue)new BallMap { [k] = Int(1L) });
        """)));

        Assert.Contains("BallMap", ex.Message, StringComparison.Ordinal);
        Assert.Contains("string-literal", ex.Message, StringComparison.Ordinal);
    }

    // ── BallList: a list literal ─────────────────────────────────────────

    /// <summary><c>new BallList(new BallValue[] { … })</c> is the compiler's Ball list-literal
    /// emission, so it inverts to a <c>literal.list</c>.</summary>
    [Fact]
    public void BallListConstructionEncodesAsAListLiteral()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print((BallValue)new BallList(new BallValue[] { Int(1L), Int(2L) }));");

        Assert.Equal(Expression.ExprOneofCase.Literal, arg.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.ListValue, arg.Literal.ValueCase);
        Assert.Equal(new[] { 1L, 2L }, arg.Literal.ListValue.Elements.Select(e => e.Literal.IntValue).ToArray());
    }

    /// <summary><c>new BallList()</c> — the empty-list emission.</summary>
    [Fact]
    public void EmptyBallListConstructionEncodesAsAnEmptyListLiteral()
    {
        var arg = FirstPrintedArgument("        BallRuntime.Print((BallValue)new BallList());");

        Assert.Equal(Expression.ExprOneofCase.Literal, arg.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.ListValue, arg.Literal.ValueCase);
        Assert.Empty(arg.Literal.ListValue.Elements);
    }

    // ── BallRuntime.FieldSet: assign to a field_access ───────────────────

    /// <summary><c>BallRuntime.FieldSet(obj, "x", v)</c> is the compiler's emission of
    /// <c>obj.x = v</c>, whose Ball inverse is <c>std.assign</c> over a <c>field_access</c>
    /// TARGET — the exact shape <c>dart/engine/lib/engine_control_flow.dart</c>'s
    /// <c>_evalAssign</c> routes through <c>_trySetterDispatch</c> and then writes.</summary>
    [Fact]
    public void FieldSetEncodesAsAnAssignToAFieldAccess()
    {
        var expr = FirstStatementExpression(
            "        BallRuntime.FieldSet(BallValue.Null, \"x\", Int(5L));");

        Assert.Equal(Expression.ExprOneofCase.Call, expr.ExprCase);
        Assert.Equal("std", expr.Call.Module);
        Assert.Equal("assign", expr.Call.Function);

        var fields = expr.Call.Input.MessageCreation.Fields;
        var target = fields.Single(f => f.Name == "target").Value;
        Assert.Equal(Expression.ExprOneofCase.FieldAccess, target.ExprCase);
        Assert.Equal("x", target.FieldAccess.Field);
        Assert.Equal(5L, fields.Single(f => f.Name == "value").Value.Literal.IntValue);
    }

    /// <summary>Same fail-loud boundary as <c>FieldGet</c>: a Ball <c>field_access</c> names its
    /// field, so a computed one is an error.</summary>
    [Fact]
    public void FieldSetWithAComputedFieldNameFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var key = "x";
                    BallRuntime.FieldSet(BallValue.Null, key, Int(5L));
        """)));

        Assert.Contains("FieldSet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("string-literal field name", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>The arity boundary the table's rows already enforce, kept by the node arm.</summary>
    [Fact]
    public void FieldSetArityIsChecked()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap(
            "        BallRuntime.FieldSet(BallValue.Null, \"x\");")));

        Assert.Contains("FieldSet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("expects 3 argument(s)", ex.Message, StringComparison.Ordinal);
    }

    // ── BallRuntime.MessageTypeName: the receiver-type probe ─────────────

    /// <summary>
    /// <c>BallRuntime.MessageTypeName(obj)</c> opens every dispatcher the compiler emits
    /// (<c>compiler/src/Accessors.cs</c>, <c>compiler/src/TypeEmit.cs</c>), which then compares it
    /// against BOTH the full <c>module:Type</c> name and the short one. Its portable Ball
    /// counterpart is <c>std.type_of</c> — by <c>dart/shared/std.json</c>'s own declaration "the
    /// canonical base type name … with any module prefix stripped", i.e. the short name the
    /// dispatcher already tests.
    /// </summary>
    [Fact]
    public void MessageTypeNameEncodesAsStdTypeOf()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print(BallRuntime.MessageTypeName(BallValue.Null));");

        Assert.Equal(Expression.ExprOneofCase.Call, arg.ExprCase);
        Assert.Equal("std", arg.Call.Module);
        Assert.Equal("type_of", arg.Call.Function);
        Assert.Contains(arg.Call.Input.MessageCreation.Fields, f => f.Name == "value");
    }

    /// <summary>The arity boundary.</summary>
    [Fact]
    public void MessageTypeNameArityIsChecked()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap(
            "        BallRuntime.Print(BallRuntime.MessageTypeName(BallValue.Null, BallValue.Null));")));

        Assert.Contains("MessageTypeName", ex.Message, StringComparison.Ordinal);
        Assert.Contains("expects 1 argument(s)", ex.Message, StringComparison.Ordinal);
    }

    // ── shadowing: a same-file declaration still wins ────────────────────

    /// <summary>
    /// These are Ball.Shared types, not keywords. A file that declares its OWN
    /// <c>BallMap</c> keeps the ordinary same-file-class path — the shadowing order C# itself
    /// uses, and the same order <c>EncodeObjectCreation</c> already applies to the
    /// <c>*Exception</c> fallback.
    /// </summary>
    [Fact]
    public void ASameFileClassNamedBallMapStillWins()
    {
        var program = CSharpEncoder.Encode("""
            using Ball.Shared;

            internal sealed class BallMap
            {
                public int X { get; set; }
            }

            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.Print(new BallMap { X = 1 });
                }
            }
            """);

        var main = program.Modules.Single(m => m.Name == "main").Functions.Single(f => f.Name == "Main");
        var arg = main.Body.Block.Statements[0].Expression.Call.Input.MessageCreation.Fields
            .Single(f => f.Name == "message").Value;

        Assert.Equal(Expression.ExprOneofCase.MessageCreation, arg.ExprCase);
        Assert.Equal("main:BallMap", arg.MessageCreation.TypeName);
        Assert.Equal(new[] { "X" }, arg.MessageCreation.Fields.Select(f => f.Name).ToArray());
    }
}
