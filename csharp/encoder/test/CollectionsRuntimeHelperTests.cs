using System;
using System.Collections.Generic;
using System.Linq;
using Ball.Compiler;
using Ball.Encoder;
using Ball.Shared;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// The <c>std_collections</c> half of <c>encoder/src/RuntimeHelpers.cs</c>'s helper table
/// (issue #689).
///
/// <para>Every <c>std_collections</c> base call <c>Ball.Compiler</c> emits — <c>list_push</c>,
/// <c>map_get</c>, <c>set_create</c>, <c>list_sort</c>, … — lowers to exactly the shape that
/// table already expresses: one <c>BallRuntime.&lt;Helper&gt;(a, b, …)</c> call of fixed arity
/// whose positional arguments fill that base function's NAMED input fields
/// (<c>compiler/src/BaseCall.cs</c>'s <c>CompileCollectionsCall</c>). They were nevertheless
/// ABSENT from it — not wrong in it — for one structural reason: a row named a function but never
/// a MODULE, and the only emitter it had was <c>Builders.StdCall</c>, which hard-codes
/// <c>module = "std"</c>. So every collections helper fell through to the encoder's loud refusal
/// (<c>unsupported runtime helper `BallRuntime.ListPush(...)`</c>), and that refusal was the
/// largest single family of first blockers left in the <c>csharp-roundtrip</c> matrix row once
/// #730 and #780 had closed the dispatch preamble and the object model.</para>
///
/// <para><b>This is a closed-set gate, derived from two in-solution sources of truth</b> rather
/// than from a hand-copied list of helper names:</para>
/// <list type="number">
///   <item><see cref="StdModuleBuilders.BuildStdCollectionsModule"/> — the declaration of every
///   <c>std_collections</c> base function AND of the input type whose fields name its
///   arguments;</item>
///   <item><see cref="CSharpCompiler"/> itself — each probe program is COMPILED, so the C# the
///   encoder is asked to read back is the compiler's real emission, never a hand-written
///   imitation of it.</item>
/// </list>
///
/// <para>Each probe packs every declared field of a function's input type with a distinct string
/// marker named after that field, compiles the call, re-encodes the emitted C#, and requires the
/// call to come back as <c>std_collections.&lt;the same function&gt;</c> with every surviving
/// field still carrying ITS OWN marker. A mis-mapped row (<c>ListPush</c> → <c>{list, index}</c>)
/// is therefore a failure rather than a silently wrong round-trip, and a helper the compiler
/// starts emitting for a newly-cased function fails here the day it is added rather than costing
/// the matrix row a fixture.</para>
///
/// <para>The compiler has no case at all for eleven declared <c>std_collections</c> functions;
/// those compile to <c>BallRuntime.UnsupportedBaseCall(...)</c>, a loud run-time throw. That is a
/// COMPILER gap, not an encoder one, so it is recorded here as an exact measured set
/// (<see cref="CompilerGaps"/>) and asserted in BOTH directions — a new gap fails, and a gap
/// somebody closes fails until it is taken off the list and given its inverse.</para>
///
/// <para>A shape assertion cannot see whether the tree it asserts actually RUNS (that is how
/// #730's first <c>ArgGet</c> cut shipped operands that throw on the reference engine with every
/// check green), so <see cref="ReferenceEngineExecutionTests"/> carries the executable half.</para>
/// </summary>
public class CollectionsRuntimeHelperTests
{
    /// <summary>
    /// The <c>std_collections</c> functions <c>compiler/src/BaseCall.cs</c>'s
    /// <c>CompileCollectionsCall</c> has NO case for — measured by
    /// <see cref="EveryCompiledCollectionsCallReEncodesToItself"/> itself, never hand-listed from
    /// reading the switch. Each compiles to
    /// <c>BallRuntime.UnsupportedBaseCall("std_collections", "&lt;fn&gt;")</c>, which throws at
    /// run time. They are listed so the set is closed in both directions, never to excuse them: a
    /// Ball program that calls any of them compiles to C# that dies when it reaches the call.
    /// </summary>
    private static readonly string[] CompilerGaps =
    {
        "list_flat_map",
        "list_foreach",
        "list_none",
        "list_reduce",
        "list_single",
        "list_sort_by",
        "list_zip",
        "map_entries",
        "map_filter",
        "map_from_entries",
        "map_map",
    };

    /// <summary>The marker a probe packs into the input field <paramref name="field"/>. Distinct
    /// per field, so a row that maps a positional argument to the WRONG input field is caught
    /// rather than passing on a coincidence.</summary>
    private static string Marker(string field) => "@" + field;

    /// <summary>
    /// A one-statement Ball program:
    /// <c>std.print(message: std_collections.&lt;function&gt;(…))</c>, whose input packs every
    /// field <paramref name="fields"/> names with that field's marker.
    /// </summary>
    private static Program BuildProbe(string function, IEnumerable<string> fields, Module collections)
    {
        var input = new MessageCreation();
        foreach (var field in fields)
        {
            input.Fields.Add(new FieldValuePair
            {
                Name = field,
                Value = new Expression { Literal = new Literal { StringValue = Marker(field) } },
            });
        }

        var call = new Expression
        {
            Call = new FunctionCall
            {
                Module = "std_collections",
                Function = function,
                Input = new Expression { MessageCreation = input },
            },
        };

        var printInput = new MessageCreation();
        printInput.Fields.Add(new FieldValuePair { Name = "message", Value = call });

        var body = new Expression { Block = new Block() };
        body.Block.Statements.Add(new Statement
        {
            Expression = new Expression
            {
                Call = new FunctionCall
                {
                    Module = "std",
                    Function = "print",
                    Input = new Expression { MessageCreation = printInput },
                },
            },
        });

        var main = new Module { Name = "main" };
        main.Functions.Add(new FunctionDefinition { Name = "main", Body = body });

        var program = new Program
        {
            Name = "collections_probe",
            EntryModule = "main",
            EntryFunction = "main",
        };
        program.Modules.Add(StdModuleBuilders.BuildStdModule());
        program.Modules.Add(collections);
        program.Modules.Add(main);
        return program;
    }

    /// <summary>
    /// The closed set: every <c>std_collections</c> function the module declares either has no
    /// compiler case (a recorded gap) or survives Ball → C# → Ball as the very same call, field
    /// for field.
    /// </summary>
    [Fact]
    public void EveryCompiledCollectionsCallReEncodesToItself()
    {
        var collections = StdModuleBuilders.BuildStdCollectionsModule();
        var inputFields = collections.TypeDefs.ToDictionary(
            t => t.Name,
            t => t.Descriptor_.Field.Select(f => f.Name).ToList(),
            StringComparer.Ordinal);

        var gapsSeen = new List<string>();
        var failures = new List<string>();
        var covered = 0;

        foreach (var function in collections.Functions)
        {
            Assert.True(
                inputFields.ContainsKey(function.InputType),
                $"{function.Name} declares input type `{function.InputType}`, which the module does not define");

            var fields = inputFields[function.InputType];
            var source = CSharpCompiler.Compile(BuildProbe(function.Name, fields, collections));

            if (source.Contains("BallRuntime.UnsupportedBaseCall", StringComparison.Ordinal))
            {
                gapsSeen.Add(function.Name);
                continue;
            }

            Expression argument;
            try
            {
                argument = PrintedArgument(CSharpEncoder.Encode(source));
            }
            catch (Exception ex)
            {
                failures.Add($"{function.Name}: {ex.Message}");
                continue;
            }

            if (argument.ExprCase != Expression.ExprOneofCase.Call)
            {
                failures.Add($"{function.Name}: re-encoded to a {argument.ExprCase}, not a call");
                continue;
            }

            var call = argument.Call;
            if (call.Module != "std_collections" || call.Function != function.Name)
            {
                failures.Add($"{function.Name}: re-encoded to `{call.Module}.{call.Function}`");
                continue;
            }

            if (call.Input is not { ExprCase: Expression.ExprOneofCase.MessageCreation } reencoded)
            {
                failures.Add($"{function.Name}: re-encoded input is not a message_creation");
                continue;
            }

            var packed = reencoded.MessageCreation.Fields
                .Where(f => f.Value.ExprCase == Expression.ExprOneofCase.Literal
                    && f.Value.Literal.ValueCase == Literal.ValueOneofCase.StringValue)
                .ToList();

            if (packed.Count == 0)
            {
                failures.Add($"{function.Name}: re-encoded input carries none of the probe's markers");
                continue;
            }

            foreach (var field in packed)
            {
                if (field.Value.Literal.StringValue != Marker(field.Name))
                {
                    failures.Add(
                        $"{function.Name}: field `{field.Name}` carries "
                        + $"`{field.Value.Literal.StringValue}`, the marker of another field");
                }

                if (!fields.Contains(field.Name))
                {
                    failures.Add(
                        $"{function.Name}: re-encoded field `{field.Name}` is not declared by "
                        + $"input type `{function.InputType}`");
                }
            }

            covered++;
        }

        Assert.Equal(
            CompilerGaps.OrderBy(n => n, StringComparer.Ordinal),
            gapsSeen.OrderBy(n => n, StringComparer.Ordinal));
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));

        // A positive floor: the gate must not pass by having exercised nothing.
        Assert.Equal(collections.Functions.Count - CompilerGaps.Length, covered);
    }

    /// <summary>
    /// The fail-loud boundary (issue #55 doctrine) covers the new rows too: a collections helper
    /// called with the wrong number of arguments is an <see cref="EncoderException"/> naming the
    /// helper, never a call encoded with a missing or invented operand.
    /// </summary>
    [Fact]
    public void ACollectionsHelperWithTheWrongArityFailsLoud()
    {
        const string source = """
            using Ball.Shared;
            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.Print(BallRuntime.ListPush(BallValue.Null));
                }
            }
            """;

        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(source));

        Assert.Contains("ListPush", ex.Message, StringComparison.Ordinal);
        Assert.Contains("expects 2 argument(s), got 1", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// A collections helper's inverse must DECLARE the module it reads through — unlike
    /// <c>std</c>, <c>std_collections</c> is an explicitly-declared module, so a program that
    /// calls <c>list_push</c> without declaring it does not resolve on any engine. This is the
    /// same <c>MarkCollectionsUsed()</c> obligation every other <c>std_collections</c> route in
    /// the encoder carries.
    /// </summary>
    [Fact]
    public void ACollectionsHelperDeclaresTheCollectionsModule()
    {
        const string source = """
            using Ball.Shared;
            internal static class BallProgram
            {
                public static void Main(string[] args)
                {
                    BallRuntime.Print(BallRuntime.ListPush(BallValue.Null, BallValue.Null));
                }
            }
            """;

        var program = CSharpEncoder.Encode(source);

        var module = program.Modules.SingleOrDefault(m => m.Name == "std_collections");
        Assert.NotNull(module);
        Assert.Contains(module!.Functions, f => f.Name == "list_push");
    }

    // ── tree walking ──────────────────────────────────────────────────────

    /// <summary>The single <c>message</c> argument of the one <c>std.print</c> in a re-encoded
    /// program, found by walking the tree rather than by assuming where the encoder put it.</summary>
    private static Expression PrintedArgument(Program program)
    {
        foreach (var module in program.Modules)
        {
            foreach (var function in module.Functions)
            {
                if (function.Body is null)
                {
                    continue;
                }

                if (FindPrint(function.Body) is { } found)
                {
                    return found;
                }
            }
        }

        throw new InvalidOperationException("the re-encoded program contains no std.print call");
    }

    private static Expression? FindPrint(Expression expression)
    {
        if (expression.ExprCase == Expression.ExprOneofCase.Call
            && expression.Call.Module == "std"
            && expression.Call.Function == "print"
            && expression.Call.Input is { ExprCase: Expression.ExprOneofCase.MessageCreation } input
            && input.MessageCreation.Fields.FirstOrDefault(f => f.Name == "message") is { } message)
        {
            return message.Value;
        }

        foreach (var child in Children(expression))
        {
            if (FindPrint(child) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    private static IEnumerable<Expression> Children(Expression expression)
    {
        switch (expression.ExprCase)
        {
            case Expression.ExprOneofCase.Call:
                if (expression.Call.Input is not null)
                {
                    yield return expression.Call.Input;
                }

                break;
            case Expression.ExprOneofCase.MessageCreation:
                foreach (var field in expression.MessageCreation.Fields)
                {
                    yield return field.Value;
                }

                break;
            case Expression.ExprOneofCase.FieldAccess:
                yield return expression.FieldAccess.Object;
                break;
            case Expression.ExprOneofCase.Lambda:
                if (expression.Lambda.Body is not null)
                {
                    yield return expression.Lambda.Body;
                }

                break;
            case Expression.ExprOneofCase.Block:
                foreach (var statement in expression.Block.Statements)
                {
                    foreach (var child in StatementChildren(statement))
                    {
                        yield return child;
                    }
                }

                if (expression.Block.Result is not null)
                {
                    yield return expression.Block.Result;
                }

                break;
            case Expression.ExprOneofCase.Literal:
                if (expression.Literal.ValueCase == Literal.ValueOneofCase.ListValue)
                {
                    foreach (var element in expression.Literal.ListValue.Elements)
                    {
                        yield return element;
                    }
                }

                break;
        }
    }

    private static IEnumerable<Expression> StatementChildren(Statement statement)
    {
        switch (statement.StmtCase)
        {
            case Statement.StmtOneofCase.Expression:
                yield return statement.Expression;
                break;
            case Statement.StmtOneofCase.Let:
                if (statement.Let.Value is not null)
                {
                    yield return statement.Let.Value;
                }

                break;
        }
    }
}
