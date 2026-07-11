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
            // No entry point (no top-level statements, no Main) — the encoder requires one.
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
}
