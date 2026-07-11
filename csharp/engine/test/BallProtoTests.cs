using Ball.Engine;
using Ball.Shared;

namespace Ball.Engine.Tests;

/// <summary>
/// Unit tests for the <see cref="BallProto"/> access-pattern base functions
/// (issue #383) — the protobuf-compat layer the self-hosted engine reads every
/// target program through. Mirrors <c>rust/engine/src/ball_proto.rs</c>'s tests:
/// synthetic IR shapes for the discriminator/presence/field semantics, plus a
/// <b>real</b> program IR shape (the <c>hello_world</c> example loaded through
/// <see cref="Loader"/>) to prove the natives work on the actual view the engine
/// consumes.
/// </summary>
public sealed class BallProtoTests
{
    private static BallMap Map(params (string Key, BallValue Value)[] pairs)
    {
        var map = new BallMap();
        foreach (var (key, value) in pairs)
        {
            map.Set(key, value);
        }

        return map;
    }

    private static string Str(BallValue value) => ((BallString)value).Value;

    private static bool Truth(BallValue value) => ((BallBool)value).Value;

    // ── Oneof discriminators ──────────────────────────────────────

    [Fact]
    public void WhichExpr_returns_the_present_oneof_arm()
    {
        var call = Map(("call", Map(("function", BallValue.Str("f")))));
        Assert.Equal("call", Str(BallProto.WhichExpr(call)));

        var reference = Map(("reference", Map(("name", BallValue.Str("x")))));
        Assert.Equal("reference", Str(BallProto.WhichExpr(reference)));
    }

    [Fact]
    public void WhichExpr_returns_notSet_when_no_arm_present()
    {
        Assert.Equal("notSet", Str(BallProto.WhichExpr(new BallMap())));
        Assert.Equal("notSet", Str(BallProto.WhichExpr(BallValue.Null)));
    }

    [Fact]
    public void WhichValue_and_WhichKind_use_their_own_variant_sets()
    {
        var literal = Map(("stringValue", BallValue.Str("hi")));
        Assert.Equal("stringValue", Str(BallProto.WhichValue(literal)));

        var value = Map(("numberValue", BallValue.Double(1.0)));
        Assert.Equal("numberValue", Str(BallProto.WhichKind(value)));
    }

    [Fact]
    public void WhichExpr_checks_variants_in_declaration_order()
    {
        // A map with two arms present returns the first in declaration order
        // (call before literal) — the first-present-wins rule ball_proto.dart uses.
        var ambiguous = Map(("literal", Map()), ("call", Map(("function", BallValue.Str("f")))));
        Assert.Equal("call", Str(BallProto.WhichExpr(ambiguous)));
    }

    // ── Presence checks ───────────────────────────────────────────

    [Fact]
    public void HasField_follows_proto3_present_and_non_default()
    {
        var func = Map(("body", Map(("literal", BallValue.Null))));
        Assert.True(Truth(BallProto.HasField(func, "body")));
        Assert.False(Truth(BallProto.HasField(func, "metadata")));

        // Empty string / empty list read as not present.
        var empties = Map(("name", BallValue.Str(string.Empty)), ("items", new BallList()));
        Assert.False(Truth(BallProto.HasField(empties, "name")));
        Assert.False(Truth(BallProto.HasField(empties, "items")));
    }

    // ── Safe field get / set ──────────────────────────────────────

    [Fact]
    public void GetField_and_SetField_round_trip()
    {
        var obj = Map(("a", BallValue.Int(1)));
        Assert.Equal(1L, ((BallInt)BallProto.GetField(obj, BallValue.Str("a"))).Value);
        Assert.IsType<BallNull>(BallProto.GetField(obj, BallValue.Str("missing")));
        Assert.Equal(9L, ((BallInt)BallProto.GetFieldOr(obj, BallValue.Str("missing"), BallValue.Int(9))).Value);

        var updated = BallProto.SetField(obj, BallValue.Str("b"), BallValue.Int(2));
        Assert.Equal(2L, ((BallInt)BallProto.GetField(updated, BallValue.Str("b"))).Value);
        // Reference semantics: the set is visible through the original map.
        Assert.Equal(2L, ((BallInt)BallProto.GetField(obj, BallValue.Str("b"))).Value);
    }

    // ── Struct access, defaults, virtual properties ───────────────

    [Fact]
    public void GetStructFieldKeys_lists_a_struct_fields()
    {
        var structVal = Map(("fields", Map(("kind", BallValue.Str("function")), ("doc", BallValue.Str("x")))));
        var keys = (BallList)BallProto.GetStructFieldKeys(structVal);
        Assert.Equal(2, keys.Count);
        Assert.Equal("kind", Str(keys.Get(0)));
        Assert.Equal("doc", Str(keys.Get(1)));
    }

    [Fact]
    public void GetStringField_reads_the_wrapped_value_or_default()
    {
        var structVal = Map(("fields", Map(("kind", Map(("stringValue", BallValue.Str("function")))))));
        Assert.Equal("function", Str(BallProto.GetStringField(structVal, BallValue.Str("kind"))));
        Assert.Equal(string.Empty, Str(BallProto.GetStringField(structVal, BallValue.Str("absent"))));
    }

    [Fact]
    public void Defaults_are_the_proto3_zero_values()
    {
        Assert.Equal(string.Empty, Str(BallProto.DefaultString()));
        Assert.Equal(0, ((BallList)BallProto.DefaultList()).Count);
        Assert.False(Truth(BallProto.DefaultBool()));
        Assert.Equal(0L, ((BallInt)BallProto.DefaultInt()).Value);
    }

    [Fact]
    public void VirtualProperty_resolves_length_and_isEmpty()
    {
        Assert.Equal(3L, ((BallInt)BallProto.VirtualProperty(BallValue.Str("abc"), "length")!).Value);
        Assert.False(Truth(BallProto.VirtualProperty(new BallList(new[] { BallValue.Int(1) }), "isEmpty")!));
        // Not a virtual property -> null (the engine falls back to a field lookup).
        Assert.Null(BallProto.VirtualProperty(BallValue.Int(1), "length"));
    }

    // ── Real program IR shape (loaded through the loader) ──────────

    [Fact]
    public void Discriminators_work_on_a_real_loaded_program_view()
    {
        var path = Path.Combine(TestPaths.RepoRoot(), "examples", "hello_world", "hello_world.ball.json");
        var engine = BallEngine.FromJson(File.ReadAllText(path));

        // Navigate the canonical view: program.modules[main].functions[main].
        var modules = (BallList)BallProto.GetField(engine.ProgramValue, BallValue.Str("modules"));
        var mainModule = FindByName(modules, "main");
        var functions = (BallList)BallProto.GetField(mainModule, BallValue.Str("functions"));
        var mainFn = FindByName(functions, "main");

        // The entry function has a body, and that body is a `call` (print).
        Assert.True(Truth(BallProto.HasField(mainFn, "body")));
        var body = BallProto.GetField(mainFn, BallValue.Str("body"));
        Assert.Equal("call", Str(BallProto.WhichExpr(body)));
    }

    private static BallValue FindByName(BallList items, string name)
    {
        for (var i = 0; i < items.Count; i++)
        {
            var item = items.Get(i);
            if (Str(BallProto.GetField(item, BallValue.Str("name"))) == name)
            {
                return item;
            }
        }

        throw new Xunit.Sdk.XunitException($"no item named '{name}' in the list");
    }
}
