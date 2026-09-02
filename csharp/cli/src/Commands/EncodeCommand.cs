using Ball.Encoder;

namespace Ball.Cli.Commands;

/// <summary>Output format for <c>ball encode</c> (mirrors <c>dart/cli</c>'s <c>--format json|binary</c>).</summary>
public enum EncodeFormat
{
    /// <summary>Proto3 JSON, <c>@type</c>-enveloped (<c>.ball.json</c>) — human-readable, the default.</summary>
    Json,

    /// <summary>Raw protobuf binary (<c>.ball.bin</c>) — compact.</summary>
    Binary,
}

/// <summary>
/// <c>ball encode &lt;source.cs&gt;</c> — C# -&gt; Ball (issue #385).
/// </summary>
public static class EncodeCommand
{
    /// <summary>
    /// Read <paramref name="sourcePath"/> as C# source, encode it via <see cref="CSharpEncoder"/>,
    /// and write the resulting <c>ball.v1.Program</c> to <paramref name="output"/> (or stdout) in
    /// <paramref name="format"/>.
    ///
    /// <para><see cref="CSharpEncoder.Encode"/> throws on source it doesn't support (no entry
    /// point, an unsupported construct outside its documented scope — see
    /// <c>csharp/encoder/src/CSharpEncoder.cs</c>'s type doc comment) —
    /// <see cref="ExceptionGuard.Guard{T}"/> converts that into a <see cref="CliParseError"/>
    /// (exit <c>2</c>).</para>
    ///
    /// <para>With <paramref name="library"/> set (<c>ball encode --library</c>, issue #492) the
    /// source is encoded through <see cref="CSharpEncoder.EncodeLibrary"/> instead: no
    /// <c>Main</c> entry point is required, and the emitted program has an empty
    /// <c>entry_function</c>, so it is deliberately not runnable (<c>ball check</c> reports
    /// <c>missing entry_function</c>). Every <em>other</em> documented-gap throw still surfaces
    /// as the same clean exit <c>2</c> — the flag relaxes the entry-point requirement, nothing
    /// else.</para>
    /// </summary>
    public static void Run(string sourcePath, string? output, EncodeFormat format, bool library = false)
    {
        string source;
        try
        {
            source = File.ReadAllText(sourcePath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new CliIoError($"could not read {sourcePath}: {e.Message}");
        }

        var program = ExceptionGuard.Guard(() =>
            library ? CSharpEncoder.EncodeLibrary(source) : CSharpEncoder.Encode(source));
        switch (format)
        {
            case EncodeFormat.Json:
                Output.WriteText(output, Serialize.ProgramToJson(program));
                break;
            case EncodeFormat.Binary:
                Output.WriteBytes(output, Serialize.ProgramToBinary(program));
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(format), format, "unknown encode format");
        }
    }
}
