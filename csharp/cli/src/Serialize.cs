using System.Text;
using System.Text.Json;
using Ball.V1;
using Google.Protobuf;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Cli;

/// <summary>
/// Serializing an encoded <c>ball.v1.Program</c> back out to <c>.ball.json</c>/<c>.ball.bin</c>
/// for <c>ball encode</c>'s output (issue #385) — the reverse direction of
/// <see cref="Ball.Cli.Loader"/> / <c>csharp/engine/src/Loader.cs</c>'s <c>ParseBinary</c>.
/// </summary>
public static class Serialize
{
    /// <summary>
    /// <see cref="Program"/> -&gt; binary <c>.ball.bin</c> bytes: a serialized
    /// <c>google.protobuf.Any</c> envelope wrapping the <c>Program</c> — the canonical binary
    /// ball-file shape every other target's loader (Dart's <c>encodeBallFileBinary</c>,
    /// <c>csharp/engine/src/Loader.cs</c>'s <c>ParseBinary</c>) reads, deliberately NOT a bare
    /// <c>Program</c> encoding (unlike <c>rust/cli/src/serialize.rs</c>'s
    /// Rust-engine-loader-specific convention — Rust's own <c>.ball.bin</c> loader expects an
    /// unwrapped message, which is a Rust-target-only divergence from the Dart-canonical, Any
    /// -wrapped format this CLI's own <see cref="Loader"/>/engine expect).
    /// </summary>
    public static byte[] ProgramToBinary(Program program) =>
        Any.Pack(program).ToByteArray();

    /// <summary>
    /// <see cref="Program"/> -&gt; pretty-printed, <c>@type</c>-enveloped proto3 JSON
    /// (<c>.ball.json</c>) — canonical field names, default-valued fields omitted (matching
    /// <see cref="JsonFormatter.Default"/>'s <c>FormatDefaultValues = false</c>), wrapped in the
    /// cosmetic <c>@type</c> <c>google.protobuf.Any</c> envelope every other target's
    /// <c>.ball.json</c> output carries (see <c>csharp/engine/src/Loader.cs</c>'s doc comment and
    /// <c>examples/hello_world/hello_world.ball.json</c>).
    /// </summary>
    public static string ProgramToJson(Program program)
    {
        var body = JsonFormatter.Default.Format(program);
        using var doc = JsonDocument.Parse(body);

        using var stream = new MemoryStream();
        var writerOptions = new JsonWriterOptions { Indented = true };
        using (var writer = new Utf8JsonWriter(stream, writerOptions))
        {
            writer.WriteStartObject();
            writer.WriteString("@type", "type.googleapis.com/ball.v1.Program");
            foreach (var property in doc.RootElement.EnumerateObject())
            {
                property.WriteTo(writer);
            }

            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(stream.ToArray()) + "\n";
    }
}
