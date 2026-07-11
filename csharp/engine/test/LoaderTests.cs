using Ball.Shared;
using Ball.V1;
using Google.Protobuf;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Engine.Tests;

/// <summary>
/// Tests for the program <see cref="Loader"/> — the C# sibling of
/// <c>rust/engine/src/loader.rs</c>'s tests. Proves the JSON and binary entry
/// points produce the same canonical <see cref="BallValue"/> view, that the
/// <c>@type</c> Any envelope is stripped, that proto3 defaults are materialized,
/// and that metadata is reconstructed into the raw <c>Struct</c> shape the engine
/// reads.
/// </summary>
public sealed class LoaderTests
{
    private const string Hello = """
        {
            "@type": "type.googleapis.com/ball.v1.Program",
            "name": "hello", "version": "1.0.0",
            "entryModule": "main", "entryFunction": "main",
            "modules": [ { "name": "main", "functions": [
                { "name": "main", "body": { "literal": { "stringValue": "hi" } } }
            ] } ]
        }
        """;

    [Fact]
    public void FromJson_parses_and_strips_the_type_envelope()
    {
        var engine = BallEngine.FromJson(Hello);
        Assert.Equal("hello", engine.Program.Name);
        Assert.Equal("main", engine.Program.EntryModule);

        var root = Assert.IsType<BallMap>(engine.ProgramValue);
        Assert.True(root.ContainsKey("name"));
        Assert.True(root.ContainsKey("modules"));
        // The cosmetic @type envelope is gone from the typed/canonical view.
        Assert.False(root.ContainsKey("@type"));
    }

    [Fact]
    public void Json_and_binary_views_are_identical()
    {
        var jsonEngine = BallEngine.FromJson(Hello);

        // Re-encode the typed program as a binary Any envelope, then load it back.
        var any = Any.Pack(jsonEngine.Program);
        var binaryEngine = BallEngine.FromBinary(any.ToByteArray());

        Assert.Equal(jsonEngine.Program.Name, binaryEngine.Program.Name);
        Assert.True(
            BallValue.ValueEquals(jsonEngine.ProgramValue, binaryEngine.ProgramValue),
            "the JSON and binary views of the same program must be identical");
    }

    [Fact]
    public void JsonToBallValue_picks_int_vs_double()
    {
        using var seven = System.Text.Json.JsonDocument.Parse("7");
        using var half = System.Text.Json.JsonDocument.Parse("2.5");
        Assert.Equal(7L, ((BallInt)Loader.JsonToBallValue(seven.RootElement)).Value);
        Assert.Equal(2.5, ((BallDouble)Loader.JsonToBallValue(half.RootElement)).Value);
    }

    [Fact]
    public void View_materializes_proto3_defaults()
    {
        var engine = BallEngine.FromJson(Hello);
        var root = (BallMap)engine.ProgramValue;
        var modules = (BallList)root.Get("modules")!;
        var mainModule = (BallMap)modules.Get(0);

        // `functions` was present; an absent repeated field like `typeDefs`
        // materializes as [] (FormatDefaultValues), never null — the property the
        // engine's `listVal.length` access relies on.
        Assert.IsType<BallList>(mainModule.Get("typeDefs"));
    }

    [Fact]
    public void Metadata_is_reconstructed_into_the_raw_struct_shape()
    {
        // A program whose entry function carries metadata {kind: "function"}.
        const string withMeta = """
            {
                "@type": "type.googleapis.com/ball.v1.Program",
                "name": "m", "version": "1.0.0",
                "entryModule": "main", "entryFunction": "main",
                "modules": [ { "name": "main", "functions": [
                    { "name": "main",
                      "metadata": { "kind": "function" },
                      "body": { "literal": { "stringValue": "hi" } } }
                ] } ]
            }
            """;
        var engine = BallEngine.FromJson(withMeta);
        var root = (BallMap)engine.ProgramValue;
        var fn = (BallMap)((BallList)((BallMap)((BallList)root.Get("modules")!).Get(0)).Get("functions")!).Get(0);

        // metadata is re-expanded to {fields: {kind: {stringValue: "function"}}}.
        var metadata = (BallMap)fn.Get("metadata")!;
        var fields = (BallMap)metadata.Get("fields")!;
        var kind = (BallMap)fields.Get("kind")!;
        Assert.Equal("function", ((BallString)kind.Get("stringValue")!).Value);
    }

    [Fact]
    public void FromJson_throws_on_invalid_json()
    {
        Assert.Throws<EngineException>(() => BallEngine.FromJson("{ not valid"));
    }

    [Fact]
    public void Run_reports_self_host_pending_in_the_default_build()
    {
        var engine = BallEngine.FromJson(Hello);
        Assert.Throws<SelfHostPendingException>(() => engine.Run());
    }
}
