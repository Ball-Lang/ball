// Aliased rather than `using Ball.V1;` — xunit v3 test projects are
// self-executing apps, so the SDK injects a global `Program` entry-point
// type into this project that would otherwise shadow `Ball.V1.Program`.
using BallProgram = Ball.V1.Program;
using Google.Protobuf;
using System.Text.Json.Nodes;

namespace Ball.Shared.Tests;

/// <summary>
/// #379 JSON-leg smoke test: proves the buf-generated bindings in
/// csharp/shared/gen/Ball.cs correctly parse real proto3-JSON `.ball.json`
/// conformance fixtures (not just hand-built messages) via
/// Google.Protobuf's <see cref="JsonParser"/>, and that the result
/// round-trips losslessly through binary protobuf. This is what the
/// self-hosted engine loader (a later phase) will rely on when it reads
/// `.ball.json` files off disk.
///
/// A `.ball.json` file is a proto3-JSON `google.protobuf.Any` envelope: an
/// explicit `"@type": "type.googleapis.com/ball.v1.Program"` key alongside
/// the message's own fields (see `dart/shared/lib/ball_file.dart` for the
/// canonical reader, which strips `@type` and merges the remainder). This
/// test mirrors that convention rather than reaching for
/// `JsonParser.Settings.IgnoreUnknownFields` — proto3-JSON compat means
/// parsing the wire format Ball programs are actually shipped in, envelope
/// included.
/// </summary>
public class ProtoJsonRoundTripSmokeTests
{
    private const string ExpectedTypeUrl = "type.googleapis.com/ball.v1.Program";

    [Fact]
    public void ConformanceFixture_RoundTrips_ThroughJsonThenBinary()
    {
        // 202_sandbox_mode.ball.json is a small, real conformance fixture
        // (a `std.file_read` call inside `main`) — not a hand-authored
        // string — so this exercises the generated bindings' JSON parser
        // against genuine multi-module Program/Module/FunctionDefinition/
        // Expression nesting.
        var fixturePath = FindConformanceFixture("202_sandbox_mode.ball.json");
        var envelope = JsonNode.Parse(File.ReadAllText(fixturePath))!.AsObject();

        var typeUrl = envelope["@type"]?.GetValue<string>();
        Assert.Equal(ExpectedTypeUrl, typeUrl);
        envelope.Remove("@type");
        var bodyJson = envelope.ToJsonString();

        // Step 1: JSON -> message. Mirrors the Dart reader's
        // `ignoreUnknownFields: true` safety net (harmless here since
        // `@type` was already stripped above).
        var jsonParser = new JsonParser(JsonParser.Settings.Default.WithIgnoreUnknownFields(true));
        var fromJson = jsonParser.Parse<BallProgram>(bodyJson);

        Assert.Equal("sandbox_mode", fromJson.Name);
        Assert.Equal("main", fromJson.EntryModule);
        Assert.Equal("main", fromJson.EntryFunction);
        Assert.Equal(2, fromJson.Modules.Count);

        // Step 2: message -> binary -> message.
        var bytes = fromJson.ToByteArray();
        var fromBinary = BallProgram.Parser.ParseFrom(bytes);

        // Full structural equality (generated messages implement deep
        // field-by-field Equals), not just a handful of top-level fields —
        // proves nothing was lost or altered across the JSON->binary hop.
        Assert.Equal(fromJson, fromBinary);
    }

    /// <summary>
    /// Walks up from the test assembly's output directory to find the repo
    /// root's `tests/conformance/` directory. Avoids depending on
    /// `dotnet test`'s current-working-directory behavior, which differs
    /// between IDE test runners and the CLI.
    /// </summary>
    private static string FindConformanceFixture(string fileName)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "tests", "conformance", fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }

        throw new FileNotFoundException(
            $"Could not locate tests/conformance/{fileName} by walking up from {AppContext.BaseDirectory}");
    }
}
