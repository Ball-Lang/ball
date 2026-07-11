namespace Ball.Cli;

/// <summary>
/// Writing a subcommand's result to <c>--output &lt;file&gt;</c> or stdout (issue #385). Shared
/// by <c>compile</c> (C# source, text) and <c>encode</c> (JSON text or binary bytes) — the C#
/// analog of <c>rust/cli/src/output.rs</c>.
/// </summary>
public static class Output
{
    /// <summary>
    /// Write <paramref name="content"/> to <paramref name="outputPath"/> if given, else to
    /// stdout.
    /// </summary>
    public static void WriteText(string? outputPath, string content)
    {
        if (outputPath is null)
        {
            Console.Out.Write(content);
            return;
        }

        try
        {
            File.WriteAllText(outputPath, content);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new CliIoError($"could not write {outputPath}: {e.Message}");
        }
    }

    /// <summary>
    /// Write raw <paramref name="content"/> bytes to <paramref name="outputPath"/> if given,
    /// else to stdout.
    /// </summary>
    public static void WriteBytes(string? outputPath, byte[] content)
    {
        if (outputPath is null)
        {
            using var stdout = Console.OpenStandardOutput();
            stdout.Write(content, 0, content.Length);
            return;
        }

        try
        {
            File.WriteAllBytes(outputPath, content);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new CliIoError($"could not write {outputPath}: {e.Message}");
        }
    }
}
