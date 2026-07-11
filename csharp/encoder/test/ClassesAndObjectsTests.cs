using System.Linq;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>Classes → <see cref="TypeDefinition"/> + <c>DescriptorProto</c> fields; methods →
/// dispatch metadata; object creation → <see cref="MessageCreation"/> (issue #382's "classes
/// with fields+methods... object initializers" checklist item).</summary>
public class ClassesAndObjectsTests
{
    private const string PointSource = """
        class Point
        {
            public int X;
            public int Y;

            public int SumCoords()
            {
                return X + Y;
            }

            public static Point Origin()
            {
                return new Point { X = 0, Y = 0 };
            }
        }

        class Program
        {
            static void Main()
            {
                var p = new Point { X = 3, Y = 4 };
                var sum = p.SumCoords();
                var origin = Point.Origin();
            }
        }
        """;

    [Fact]
    public void EncodesClassAsTypeDefinitionWithDescriptorFields()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainModule = TestHelpers.MainModule(program);
        var pointType = mainModule.TypeDefs.Single(t => t.Name == "main:Point");

        Assert.NotNull(pointType.Descriptor_);
        Assert.Equal(new[] { "X", "Y" }, pointType.Descriptor_.Field.Select(f => f.Name));
        Assert.Equal("class", pointType.Metadata.Fields["kind"].StringValue);
    }

    [Fact]
    public void EncodesInstanceMethodWithQualifiedNameAndSelfConvention()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainModule = TestHelpers.MainModule(program);
        var method = mainModule.Functions.Single(f => f.Name == "main:Point.SumCoords");

        Assert.Equal("method", method.Metadata.Fields["kind"].StringValue);
        Assert.False(method.Metadata.Fields.ContainsKey("is_static"));

        // Body reads fields via field_access(reference("self"), field) — never a bare name —
        // see CSharpEncoder's module doc comment on the reference-engine `self` convention.
        var returnCall = method.Body.Block.Statements[0].Expression;
        Assert.Equal("return", returnCall.Call.Function);
        var addCall = returnCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("add", addCall.Call.Function);
        var left = addCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal(Expression.ExprOneofCase.FieldAccess, left.ExprCase);
        Assert.Equal("self", left.FieldAccess.Object.Reference.Name);
        Assert.Equal("X", left.FieldAccess.Field);
    }

    [Fact]
    public void EncodesStaticMethodAsQualifiedTopLevelFunction()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainModule = TestHelpers.MainModule(program);
        var method = mainModule.Functions.Single(f => f.Name == "Point_Origin");
        Assert.True(method.Metadata.Fields["is_static"].BoolValue);
    }

    [Fact]
    public void ObjectInitializerFieldsMatchDeclaredNames()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var creation = mainFn.Body.Block.Statements[0].Let.Value;
        Assert.Equal(Expression.ExprOneofCase.MessageCreation, creation.ExprCase);
        Assert.Equal("main:Point", creation.MessageCreation.TypeName);
        Assert.Equal("X", creation.MessageCreation.Fields[0].Name);
        Assert.Equal(3, creation.MessageCreation.Fields[0].Value.Literal.IntValue);
        Assert.Equal("Y", creation.MessageCreation.Fields[1].Name);
        Assert.Equal(4, creation.MessageCreation.Fields[1].Value.Literal.IntValue);
    }

    [Fact]
    public void InstanceMethodCallPacksReceiverUnderSelfField()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var call = mainFn.Body.Block.Statements[1].Let.Value;
        Assert.Equal(Expression.ExprOneofCase.Call, call.ExprCase);
        Assert.Equal(string.Empty, call.Call.Module);
        Assert.Equal("SumCoords", call.Call.Function);
        var selfField = call.Call.Input.MessageCreation.Fields.Single(f => f.Name == "self");
        Assert.Equal("p", selfField.Value.Reference.Name);
    }

    [Fact]
    public void StaticMethodCalledViaTypeNameResolvesToQualifiedFunction()
    {
        var program = TestHelpers.EncodeProgram(PointSource);
        var mainFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var call = mainFn.Body.Block.Statements[2].Let.Value;
        Assert.Equal("Point_Origin", call.Call.Function);
        Assert.Equal(string.Empty, call.Call.Module);
    }

    [Fact]
    public void RecursiveStaticMethodCallsItselfByQualifiedName()
    {
        const string source = """
            class MathHelper
            {
                static int Fib(int n)
                {
                    if (n <= 1)
                    {
                        return n;
                    }

                    return Fib(n - 1) + Fib(n - 2);
                }
            }

            class Program
            {
                static void Main()
                {
                    var r = MathHelper.Fib(5);
                }
            }
            """;
        var program = TestHelpers.EncodeProgram(source);
        var fibFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "MathHelper_Fib");
        // statements[0] is the `if (n <= 1) { return n; }`; the unconditional
        // `return Fib(n - 1) + Fib(n - 2);` is statements[1].
        var addCall = fibFn.Body.Block.Statements[1].Expression;
        Assert.Equal("return", addCall.Call.Function);
        var addExpr = addCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("add", addExpr.Call.Function);
        var recursiveCall = addExpr.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("MathHelper_Fib", recursiveCall.Call.Function);
    }
}
