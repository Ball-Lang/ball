using System.Text;
using Ball.CoverageStudy;

namespace Ball.CoverageStudy.Tests;

/// <summary>Self-test for the C# Tier A coverage-study harness (issue #493).
///
/// <para>A new measuring instrument must not inherit the blind spot it exists
/// to close. The gap #493 documents is that every existing gate is scoped to
/// the project's own single-file, entry-point-shaped conformance fixtures, so
/// real class libraries — no <c>Main</c>, declarations split across files —
/// were never looked at. The cheapest way for this harness to inherit that
/// blind spot would be to SKIP such files (by reaching for
/// <c>CSharpEncoder.Encode</c>, which throws without an entry point) and then
/// report a flattering number over what is left.</para>
///
/// <para><b>What this does and does not prove.</b> These assertions validate
/// the HARNESS. They are not regression tests for any encoder/compiler defect:
/// the Tier A run itself is report-only (coverage-study.yml has no
/// <c>pull_request:</c> trigger), so a C#-pipeline regression it measures would
/// not redden this or any other PR.</para>
///
/// <para>The Dart original (<c>rq1_study_self_test.dart</c>) can assert "a plain
/// file is reported clean" because the Dart round trip is closed — the Dart
/// compiler emits idiomatic Dart the Dart encoder reads back. The C# round trip
/// is NOT closed: the compiler emits <c>BallRuntime.*</c> shapes the syntactic
/// encoder does not recognise, which is exactly why the existing
/// <c>csharp-roundtrip</c> row in conformance-matrix.yml reports an honest
/// 0/320 on the project's own corpus. There is therefore no C# source this
/// harness can honestly call clean, and asserting one would mean weakening the
/// harness until something passed.
/// <see cref="A_plain_class_library_survives_encode_and_compile_back"/> asserts
/// the funnel instead — the strongest statement true today — and it strengthens
/// by itself the moment the round trip closes.</para></summary>
public class TierASelfTests
{
    /// <summary>Helper.cs — a plain class library: no <c>Main</c>, nothing
    /// exotic. Exactly the shape every gate before #493 never looked at, and
    /// the shape #492 slice 2's <c>EncodeLibrary</c> exists to accept.</summary>
    private const string HelperSource = """
        namespace Demo;

        public class Helper
        {
            public int Twice(int value)
            {
                return value * 2;
            }
        }
        """;

    /// <summary>Consumer.cs — references the sibling file's type, so it cannot
    /// be understood in isolation, and still has no entry point.</summary>
    private const string ConsumerSource = """
        namespace Demo;

        public class Consumer
        {
            public int Doubled(int value)
            {
                return new Helper().Twice(value);
            }
        }
        """;

    /// <summary>A construct the encoder explicitly rejects (a top-level
    /// <c>enum</c> declaration is a documented gap). The negative control: it
    /// must be REPORTED with its own taxonomy tag and must stop strictly
    /// earlier in the funnel than the plain file, so the harness cannot pass by
    /// painting every file with one reason.</summary>
    private const string UnsupportedSource = """
        namespace Demo;

        public enum Colour
        {
            Red,
            Green,
        }
        """;

    private static string WritePackage()
    {
        var dir = Path.Combine(Path.GetTempPath(), "rq1_cs_self_test_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "Helper.cs"), HelperSource);
        File.WriteAllText(Path.Combine(dir, "Consumer.cs"), ConsumerSource);
        return dir;
    }

    /// <summary>1 — the whole point of #493: entry-point-less files are SCORED,
    /// never silently skipped, and the scored denominator is >= 1 (a run that
    /// scores nothing proves nothing). This is also the direct assertion that
    /// #492 slice 2's <c>EncodeLibrary</c> path is the one in use: reaching for
    /// <c>Encode</c> here would make both files a blanket encode-error.</summary>
    [Fact]
    public void Entry_point_less_files_are_scored_not_skipped()
    {
        var dir = WritePackage();
        try
        {
            var results = TierA.StudyDirectory("synthetic", dir);
            Assert.Equal(2, results.Count);
            Assert.All(results, r => Assert.True(r.Scored,
                $"{r.File} was silently skipped (reason \"{r.Reason}\") — " +
                "the blind spot #493 exists to close"));
            Assert.True(results.Count(r => r.Scored) >= 1,
                "the scored denominator is 0 — a run that scores nothing proves nothing");
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>2 — the funnel is real: a plain class library gets PAST encode
    /// and compile-back. If the harness were failing everything at stage 1 and
    /// calling that a measurement, this would be 0.</summary>
    [Fact]
    public void A_plain_class_library_survives_encode_and_compile_back()
    {
        var result = TierA.StudyFile("synthetic", "Helper.cs", HelperSource);
        var stage = TierA.StageReached(result.Reason);
        Assert.True(stage >= 2,
            $"a plain class library only reached stage {stage} (reason \"{result.Reason}\"); " +
            "expected it to encode and compile back");
    }

    /// <summary>3 — every verdict carries a taxonomy tag the funnel knows. An
    /// unknown tag makes <see cref="TierA.StageReached"/> throw, so a new
    /// failure mode cannot be silently mis-attributed into the funnel.</summary>
    [Fact]
    public void Every_verdict_carries_a_known_taxonomy_tag()
    {
        var dir = WritePackage();
        try
        {
            var results = TierA.StudyDirectory("synthetic", dir);
            results.Add(TierA.StudyFile("synthetic", "Colour.cs", UnsupportedSource));
            foreach (var result in results)
            {
                Assert.Contains(":", result.Reason, StringComparison.Ordinal);
                TierA.StageReached(result.Reason);
            }
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>4 — the negative control: a construct the encoder rejects is
    /// scored, not clean, tagged encode-error, and stops STRICTLY EARLIER than
    /// the plain file. "Same reason for everything" is what this catches.</summary>
    [Fact]
    public void The_harness_discriminates_between_failure_modes()
    {
        var unsupported = TierA.StudyFile("synthetic", "Colour.cs", UnsupportedSource);
        Assert.True(unsupported.Scored);
        Assert.False(unsupported.Clean);
        Assert.StartsWith("encode-error:", unsupported.Reason, StringComparison.Ordinal);

        var plain = TierA.StudyFile("synthetic", "Helper.cs", HelperSource);
        Assert.True(TierA.StageReached(unsupported.Reason) < TierA.StageReached(plain.Reason),
            "the harness is not discriminating between failure modes");
    }

    /// <summary>The declaration inventory is the harness's own eyes for stage 4.
    /// Prove it is a real Roslyn walk: it must see nested members, and it must
    /// actually MISS a declaration that was removed, or stage 4 is a rubber
    /// stamp.</summary>
    [Fact]
    public void Declaration_inventory_is_a_real_roslyn_walk()
    {
        var full = TierA.DeclarationInventory("""
            namespace Demo;

            public class Box
            {
                private int _size;

                public Box(int size)
                {
                    _size = size;
                }

                public int Size => _size;

                public int Area()
                {
                    return _size;
                }
            }
            """);

        Assert.Equal(
            new[] { "class Box", "ctor Box.Box", "field Box._size", "method Box.Area", "property Box.Size" },
            full.ToArray());

        var pruned = TierA.DeclarationInventory("public class Box { }");
        Assert.Equal(
            new[] { "ctor Box.Box", "field Box._size", "method Box.Area", "property Box.Size" },
            full.Where(name => !pruned.Contains(name)).ToArray());
    }

    /// <summary>The report's positive floor is real: a run that scored nothing
    /// exits non-zero rather than printing a flattering 0%.</summary>
    [Fact]
    public void An_empty_run_is_a_harness_failure_not_a_zero_percent_result()
    {
        var output = new StringBuilder();
        var code = EntryPoint.Report(output, [], []);
        Assert.Equal(1, code);
        Assert.Contains("Results: 0 passed, 0 failed, 0 total", output.ToString(), StringComparison.Ordinal);
    }
}
