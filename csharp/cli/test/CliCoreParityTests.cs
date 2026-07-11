namespace Ball.Cli.Tests;

/// <summary>
/// <c>ball info</c>/<c>validate</c>/<c>tree</c> golden-parity gate (epic #361 cli-core adoption
/// pattern) — the C# analog of <c>rust/cli/tests/cli_core_parity.rs</c> /
/// <c>dart/cli/test/cli_core_parity_test.dart</c>.
///
/// <para>Compares the <b>built <c>ball</c> binary's</b> stdout for <c>info</c>/<c>validate</c>/
/// <c>tree</c> against golden <c>.txt</c> files checked into <c>test/golden/cli_core/</c>,
/// generated once from the real Dart CLI (<c>dart run dart/cli/bin/ball.dart &lt;verb&gt;
/// &lt;fixture&gt;</c>) — proving the compiled C# report functions produce byte-identical output
/// to the reference implementation, without depending on a Dart toolchain at test time.</para>
///
/// <para>## Regenerating the goldens</para>
/// <para>Only needed when <c>dart/shared/lib/cli_core.dart</c>'s report format changes. From the
/// repo root, with a Dart SDK on <c>PATH</c>:</para>
/// <code>
/// for f in 100_complex_control_flow 101_simple_class 111_cascade_operator \
///          116_map_iteration 118_set_operations; do
///   for verb in info validate tree; do
///     dart run dart/cli/bin/ball.dart "$verb" "tests/conformance/$f.ball.json" \
///       > "csharp/cli/test/golden/cli_core/$f.$verb.txt"
///   done
/// done
/// </code>
/// <para><c>version</c> has no golden file — its entire logic is the one-line format <c>"ball " +
/// version</c>, checked directly in <c>VersionCommandTests</c> instead.</para>
/// </summary>
public sealed class CliCoreParityTests
{
    /// <summary>
    /// The same golden fixture set <c>rust/cli/tests/cli_core_parity.rs</c> /
    /// <c>dart/cli/test/cli_core_parity_test.dart</c> exercise — a deliberately varied slice of
    /// the conformance corpus (control flow, classes, collections, strings).
    /// </summary>
    private static readonly string[] GoldenFixtures =
    [
        "100_complex_control_flow",
        "101_simple_class",
        "111_cascade_operator",
        "116_map_iteration",
        "118_set_operations",
    ];

    private static readonly string[] Verbs = ["info", "validate", "tree"];

    public static IEnumerable<object[]> FixtureVerbPairs()
    {
        foreach (var fixture in GoldenFixtures)
        {
            foreach (var verb in Verbs)
            {
                yield return [fixture, verb];
            }
        }
    }

#if CLI_CORE
    [Theory]
    [MemberData(nameof(FixtureVerbPairs))]
    public void Golden_fixture_matches_the_dart_cli_for_every_verb(string fixture, string verb)
    {
        var program = TestPaths.RepoPath("tests", "conformance", $"{fixture}.ball.json");
        var goldenPath = TestPaths.RepoPath("csharp", "cli", "test", "golden", "cli_core", $"{fixture}.{verb}.txt");
        var golden = File.ReadAllText(goldenPath).ReplaceLineEndings("\n");

        var result = CliProcess.Run(verb, program);

        Assert.True(result.ExitCode == 0, $"verb {verb} on fixture {fixture} should succeed; stderr: {result.Stderr}");
        Assert.Equal(golden, result.Stdout.ReplaceLineEndings("\n"));
    }

    [Fact]
    public void Validate_reports_an_invalid_program_to_stderr_and_exits_2()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_validate_invalid_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "invalid.ball.json");
            File.WriteAllText(
                path,
                """{"@type":"type.googleapis.com/ball.v1.Program","name":"bad","version":"1.0.0","entryModule":"","entryFunction":"","modules":[]}""");

            var result = CliProcess.Run("validate", path);

            Assert.Equal(2, result.ExitCode);
            Assert.Empty(result.Stdout);
            Assert.Contains("Invalid: 2 error(s) found", result.Stderr);
            Assert.Contains("Missing entry_module", result.Stderr);
            Assert.Contains("Missing entry_function", result.Stderr);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
#else
    /// <summary>
    /// Without <c>CliCore</c>, <c>info</c>/<c>validate</c>/<c>tree</c> must degrade honestly (a
    /// <see cref="CliRuntimeError"/>-style message, exit <c>1</c>, no stdout) rather than
    /// silently succeeding with wrong/empty output — mirrors
    /// <see cref="CliRunTests.Default_build_reports_self_host_pending_honestly_for_a_valid_program"/>.
    /// </summary>
    [Theory]
    [InlineData("info")]
    [InlineData("validate")]
    [InlineData("tree")]
    public void Default_build_reports_cli_core_pending_honestly(string verb)
    {
        var program = TestPaths.RepoPath("tests", "conformance", "101_simple_class.ball.json");
        var result = CliProcess.Run(verb, program);

        Assert.Equal(1, result.ExitCode);
        Assert.Empty(result.Stdout);
        Assert.Contains("CliCore", result.Stderr);
    }
#endif
}
