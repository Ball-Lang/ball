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

    /// <summary>A construct the encoder explicitly rejects — today, target-typed
    /// <c>new()</c>, which has no semantic model to resolve the implied type and
    /// is bucket (f) of the real-world sweep's still-open taxonomy. The negative
    /// control: it must be REPORTED with its own taxonomy tag and must stop
    /// strictly earlier in the funnel than the plain file, so the harness cannot
    /// pass by painting every file with one reason.
    ///
    /// <para>This was a top-level <c>enum</c> until #492 slice C closed that gap.
    /// When a slice closes the gap this control uses, MOVE it to another
    /// still-open one (`csharp/AGENTS.md`'s "Documented gaps" list) — never
    /// relax the assertion, which is what would actually blind the harness.
    /// </para></summary>
    private const string UnsupportedSource = """
        namespace Demo;

        public class Widget
        {
            public Widget Clone()
            {
                return new();
            }
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
            results.Add(TierA.StudyFile("synthetic", "Widget.cs", UnsupportedSource));
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
        var unsupported = TierA.StudyFile("synthetic", "Widget.cs", UnsupportedSource);
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

    /// <summary>
    /// <c>--project-mode</c> keeps Tier A's unit the FILE — same denominator, same taxonomy
    /// tags — and resolves what only a project-wide model can (issue #492, W12-C slice 1).
    ///
    /// <para>This is the instrument's own proof that the basis is COMPARABLE, which is what a
    /// two-basis measurement in a PR body claims. Without it, "project mode moved the funnel"
    /// could just as well mean "project mode counts something else".</para>
    /// </summary>
    [Fact]
    public void Project_mode_keeps_the_per_file_basis_and_resolves_a_cross_file_callee()
    {
        var dir = Path.Combine(Path.GetTempPath(), "rq1_cs_project_mode_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            File.WriteAllText(Path.Combine(dir, "MathHelper.cs"), """
                namespace Demo;

                public static class MathHelper
                {
                    public static int Square(int value)
                    {
                        return value * value;
                    }
                }
                """);
            File.WriteAllText(Path.Combine(dir, "Caller.cs"), """
                namespace Demo;

                public class Caller
                {
                    public int Of(int seed)
                    {
                        return MathHelper.Square(seed);
                    }
                }
                """);

            var library = TierA.StudyDirectory("synthetic", dir);
            var project = TierA.StudyDirectory("synthetic", dir, projectMode: true);

            // Same unit, same denominator — the funnels are comparable.
            Assert.Equal(library.Count, project.Count);
            Assert.Equal(
                library.Select(r => r.File).ToArray(),
                project.Select(r => r.File).ToArray());
            Assert.All(project, r => TierA.StageReached(r.Reason));

            // The cross-file callee is the difference, and it is a real one.
            var libraryCaller = library.Single(r => r.File == "Caller.cs");
            var projectCaller = project.Single(r => r.File == "Caller.cs");
            Assert.StartsWith("encode-error:", libraryCaller.Reason, StringComparison.Ordinal);
            Assert.True(
                TierA.StageReached(projectCaller.Reason) > TierA.StageReached(libraryCaller.Reason),
                $"project mode did not advance the cross-file caller (reason \"{projectCaller.Reason}\")");
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>The report's positive floor is real: a run that scored nothing
    /// exits non-zero rather than printing a flattering 0%.</summary>
    [Fact]
    public void An_empty_run_is_a_harness_failure_not_a_zero_percent_result()
    {
        var output = new StringBuilder();
        var code = EntryPoint.Report(output, [], [], []);
        Assert.Equal(1, code);
        Assert.Contains("Results: 0 passed, 0 failed, 0 total", output.ToString(), StringComparison.Ordinal);
    }

    // ── test-only exclusion (the owner's 2026-09-14 decision on #491) ───────
    //
    // Tier A scores the LIBRARY code a user would encode; a package's own test
    // suite is a different population and is out of the denominator. The rule
    // must be EXPLICIT, self-tested and COUNTED in the run summary — a silent
    // filter is how a denominator shrinks without anyone noticing.
    //
    // C#'s convention has two halves: a TEST PROJECT (a `*.Tests.csproj`, or a
    // .csproj whose MANIFEST declares a test-framework PackageReference or
    // IsTestProject) and a test DIRECTORY. The negative control is
    // load-bearing, and it has two forms: a library file whose NAME merely
    // contains "test" ("la-test", "con-test", "at-test-ation"), and a library
    // project whose .csproj merely MENTIONS a test framework — in a comment, or
    // behind a Condition this harness does not evaluate. Both must still be
    // studied; a substring rule over the path fails the first and a substring
    // rule over the manifest text fails the second.

    /// <summary>Library file paths whose name merely contains "test" — the
    /// negative control.</summary>
    private static readonly string[] LibraryLookalikes =
        ["src/Latest.cs", "src/Contest.cs", "src/Attestation/Verify.cs"];

    /// <summary>Library files in projects whose .csproj only MENTIONS a test
    /// framework — in an XML comment, and behind an unevaluated Condition. A
    /// raw-text marker search classifies both as test projects and silently
    /// takes their library code out of the denominator.</summary>
    private static readonly string[] LibraryProjectLookalikes =
        ["Demo.Documented/Helper.cs", "Demo.Conditioned/Helper.cs"];

    private static readonly string[] TestOnlyFiles =
    [
        "test/Support.cs",
        "tests/Legacy.cs",
        "Demo.Tests/CoreTests.cs",
        "Demo.Verification/Cases.cs",
        "Demo.Marked/Cases.cs",
    ];

    private static void Write(string root, string rel, string source)
    {
        var full = Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllText(full, source);
    }

    /// <summary>A scratch tree with library files, a test DIRECTORY, a
    /// <c>*.Tests.csproj</c> project and an xunit-referencing project whose
    /// name says nothing about tests.</summary>
    private static string WriteMixedTree()
    {
        var dir = Path.Combine(Path.GetTempPath(), "rq1_cs_exclusion_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        Write(dir, "src/Core.cs", "namespace Demo;\npublic class Core { public int V() { return 1; } }\n");
        foreach (var rel in LibraryLookalikes.Concat(LibraryProjectLookalikes))
        {
            Write(dir, rel, "namespace Demo;\npublic class Item { public int V() { return 1; } }\n");
        }

        foreach (var rel in TestOnlyFiles)
        {
            Write(dir, rel, "namespace Demo;\npublic class Cases { public int V() { return 1; } }\n");
        }

        // A project whose FILENAME declares it a test project.
        Write(dir, "Demo.Tests/Demo.Tests.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>\n");
        // A project whose filename says nothing about tests, but which
        // references xunit — the half a filename rule alone would miss.
        Write(dir, "Demo.Verification/Demo.Verification.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><ItemGroup><PackageReference Include=\"xunit.v3\" /></ItemGroup></Project>\n");
        // A project that declares itself a test project by PROPERTY and names
        // no package at all — the half a package rule alone would miss.
        Write(dir, "Demo.Marked/Demo.Marked.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>\n");
        // A LIBRARY project that merely mentions xunit in an XML comment. A
        // raw-text marker search reads the comment and excludes the project's
        // library code; parsing the manifest as XML cannot see a comment at all.
        Write(dir, "Demo.Documented/Demo.Documented.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
                + "  <!-- Consumers testing this library with xunit should also reference NUnit3TestAdapter. -->\n"
                + "  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>\n"
                + "</Project>\n");
        // A LIBRARY project carrying a CONDITIONED test-framework reference:
        // whether it is even referenced depends on an MSBuild property this
        // harness does not evaluate, so it is not proof of a test project.
        Write(dir, "Demo.Conditioned/Demo.Conditioned.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
                + "  <ItemGroup Condition=\"'$(BuildingTests)' == 'true'\">\n"
                + "    <PackageReference Include=\"xunit.v3\" />\n"
                + "  </ItemGroup>\n"
                + "</Project>\n");
        // And the library's own project, which must NOT make its files test-only.
        Write(dir, "src/Demo.csproj",
            "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>\n");
        return dir;
    }

    [Fact]
    public void Test_only_files_are_excluded_counted_and_named()
    {
        var dir = WriteMixedTree();
        try
        {
            var (studied, excluded) = TierA.ClassifyCsFiles("synthetic", dir);
            var studiedRel = studied
                .Select(p => Path.GetRelativePath(dir, p).Replace('\\', '/'))
                .ToHashSet(StringComparer.Ordinal);
            var excludedRel = excluded.ToDictionary(e => e.File, e => e.Rule, StringComparer.Ordinal);

            var library = new[] { "src/Core.cs" }
                .Concat(LibraryLookalikes)
                .Concat(LibraryProjectLookalikes)
                .ToArray();
            foreach (var rel in library)
            {
                Assert.True(
                    studiedRel.Contains(rel),
                    $"library file \"{rel}\" was not studied — the rule is excluding library code "
                        + $"(studied: {string.Join(", ", studiedRel.Order(StringComparer.Ordinal))})");
            }

            Assert.Equal(library.Length, studiedRel.Count);

            foreach (var rel in TestOnlyFiles)
            {
                Assert.True(
                    excludedRel.ContainsKey(rel),
                    $"test-only file \"{rel}\" was not excluded "
                        + $"(excluded: {string.Join(", ", excludedRel.Keys.Order(StringComparer.Ordinal))})");
            }

            Assert.Equal(TestOnlyFiles.Length, excludedRel.Count);
            Assert.All(excluded, e => Assert.False(string.IsNullOrEmpty(e.Rule)));

            // The project half is read from the MANIFEST, not from its text: a
            // real <PackageReference Include="xunit.v3" /> and an
            // <IsTestProject>true</IsTestProject> each excludes on its own.
            Assert.Contains("PackageReference", excludedRel["Demo.Verification/Cases.cs"], StringComparison.Ordinal);
            Assert.Contains("IsTestProject", excludedRel["Demo.Marked/Cases.cs"], StringComparison.Ordinal);

            var results = TierA.StudyDirectory("synthetic", dir);
            Assert.DoesNotContain(results, r => excludedRel.ContainsKey(r.File));

            var output = new StringBuilder();
            EntryPoint.Report(output, results, excluded, []);
            Assert.Contains(
                $"  excluded (test-only): {TestOnlyFiles.Length}\n",
                output.ToString(),
                StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>A run that excluded nothing STILL prints the line: a missing
    /// line is indistinguishable from a rule that vanished, and summarize.sh
    /// fails on it.</summary>
    [Fact]
    public void The_exclusion_count_is_printed_even_when_zero()
    {
        var output = new StringBuilder();
        EntryPoint.Report(output, [TierA.StudyFile("synthetic", "Helper.cs", HelperSource)], [], []);
        Assert.Contains("  excluded (test-only): 0\n", output.ToString(), StringComparison.Ordinal);
    }
}
