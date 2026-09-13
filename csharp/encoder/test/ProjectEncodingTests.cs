using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.V1;
using Google.Protobuf;

namespace Ball.Encoder.Tests;

/// <summary>
/// The project-wide, semantic-model-backed encode seam — <see cref="CSharpEncoder.EncodeProject"/>
/// (issue #492, W12-C slice 1).
///
/// <para><b>What was wrong.</b> Every entry point this encoder had was syntax-only: it parsed
/// ONE file with <c>CSharpSyntaxTree.ParseText</c> and rebuilt its whole symbol table
/// (<c>ClassNames</c>/<c>ClassFields</c>/<c>MethodParams</c>) from that file's own declarations.
/// Three consequences were measured across the four Tier A pins: a callee declared in a sibling
/// file could not be resolved at all (44 files), a project's own extension methods looked like
/// instance calls with no route (15 files), and <c>nameof(x)</c> had no model to fold to a
/// constant. The same syntax-only keying also made two DISTINCT types sharing one short name
/// collapse into one <c>main:</c> name with no error — 13 occurrences over 828 type symbols in
/// the corpus, silent in every one of them.</para>
///
/// <para><b>Why the existing tests could not catch it.</b> Every other suite here hand-authors a
/// single, self-contained C# snippet (see <c>TestHelpers</c>'s doc comment) — a shape by
/// construction free of cross-file references — and the one committed multi-file bucket
/// (<c>d_cross_file_caller.cs</c> + <c>d_cross_file_callee.cs</c>) was declared
/// <c>MustEncode: false</c>, i.e. asserted to FAIL. Nothing in CI ever handed this encoder two
/// files that belonged together, so nothing could observe the gap.</para>
///
/// <para><b>The blast-radius guard.</b>
/// <see cref="EncodeSingleFile_IsByteIdenticalToACommittedGolden"/> pins
/// <see cref="CSharpEncoder.Encode"/>'s output against a committed golden, so the seam cannot
/// leak into the resolution-free path — the same structural guarantee
/// <c>dart/encoder/lib/encoder.dart</c> states for <c>encode(String)</c> ("byte-identical to
/// before — which is what keeps every self-hosted engine unaffected").</para>
/// </summary>
public class ProjectEncodingTests
{
    private static string FixtureDirectory(string name) =>
        Path.Combine(AppContext.BaseDirectory, "fixtures", name);

    private static Ball.V1.Program EncodeFixtureProject(string name) =>
        CSharpEncoder.EncodeProject(FixtureDirectory(name)).Program;

    private static Module MainModule(Ball.V1.Program program) =>
        program.Modules.Single(m => m.Name == "main");

    private static FunctionDefinition Function(Ball.V1.Program program, string name) =>
        MainModule(program).Functions.Single(f => f.Name == name);

    /// <summary>Every <c>call</c> node in a function body, flattened.</summary>
    private static List<FunctionCall> Calls(FunctionDefinition function)
    {
        var found = new List<FunctionCall>();
        Walk(function.Body);
        return found;

        void Walk(Expression? expr)
        {
            if (expr is null)
            {
                return;
            }

            switch (expr.ExprCase)
            {
                case Expression.ExprOneofCase.Call:
                    found.Add(expr.Call);
                    Walk(expr.Call.Input);
                    break;
                case Expression.ExprOneofCase.FieldAccess:
                    Walk(expr.FieldAccess.Object);
                    break;
                case Expression.ExprOneofCase.MessageCreation:
                    foreach (var field in expr.MessageCreation.Fields)
                    {
                        Walk(field.Value);
                    }

                    break;
                case Expression.ExprOneofCase.Literal when expr.Literal.ValueCase == Literal.ValueOneofCase.ListValue:
                    foreach (var element in expr.Literal.ListValue.Elements)
                    {
                        Walk(element);
                    }

                    break;
                case Expression.ExprOneofCase.Block:
                    foreach (var statement in expr.Block.Statements)
                    {
                        switch (statement.StmtCase)
                        {
                            case Statement.StmtOneofCase.Let:
                                Walk(statement.Let.Value);
                                break;
                            case Statement.StmtOneofCase.Expression:
                                Walk(statement.Expression);
                                break;
                        }
                    }

                    Walk(expr.Block.Result);
                    break;
                case Expression.ExprOneofCase.Lambda:
                    Walk(expr.Lambda.Body);
                    break;
            }
        }
    }

    private static FunctionCall SingleCallTo(FunctionDefinition function, string module, string name) =>
        Calls(function).Single(c => c.Module == module && c.Function == name);

    // ════════════════════════════════════════════════════════════
    // Route family 1 — source symbols
    // ════════════════════════════════════════════════════════════

    /// <summary>A callee declared in a SIBLING file resolves, and its input is keyed by the
    /// callee's real parameter name (<c>value</c>) rather than a positional fallback — the
    /// three facts <c>IMethodSymbol</c> supplies that syntax alone cannot.</summary>
    [Fact]
    public void EncodeProject_ResolvesACalleeDeclaredInASiblingFile()
    {
        var program = EncodeFixtureProject("project");

        // The callee itself was encoded, from the other file, into the same module.
        Assert.Equal("value", Function(program, "MathHelper_Square").Metadata.Fields["params"]
            .ListValue.Values.Single().StringValue);

        var call = SingleCallTo(Function(program, "Main"), string.Empty, "MathHelper_Square");
        Assert.Equal(Expression.ExprOneofCase.Reference, call.Input.ExprCase);
        Assert.Equal("seed", call.Input.Reference.Name);
    }

    /// <summary>A project-declared extension method routes through its UNREDUCED static
    /// signature — <c>squared.Doubled()</c> becomes a call to <c>NumberExtensions_Doubled</c>
    /// with the receiver bound to that static method's first parameter. Name-based dispatch
    /// cannot reach this shape at all: the call site looks like an instance method on
    /// <c>int</c>.</summary>
    [Fact]
    public void EncodeProject_RoutesAnExtensionMethodThroughItsUnreducedStaticSignature()
    {
        var program = EncodeFixtureProject("project");
        var call = SingleCallTo(Function(program, "Main"), string.Empty, "NumberExtensions_Doubled");

        // One parameter, so the receiver is the bare input (the single-argument convention),
        // NOT a `self`-keyed message — this is a static call, not an instance dispatch.
        Assert.Equal(Expression.ExprOneofCase.Reference, call.Input.ExprCase);
        Assert.Equal("squared", call.Input.Reference.Name);
    }

    /// <summary><c>nameof(MathHelper)</c> folds to the constant string Roslyn already computed,
    /// instead of encoding an unresolvable user call to a function named <c>nameof</c>.</summary>
    [Fact]
    public void EncodeProject_ResolvesNameofToItsConstantString()
    {
        var program = EncodeFixtureProject("project");
        var main = Function(program, "Main");

        Assert.DoesNotContain(Calls(main), c => c.Function == "nameof");

        var let = main.Body.Block.Statements.Single(s =>
            s.StmtCase == Statement.StmtOneofCase.Let && s.Let.Name == "label");
        Assert.Equal("MathHelper", let.Let.Value.Literal.StringValue);
    }

    /// <summary>The positive control for the receiver-typed guard: a receiver that DOES bind,
    /// and binds to <c>System.String</c>, keeps today's <c>string_contains</c> route.</summary>
    [Fact]
    public void EncodeProject_KeepsTheStringRouteWhenTheReceiverBindsToString()
    {
        var program = EncodeFixtureProject("project");
        var call = SingleCallTo(Function(program, "Main"), "std", "string_contains");
        Assert.Equal("label", call.Input.MessageCreation.Fields[0].Value.Reference.Name);
    }

    /// <summary>The end-to-end proof: the encoded project compiles back through
    /// <see cref="CSharpCompiler"/> and RUNS, printing exactly what the C# project itself
    /// prints. #578's lesson — an encode-only assertion once declared a bucket closed while its
    /// output crashed at run time.</summary>
    [Fact]
    public void EncodeProject_EncodedOutputCompilesAndRuns()
    {
        var program = EncodeFixtureProject("project");
        Assert.Equal("Main", program.EntryFunction);
        Assert.Equal("49\n98\nMathHelper\n", CSharpRunner.Run(CSharpCompiler.Compile(program)));
    }

    // ════════════════════════════════════════════════════════════
    // Symbol-keyed declarations — collisions and partials
    // ════════════════════════════════════════════════════════════

    /// <summary>Two DISTINCT type symbols sharing one short name is a loud error naming both
    /// fully-qualified types — not two silent <c>main:Box</c> declarations in one module.</summary>
    [Fact]
    public void EncodeProject_FailsLoudOnADuplicateShortName()
    {
        var error = Assert.Throws<EncoderException>(() => EncodeFixtureProject("project_collision"));
        Assert.Contains("A.Box", error.Message);
        Assert.Contains("B.Box", error.Message);
        Assert.Contains("alpha.cs", error.Message);
        Assert.Contains("beta.cs", error.Message);
    }

    /// <summary>Two syntax parts of ONE symbol are the opposite case: they merge into a single
    /// <c>main:Counter</c> carrying every field and every method from both parts.</summary>
    [Fact]
    public void EncodeProject_MergesPartialTypeParts()
    {
        var program = EncodeFixtureProject("project_partial");
        var counter = MainModule(program).TypeDefs.Single(t => t.Name == "main:Counter");

        Assert.Equal(["Start", "Step"], counter.Descriptor_.Field.Select(f => f.Name).ToArray());
        Assert.Contains(MainModule(program).Functions, f => f.Name == "Counter.Doubled");
        Assert.Contains(MainModule(program).Functions, f => f.Name == "Counter.Tripled");
        Assert.Equal("8\n15\n", CSharpRunner.Run(CSharpCompiler.Compile(program)));
    }

    // ════════════════════════════════════════════════════════════
    // Failure modes — all loud
    // ════════════════════════════════════════════════════════════

    /// <summary>An unbindable receiver on a receiver-discriminated route is an ERROR in project
    /// mode, never a fallback to the name heuristic — that fallback would be a silent fail-soft
    /// inside the mode advertised as symbol-grade.</summary>
    [Fact]
    public void EncodeProject_FailsLoudWhenAReceiverDiscriminatedCallCannotBind()
    {
        var error = Assert.Throws<EncoderException>(
            () => EncodeFixtureProject("project_unbound_receiver"));
        Assert.Contains("unbound.cs", error.Message);
        Assert.Contains("Contains", error.Message);
    }

    /// <summary>…and the SAME text under the resolution-free entry point still returns today's
    /// answer, unchanged: no model was ever promised there.</summary>
    [Fact]
    public void EncodeSingleFile_KeepsTodaysAnswerForAnUnbindableReceiver()
    {
        var source = File.ReadAllText(
            Path.Combine(FixtureDirectory("project_unbound_receiver"), "unbound.cs"));
        var program = CSharpEncoder.EncodeLibrary(source);
        SingleCallTo(Function(program, "Unbound_Check"), "std", "string_contains");
    }

    [Fact]
    public void EncodeProject_FailsLoudOnAMissingDirectory()
    {
        var missing = Path.Combine(Path.GetTempPath(), "ball-no-such-project-" + Guid.NewGuid().ToString("N"));
        var error = Assert.Throws<EncoderException>(() => CSharpEncoder.EncodeProject(missing));
        Assert.Contains(missing, error.Message);
    }

    [Fact]
    public void EncodeProject_FailsLoudOnADirectoryWithNoSources()
    {
        var empty = Path.Combine(Path.GetTempPath(), "ball-empty-project-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(empty);
        try
        {
            var error = Assert.Throws<EncoderException>(() => CSharpEncoder.EncodeProject(empty));
            Assert.Contains(empty, error.Message);
        }
        finally
        {
            Directory.Delete(empty, recursive: true);
        }
    }

    /// <summary>An EMPTY reference list is a loud error, never "compile with no references" —
    /// a reference-less compilation makes every BCL symbol silently unresolvable, which is
    /// exactly the wrong-answer-instead-of-no-answer failure this seam exists to remove.</summary>
    [Fact]
    public void EncodeProject_FailsLoudOnAnEmptyReferenceList()
    {
        var error = Assert.Throws<EncoderException>(() => CSharpEncoder.EncodeProject(
            FixtureDirectory("project"),
            new ProjectEncodeOptions { ReferencePaths = [] }));
        Assert.Contains("reference", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>A reference path that cannot be read is a loud error naming the path. Never
    /// continue with a PARTIAL reference set: a half-referenced compilation answers wrongly,
    /// not not-at-all.</summary>
    [Fact]
    public void EncodeProject_FailsLoudOnAnUnreadableReference()
    {
        var bogus = Path.Combine(Path.GetTempPath(), "ball-no-such-ref-" + Guid.NewGuid().ToString("N") + ".dll");
        var error = Assert.Throws<EncoderException>(() => CSharpEncoder.EncodeProject(
            FixtureDirectory("project"),
            new ProjectEncodeOptions { ReferencePaths = [bogus] }));
        Assert.Contains(bogus, error.Message);
    }

    /// <summary>Compilation diagnostics from the INPUT are surfaced, never swallowed: the
    /// unbound-receiver fixture's own <c>CS0246</c> must reach the caller.</summary>
    [Fact]
    public void EncodeProject_SurfacesCompilationDiagnostics()
    {
        var project = CSharpEncoder.CreateProjectCompilation(FixtureDirectory("project_unbound_receiver"));
        Assert.Contains(project.CompilationDiagnostics, d => d.Contains("CS0246", StringComparison.Ordinal));

        // …and a clean project reports none, so the assertion above is not vacuous.
        Assert.Empty(CSharpEncoder.CreateProjectCompilation(FixtureDirectory("project")).CompilationDiagnostics);
    }

    /// <summary>The per-file seam Tier A uses (the C# analogue of
    /// <c>dart/encoder</c>'s <c>PackageEncoder.prepareStaticTypes()</c> followed by a per-file
    /// <c>encode()</c>): the compilation is built ONCE over the directory, then each file is
    /// encoded independently with its own <see cref="Microsoft.CodeAnalysis.SemanticModel"/>.
    /// This keeps the Tier A funnel on its file-at-a-time basis — a whole-project,
    /// abort-on-first-error encode could not produce a comparable per-file number at all.</summary>
    [Fact]
    public void EncodeFileInProject_EncodesOneFileWithProjectWideSemantics()
    {
        var project = CSharpEncoder.CreateProjectCompilation(FixtureDirectory("project"));
        Assert.Equal(3, project.Files.Count);

        var caller = project.Files.Single(f => f.EndsWith("program.cs", StringComparison.Ordinal));
        var program = CSharpEncoder.EncodeFileInProject(project, caller);

        // Only THIS file's declarations are in the module…
        Assert.DoesNotContain(MainModule(program).Functions, f => f.Name == "MathHelper_Square");

        // …yet the cross-file callee still resolved, because the SEMANTICS are project-wide.
        var call = SingleCallTo(Function(program, "Main"), string.Empty, "MathHelper_Square");
        Assert.Equal("seed", call.Input.Reference.Name);
    }

    // ════════════════════════════════════════════════════════════
    // Blast-radius guard
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// <see cref="CSharpEncoder.Encode"/> never builds a compilation and never binds a semantic
    /// query, so its output is byte-identical to before this seam existed. The golden is the
    /// canonical proto3-JSON of the committed bucket (e) fixture, produced on <c>origin/main</c>
    /// before any of W12-C's source changes. It must never be relaxed: it is the structural
    /// guard that keeps the resolution-free path — the one every other consumer of this encoder
    /// uses — out of the seam's blast radius.
    /// </summary>
    [Fact]
    public void EncodeSingleFile_IsByteIdenticalToACommittedGolden()
    {
        var source = File.ReadAllText(Path.Combine(
            AppContext.BaseDirectory, "fixtures", "realworld", "e_lambda_and_predefined_types.cs"));
        var golden = BallJson.Load(Path.Combine(
            AppContext.BaseDirectory, "fixtures", "goldens", "e_lambda_and_predefined_types.ball.json"));

        Assert.Equal(
            JsonFormatter.Default.Format(golden),
            JsonFormatter.Default.Format(CSharpEncoder.Encode(source)));
    }
}
