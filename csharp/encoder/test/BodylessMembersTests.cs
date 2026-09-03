using System.Linq;

namespace Ball.Encoder.Tests;

/// <summary>
/// Bodyless class members (issue #492, slice A — taxonomy buckets b and g).
///
/// <para>An interface method or an <c>abstract</c> method has no body to encode. The encoder
/// used to throw on it (<c>method `IShape.Area` has no body</c>), which rejected every file
/// declaring an interface or an abstract base class. It now OMITS the member from
/// <c>Module.Functions</c> instead.</para>
///
/// <para><b>Why omit rather than emit <c>IsBase = true</c>?</b> <c>CSharpCompiler</c>'s
/// class-member REGISTRATION loop — the one that populates <c>_classMembersByOwner</c>, which
/// <c>TypeEmit.cs</c>'s <c>CompileClassMembers</c>/<c>CompileMethodImpl</c> consume — has its
/// own <c>if (func.IsBase) { continue; }</c> guard evaluated BEFORE the dotted-name split. So
/// an <c>IsBase = true</c> class member is filtered out of <c>_classMembersByOwner</c>
/// entirely and never reaches <c>CompileMethodImpl</c>: the member would simply VANISH from
/// the compiled class with no diagnostic. Omitting it in the encoder is the minimal,
/// encoder-only fix with the same end state and no misleading IR. It costs nothing
/// semantically either — Ball dispatch always resolves by the receiver's concrete runtime
/// type (the <c>message_creation</c>'s <c>type_name</c>), never by the interface/abstract
/// declaring type, so an abstract member is unreachable at run time by construction.</para>
/// </summary>
public class BodylessMembersTests
{
    private const string InterfaceSource = """
        public interface IShape
        {
            double Area();
        }

        public class Circle : IShape
        {
            private double _r;

            public Circle(double r)
            {
                _r = r;
            }

            public double Area()
            {
                return _r * _r;
            }
        }

        public class Program
        {
            public static void Main()
            {
                var c = new Circle(2.0);
                System.Console.WriteLine(c.Area());
            }
        }
        """;

    private const string AbstractSource = """
        public abstract class Shape
        {
            public abstract double Area();
        }

        public class Program
        {
            public static void Main()
            {
                System.Console.WriteLine("area");
            }
        }
        """;

    [Fact]
    public void InterfaceMethodIsOmittedFromModuleFunctions()
    {
        var program = TestHelpers.EncodeProgram(InterfaceSource);
        var main = TestHelpers.MainModule(program);

        Assert.DoesNotContain(main.Functions, f => f.Name == "main:IShape.Area");

        // The declaration itself still round-trips as a TypeDefinition — only the
        // signature-only member is dropped.
        Assert.Contains(main.TypeDefs, t => t.Name == "main:IShape");
    }

    [Fact]
    public void AbstractMethodIsOmittedFromModuleFunctions()
    {
        var program = TestHelpers.EncodeProgram(AbstractSource);
        var main = TestHelpers.MainModule(program);

        Assert.DoesNotContain(main.Functions, f => f.Name == "main:Shape.Area");
        Assert.Contains(main.TypeDefs, t => t.Name == "main:Shape");
    }

    /// <summary>Regression guard: dropping the abstract declaration must not drop the
    /// concrete implementation in the same file, nor change how a call site dispatches to it.
    /// </summary>
    [Fact]
    public void ConcreteImplementationInTheSameFileStillEncodesAndDispatches()
    {
        var program = TestHelpers.EncodeProgram(InterfaceSource);
        var main = TestHelpers.MainModule(program);

        var area = main.Functions.Single(f => f.Name == "main:Circle.Area");
        Assert.NotNull(area.Body);
        Assert.False(area.Metadata.Fields.ContainsKey("is_static"));

        // `c.Area()` still packs its receiver under the literal `self` field and targets the
        // method's short name — the runtime-type dispatch convention, unchanged.
        // `Console.WriteLine(X)` encodes as `std.print(message: std.to_string(value: X))`.
        var mainFn = main.Functions.Single(f => f.Name == "Main");
        var print = mainFn.Body.Block.Statements[1].Expression;
        Assert.Equal("print", print.Call.Function);
        var toString = print.Call.Input.MessageCreation.Fields.Single(f => f.Name == "message").Value;
        Assert.Equal("to_string", toString.Call.Function);
        var call = toString.Call.Input.MessageCreation.Fields.Single(f => f.Name == "value").Value;
        Assert.Equal("Area", call.Call.Function);
        Assert.Equal("c", call.Call.Input.MessageCreation.Fields.Single(f => f.Name == "self").Value.Reference.Name);
    }
}
