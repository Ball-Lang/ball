using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Same-class constructor chaining, <c>: this(...)</c> (issue #492, slice D).
///
/// <para><b>Where the gap came from.</b> #492 slice B made construction resolve
/// a constructor's body into a <c>CtorShape</c> so a message could be keyed by
/// the class's DECLARED field names. That slice narrowed the older
/// "class declares more than one constructor" rejection, but it introduced an
/// unconditional throw on any <c>ctor.Initializer</c> — so
/// <c>Point(int x) : this(x, 0)</c>, previously rejected earlier for a
/// different reason, became its own bucket: 19 of the 63 ctor-chain encode
/// errors in the live Tier A funnel (<c>: base(...)</c> is the other 44 and
/// stays out of scope — see <see cref="BaseChainStillThrowsLoud"/>).</para>
///
/// <para><b>Why a two-pass resolution, not one.</b> C# lets a constructor chain
/// FORWARD or BACKWARD textually — <c>Point(int x) : this(x, 0)</c> may be
/// declared before or after the 2-argument target. A single pass would resolve
/// only the backward case and silently mis-shape the forward one, so
/// <c>Encoder.CollectDeclarations</c> collects every shape first and resolves
/// chains in a second pass over the finished table. Both directions are proven
/// here, because a construction bug in this encoder is SILENT: nothing fails
/// loud on a wrong field mapping — only running the program catches it (the
/// same postmortem #492 slice B already wrote once).</para>
///
/// <para>The <c>Sum()</c> proofs are the same shape as slice B's <c>Point</c>
/// <c>_x</c>/<c>_y</c> proof: a method reads the class's own declared fields, so
/// a message keyed by anything else reads back <c>0</c>.</para>
/// </summary>
public class ConstructorChainingTests
{
    /// <summary>Backward chain: the 1-argument constructor is declared AFTER
    /// the 2-argument target it delegates to.</summary>
    private const string BackwardChainSource = """
        public class Point
        {
            private int _x;
            private int _y;

            public Point(int x, int y)
            {
                _x = x;
                _y = y;
            }

            public Point(int x) : this(x, 0)
            {
            }

            public int Sum()
            {
                return _x + _y;
            }

            public static void Main()
            {
                System.Console.WriteLine(new Point(3).Sum());
            }
        }
        """;

    /// <summary>Forward chain: the delegating constructor is declared BEFORE its
    /// target — the ordering a single-pass resolution would get wrong.</summary>
    private const string ForwardChainSource = """
        public class Point
        {
            private int _x;
            private int _y;

            public Point(int x) : this(x, 7)
            {
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

            public static void Main()
            {
                System.Console.WriteLine(new Point(3).Sum());
            }
        }
        """;

    [Fact]
    public void ThisChainResolvesThroughTargetShape()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram(BackwardChainSource));
        var fields = ConstructionFields(main);

        // The 1-argument call site must produce BOTH declared fields: `_x` from
        // the initializer's own argument (3), `_y` from the literal the target
        // constructor writes for the argument the initializer supplied (0).
        Assert.Equal(new[] { "_x", "_y" }, fields.Select(f => f.Name).ToArray());
        Assert.Equal(3L, fields[0].Value.Literal.IntValue);
        Assert.Equal(0L, fields[1].Value.Literal.IntValue);
    }

    [Fact]
    public void ThisChainResolvesWhenTheTargetIsDeclaredLater()
    {
        var main = TestHelpers.MainModule(TestHelpers.EncodeProgram(ForwardChainSource));
        var fields = ConstructionFields(main);

        Assert.Equal(new[] { "_x", "_y" }, fields.Select(f => f.Name).ToArray());
        Assert.Equal(3L, fields[0].Value.Literal.IntValue);
        Assert.Equal(7L, fields[1].Value.Literal.IntValue);
    }

    /// <summary>The end-to-end proof — the encoded program is compiled back to
    /// C# and executed. A silently wrong field mapping (the exact defect class
    /// slice B had to fix once) prints the wrong number here and nowhere
    /// else.</summary>
    [Theory]
    [InlineData(nameof(BackwardChainSource), "3\n")]
    [InlineData(nameof(ForwardChainSource), "10\n")]
    public void ChainedConstructionEncodesCompilesAndRuns(string which, string expected)
    {
        var source = which == nameof(BackwardChainSource) ? BackwardChainSource : ForwardChainSource;
        var output = CSharpRunner.Run(CSharpCompiler.Compile(TestHelpers.EncodeProgram(source)));
        Assert.Equal(expected, output);
    }

    /// <summary>
    /// A REGRESSION GUARD added alongside the fix, deliberately not a
    /// red-before-green test: <c>: base(...)</c> already threw before this
    /// slice and must keep throwing. Resolving a base chain needs the
    /// SUPERCLASS's own <c>CtorShapes</c> and field list — a materially bigger
    /// scope decision — so a half-finished fix that routed a base chain through
    /// the same-class path would silently build a message from the wrong
    /// class's fields. The message must name the class and say this-vs-base.
    /// </summary>
    [Fact]
    public void BaseChainStillThrowsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            public class Shape
            {
                private int _sides;

                public Shape(int sides)
                {
                    _sides = sides;
                }
            }

            public class Square : Shape
            {
                public Square() : base(4)
                {
                }

                public static void Main()
                {
                    System.Console.WriteLine("square");
                }
            }
            """));
        Assert.Contains("Square", ex.Message);
        Assert.Contains("base(", ex.Message);
    }

    /// <summary>
    /// A <c>this(...)</c> chain whose argument count matches no sibling
    /// constructor is a loud error, not a silently dropped field set. (C#
    /// itself would reject this too; a syntax-only encoder must still say so
    /// rather than emit an empty message.)
    /// </summary>
    [Fact]
    public void ThisChainWithNoMatchingTargetThrowsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            public class Point
            {
                private int _x;

                public Point(int x)
                {
                    _x = x;
                }

                public Point(int x, int y, int z) : this(x, y)
                {
                }

                public static void Main()
                {
                    System.Console.WriteLine("point");
                }
            }
            """));
        Assert.Contains("Point", ex.Message);
        Assert.Contains("this(", ex.Message);
    }

    /// <summary>The <c>new Point(3)</c> construction inside <c>Main</c>, as its
    /// ordered field list.</summary>
    private static List<FieldValuePair> ConstructionFields(Module main)
    {
        var mainFn = main.Functions.Single(f => f.Name == "Main");
        var creation = FindMessageCreation(mainFn.Body, "main:Point");
        Assert.NotNull(creation);
        return creation!.Fields.ToList();
    }

    private static MessageCreation? FindMessageCreation(Expression? expr, string typeName)
    {
        if (expr is null)
        {
            return null;
        }

        switch (expr.ExprCase)
        {
            case Expression.ExprOneofCase.MessageCreation:
                if (expr.MessageCreation.TypeName == typeName)
                {
                    return expr.MessageCreation;
                }

                return expr.MessageCreation.Fields
                    .Select(f => FindMessageCreation(f.Value, typeName))
                    .FirstOrDefault(m => m is not null);
            case Expression.ExprOneofCase.Call:
                return FindMessageCreation(expr.Call.Input, typeName);
            case Expression.ExprOneofCase.FieldAccess:
                return FindMessageCreation(expr.FieldAccess.Object, typeName);
            case Expression.ExprOneofCase.Lambda:
                return FindMessageCreation(expr.Lambda.Body, typeName);
            case Expression.ExprOneofCase.Block:
                foreach (var stmt in expr.Block.Statements)
                {
                    var found = FindMessageCreation(
                        stmt.StmtCase == Statement.StmtOneofCase.Let ? stmt.Let.Value : stmt.Expression,
                        typeName);
                    if (found is not null)
                    {
                        return found;
                    }
                }

                return FindMessageCreation(expr.Block.Result, typeName);
            default:
                return null;
        }
    }
}
