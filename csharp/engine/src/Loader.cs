using System.Text.Json;
using Ball.Shared;
using Ball.V1;
using Google.Protobuf;

namespace Ball.Engine;

/// <summary>
/// Loads a target Ball <see cref="Program"/> into the runtime (issue #383) — the
/// C# sibling of <c>rust/engine/src/loader.rs</c> / the TS wrapper's
/// <c>protoWrap</c>.
///
/// <para>Two entry points, mirroring the CLI's two input formats:</para>
/// <list type="bullet">
/// <item><see cref="ParseJson"/> — proto3-JSON <c>.ball.json</c> (the
/// examples/conformance format). Strips the cosmetic <c>@type</c> Any
/// envelope.</item>
/// <item><see cref="ParseBinary"/> — binary protobuf (a <c>google.protobuf.Any</c>
/// envelope wrapping the <c>ball.v1.Program</c>).</item>
/// </list>
///
/// <para>Both return the typed <see cref="Program"/> (for the wrapper's own
/// structural needs) <b>and</b> a canonical proto3-JSON <see cref="BallValue"/>
/// view of it — a tree of insertion-ordered <see cref="BallMap"/>s keyed by
/// camelCase <c>jsonName</c>s, oneofs represented by the set field being
/// present. That view is exactly the shape the compiled self-hosted engine reads
/// through the <see cref="BallProto"/> access-pattern functions
/// (<c>whichExpr</c>/<c>hasBody</c>/…).</para>
/// </summary>
public static class Loader
{
    /// <summary>
    /// Parse a proto3-JSON <c>.ball.json</c> program (stripping the cosmetic
    /// <c>@type</c> Any envelope) into a typed <see cref="Program"/> plus its
    /// canonical <see cref="BallValue"/> view.
    /// </summary>
    public static (Program Program, BallValue View) ParseJson(string json)
    {
        string body;
        try
        {
            body = StripTypeEnvelope(json);
        }
        catch (JsonException e)
        {
            throw new EngineException($"parse error: {e.Message}");
        }

        Program program;
        try
        {
            var parser = new JsonParser(JsonParser.Settings.Default.WithIgnoreUnknownFields(true));
            program = parser.Parse<Program>(body);
        }
        catch (InvalidProtocolBufferException e)
        {
            throw new EngineException($"not a valid ball.v1.Program: {e.Message}");
        }

        return (program, BuildView(program));
    }

    /// <summary>
    /// Parse a binary-protobuf program — a <c>google.protobuf.Any</c> envelope
    /// wrapping the <c>ball.v1.Program</c> — into a typed <see cref="Program"/>
    /// plus its canonical <see cref="BallValue"/> view.
    /// </summary>
    public static (Program Program, BallValue View) ParseBinary(byte[] bytes)
    {
        Program program;
        try
        {
            var any = Google.Protobuf.WellKnownTypes.Any.Parser.ParseFrom(bytes);
            program = any.Unpack<Program>();
        }
        catch (InvalidProtocolBufferException e)
        {
            throw new EngineException($"not a valid ball.v1.Program: {e.Message}");
        }

        return (program, BuildView(program));
    }

    /// <summary>Strip the top-level <c>@type</c> Any-envelope key, returning the remaining JSON body.</summary>
    private static string StripTypeEnvelope(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Object)
        {
            return json;
        }

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            foreach (var property in doc.RootElement.EnumerateObject())
            {
                if (property.NameEquals("@type"))
                {
                    continue;
                }

                property.WriteTo(writer);
            }

            writer.WriteEndObject();
        }

        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>
    /// The canonical proto3-JSON <see cref="BallValue"/> view of
    /// <paramref name="program"/>. Serializes with <c>FormatDefaultValues</c> so
    /// every proto3 default is materialized (an absent repeated field becomes
    /// <c>[]</c>, an absent string <c>""</c>) — matching how the reference engine
    /// reads a program (its protobuf getters always return a field's default,
    /// never null) — then reconstructs the raw <c>google.protobuf.Struct</c>
    /// shape for every <c>metadata</c> field (the engine reads metadata through
    /// the proto <c>Value</c> API it was authored against).
    /// </summary>
    public static BallValue BuildView(Program program)
    {
        var formatter = new JsonFormatter(JsonFormatter.Settings.Default.WithFormatDefaultValues(true));
        var json = formatter.Format(program);
        using var doc = JsonDocument.Parse(json);
        return NormalizeMetadata(JsonToBallValue(doc.RootElement));
    }

    /// <summary>
    /// Convert a proto3-JSON element into a <see cref="BallValue"/> tree. Objects
    /// become insertion-ordered <see cref="BallMap"/>s; arrays become
    /// <see cref="BallList"/>s; an integral number becomes an <see cref="BallInt"/>,
    /// else a <see cref="BallDouble"/>. Proto3-JSON int64 fields arrive as
    /// <em>strings</em> (left as-is — the engine's literal path parses them), and
    /// a <c>bytesValue</c> base64 string is decoded to raw bytes.
    /// </summary>
    public static BallValue JsonToBallValue(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Null => BallValue.Null,
        JsonValueKind.True => BallValue.Bool(true),
        JsonValueKind.False => BallValue.Bool(false),
        JsonValueKind.String => BallValue.Str(element.GetString()!),
        JsonValueKind.Number => element.TryGetInt64(out var i)
            ? BallValue.Int(i)
            : BallValue.Double(element.GetDouble()),
        JsonValueKind.Array => BuildList(element),
        JsonValueKind.Object => BuildMap(element),
        _ => BallValue.Null,
    };

    private static BallValue BuildList(JsonElement array)
    {
        var list = new BallList();
        foreach (var item in array.EnumerateArray())
        {
            list.Add(JsonToBallValue(item));
        }

        return list;
    }

    private static BallValue BuildMap(JsonElement obj)
    {
        var map = new BallMap();
        foreach (var property in obj.EnumerateObject())
        {
            // A Literal.bytesValue serializes as base64; the engine reads a bytes
            // literal as a list of byte ints, so decode it here.
            if (property.NameEquals("bytesValue") && property.Value.ValueKind == JsonValueKind.String)
            {
                map.Set("bytesValue", BallValue.Bytes(Convert.FromBase64String(property.Value.GetString()!)));
                continue;
            }

            // A Literal.doubleValue is a proto double, but proto3-JSON renders a
            // whole double (`9.0`) as a bare integer (`9`) — which the generic
            // number path below would load as a BallInt, dropping the double-ness
            // the engine's BallDouble literal path (and its trailing `.0`
            // formatting) depends on. Coerce it to a BallDouble regardless of the
            // JSON token's shape (a fractional value already loads as a double).
            if (property.NameEquals("doubleValue") && property.Value.ValueKind == JsonValueKind.Number)
            {
                map.Set("doubleValue", BallValue.Double(property.Value.GetDouble()));
                continue;
            }

            map.Set(property.Name, JsonToBallValue(property.Value));
        }

        return map;
    }

    // ════════════════════════════════════════════════════════════
    // metadata Struct reconstruction (issue #300 / rust loader parity)
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Reconstruct the raw <c>google.protobuf.Struct</c> proto shape for every
    /// <c>metadata</c> field of the program view. Proto3-JSON collapses a Struct
    /// to a plain object (<c>{kind: "function", …}</c>), but the self-hosted
    /// engine reads metadata through the proto object API
    /// (<c>func.metadata.fields['kind'].stringValue</c>, the <c>whichKind</c>/
    /// <c>hasStringValue</c> discriminators on each <c>Value</c>). Each metadata
    /// Struct is therefore re-expanded to <c>{fields: {key: Value}}</c>.
    /// </summary>
    private static BallValue NormalizeMetadata(BallValue value)
    {
        switch (value)
        {
            case BallMap map:
                var outMap = new BallMap(map.Count);
                foreach (var (key, val) in map.Entries())
                {
                    if (key == "metadata" && val is BallMap structMap)
                    {
                        outMap.Set(key, WrapStruct(structMap));
                    }
                    else
                    {
                        outMap.Set(key, NormalizeMetadata(val));
                    }
                }

                return outMap;
            case BallList list:
                var outList = new BallList();
                foreach (var item in list.Snapshot())
                {
                    outList.Add(NormalizeMetadata(item));
                }

                return outList;
            default:
                return value;
        }
    }

    /// <summary>A collapsed metadata object → the raw Struct shape <c>{fields: {key: Value}}</c>.</summary>
    private static BallValue WrapStruct(BallMap map)
    {
        var fields = new BallMap(map.Count);
        foreach (var (key, val) in map.Entries())
        {
            fields.Set(key, WrapValue(val));
        }

        var outMap = new BallMap(1);
        outMap.Set("fields", fields);
        return outMap;
    }

    /// <summary>A plain metadata value → a <c>google.protobuf.Value</c> wrapper (the arm keyed by its kind).</summary>
    private static BallValue WrapValue(BallValue value)
    {
        var outMap = new BallMap(1);
        switch (value)
        {
            case BallNull:
                outMap.Set("nullValue", BallValue.Int(0));
                break;
            case BallBool b:
                outMap.Set("boolValue", b);
                break;
            case BallInt i:
                outMap.Set("numberValue", BallValue.Double(i.Value));
                break;
            case BallDouble d:
                outMap.Set("numberValue", d);
                break;
            case BallString s:
                outMap.Set("stringValue", s);
                break;
            case BallList list:
                var values = new BallList();
                foreach (var item in list.Snapshot())
                {
                    values.Add(WrapValue(item));
                }

                var listValue = new BallMap(1);
                listValue.Set("values", values);
                outMap.Set("listValue", listValue);
                break;
            case BallMap m:
                outMap.Set("structValue", WrapStruct(m));
                break;
            default:
                outMap.Set("stringValue", BallValue.Str(value.ToString() ?? string.Empty));
                break;
        }

        return outMap;
    }
}
