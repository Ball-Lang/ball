using System.Linq;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Constructor → field mapping (issue #492, slice B).
///
/// <para><b>The defect these close.</b> <c>EncodeObjectCreation</c> used to key a
/// <c>new Foo(a, b)</c> <see cref="MessageCreation"/> by the CONSTRUCTOR'S OWN PARAMETER
/// NAMES, while every method body reads its fields by the class's DECLARED FIELD NAMES
/// (sourced independently from <c>field</c>/auto-property declarations). Those two agree
/// only for a primary constructor or an object initializer — the only two shapes any test
/// exercised — and disagree for the single most common real C# idiom,
/// <c>private int _x; public Point(int x) { _x = x; }</c>. The result was not a thrown gap
/// but SILENT WRONG OUTPUT: verified end to end on the Dart reference engine, the repro in
/// <see cref="FieldMappingUsesDeclaredFieldNamesNotParameterNames"/> printed <c>0</c>
/// instead of <c>3</c>, because every later <c>field_access(self, "_x")</c> read the proto3
/// default of a field that was never populated.
/// </para>
///
/// <para><b>Why nothing caught it.</b> <c>ClassesAndObjectsTests</c>' only construction
/// fixture uses an object initializer (<c>new Point { X = 3, Y = 4 }</c>) — a different code
/// path (<c>EncodeObjectInitializerFields</c>) that reads the initializer's own key names and
/// therefore cannot expose a param-vs-field mismatch — and <c>ProofProgramsTests</c>' three
/// programs (hello_world/fibonacci/factorial) declare no class with an explicit,
/// non-primary constructor at all. <c>RealWorldSweepTests</c> only ever asserts "did
/// <c>Encode()</c> throw", never "is the output correct".</para>
///
/// <para><b>End-to-end proof</b> (mirrors <c>ProofProgramsTests</c>' own convention: the
/// engine run is done by hand and its verbatim output recorded here; the xunit tests re-run
/// the fast, in-process ENCODE step and assert the structural properties that make that run
/// correct). <see cref="PointSource"/> below was encoded with this encoder, wrapped as a
/// <c>@type</c>-enveloped <c>.ball.json</c> and run on the DART REFERENCE ENGINE
/// (<c>dart run dart/cli/bin/ball.dart run &lt;file&gt;</c>):
/// <code>
/// 3
/// </code>
/// At <c>origin/main</c> the same command printed <c>0</c>.</para>
/// </summary>
public class ConstructorFieldMappingTests
{
    /// <summary>The repro: field names (<c>_x</c>/<c>_y</c>) deliberately differ from the
    /// constructor's parameter names (<c>x</c>/<c>y</c>) — ordinary C#, and the shape the
    /// epic's own <c>c_two_constructors.cs</c> fixture already used.</summary>
    private const string PointSource = """
        using System;

        class Point
        {
            private int _x;
            private int _y;

            public Point(int x, int y)
            {
                _x = x;
                _y = y;
            }

            public int Sum()
            {
                return _x + _y;
            }

            static void Main()
            {
                var p = new Point(1, 2);
                Console.WriteLine(p.Sum());
            }
        }
        """;

    /// <summary>Two constructors of distinct arity, the arity-1 one setting a field from a
    /// body LITERAL rather than from any parameter — byte-for-byte the shape of the
    /// committed <c>fixtures/realworld/c_two_constructors.cs</c> bucket-(c) fixture.</summary>
    private const string TwoConstructorSource = """
        using System;

        class Point
        {
            private int _x;
            private int _y;

            public Point(int x)
            {
                _x = x;
                _y = 0;
            }

            public Point(int x, int y)
            {
                _x = x;
                _y = y;
            }

            public int Sum()
            {
                return _x + _y;
            }

            static void Main()
            {
                Console.WriteLine(new Point(5).Sum() + new Point(1, 2).Sum());
            }
        }
        """;

    /// <summary>Unwrap <c>std.print(message: std.to_string(value: X))</c> — what a
    /// <c>Console.WriteLine(X)</c> statement encodes to — down to <c>X</c>.</summary>
    private static Expression PrintedExpression(Expression printCall)
    {
        Assert.Equal("print", printCall.Call.Function);
        var toString = printCall.Call.Input.MessageCreation.Fields.Single(f => f.Name == "message").Value;
        Assert.Equal("to_string", toString.Call.Function);
        return toString.Call.Input.MessageCreation.Fields.Single(f => f.Name == "value").Value;
    }

    private static MessageCreation ConstructionIn(string source, int statementIndex)
    {
        var program = TestHelpers.EncodeProgram(source);
        var main = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var stmt = main.Body.Block.Statements[statementIndex];
        var expr = stmt.StmtCase == Statement.StmtOneofCase.Let ? stmt.Let.Value : stmt.Expression;
        Assert.Equal(Expression.ExprOneofCase.MessageCreation, expr.ExprCase);
        return expr.MessageCreation;
    }

    [Fact]
    public void FieldMappingUsesDeclaredFieldNamesNotParameterNames()
    {
        var creation = ConstructionIn(PointSource, 0);

        Assert.Equal("main:Point", creation.TypeName);
        Assert.Equal(new[] { "_x", "_y" }, creation.Fields.Select(f => f.Name));
        Assert.Equal(1, creation.Fields[0].Value.Literal.IntValue);
        Assert.Equal(2, creation.Fields[1].Value.Literal.IntValue);
    }

    /// <summary>The other half of the same claim: the method body that READS those fields
    /// uses the very names the construction wrote. This is what makes the mismatch a
    /// correctness bug rather than a naming preference — assert both ends together so a
    /// future change cannot "fix" one side in isolation.</summary>
    [Fact]
    public void MethodBodyReadsTheSameFieldNamesConstructionWrites()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var sum = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "main:Point.Sum");
        var returnCall = sum.Body.Block.Statements[0].Expression;
        Assert.Equal("return", returnCall.Call.Function);
        var add = returnCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("add", add.Call.Function);

        var left = add.Call.Input.MessageCreation.Fields[0].Value;
        var right = add.Call.Input.MessageCreation.Fields[1].Value;
        Assert.Equal("_x", left.FieldAccess.Field);
        Assert.Equal("_y", right.FieldAccess.Field);

        var written = ConstructionIn(PointSource, 0).Fields.Select(f => f.Name).ToList();
        Assert.Contains(left.FieldAccess.Field, written);
        Assert.Contains(right.FieldAccess.Field, written);
    }

    /// <summary>
    /// A new-feature test for slice B's design (not a pre-existing uncovered path): before
    /// this slice a class's second constructor threw outright, so a field set from a body
    /// literal had no representation at all. Each call site picks the constructor whose
    /// arity it matches, and a <c>_y = 0;</c> literal assignment lands as a real field.
    /// </summary>
    [Fact]
    public void ConstructorWithLiteralDefaultFieldEncodesCorrectly()
    {
        var program = TestHelpers.EncodeProgram(TwoConstructorSource);
        var main = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");

        // `Console.WriteLine(...)` encodes as `std.print(message: std.to_string(value: <expr>))`.
        var add = PrintedExpression(main.Body.Block.Statements[0].Expression);
        Assert.Equal("add", add.Call.Function);
        var arityOne = add.Call.Input.MessageCreation.Fields[0].Value
            .Call.Input.MessageCreation.Fields.Single(f => f.Name == "self").Value.MessageCreation;
        var arityTwo = add.Call.Input.MessageCreation.Fields[1].Value
            .Call.Input.MessageCreation.Fields.Single(f => f.Name == "self").Value.MessageCreation;

        Assert.Equal(new[] { "_x", "_y" }, arityOne.Fields.Select(f => f.Name));
        Assert.Equal(5, arityOne.Fields[0].Value.Literal.IntValue);
        Assert.Equal(0, arityOne.Fields[1].Value.Literal.IntValue);

        Assert.Equal(new[] { "_x", "_y" }, arityTwo.Fields.Select(f => f.Name));
        Assert.Equal(1, arityTwo.Fields[0].Value.Literal.IntValue);
        Assert.Equal(2, arityTwo.Fields[1].Value.Literal.IntValue);
    }

    /// <summary>A primary constructor's parameters ARE its fields, so the corrected mapping
    /// must leave that already-working shape byte-identical.</summary>
    [Fact]
    public void PrimaryConstructorStillMapsParametersDirectlyOntoFields()
    {
        const string source = """
            class Point(int X, int Y)
            {
                public int Sum()
                {
                    return X + Y;
                }
            }

            class Program
            {
                static void Main()
                {
                    var p = new Point(3, 4);
                }
            }
            """;
        var creation = ConstructionIn(source, 0);
        Assert.Equal(new[] { "X", "Y" }, creation.Fields.Select(f => f.Name));
        Assert.Equal(3, creation.Fields[0].Value.Literal.IntValue);
        Assert.Equal(4, creation.Fields[1].Value.Literal.IntValue);
    }

    /// <summary>Documented scope limit #1: a syntax-only encoder has no semantic model to
    /// pick between two same-arity overloads, so it fails loud rather than guessing.</summary>
    [Fact]
    public void SameArityConstructorOverloadsThrowAmbiguity()
    {
        const string source = """
            class Point
            {
                private int _x;
                private int _y;

                public Point(int x)
                {
                    _x = x;
                    _y = 0;
                }

                public Point(int y)
                {
                    _x = 0;
                    _y = y;
                }

                static void Main()
                {
                    var p = new Point(1);
                }
            }
            """;
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(source));
        Assert.Contains("ambiguous constructor arity", ex.Message);
    }

    /// <summary>Documented scope limit #2: the constructor-body pattern match is deliberately
    /// NARROW — <c>field = param;</c> and <c>field = literal;</c> only. Anything else is a
    /// loud, named failure rather than a silently dropped assignment (which is what the old
    /// "never interpret a constructor body at all" posture actually did).</summary>
    [Fact]
    public void NonTrivialConstructorBodyThrows()
    {
        const string source = """
            class Point
            {
                private int _x;

                public Point(int x)
                {
                    _x = x * 2;
                }

                static void Main()
                {
                    var p = new Point(1);
                }
            }
            """;
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(source));
        Assert.Contains("non-trivial field assignment", ex.Message);
        Assert.Contains("Point", ex.Message);
    }

    /// <summary>A call site whose argument count matches no declared constructor names every
    /// declared arity, so the message is actionable rather than "declares 2 parameters".</summary>
    [Fact]
    public void ArgumentCountMatchingNoConstructorListsEveryDeclaredArity()
    {
        const string source = """
            class Point
            {
                private int _x;
                private int _y;

                public Point(int x)
                {
                    _x = x;
                    _y = 0;
                }

                public Point(int x, int y)
                {
                    _x = x;
                    _y = y;
                }

                static void Main()
                {
                    var p = new Point(1, 2, 3);
                }
            }
            """;
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(source));
        Assert.Contains("3 positional argument(s)", ex.Message);
        Assert.Contains("1, 2", ex.Message);
    }
}
