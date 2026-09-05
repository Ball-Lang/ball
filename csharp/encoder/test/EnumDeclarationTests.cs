using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// <c>enum</c> declarations and enum-member references (issue #492, slice C).
///
/// <para><b>Why this bucket mattered most.</b> In the live Tier A funnel
/// (<c>tools/coverage-study/packages/csharp.json</c>: Cronos, CommandLine,
/// Humanizer, Newtonsoft.Json) 66 of the 398 encode errors were the single
/// message <c>unsupported type declaration kind `EnumDeclaration`</c> — every
/// one of them an enum, none an interface or delegate. The throw fires on the
/// FIRST non-<see cref="Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax"/>
/// top-level declaration regardless of where it sits, so one enum anywhere in a
/// file killed that whole file.</para>
///
/// <para><b>The compiler was already the ready consumer.</b>
/// <c>csharp/compiler/src/TypeEmit.cs</c>'s <c>CompileEnum</c> has always
/// emitted a real enum namespace (<c>public static readonly BallValue Color</c>,
/// a map of member name → a <c>{index, name}</c> message plus a <c>values</c>
/// list) off <c>Module.Enums[]</c>, and <c>CSharpCompiler</c> resolves a bare
/// <c>reference("Color")</c> to that static. The encoder's own <c>enums</c>
/// list existed and was added to the module — and was never populated. Pure
/// missing encoder work.</para>
///
/// <para><b>Cross-language IR convention (deliberate, not invented here).</b>
/// The shape matches <c>rust/encoder/src/types.rs</c> exactly, because two
/// encoders that disagree on "what an enum value is" only surface the
/// divergence much later as a round-trip mismatch:
/// <list type="bullet">
/// <item>an <c>EnumDescriptorProto</c> in <c>Module.Enums[]</c>, named
/// <c>"main:&lt;ShortName&gt;"</c>, one <c>Value</c> per member;</item>
/// <item>a companion, <b>descriptor-less</b> <c>TypeDefinition</c> of the same
/// name carrying <c>metadata.kind = "enum"</c> and a <c>values</c> list — the
/// exact shape <c>CompileModuleTypes</c> skips re-emitting as a class;</item>
/// <item>a member reference <c>Color.Green</c> as
/// <c>field_access(reference("Color"), "Green")</c> — Rust's
/// <c>encode_path_expr</c> emits the identical tree for <c>Color::Green</c>,
/// and the Dart reference encoder for <c>Color.green</c>.</item>
/// </list></para>
/// </summary>
public class EnumDeclarationTests
{
    private const string SequentialEnumSource = """
        Console.WriteLine("start");

        public enum Color { Red, Green, Blue }
        """;

    /// <summary>C# continues numbering from the last EXPLICIT member, so
    /// <c>Blue</c> is 6, not 2 — a positional index would be wrong.</summary>
    private const string ExplicitValueEnumSource = """
        Console.WriteLine("start");

        public enum Color { Red, Green = 5, Blue }
        """;

    private const string EnumUsageSource = """
        using System;

        public enum Color { Red, Green, Blue }

        public class Program
        {
            public static string Name(Color c)
            {
                if (c == Color.Green)
                {
                    return "green";
                }

                if (c == Color.Blue)
                {
                    return "blue";
                }

                return "red";
            }

            public static void Main()
            {
                Console.WriteLine(Name(Color.Green));
                Console.WriteLine(Name(Color.Blue));
                Console.WriteLine(Name(Color.Red));
            }
        }
        """;

    [Fact]
    public void TopLevelEnumEncodesAsModuleEnum()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram(SequentialEnumSource));

        var colorEnum = Assert.Single(main.Enums);
        Assert.Equal("main:Color", colorEnum.Name);
        Assert.Equal(
            new[] { "Red", "Green", "Blue" },
            colorEnum.Value.Select(v => v.Name).ToArray());
        Assert.Equal(new[] { 0, 1, 2 }, colorEnum.Value.Select(v => v.Number).ToArray());

        // The companion TypeDefinition: descriptor-less (its values live in
        // Module.Enums[]), tagged `kind: "enum"` — the Rust/Dart convention.
        var typeDef = main.TypeDefs.Single(td => td.Name == "main:Color");
        Assert.Null(typeDef.Descriptor_);
        Assert.Equal("enum", typeDef.Metadata.Fields["kind"].StringValue);
        Assert.Equal(
            new[] { "Red", "Green", "Blue" },
            typeDef.Metadata.Fields["values"].ListValue.Values
                .Select(v => v.StructValue.Fields["name"].StringValue)
                .ToArray());
    }

    [Fact]
    public void ExplicitEnumMemberValueIsHonoredAndSubsequentMembersContinueFromIt()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram(ExplicitValueEnumSource));

        var colorEnum = Assert.Single(main.Enums);
        Assert.Equal(
            new[] { ("Red", 0), ("Green", 5), ("Blue", 6) },
            colorEnum.Value.Select(v => (v.Name, v.Number)).ToArray());
    }

    [Fact]
    public void EnumMemberReferenceEncodesAsFieldAccessOnTheEnumNamespace()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram(EnumUsageSource));
        var name = main.Functions.Single(f => f.Name == "Program_Name");

        // `Color.Green`/`Color.Blue` must be the cross-language member-reference
        // shape — field_access(reference("Color"), "<Member>"), identical to what
        // `rust/encoder/src/types.rs`'s enum path emits for `Color::Green`.
        var members = EnumMemberReads(name.Body, enumName: "Color");
        Assert.Equal(new[] { "Blue", "Green" }, members.Order(StringComparer.Ordinal).ToArray());
    }

    /// <summary>Every <c>field_access(reference(<paramref name="enumName"/>), X)</c>
    /// anywhere under <paramref name="root"/>, as the distinct set of X. Walking
    /// the whole tree keeps the assertion about the encoded SHAPE rather than
    /// about where a particular statement happens to sit.</summary>
    private static HashSet<string> EnumMemberReads(Expression root, string enumName)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        Walk(root);
        return found;

        void Walk(Expression? expr)
        {
            if (expr is null)
            {
                return;
            }

            switch (expr.ExprCase)
            {
                case Expression.ExprOneofCase.FieldAccess:
                    if (expr.FieldAccess.Object?.ExprCase == Expression.ExprOneofCase.Reference &&
                        expr.FieldAccess.Object.Reference.Name == enumName)
                    {
                        found.Add(expr.FieldAccess.Field);
                    }

                    Walk(expr.FieldAccess.Object);
                    break;
                case Expression.ExprOneofCase.Call:
                    Walk(expr.Call.Input);
                    break;
                case Expression.ExprOneofCase.MessageCreation:
                    foreach (var field in expr.MessageCreation.Fields)
                    {
                        Walk(field.Value);
                    }

                    break;
                case Expression.ExprOneofCase.Lambda:
                    Walk(expr.Lambda.Body);
                    break;
                case Expression.ExprOneofCase.Block:
                    foreach (var stmt in expr.Block.Statements)
                    {
                        Walk(stmt.StmtCase == Statement.StmtOneofCase.Let ? stmt.Let.Value : stmt.Expression);
                    }

                    Walk(expr.Block.Result);
                    break;
                default:
                    break;
            }
        }
    }

    /// <summary>
    /// The end-to-end proof: the ENCODED program is handed back to
    /// <see cref="CSharpCompiler"/>, compiled in memory and executed, and each
    /// enum member must resolve to its own distinct value. A structural
    /// assertion alone could not catch an encoding that names every member the
    /// same thing.
    /// </summary>
    [Fact]
    public void EnumValueReferenceEncodesCompilesAndRuns()
    {
        var program = TestHelpers.EncodeProgram(EnumUsageSource);
        var output = CSharpRunner.Run(CSharpCompiler.Compile(program));
        Assert.Equal("green\nblue\nred\n", output);
    }

    /// <summary>
    /// An enum member whose value is a computed constant expression
    /// (<c>Read = 1 &lt;&lt; 0</c>, <c>All = Read | Write</c>) is a documented,
    /// NARROWER gap than "enums are unsupported": a syntax-only encoder has no
    /// constant evaluator, so it fails loud naming the member rather than
    /// guessing an ordinal. Pinned so the boundary cannot silently move.
    /// </summary>
    [Fact]
    public void ComputedEnumMemberValueThrowsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            Console.WriteLine("start");

            public enum Flags { Read = 1, Write = 2, All = Read | Write }
            """));
        Assert.Contains("Flags", ex.Message);
        Assert.Contains("All", ex.Message);
    }

    /// <summary>
    /// A negative discriminant is a plain literal behind a unary minus and IS
    /// supported — the gap above is computed expressions, not signs.
    /// </summary>
    [Fact]
    public void NegativeEnumMemberValueIsHonored()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram("""
            Console.WriteLine("start");

            public enum Level { Unknown = -1, Off = 0, On = 1 }
            """));

        var levelEnum = Assert.Single(main.Enums);
        Assert.Equal(
            new[] { ("Unknown", -1), ("Off", 0), ("On", 1) },
            levelEnum.Value.Select(v => (v.Name, v.Number)).ToArray());
    }
}
