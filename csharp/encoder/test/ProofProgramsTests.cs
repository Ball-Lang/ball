using System.Linq;

namespace Ball.Encoder.Tests;

/// <summary>
/// Issue #382's proof bar: encode ≥3 real, idiomatic C# programs and prove the encoded
/// <c>.ball.json</c> actually runs correctly. These three exact sources (byte-for-byte) were
/// encoded with this encoder and run on the DART REFERENCE ENGINE
/// (<c>dart run dart/cli/bin/ball.dart run &lt;file&gt;</c>) — the ground truth for "does the
/// encoded program actually mean what the C# source meant":
///
/// <code>
/// === hello_world ===
/// Hello, World!
///
/// === fibonacci ===
/// 0
/// 1
/// 1
/// 2
/// 3
/// 5
/// 8
/// 13
/// 21
/// 34
///
/// === factorial ===
/// 1! = 1
/// 2! = 2
/// 3! = 6
/// 4! = 24
/// 5! = 120
/// 6! = 720
/// 7! = 5040
/// 8! = 40320
/// 9! = 362880
/// 10! = 3628800
/// </code>
///
/// Every line matches the real C# semantics exactly (fib(0..9), 1!..10!). These xunit tests
/// re-run the ENCODE step (fast, in-process, CI-safe — no external `dart` process dependency)
/// and assert the structural properties that make that engine run correct: zero non-universal
/// base modules, a `Main` entry point, and (for fibonacci/factorial) genuine self-recursion
/// through the qualified static-function name.
/// </summary>
public class ProofProgramsTests
{
    private const string HelloWorldSource = "Console.WriteLine(\"Hello, World!\");";

    private const string FibonacciSource = """
        using System;

        class Program
        {
            static int Fibonacci(int n)
            {
                if (n <= 1)
                {
                    return n;
                }

                return Fibonacci(n - 1) + Fibonacci(n - 2);
            }

            static void Main()
            {
                for (int i = 0; i < 10; i++)
                {
                    Console.WriteLine(Fibonacci(i));
                }
            }
        }
        """;

    private const string FactorialSource = """
        using System;

        class Program
        {
            static long Factorial(int n)
            {
                if (n <= 1)
                {
                    return 1;
                }

                return n * Factorial(n - 1);
            }

            static void Main()
            {
                for (int i = 1; i <= 10; i++)
                {
                    Console.WriteLine($"{i}! = {Factorial(i)}");
                }
            }
        }
        """;

    private static readonly string[] UniversalModuleNames = { "std", "std_collections", "std_io", "std_memory", "main" };

    [Theory]
    [InlineData(HelloWorldSource)]
    [InlineData(FibonacciSource)]
    [InlineData(FactorialSource)]
    public void EncodesToARunnableProgramWithOnlyUniversalModules(string source)
    {
        var program = TestHelpers.EncodeProgram(source);

        Assert.Equal("main", program.EntryModule);
        Assert.Equal("Main", program.EntryFunction);
        Assert.Contains(TestHelpers.MainModule(program).Functions, f => f.Name == "Main");
        Assert.All(program.Modules, m => Assert.Contains(m.Name, UniversalModuleNames));
    }

    [Fact]
    public void HelloWorldPrintsTheLiteralGreeting()
    {
        var program = TestHelpers.EncodeProgram(HelloWorldSource);
        var mainFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var printCall = mainFn.Body.Block.Statements[0].Expression;
        Assert.Equal("print", printCall.Call.Function);
        var message = printCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("to_string", message.Call.Function);
        Assert.Equal("Hello, World!", message.Call.Input.MessageCreation.Fields[0].Value.Literal.StringValue);
    }

    [Fact]
    public void FibonacciRecursesThroughItsOwnQualifiedStaticName()
    {
        var program = TestHelpers.EncodeProgram(FibonacciSource);
        var fibFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Program_Fibonacci");
        var ifCall = fibFn.Body.Block.Statements[0].Expression;
        Assert.Equal("if", ifCall.Call.Function);

        var addCall = fibFn.Body.Block.Result;
        // The tail is null_literal() (Statements.cs's documented convention) — the real
        // computation lives in the trailing `return` statement instead.
        Assert.Equal(Ball.V1.Literal.ValueOneofCase.None, addCall.Literal.ValueCase);

        var returnCall = fibFn.Body.Block.Statements[1].Expression;
        Assert.Equal("return", returnCall.Call.Function);
        var sum = returnCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("add", sum.Call.Function);
        var leftRecursion = sum.Call.Input.MessageCreation.Fields[0].Value;
        var rightRecursion = sum.Call.Input.MessageCreation.Fields[1].Value;
        Assert.Equal("Program_Fibonacci", leftRecursion.Call.Function);
        Assert.Equal("Program_Fibonacci", rightRecursion.Call.Function);
    }

    [Fact]
    public void FactorialRecursesThroughItsOwnQualifiedStaticName()
    {
        var program = TestHelpers.EncodeProgram(FactorialSource);
        var factorialFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Program_Factorial");
        var returnCall = factorialFn.Body.Block.Statements[1].Expression;
        Assert.Equal("return", returnCall.Call.Function);
        var product = returnCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("multiply", product.Call.Function);
        var recursiveCall = product.Call.Input.MessageCreation.Fields[1].Value;
        Assert.Equal("Program_Factorial", recursiveCall.Call.Function);
    }

    [Fact]
    public void FactorialUsesStringInterpolationForOutput()
    {
        var program = TestHelpers.EncodeProgram(FactorialSource);
        var mainFn = TestHelpers.MainModule(program).Functions.Single(f => f.Name == "Main");
        var forCall = mainFn.Body.Block.Statements[0].Expression;
        var body = forCall.Call.Input.MessageCreation.Fields[3].Value;
        var printCall = body.Block.Statements[0].Expression;
        Assert.Equal("print", printCall.Call.Function);
        var message = printCall.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("to_string", message.Call.Function);
        var concatChain = message.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("concat", concatChain.Call.Function);
    }
}
