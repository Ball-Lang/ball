namespace Ball.Cli.Tests;

/// <summary><c>ball encode</c> — C# -&gt; Ball, both output formats. Mirrors <c>rust/cli/tests/cli_encode.rs</c>.</summary>
public sealed class CliEncodeTests
{
    private static string WriteHelloSource(string dir)
    {
        var path = Path.Combine(dir, "hello.cs");
        File.WriteAllText(path, "Console.WriteLine(\"Hello, encode!\");");
        return path;
    }

    [Fact]
    public void Encodes_to_json_on_stdout_by_default()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_encode_json_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var source = WriteHelloSource(dir);
            var result = CliProcess.Run("encode", source);

            Assert.Equal(0, result.ExitCode);
            Assert.Contains("\"@type\": \"type.googleapis.com/ball.v1.Program\"", result.Stdout);
            Assert.Contains("Hello, encode!", result.Stdout);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Encodes_to_binary_with_output_flag()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_encode_bin_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var source = WriteHelloSource(dir);
            var outputPath = Path.Combine(dir, "out.ball.bin");
            var result = CliProcess.Run("encode", source, "--format", "binary", "--output", outputPath);

            Assert.Equal(0, result.ExitCode);
            Assert.Empty(result.Stdout);
            var bytes = File.ReadAllBytes(outputPath);
            Assert.NotEmpty(bytes);

            // The encoded binary round-trips through `check` (a decode-and-validate pass),
            // proving it's a real `google.protobuf.Any`-wrapped `ball.v1.Program`, not just
            // non-empty bytes.
            var checkResult = CliProcess.Run("check", outputPath);
            Assert.Equal(0, checkResult.ExitCode);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Missing_source_file_is_an_io_error_exit_3()
    {
        var result = CliProcess.Run("encode", "does_not_exist.cs");
        Assert.Equal(3, result.ExitCode);
    }

    [Fact]
    public void Unsupported_source_is_a_parse_error_exit_2()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_encode_bad_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            // No entry point (no top-level statements, no Main) — the encoder requires one
            // by default. `--library` is the opt-out; see
            // Library_flag_encodes_a_main_less_source_and_check_rejects_it.
            var path = Path.Combine(dir, "no_entry.cs");
            File.WriteAllText(path, "class Foo { public int Bar() => 1; }");

            var result = CliProcess.Run("encode", path);
            Assert.Equal(2, result.ExitCode);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>
    /// Library mode (issue #492): <c>ball encode --library</c> accepts the very source the
    /// default path rejects, and the program it emits is deliberately <b>not runnable</b> —
    /// <c>ball check</c> must refuse it with "missing entry_function" rather than any code path
    /// silently synthesising a fake entry point. This is the documented boundary, mirrored
    /// exactly by <c>rust/cli</c>'s <c>ball encode --lib</c> +
    /// <c>a_library_mode_program_is_rejected_by_check_as_non_runnable</c>.
    /// </summary>
    [Fact]
    public void Library_flag_encodes_a_main_less_source_and_check_rejects_it()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_encode_library_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "library.cs");
            File.WriteAllText(path, "namespace Sample;\n\npublic class Greeter\n{\n    public string Greet(string name)\n    {\n        return \"Hello, \" + name;\n    }\n}\n");
            var outputPath = Path.Combine(dir, "library.ball.json");

            var encoded = CliProcess.Run("encode", "--library", path, "--output", outputPath);
            Assert.Equal(0, encoded.ExitCode);

            var json = File.ReadAllText(outputPath);
            Assert.Contains("\"@type\": \"type.googleapis.com/ball.v1.Program\"", json);
            Assert.Contains("\"main:Greeter.Greet\"", json);
            // Proto3 JSON omits an empty string entirely, so an absent
            // `entryFunction` key IS the empty entry function.
            Assert.DoesNotContain("\"entryFunction\"", json);
            Assert.Contains("\"entryModule\": \"main\"", json);

            var checkResult = CliProcess.Run("check", outputPath);
            Assert.Equal(2, checkResult.ExitCode);
            Assert.Contains("missing entry_function", checkResult.Stderr);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
