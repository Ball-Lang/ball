using System;
using System.Collections.Generic;
using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.Shared;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Issue #588 — <c>.FirstOrDefault()</c> used to share <c>.First()</c>'s two arity windows,
/// so it encoded to trees that THROW where C# returns <c>default(T)</c>.
///
/// <para><b>The defect.</b> <c>DispatchInstanceOrBuiltinMethod</c> carried
/// <c>case ("First" or "FirstOrDefault", 0) → list_first</c> and
/// <c>case ("First" or "FirstOrDefault", 1) → list_find</c>. Both targets throw when there is
/// nothing to return — <c>BallRuntime.ListFirst</c>/<c>ListFind</c> in
/// <c>csharp/shared/src/BallRuntime.cs</c>, and in the Dart REFERENCE engine
/// <c>_stdAsList(...)!.first</c> and a <c>firstWhere</c> with no <c>orElse</c>
/// (<c>dart/engine/lib/engine_std.dart</c>). That is the right contract for <c>.First()</c>
/// and <c>.First(pred)</c>, which throw in C# too. It is the exact OPPOSITE of what
/// <c>.FirstOrDefault()</c> promises, so the encoded program was silently wrong on precisely
/// the input the name exists to handle. Both arms were reproduced end-to-end before the fix:
/// encoding each shape with the real <c>ball encode</c> and running the emitted
/// <c>.ball.json</c> on the Dart reference engine threw <c>Bad state: No element</c> where
/// real C# prints <c>0</c>.</para>
///
/// <para><b>Why the fix is a subtraction, not a new route.</b> <c>default(T)</c> is
/// <c>null</c> for a reference type but <c>0</c>/<c>0.0</c>/<c>false</c>/a zeroed struct for a
/// value type, and this encoder is syntax-only (no semantic model): at
/// <c>someSequence.FirstOrDefault()</c> the element type is not written down anywhere, so it
/// cannot be recovered — unlike #578's <c>default(int)</c>, where the keyword IS the syntax.
/// A hypothetical <c>list_first_or_null</c> primitive returning <c>null</c> on empty would be
/// byte-exact for a reference <c>T</c> and WRONG for every value <c>T</c>, with nothing in the
/// encoded IR or the re-emitted C# to tell the two apart — trading one uniform loud failure
/// for a non-uniform silent one. Nor can the C# compiler target repair it later: every
/// compiled expression is a dynamically-dispatched <c>BallValue</c>, and the other engines
/// (Dart/TS/C++/Rust/Go/Python) that run the same IR have no C# type information at all. So
/// <c>FirstOrDefault</c> joins <c>LastOrDefault</c>/<c>SingleOrDefault</c> as a LOUD
/// <c>EncoderException</c>, which is the trade CLAUDE.md's fail-loud invariant asks for.</para>
///
/// <para><b>Per-<c>T</c> semantics this encoder cannot distinguish</b> —
/// <c>new List&lt;T&gt;().FirstOrDefault()</c>: <c>int</c> → <c>0</c>, <c>double</c> →
/// <c>0.0</c>, <c>bool</c> → <c>false</c>, a struct → a zeroed struct, a class/interface/
/// nullable → <c>null</c>. Only the last row is what any nullable route could produce.</para>
///
/// <para>The loud-refusal assertions live next door in
/// <see cref="ZeroArgLinqTerminalTests.OrDefaultTerminalsFailLoud"/>, which now covers all four
/// <c>*OrDefault</c> spellings with one test for one reason. This file pins the other half: the
/// real C# contract the routes were measured against, and that <c>.First()</c>'s own two routes
/// survived the arity-window split untouched.</para>
/// </summary>
public class FirstOrDefaultContractTests
{
    private const string ListPreamble = """
        using System;
        using System.Collections.Generic;
        using System.Linq;
        """;

    /// <summary>Ground truth, executed rather than asserted in prose: what real C# does for the
    /// two shapes #588 mis-routed. <c>0</c> here is <c>default(int)</c> — the value no tree in
    /// <c>std_collections</c> can produce without knowing <c>T</c>.</summary>
    [Fact]
    public void RealCSharpFirstOrDefaultReturnsTheZeroValueAndNeverThrows()
    {
        var empty = new List<int>();

        Assert.Equal(0, empty.FirstOrDefault());
        Assert.Equal(0, new List<int> { 1, 2, 3 }.FirstOrDefault(v => v > 99));

        // ... while the un-suffixed spellings throw, which is why THEY stay routed.
        Assert.Throws<InvalidOperationException>(() => empty.First());
        Assert.Throws<InvalidOperationException>(() => new List<int> { 1, 2, 3 }.First(v => v > 99));
    }

    /// <summary><c>.First()</c> and <c>.First(pred)</c> must keep BOTH of their routes: the fix
    /// narrows two arity windows by one name each, and narrowing them by one name too many
    /// would be just as wrong. Asserting the emitted function per arity is what makes a
    /// collapsed or swapped window fail here.</summary>
    [Theory]
    [InlineData("values.First()", "list_first", "list")]
    [InlineData("values.First(v => v > 1)", "list_find", "callback")]
    public void FirstKeepsBothOfItsRoutes(string expression, string function, string field)
    {
        var value = NthLetValue(OnValues($"        var x = {expression};"), 1);

        Assert.Equal("std_collections", value.Call.Module);
        Assert.Equal(function, value.Call.Function);
        Assert.Contains(value.Call.Input.MessageCreation.Fields, f => f.Name == field);
        Assert.Contains(value.Call.Input.MessageCreation.Fields, f => f.Name == "list");
    }

    /// <summary>The surviving route, proven end-to-end rather than by tree shape: <c>.First()</c>
    /// on an EMPTY list encodes, compiles back to C# and THROWS at run time — the same contract
    /// as C#'s own <c>.First()</c>, asserted above. This is the assertion that would catch the
    /// over-correction of dropping <c>First</c> along with <c>FirstOrDefault</c>, since a name
    /// with no route never reaches <see cref="CSharpCompiler"/> at all.</summary>
    [Fact]
    public void FirstOnAnEmptyListStillThrowsAtRunTime()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram(Snippet("""
                var empty = new List<int>();
                Console.WriteLine(empty.First());
            """)));

        // Since #616 that throw is a TYPED, catchable BallThrow carrying Dart's
        // StateError — not the native BallRuntimeException it used to be, which
        // sailed straight past a compiled program's own `catch (BallThrow …)`.
        var ex = Assert.Throws<BallThrow>(() => CSharpRunner.Run(compiled));

        Assert.Equal("StateError", ex.TypeName);
        Assert.Equal("Bad state: No element", ex.Payload.ToString());
    }

    /// <summary>The fix's own definition of success: <c>.FirstOrDefault()</c> now fails at
    /// ENCODE time, so it never becomes a program that compiles, runs and answers wrongly.
    /// Before the fix this snippet encoded clean, compiled clean, and threw
    /// <c>BallRuntimeException("first on an empty list")</c> out of
    /// <see cref="CSharpRunner"/> — a run-time wrong answer where C# prints <c>0</c>.</summary>
    [Fact]
    public void FirstOrDefaultNeverReachesTheCompiler()
    {
        var source = Snippet("""
                var empty = new List<int>();
                Console.WriteLine(empty.FirstOrDefault());
            """);

        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(source));

        Assert.Contains("unsupported method call", ex.Message);
        Assert.Contains("FirstOrDefault", ex.Message);
    }

    /// <summary>Wrap statement <paramref name="body"/> in a real, parseable program — the only
    /// entry point <see cref="CSharpEncoder.Encode"/> accepts.</summary>
    private static string Snippet(string body) => $$"""
        {{ListPreamble}}

        class Program
        {
            static void Main()
            {
        {{body}}
            }
        }
        """;

    /// <summary>A snippet whose statement 0 is the <c>values</c> list every tree assertion reads
    /// its receiver from, so the expression under test is always statement 1.</summary>
    private static string OnValues(string body) => Snippet($$"""
                var values = new List<int> { 1, 2, 3 };
        {{body}}
        """);

    private static Expression NthLetValue(string source, int index) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[index].Let.Value;
}
