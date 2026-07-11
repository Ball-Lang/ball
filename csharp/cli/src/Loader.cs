using Ball.Engine;

namespace Ball.Cli;

/// <summary>
/// Loading a <c>.ball.json</c>/<c>.ball.bin</c> program for every subcommand (issue #385).
///
/// <para>Reuses <see cref="Ball.Engine.BallEngine"/>'s own loader
/// (<see cref="Ball.Engine.BallEngine.FromJson"/>/<see cref="Ball.Engine.BallEngine.FromBinary"/>,
/// backed by <c>csharp/engine/src/Loader.cs</c>'s proto3-JSON&lt;-&gt;binary round trip) rather
/// than re-implementing program parsing here — the C# analog of
/// <c>rust/cli/src/loader.rs</c>.</para>
///
/// <para>Format is sniffed by extension: a path ending in <c>.bin</c> is read as raw bytes and
/// decoded as binary protobuf; anything else (<c>.ball.json</c>, <c>.json</c>, or no extension at
/// all) is read as UTF-8 text and decoded as proto3 JSON (the <c>@type</c> Any envelope, if
/// present, is stripped by the engine loader). Mirrors
/// <c>dart/cli/lib/src/runner.dart</c>'s <c>path.endsWith('.bin')</c> convention and the
/// Rust/TS CLIs' own format-sniffing rule.</para>
/// </summary>
public static class Loader
{
    /// <summary>
    /// Load a target <see cref="Ball.Engine.BallEngine"/> from <paramref name="path"/>. I/O
    /// failures (missing file, permission error, ...) become <see cref="CliIoError"/> (exit
    /// <c>3</c>); a malformed/undecodable program becomes <see cref="CliParseError"/> (exit
    /// <c>2</c>) — see the type doc comment for the format-sniffing rule.
    /// </summary>
    public static BallEngine LoadEngine(string path)
    {
        var isBinary = path.EndsWith(".bin", StringComparison.Ordinal);
        if (isBinary)
        {
            byte[] bytes;
            try
            {
                bytes = File.ReadAllBytes(path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw new CliIoError($"could not read {path}: {e.Message}");
            }

            try
            {
                return BallEngine.FromBinary(bytes);
            }
            catch (EngineException e)
            {
                throw new CliParseError(e.Message);
            }
        }

        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new CliIoError($"could not read {path}: {e.Message}");
        }

        try
        {
            return BallEngine.FromJson(text);
        }
        catch (EngineException e)
        {
            throw new CliParseError(e.Message);
        }
    }
}
