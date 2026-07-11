namespace Ball.Shared;

/// <summary>
/// Native implementation of the <c>ball_proto</c> access-pattern base functions
/// (issue #383) — the protobuf-compatibility layer the self-hosted engine reads
/// its (already-deserialized) target program through. These have
/// <c>isBase: true</c> and no body (invariant #3); this class is their C#
/// implementation, the sibling of <c>rust/engine/src/ball_proto.rs</c> /
/// <c>rust/shared/src/runtime.rs</c>'s <c>ball_proto</c> section, operating on
/// the canonical proto3-JSON <see cref="BallValue"/> view the engine loader
/// produces (a tree of insertion-ordered <see cref="BallMap"/>s keyed by
/// camelCase <c>jsonName</c>s, oneofs represented by which variant key is
/// present).
///
/// <para>Semantics match <c>dart/shared/lib/ball_proto.dart</c> (the
/// authoritative definition) exactly:</para>
/// <list type="bullet">
/// <item>A <b>discriminator</b> (<c>whichExpr</c>/<c>whichValue</c>/
/// <c>whichStmt</c>/<c>whichKind</c>/<c>whichSource</c>) returns the name of
/// whichever of its variant keys is present on the input map, checked in
/// declaration order, or <c>"notSet"</c> if none is.</item>
/// <item>A <b>presence check</b> (<c>hasBody</c>/<c>hasInput</c>/…, via
/// <see cref="HasField"/>) returns whether the named field is present and
/// non-default — an absent key, an explicit <c>null</c>, an empty string, or an
/// empty list/map all read as <em>not present</em> (the proto3 rule).</item>
/// </list>
///
/// <para>The compiler (<c>csharp/compiler/src/BaseCall.cs</c>) routes every
/// <c>ball_proto.&lt;fn&gt;</c> base call to a method here; the compiled engine
/// (<c>csharp/engine/src/CompiledEngine.cs</c>) therefore calls into this class.
/// It is unit-tested against real fixture IR shapes in
/// <c>csharp/engine/test/BallProtoTests.cs</c>.</para>
/// </summary>
public static class BallProto
{
    // ════════════════════════════════════════════════════════════
    // Oneof discriminators
    // ════════════════════════════════════════════════════════════

    // The oneof variant keys of each discriminated message, in the check order
    // ball_proto.dart declares (the first present key wins). Keys are canonical
    // proto3 jsonNames — the shape the engine loader produces.
    private static readonly string[] ExprVariants =
        { "call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda" };

    private static readonly string[] LiteralVariants =
        { "intValue", "doubleValue", "stringValue", "boolValue", "bytesValue", "listValue" };

    private static readonly string[] StmtVariants = { "let", "expression" };

    private static readonly string[] ValueKindVariants =
        { "nullValue", "numberValue", "stringValue", "boolValue", "structValue", "listValue" };

    private static readonly string[] SourceVariants = { "http", "file", "git", "registry", "inline" };

    /// <summary>
    /// Shared discriminator: the first <paramref name="variants"/> key present
    /// (and non-null) on <paramref name="obj"/>, or <c>"notSet"</c>. A non-map
    /// input has no oneof set, so it is <c>"notSet"</c> too (matching
    /// <c>ball_proto.dart</c>, which treats a missing/empty object the same way
    /// rather than throwing).
    /// </summary>
    private static BallValue Which(BallValue obj, string[] variants)
    {
        var fields = AsFields(obj);
        if (fields is not null)
        {
            foreach (var variant in variants)
            {
                var value = fields.Get(variant);
                if (value is not null && value is not BallNull)
                {
                    return BallValue.Str(variant);
                }
            }
        }

        return BallValue.Str("notSet");
    }

    /// <summary><c>whichExpr(obj)</c> — which <c>Expression</c> oneof arm is set.</summary>
    public static BallValue WhichExpr(BallValue obj) => Which(obj, ExprVariants);

    /// <summary><c>whichValue(obj)</c> — which <c>Literal</c> value arm is set.</summary>
    public static BallValue WhichValue(BallValue obj) => Which(obj, LiteralVariants);

    /// <summary><c>whichStmt(obj)</c> — which <c>Statement</c> arm is set.</summary>
    public static BallValue WhichStmt(BallValue obj) => Which(obj, StmtVariants);

    /// <summary><c>whichKind(obj)</c> — which <c>google.protobuf.Value</c> kind is set.</summary>
    public static BallValue WhichKind(BallValue obj) => Which(obj, ValueKindVariants);

    /// <summary><c>whichSource(obj)</c> — which <c>ModuleImport</c> source is set.</summary>
    public static BallValue WhichSource(BallValue obj) => Which(obj, SourceVariants);

    // ════════════════════════════════════════════════════════════
    // Presence checks
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// <c>has&lt;Field&gt;(obj)</c> — whether <paramref name="field"/> is present
    /// and non-default on <paramref name="obj"/>. "Non-default" follows proto3:
    /// an absent key, an explicit <c>null</c>, an empty string, or an empty
    /// list/map all read as <em>not present</em> (the same rule the Dart getters
    /// encode). A present scalar/message reads as present.
    /// </summary>
    public static BallValue HasField(BallValue obj, string field)
    {
        var fields = AsFields(obj);
        var value = fields?.Get(field);
        var present = value switch
        {
            null or BallNull => false,
            BallString s => s.Value.Length != 0,
            BallList l => l.Count != 0,
            BallMap m => m.Count != 0,
            BallMessage msg => msg.Count != 0,
            _ => true,
        };
        return BallValue.Bool(present);
    }

    // ════════════════════════════════════════════════════════════
    // Safe field get / set
    // ════════════════════════════════════════════════════════════

    /// <summary><c>getField(obj, name)</c> — read <paramref name="name"/>, or <c>null</c> if missing/not a map.</summary>
    public static BallValue GetField(BallValue obj, BallValue name) =>
        AsFields(obj)?.Get(AsStr(name)) ?? BallValue.Null;

    /// <summary><c>getFieldOr(obj, name, default)</c> — read <paramref name="name"/>, or <paramref name="defaultValue"/> if missing.</summary>
    public static BallValue GetFieldOr(BallValue obj, BallValue name, BallValue defaultValue)
    {
        var value = AsFields(obj)?.Get(AsStr(name));
        return value is null or BallNull ? defaultValue : value;
    }

    /// <summary>
    /// <c>setField(obj, name, value)</c> — set <paramref name="name"/> on a
    /// (reference-semantic) map/message and return it. A non-map/message
    /// <paramref name="obj"/> is returned unchanged (never throws — matching
    /// <c>ball_proto.dart</c>'s permissive setter).
    /// </summary>
    public static BallValue SetField(BallValue obj, BallValue name, BallValue value)
    {
        switch (obj)
        {
            case BallMap map:
                map.Set(AsStr(name), value);
                return map;
            case BallMessage msg:
                msg.Set(AsStr(name), value);
                return msg;
            default:
                return obj;
        }
    }

    // ════════════════════════════════════════════════════════════
    // Struct field access (google.protobuf.Struct)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>getStructField(struct, key)</c> — the raw <c>Value</c> map at <paramref name="key"/>, or <c>null</c>.</summary>
    public static BallValue GetStructField(BallValue structValue, BallValue key) =>
        StructFields(structValue)?.Get(AsStr(key)) ?? BallValue.Null;

    /// <summary><c>getStringField(struct, key)</c> — the string value at <paramref name="key"/>, or <c>""</c>.</summary>
    public static BallValue GetStringField(BallValue structValue, BallValue key) =>
        BallValue.Str(ValueArm(GetStructField(structValue, key), "stringValue") is BallString s ? s.Value : string.Empty);

    /// <summary><c>getBoolField(struct, key)</c> — the bool value at <paramref name="key"/>, or <c>false</c>.</summary>
    public static BallValue GetBoolField(BallValue structValue, BallValue key) =>
        BallValue.Bool(ValueArm(GetStructField(structValue, key), "boolValue") is BallBool b && b.Value);

    /// <summary><c>getListField(struct, key)</c> — the list value at <paramref name="key"/>, or <c>[]</c>.</summary>
    public static BallValue GetListField(BallValue structValue, BallValue key)
    {
        var arm = ValueArm(GetStructField(structValue, key), "listValue");
        // A ListValue is {values: [...]}; unwrap to the element list.
        if (arm is BallMap lv && lv.Get("values") is BallList inner)
        {
            return inner;
        }

        return arm is BallList direct ? direct : new BallList();
    }

    /// <summary><c>getNumberField(struct, key)</c> — the number value at <paramref name="key"/>, or <c>0</c>.</summary>
    public static BallValue GetNumberField(BallValue structValue, BallValue key)
    {
        var arm = ValueArm(GetStructField(structValue, key), "numberValue");
        return arm switch
        {
            BallDouble d => d,
            BallInt i => i,
            _ => BallValue.Double(0.0),
        };
    }

    /// <summary><c>getStructFieldKeys(struct)</c> — every key of a Struct/metadata map, in order.</summary>
    public static BallValue GetStructFieldKeys(BallValue structValue)
    {
        var fields = StructFields(structValue);
        var list = new BallList();
        if (fields is not null)
        {
            foreach (var key in fields.Keys)
            {
                list.Add(BallValue.Str(key));
            }
        }

        return list;
    }

    // ════════════════════════════════════════════════════════════
    // Proto3 defaults
    // ════════════════════════════════════════════════════════════

    /// <summary><c>ensureDefaults(obj, messageType)</c> — the engine loader materializes proto3 defaults, so this is a pass-through.</summary>
    public static BallValue EnsureDefaults(BallValue obj, BallValue messageType) => obj;

    /// <summary><c>defaultString()</c> — proto3 default for a string field.</summary>
    public static BallValue DefaultString() => BallValue.Str(string.Empty);

    /// <summary><c>defaultList()</c> — proto3 default for a repeated field.</summary>
    public static BallValue DefaultList() => new BallList();

    /// <summary><c>defaultBool()</c> — proto3 default for a bool field.</summary>
    public static BallValue DefaultBool() => BallValue.Bool(false);

    /// <summary><c>defaultInt()</c> — proto3 default for an int field.</summary>
    public static BallValue DefaultInt() => BallValue.Int(0);

    // ════════════════════════════════════════════════════════════
    // Type-enum-constant validators (exprCase / literalCase / stmtCase)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>exprCase(name)</c> — validate an <c>Expression</c> oneof case name (identity when known).</summary>
    public static BallValue ExprCase(BallValue name) => ValidateCase(name, ExprVariants);

    /// <summary><c>literalCase(name)</c> — validate a <c>Literal</c> value case name (identity when known).</summary>
    public static BallValue LiteralCase(BallValue name) => ValidateCase(name, LiteralVariants);

    /// <summary><c>stmtCase(name)</c> — validate a <c>Statement</c> oneof case name (identity when known).</summary>
    public static BallValue StmtCase(BallValue name) => ValidateCase(name, StmtVariants);

    // ════════════════════════════════════════════════════════════
    // Virtual properties
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Resolve a virtual (computed) property <paramref name="name"/> on a native
    /// value, or <c>null</c> if <paramref name="name"/> is not a virtual
    /// property of the value's type (the caller then falls back to an ordinary
    /// field lookup). Covers the <c>.length</c>/<c>.isEmpty</c>/… properties Ball
    /// programs read as bare field accesses on primitives rather than as
    /// <c>std_collections</c> calls — the sibling of
    /// <c>ball_proto.rs</c>'s <c>virtual_property</c>.
    /// </summary>
    public static BallValue? VirtualProperty(BallValue value, string name) => (value, name) switch
    {
        (BallString s, "length") => BallValue.Int(s.Value.Length),
        (BallList l, "length") => BallValue.Int(l.Count),
        (BallMap m, "length") => BallValue.Int(m.Count),
        (BallBytes b, "length") => BallValue.Int(b.Value.Length),
        (BallString s, "isEmpty") => BallValue.Bool(s.Value.Length == 0),
        (BallList l, "isEmpty") => BallValue.Bool(l.Count == 0),
        (BallMap m, "isEmpty") => BallValue.Bool(m.Count == 0),
        (BallString s, "isNotEmpty") => BallValue.Bool(s.Value.Length != 0),
        (BallList l, "isNotEmpty") => BallValue.Bool(l.Count != 0),
        (BallMap m, "isNotEmpty") => BallValue.Bool(m.Count != 0),
        _ => null,
    };

    // ════════════════════════════════════════════════════════════
    // Helpers
    // ════════════════════════════════════════════════════════════

    /// <summary>The field map of a map/message value, or <c>null</c> for any other value (a non-object has no fields).</summary>
    private static BallMap? AsFields(BallValue obj) => obj switch
    {
        BallMap map => map,
        BallMessage msg => msg.Fields,
        _ => null,
    };

    /// <summary>
    /// The <c>fields</c> submap of a raw <c>google.protobuf.Struct</c> shape
    /// (<c>{fields: {key: Value}}</c>, what the loader reconstructs for
    /// metadata), or the object's own field map when it is already a flat map
    /// (a defensive fallback for a plain metadata object).
    /// </summary>
    private static BallMap? StructFields(BallValue structValue)
    {
        var fields = AsFields(structValue);
        if (fields?.Get("fields") is BallMap inner)
        {
            return inner;
        }

        return fields;
    }

    /// <summary>The value carried by <paramref name="arm"/> of a <c>google.protobuf.Value</c> map, or <c>null</c>.</summary>
    private static BallValue? ValueArm(BallValue value, string arm) =>
        AsFields(value)?.Get(arm);

    // The engine reads a case name back as the name (it compares it against a
    // whichExpr/whichValue/whichStmt result), so validation is identity — the
    // `variants` list documents the accepted set. Matches the Rust sibling,
    // which lowers exprCase/literalCase/stmtCase to the bare name argument.
    private static BallValue ValidateCase(BallValue name, string[] variants) => BallValue.Str(AsStr(name));

    private static string AsStr(BallValue value) => value is BallString s ? s.Value : value.ToString() ?? string.Empty;
}
