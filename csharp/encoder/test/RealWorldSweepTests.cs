using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Ball.Encoder;

namespace Ball.Encoder.Tests;

/// <summary>
/// The real-world encoder sweep (issue #492, slice 1) — a <b>measurement</b>, not
/// a gate.
///
/// <para>Every other suite in this project hand-authors single-file snippets
/// that already satisfy <see cref="CSharpEncoder.Encode"/>'s scope (see
/// <c>TestHelpers</c>'s own doc comment: "Every test wraps a snippet in a real,
/// parseable C# source ... since CSharpEncoder.Encode always requires a genuine
/// Main entry point"). The conformance corpus is generated from Ball via the
/// <em>Dart</em> encoder and never runs real C# through <c>Ball.Encoder</c> at
/// all, and the one leg that does invoke it end to end
/// (<c>csharp/engine/conformance --leg=roundtrip</c>) is not CI-gated and already
/// sits at an unrelated honest 0/320. So nothing in CI has ever handed this
/// encoder library-shaped C#, and its real-world coverage went unmeasured until
/// #492 measured it by hand at 0 of 200 files.</para>
///
/// <para>This sweep is that measurement, committed: one hand-authored fixture per
/// taxonomy bucket from #492, fed through the encoder, with a CI-parseable
/// <c>Results:</c> line. Hand-authored deliberately — no network fetch and no
/// third-party licensing (that is #493's scope).</para>
///
/// <para><b>It must never assert on the passed count.</b> Today that count is 0
/// by design; asserting <c>N &gt; 0</c> would make it a permanently-red gate, and
/// asserting <c>N == 0</c> would make it block the very slices that fix these
/// buckets. It asserts only that the sweep actually ran (a positive floor — "0
/// failed" over "0 ran" is a fake green), that the fixture set shipped beside the
/// test binary is <em>exactly</em> the declared taxonomy (compared against a real
/// directory listing, in both directions, so a lost fixture and a fixture added
/// without being wired in both fail), and that every failure is a deliberate
/// <see cref="EncoderException"/> rather than a crash. Each later slice raises
/// the number in the printed baseline.</para>
/// </summary>
public class RealWorldSweepTests(ITestOutputHelper output)
{
    private readonly ITestOutputHelper _output = output;

    /// <summary>
    /// The one committed file that is <em>not</em> a sweep entry: bucket (d)'s
    /// sibling declaration, which exists only so the caller has an out-of-file
    /// callee to fail on.
    /// </summary>
    private const string CalleeOnlyFixture = "d_cross_file_callee.cs";

    /// <summary>
    /// The taxonomy buckets from #492, one committed fixture each. This table is
    /// the sweep's labels and expected-failure reasons; the fixture *set* is
    /// checked against the shipped directory (see
    /// <see cref="DiscoverFixtureFiles"/>) so that adding a fixture without
    /// wiring it in, or losing one, is a failure rather than a silently
    /// different sweep.
    /// </summary>
    private static readonly (string Bucket, string File, string Expectation)[] Fixtures =
    [
        ("a: namespaced class library, no Main", "a_namespaced_library_no_main.cs",
            "no library mode — Encode requires a `Main` entry point (CSharpEncoder.cs's hasMain check)"),
        ("b: interface with a method", "b_interface_with_method.cs",
            "bodyless interface member (Types.cs's `method has no body` gap) — NOT the `unsupported type declaration kind` site, which only catches `enum`"),
        ("c: class with two constructors", "c_two_constructors.cs",
            "construction is field-mapping only, so at most one constructor per class (Encoder.cs)"),
        ("d: call into a type declared in a sibling file", "d_cross_file_caller.cs",
            "no cross-file symbol table — the encoder sees one file per Encode() call"),
        ("e: lambda / PredefinedType-heavy expression", "e_lambda_and_predefined_types.cs",
            "explicitly typed lambda parameters and generic collection initializers"),
        ("f: target-typed new()", "f_target_typed_new.cs",
            "a target-typed `new()` carries no type name for a message_creation"),
        ("g: abstract method with no body", "g_abstract_method_no_body.cs",
            "abstract/partial/extern members are a documented gap (Types.cs)"),
    ];

    [Fact]
    public void RealWorldSweep_ReportsHonestBaseline()
    {
        // The set actually swept is derived from what shipped beside the test
        // binary, not from the table below — otherwise the "intact fixture set"
        // claim would be unfalsifiable (a table can only ever agree with
        // itself). A fixture that stops being copied shrinks this list; one
        // added without a taxonomy entry lengthens it; either way the equality
        // in AssertFixtureSetIsIntact fails.
        var swept = AssertFixtureSetIsIntact();

        var results = new List<(string Bucket, bool Encoded, string Detail)>();
        foreach (var (bucket, file, expectation) in Fixtures)
        {
            var source = ReadFixture(file);
            try
            {
                CSharpEncoder.Encode(source);
                results.Add((bucket, true, "encoded"));
            }
            catch (EncoderException ex)
            {
                results.Add((bucket, false, Summarize(ex.Message)));
            }
        }

        var passed = results.Count(r => r.Encoded);
        var report = new StringBuilder();
        report.Append($"Results: {passed} passed, {results.Count - passed} failed, {results.Count} total\n");
        foreach (var (bucket, encoded, detail) in results)
        {
            report.Append($"  [{(encoded ? "ok  " : "FAIL")}] {bucket}: {detail}\n");
        }

        // Both sinks on purpose: the test-output helper is what `dotnet test`
        // surfaces, and stdout is what a plain runner (or a future ratchet
        // script) greps for the `Results:` line.
        _output.WriteLine(report.ToString().TrimEnd('\n'));
        Console.Write(report.ToString());

        // Positive floor: a sweep that ran nothing must not read as green.
        // `swept` came off disk, so this cannot be satisfied by an empty
        // fixture directory the way `Fixtures.Length` could.
        Assert.True(swept.Count >= 1, "the real-world sweep ran zero fixtures");
        Assert.Equal(swept.Count, results.Count);

        // Deliberately NO assertion on `passed` — see the class doc comment.
    }

    /// <summary>
    /// The shipped fixture directory must hold exactly the declared taxonomy
    /// plus bucket (d)'s callee-only sibling — no more, no less. This is the
    /// assertion that makes "the fixture set is intact" a real claim: it
    /// compares the table against the filesystem, in both directions.
    /// </summary>
    [Fact]
    public void FixtureDirectory_HoldsExactlyTheDeclaredTaxonomy()
    {
        AssertFixtureSetIsIntact();
    }

    /// <summary>
    /// Whatever a fixture does to the encoder, it must be a deliberate
    /// <see cref="EncoderException"/>. An <see cref="ArgumentException"/>, a
    /// <see cref="NullReferenceException"/> or an index crash out of a syntax
    /// walk is a real defect — the encoder's contract is fail-loud with a
    /// documented message, never an unhandled crash.
    /// </summary>
    [Fact]
    public void RealWorldSweep_EveryFailureIsADeliberateEncoderException()
    {
        var crashes = new List<string>();
        foreach (var (bucket, file, _) in Fixtures)
        {
            var source = ReadFixture(file);
            try
            {
                CSharpEncoder.Encode(source);
            }
            catch (EncoderException)
            {
                // The documented fail-loud path.
            }
            catch (Exception ex)
            {
                crashes.Add($"{bucket}: {ex.GetType().Name}: {Summarize(ex.Message)}");
            }
        }

        Assert.True(AssertFixtureSetIsIntact().Count >= 1, "the real-world sweep ran zero fixtures");
        Assert.Empty(crashes);
    }

    /// <summary>
    /// Bucket (d)'s sibling declaration is committed and non-empty — an empty
    /// callee would make the caller fail for the wrong reason.
    /// </summary>
    [Fact]
    public void CrossFileCalleeFixture_IsCommitted()
    {
        Assert.NotEqual(string.Empty, ReadFixture(CalleeOnlyFixture).Trim());
    }

    /// <summary>
    /// Compares the declared taxonomy against the fixture files that actually
    /// shipped, in both directions, and returns the swept set (everything
    /// except <see cref="CalleeOnlyFixture"/>) in taxonomy order.
    /// </summary>
    private static List<string> AssertFixtureSetIsIntact()
    {
        var onDisk = DiscoverFixtureFiles();
        var declared = Fixtures.Select(f => f.File).Append(CalleeOnlyFixture)
            .OrderBy(n => n, StringComparer.Ordinal).ToList();

        Assert.Equal(declared, onDisk);
        return Fixtures.Select(f => f.File).ToList();
    }

    /// <summary>
    /// Every <c>.cs</c> file shipped beside the test binary under
    /// <c>fixtures/realworld/</c>, sorted. Reading the directory (rather than
    /// trusting the table) is what lets a missing or unexpected fixture fail.
    ///
    /// <para><b>Local gotcha:</b> this reads
    /// <see cref="AppContext.BaseDirectory"/> — the copy under
    /// <c>bin/&lt;cfg&gt;/net10.0/fixtures/realworld/</c>, not the repo tree. MSBuild
    /// copies fixtures in but never deletes ones removed from the repo, so on an
    /// <em>incremental</em> local build a deleted fixture can linger in
    /// <c>bin/</c> and keep this check green. CI always builds fresh, so the gate
    /// is sound there; locally, delete the stale <c>bin/</c> copy (or
    /// <c>dotnet clean</c>) when verifying that removing a fixture really
    /// fails.</para>
    /// </summary>
    private static List<string> DiscoverFixtureFiles()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld");
        Assert.True(Directory.Exists(dir), $"missing real-world fixture directory: {dir}");
        return Directory.GetFiles(dir, "*.cs")
            .Select(Path.GetFileName)
            .OfType<string>()
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToList();
    }

    private static string ReadFixture(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld", name);
        Assert.True(File.Exists(path), $"missing real-world fixture: {path}");
        return File.ReadAllText(path);
    }

    /// <summary>First line only — a full Roslyn diagnostic list would swamp the report.</summary>
    private static string Summarize(string message)
    {
        var line = message.Split('\n')[0].Trim();
        return line.Length <= 160 ? line : line[..160] + "…";
    }
}
