namespace Ball.Shared;

/// <summary>
/// Dynamic built-in-method dispatch + type-literal markers (issue #383, Round 2).
///
/// <para>The self-hosted engine's own Dart source calls built-in methods on core
/// types (<c>match.group(1)</c>, <c>list.addAll(x)</c>, <c>int.tryParse(s)</c>,
/// <c>set.union(y)</c>, …). The encoder lowers each to a <c>call</c> with an
/// <b>empty module</b> and the method name as the function, packing the receiver
/// and arguments into the input as <c>{self, arg0, arg1, …}</c> — there is no
/// static receiver type, so the compiler cannot resolve them to a concrete
/// member. The compiler routes such a call (empty module, not a known callable,
/// not a local) to <see cref="CallMethod"/>, which dispatches on the method name
/// and the receiver's <em>runtime</em> type.</para>
///
/// <para>A bare reference to a core type name (<c>num</c>/<c>int</c>/
/// <c>DateTime</c>/…), used as a static-method receiver or a type argument, is
/// emitted as a <see cref="TypeLiteral"/> marker so it is a valid value the
/// dispatch can key on.</para>
///
/// <para><b>Fail loud, never wrong:</b> a method whose exact Dart semantics are
/// not implemented here throws <see cref="BallRuntimeException"/> rather than
/// returning a plausible-but-wrong value — the same discipline as
/// <see cref="UnsupportedBaseCall"/>. Compiling is decoupled from running: every
/// such call is valid C# (it reduces the self-host compile-error count), and the
/// unimplemented ones surface at runtime only if a program actually reaches them
/// (the base corpus does not).</para>
/// </summary>
public static partial class BallRuntime
{
    /// <summary>The reserved <see cref="BallMessage.TypeName"/> of a type-literal marker.</summary>
    private const string TypeMarker = "$Type";

    /// <summary>
    /// A marker value for a bare reference to a core type name (<c>int</c>,
    /// <c>List</c>, <c>DateTime</c>, …) — used as the receiver of a static-method
    /// call (<c>int.tryParse</c>) or a type argument. Represented as a
    /// <see cref="BallMessage"/> with the reserved <see cref="TypeMarker"/> type
    /// so <see cref="CallMethod"/> can distinguish it from a real string value.
    /// </summary>
    public static BallValue TypeLiteral(string name) =>
        new BallMessage(TypeMarker, new BallMap { ["name"] = BallValue.Str(name) });

    /// <summary>The core-type name a type-literal marker carries, or <c>null</c> if <paramref name="value"/> is not one.</summary>
    private static string? TypeLiteralName(BallValue value) =>
        value is BallMessage m && m.TypeName == TypeMarker && m.Get("name") is BallString s ? s.Value : null;

    /// <summary>Read the <paramref name="key"/> argument out of a method-call input map (<c>self</c>/<c>arg0</c>/…), or <c>null</c>.</summary>
    private static BallValue MethodArg(BallValue input, string key) =>
        input is BallMap m ? m.Get(key) ?? BallValue.Null : BallValue.Null;

    /// <summary>
    /// Read a declared parameter from a call input by name, falling back to its
    /// positional <c>arg{i}</c> slot (invariant #1's "one input" packing) — the
    /// method/constructor param-binding convention. Mirrors Rust's
    /// <c>ball_arg_get</c>.
    /// </summary>
    public static BallValue ArgGet(BallValue input, string namedKey, string positionalKey) => input switch
    {
        BallMap m => m.Get(namedKey) ?? m.Get(positionalKey) ?? BallValue.Null,
        BallMessage msg => msg.Get(namedKey) ?? msg.Get(positionalKey) ?? BallValue.Null,
        _ => BallValue.Null,
    };

    /// <summary>
    /// Implicit-<c>this</c> injection (issue #383): weave the enclosing receiver
    /// into a <c>this.method(args)</c> call's input so the instance-method
    /// dispatcher finds a receiver. A multi-argument <c>{arg0, arg1}</c> message
    /// (or a zero-argument <c>Null</c>) gets <c>self</c> merged in; a single
    /// positional argument is wrapped as <c>{self, arg0}</c> (see
    /// <see cref="Arg0WithSelf"/>). Mirrors Rust's <c>ball_with_self</c>.
    /// </summary>
    public static BallValue WithSelf(BallValue input, BallValue self)
    {
        switch (input)
        {
            case BallMap map:
                map.Set("self", self);
                return map;
            case BallMessage message:
                message.Set("self", self);
                return message;
            case BallNull:
                var fresh = new BallMap();
                fresh.Set("self", self);
                return fresh;
            default:
                return input;
        }
    }

    /// <summary>Implicit-<c>this</c> injection for a single positional argument — wrap it as <c>{self, arg0}</c> (Rust's <c>ball_arg0_with_self</c>).</summary>
    public static BallValue Arg0WithSelf(BallValue arg, BallValue self)
    {
        var map = new BallMap();
        map.Set("self", self);
        map.Set("arg0", arg);
        return map;
    }

    /// <summary>
    /// Dispatch a built-in method call <c><paramref name="method"/>(…)</c> on the
    /// receiver carried in <paramref name="input"/>'s <c>self</c> field, with
    /// arguments <c>arg0</c>/<c>arg1</c>/… The compiler routes here for a call
    /// whose callee is neither a base function, a known user function, nor a
    /// local function value (see <c>CSharpCompiler.CompileCall</c>).
    /// </summary>
    public static BallValue CallMethod(string method, BallValue input)
    {
        var self = MethodArg(input, "self");
        var a0 = MethodArg(input, "arg0");
        var a1 = MethodArg(input, "arg1");

        return method switch
        {
            // ── Collection mutation (reference semantics — mutate the backing) ──
            "addAll" => MethodAddAll(self, a0),
            "clear" => MethodClear(self),
            "remove" => MethodRemove(self, a0),
            "setAll" => MethodSetAll(self, a0, a1),

            // ── Collection views / transforms ──
            "cast" => self, // dynamic representation: cast<T>() is an identity view.
            "toSet" => SetCreate(self),
            "toList" => new BallList(AsList(self).Snapshot()),
            "elementAt" => ListGet(self, a0),
            "indexWhere" => MethodIndexWhere(self, a0),

            // ── Higher-order callbacks the self-hosted engine invokes on its own values ──
            "apply" => MethodApply(self, a0, a1),
            "fold" => MethodFold(self, a0, a1),

            // ── Numeric instance methods on a boxed double/int (the engine's own
            //    number-method switch calls these on a raw num receiver) ──
            "remainder" => Remainder(self, a0),
            "toInt" => ToInt(self),
            "toDouble" => ToDouble(self),

            // ── Set algebra (a set is a duplicate-free list) ──
            "union" => SetUnion(self, a0),
            "intersection" => SetIntersection(self, a0),
            "difference" => SetDifference(self, a0),

            // ── Static constructors / parsers on a type literal ──
            "tryParse" => MethodParseNumber(self, a0, tryParse: true),
            "parse" => TypeLiteralName(self) == "DateTime"
                ? MethodDateTimeParse(a0)
                : MethodParseNumber(self, a0, tryParse: false),
            "filled" => MethodFilled(self, a0, a1),
            "unmodifiable" => MethodUnmodifiable(self, a0),
            "fromCharCode" => StringFromCharCode(a0),

            // ── Regular expressions (RegExp receiver → Match, then Match.group) ──
            "firstMatch" => RegexFirstMatch(self, a0),
            "hasMatch" => RegexHasMatch(self, a0),
            "allMatches" => RegexAllMatches(self, a0),
            "group" => MatchGroup(self, a0),

            // ── Top-level Dart core functions ──
            "identical" => BallValue.Bool(MethodIdentical(a0, a1)),

            // ── JSON codec — the engine's `const JsonEncoder()/JsonDecoder().convert(x)` (std_convert) ──
            "convert" => MethodConvert(self, a0),

            // ── DateTime (static + instance) ──
            "now" => MethodDateTimeNow(),
            "fromMillisecondsSinceEpoch" => MethodDateTimeFromMillis(input),
            "toIso8601String" => MethodDateTimeToIso8601(self),

            // A proto presence getter (`binding.hasValue()`) called as a method —
            // route to the ball_proto presence check on the named field.
            _ when method.StartsWith("has", StringComparison.Ordinal) && method.Length > 3
                => BallProto.HasField(self, char.ToLowerInvariant(method[3]) + method[4..]),

            _ => UnsupportedMethod(method, self),
        };
    }

    private static BallValue UnsupportedMethod(string method, BallValue self) =>
        throw new BallRuntimeException(
            $"built-in method '{method}' on {TypeName(self)} is not implemented by the C# target yet");

    // ── addAll / clear / remove / setAll ─────────────────────────

    private static BallValue MethodAddAll(BallValue self, BallValue other)
    {
        switch (self)
        {
            case BallList list:
                foreach (var item in AsList(other).Snapshot())
                {
                    list.Add(item);
                }

                return BallValue.Null;
            case BallMap map:
                foreach (var (key, value) in MapLikeEntries(other))
                {
                    map.Set(key, value);
                }

                return BallValue.Null;
            case BallMessage message:
                foreach (var (key, value) in MapLikeEntries(other))
                {
                    message.Set(key, value);
                }

                return BallValue.Null;
            default:
                return UnsupportedMethod("addAll", self);
        }
    }

    /// <summary>The entries of a map-like value (a <see cref="BallMap"/> or a <see cref="BallMessage"/>) — for merging.</summary>
    private static IEnumerable<KeyValuePair<string, BallValue>> MapLikeEntries(BallValue value) => value switch
    {
        BallMap m => m.Entries(),
        BallMessage msg => msg.Fields.Entries(),
        _ => throw new BallRuntimeException($"expected a map, got {TypeName(value)}"),
    };

    private static BallValue MethodClear(BallValue self)
    {
        switch (self)
        {
            case BallList list:
                ListClear(list);
                return BallValue.Null;
            case BallMap map:
                map.Clear();
                return BallValue.Null;
            default:
                return UnsupportedMethod("clear", self);
        }
    }

    private static BallValue MethodRemove(BallValue self, BallValue value)
    {
        switch (self)
        {
            case BallList list:
                var snapshot = list.Snapshot();
                for (var i = 0; i < snapshot.Count; i++)
                {
                    if (BallValue.ValueEquals(snapshot[i], value))
                    {
                        ListRemoveAt(list, BallValue.Int(i));
                        return BallValue.Bool(true);
                    }
                }

                return BallValue.Bool(false);
            case BallMap map:
                return map.Remove(MapKey(value)) ?? BallValue.Null;
            default:
                return UnsupportedMethod("remove", self);
        }
    }

    // ── Core-collection copy/fill constructors (Map.from / List.of / List.filled) ──

    /// <summary><c>Map.from(source)</c> / <c>Map.of(source)</c> — a fresh insertion-ordered copy of a map-like value.</summary>
    public static BallValue MapCopy(BallValue source) => source switch
    {
        BallMap m => m.Snapshot(),
        BallMessage msg => msg.Fields.Snapshot(),
        BallNull => new BallMap(),
        _ => throw new BallRuntimeException($"Map.from/of expected a map, got {TypeName(source)}"),
    };

    /// <summary><c>List.from(source)</c> / <c>List.of(source)</c> — a fresh copy of a list-like value (a set is a list).</summary>
    public static BallValue ListCopy(BallValue source) => source switch
    {
        BallList l => new BallList(l.Snapshot()),
        BallMessage msg when msg.Get("items") is BallList items => new BallList(items.Snapshot()),
        BallNull => new BallList(),
        _ => throw new BallRuntimeException($"List.from/of expected an iterable, got {TypeName(source)}"),
    };

    /// <summary><c>List.filled(count, fill)</c> — a new list of <paramref name="count"/> copies of <paramref name="fill"/> (Dart shares the one fill reference).</summary>
    public static BallValue ListFilled(BallValue count, BallValue fill)
    {
        var n = AsIndex(count);
        var list = new BallList();
        for (var i = 0; i < n; i++)
        {
            list.Add(fill);
        }

        return list;
    }

    private static BallValue MethodSetAll(BallValue self, BallValue index, BallValue values)
    {
        var list = AsList(self);
        var start = AsIndex(index);
        var i = start;
        foreach (var value in AsList(values).Snapshot())
        {
            ListSet(list, BallValue.Int(i), value);
            i++;
        }

        return BallValue.Null;
    }

    private static BallValue MethodIndexWhere(BallValue self, BallValue predicate)
    {
        var list = AsList(self).Snapshot();
        for (var i = 0; i < list.Count; i++)
        {
            if (Truthy(CallFunction(predicate, list[i])))
            {
                return BallValue.Int(i);
            }
        }

        return BallValue.Int(-1);
    }

    // ── Higher-order callbacks the self-hosted engine invokes on its own values ──

    /// <summary>
    /// Dart's top-level <c>Function.apply(callee, positionalArgs)</c> — the std
    /// <c>invoke</c> handler's dynamic dispatch (<c>engine_std.dart</c>'s
    /// <c>_stdInvoke</c>). Encoded as <c>Function.apply(callee, [arg])</c>, so
    /// <paramref name="self"/> is the <c>Function</c> type literal,
    /// <paramref name="callee"/> the target function, and
    /// <paramref name="positional"/> the one-element positional-args list. (A
    /// <c>callee.apply([arg])</c> form — <paramref name="self"/> the callee — is
    /// also accepted.) Ball functions take one input, so the sole positional
    /// element is passed straight through.
    /// </summary>
    private static BallValue MethodApply(BallValue self, BallValue callee, BallValue positional)
    {
        if (self is BallFunction)
        {
            positional = callee;
            callee = self;
        }

        var args = positional is BallList list ? list.Snapshot() : new List<BallValue> { positional };
        var input = args.Count > 0 ? args[0] : BallValue.Null;
        return InvokeCallable(callee, input);
    }

    /// <summary>
    /// Dart's <c>Iterable.fold&lt;T&gt;(initial, (acc, elem) =&gt; …)</c> — the engine
    /// folds a native list with a two-parameter combine callback (e.g.
    /// <c>string_split</c>'s allocation accounting). The compiled combine binds
    /// its parameters name-or-positionally, so the pair is passed under
    /// <c>arg0</c>/<c>arg1</c>.
    /// </summary>
    private static BallValue MethodFold(BallValue self, BallValue initial, BallValue combine)
    {
        var acc = initial;
        foreach (var element in AsList(self).Snapshot())
        {
            var callArgs = new BallMap();
            callArgs.Set("arg0", acc);
            callArgs.Set("arg1", element);
            acc = InvokeCallable(combine, callArgs);
        }

        return acc;
    }

    /// <summary>
    /// Invoke a first-class callback that may be either a native
    /// <see cref="BallFunction"/> or the engine's own <c>BallFunction</c> value
    /// object (a <see cref="BallMessage"/> wrapping the native closure under its
    /// <c>value</c> field).
    /// </summary>
    private static BallValue InvokeCallable(BallValue callee, BallValue input) => callee switch
    {
        BallFunction => CallFunction(callee, input),
        BallMessage m when m.Get("value") is BallFunction inner => CallFunction(inner, input),
        _ => throw new BallRuntimeException($"apply/fold callback is not callable: {TypeName(callee)}"),
    };

    // ── Static constructors / parsers ────────────────────────────

    private static BallValue MethodParseNumber(BallValue typeLiteral, BallValue value, bool tryParse)
    {
        var typeName = TypeLiteralName(typeLiteral);
        var text = AsStr(value);

        BallValue? parsed = typeName switch
        {
            "int" => long.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var i) ? BallValue.Int(i) : null,
            "double" => double.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var d) ? BallValue.Double(d) : null,
            "num" => long.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var n)
                ? BallValue.Int(n)
                : double.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var nd) ? BallValue.Double(nd) : null,
            _ => throw new BallRuntimeException($"{(tryParse ? "tryParse" : "parse")} on a non-numeric type: {typeName ?? TypeName(typeLiteral)}"),
        };

        if (parsed is not null)
        {
            return parsed;
        }

        // Dart: tryParse returns null on failure; parse throws (catchably).
        return tryParse
            ? BallValue.Null
            : throw new BallThrow(BallValue.Str($"FormatException: invalid {typeName}: {text}"));
    }

    private static BallValue MethodFilled(BallValue typeLiteral, BallValue count, BallValue fill)
    {
        _ = TypeLiteralName(typeLiteral); // List.filled — self is the List type literal.
        var n = AsIndex(count);
        var list = new BallList();
        for (var i = 0; i < n; i++)
        {
            list.Add(fill);
        }

        return list;
    }

    private static BallValue MethodUnmodifiable(BallValue typeLiteral, BallValue source)
    {
        // We do not model immutability; return a snapshot so later mutation of the
        // source is not observed through the "unmodifiable" copy (the observable
        // half of the contract).
        var typeName = TypeLiteralName(typeLiteral);
        return source switch
        {
            BallList list => new BallList(list.Snapshot()),
            BallMap map => map.Snapshot(),
            _ => throw new BallRuntimeException($"unmodifiable on unsupported source {TypeName(source)} (type {typeName})"),
        };
    }

    /// <summary><c>DateTime.now()</c> — a message exposing <c>millisecondsSinceEpoch</c>/<c>microsecondsSinceEpoch</c> (what the engine reads for profiling/timeouts).</summary>
    private static BallValue MethodDateTimeNow()
    {
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return DateTimeMessage(nowMs, isUtc: false);
    }

    /// <summary>
    /// <c>DateTime.fromMillisecondsSinceEpoch(ms, isUtc: …)</c> — the engine's
    /// <c>format_timestamp</c> std_time handler. Returns the same <c>DateTime</c>
    /// message shape as <see cref="MethodDateTimeNow"/>, so a later
    /// <c>.millisecondsSinceEpoch</c> getter or <c>.toIso8601String()</c> resolves.
    /// </summary>
    private static BallValue MethodDateTimeFromMillis(BallValue input)
    {
        var ms = AsInt(MethodArg(input, "arg0"));
        var isUtc = Truthy(MethodArg(input, "isUtc"));
        return DateTimeMessage(ms, isUtc);
    }

    /// <summary><c>DateTime.parse(str)</c> — the engine's <c>parse_timestamp</c> std_time handler. An ISO-8601 string ending in <c>Z</c> is UTC.</summary>
    private static BallValue MethodDateTimeParse(BallValue value)
    {
        var text = AsStr(value);
        DateTimeOffset dto;
        try
        {
            dto = DateTimeOffset.Parse(
                text,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind | System.Globalization.DateTimeStyles.AssumeUniversal);
        }
        catch (FormatException)
        {
            // Dart surfaces an unparseable timestamp as a catchable FormatException.
            throw new BallThrow(BallValue.Str($"FormatException: invalid date: {text}"));
        }

        return DateTimeMessage(dto.ToUnixTimeMilliseconds(), isUtc: text.EndsWith('Z'));
    }

    /// <summary><c>DateTime.toIso8601String()</c> — millisecond-precision ISO-8601, <c>Z</c>-suffixed when UTC (Dart's format for a ms-resolution instant).</summary>
    private static BallValue MethodDateTimeToIso8601(BallValue self)
    {
        var ms = DateTimeField(self, "millisecondsSinceEpoch");
        var isUtc = self is BallMessage m && Truthy(m.Get("isUtc") ?? BallValue.Null);
        var text = DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime
            .ToString("yyyy-MM-ddTHH:mm:ss.fff", System.Globalization.CultureInfo.InvariantCulture);
        return BallValue.Str(isUtc ? text + "Z" : text);
    }

    private static long DateTimeField(BallValue self, string name) =>
        self is BallMessage m && m.Get(name) is { } v
            ? AsInt(v)
            : throw new BallRuntimeException($"expected a DateTime, got {TypeName(self)}");

    private static BallValue DateTimeMessage(long ms, bool isUtc)
    {
        var fields = new BallMap();
        fields.Set("millisecondsSinceEpoch", BallValue.Int(ms));
        fields.Set("microsecondsSinceEpoch", BallValue.Int(ms * 1000));
        fields.Set("isUtc", BallValue.Bool(isUtc));
        return new BallMessage("DateTime", fields);
    }

    // ── JSON codec (std_convert) ─────────────────────────────────

    /// <summary>
    /// <c>const JsonEncoder().convert(value)</c> / <c>const JsonDecoder().convert(text)</c>
    /// — the engine's <c>json_encode</c>/<c>json_decode</c> std_convert handlers.
    /// The receiver is an empty <c>main:JsonEncoder</c>/<c>main:JsonDecoder</c>
    /// message (a bodyless BCL-type <c>messageCreation</c>); dispatch on its short
    /// type name.
    /// </summary>
    private static BallValue MethodConvert(BallValue self, BallValue arg)
    {
        var codec = self is BallMessage m ? ShortTypeName(m.TypeName) : null;
        return codec switch
        {
            "JsonEncoder" => BallValue.Str(JsonEncode(arg)),
            "JsonDecoder" => JsonDecode(AsStr(arg)),
            _ => UnsupportedMethod("convert", self),
        };
    }

    /// <summary>Serialize a JSON-safe Ball value (the tree the engine's <c>_toJsonSafe</c> produces) to compact JSON, matching Dart's default <c>JsonEncoder</c>.</summary>
    private static string JsonEncode(BallValue value)
    {
        var sb = new System.Text.StringBuilder();
        JsonWrite(sb, value);
        return sb.ToString();
    }

    private static void JsonWrite(System.Text.StringBuilder sb, BallValue value)
    {
        switch (value)
        {
            case BallNull:
                sb.Append("null");
                break;
            case BallBool b:
                sb.Append(b.Value ? "true" : "false");
                break;
            case BallInt or BallDouble:
                sb.Append(value.ToString()); // Dart num.toString() (whole doubles keep `.0`).
                break;
            case BallString s:
                JsonWriteString(sb, s.Value);
                break;
            case BallList list:
                sb.Append('[');
                var firstItem = true;
                foreach (var item in list.Snapshot())
                {
                    if (!firstItem)
                    {
                        sb.Append(',');
                    }

                    firstItem = false;
                    JsonWrite(sb, item);
                }

                sb.Append(']');
                break;
            case BallMap map:
                sb.Append('{');
                var firstEntry = true;
                foreach (var (key, entryValue) in map.Entries())
                {
                    if (!firstEntry)
                    {
                        sb.Append(',');
                    }

                    firstEntry = false;
                    JsonWriteString(sb, key);
                    sb.Append(':');
                    JsonWrite(sb, entryValue);
                }

                sb.Append('}');
                break;
            default:
                throw new BallRuntimeException($"JsonEncoder cannot convert {TypeName(value)}");
        }
    }

    private static void JsonWriteString(System.Text.StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (ch < 0x20)
                    {
                        sb.Append("\\u").Append(((int)ch).ToString("x4", System.Globalization.CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(ch);
                    }

                    break;
            }
        }

        sb.Append('"');
    }

    /// <summary>Parse JSON text into a native Ball value tree, matching Dart's <c>JsonDecoder</c> (integer literals → int, fractional/exponent → double, objects keep source order).</summary>
    private static BallValue JsonDecode(string text)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(text);
            return JsonToBall(doc.RootElement);
        }
        catch (System.Text.Json.JsonException)
        {
            // Dart surfaces malformed JSON as a catchable FormatException.
            throw new BallThrow(BallValue.Str("FormatException: invalid JSON"));
        }
    }

    private static BallValue JsonToBall(System.Text.Json.JsonElement element)
    {
        switch (element.ValueKind)
        {
            case System.Text.Json.JsonValueKind.Object:
                var map = new BallMap();
                foreach (var property in element.EnumerateObject())
                {
                    map.Set(property.Name, JsonToBall(property.Value));
                }

                return map;
            case System.Text.Json.JsonValueKind.Array:
                var list = new BallList();
                foreach (var item in element.EnumerateArray())
                {
                    list.Add(JsonToBall(item));
                }

                return list;
            case System.Text.Json.JsonValueKind.String:
                return BallValue.Str(element.GetString()!);
            case System.Text.Json.JsonValueKind.Number:
                var raw = element.GetRawText();
                return raw.IndexOfAny(['.', 'e', 'E']) < 0 && element.TryGetInt64(out var i)
                    ? BallValue.Int(i)
                    : BallValue.Double(element.GetDouble());
            case System.Text.Json.JsonValueKind.True:
                return BallValue.Bool(true);
            case System.Text.Json.JsonValueKind.False:
                return BallValue.Bool(false);
            case System.Text.Json.JsonValueKind.Null:
                return BallValue.Null;
            default:
                throw new BallRuntimeException($"JsonDecoder: unexpected JSON value kind {element.ValueKind}");
        }
    }

    private static bool MethodIdentical(BallValue a, BallValue b)
    {
        // Dart `identical`: reference identity for objects, value identity for
        // the canonicalized primitives (numbers/bools/strings/null).
        if (a is BallList or BallMap or BallMessage or BallFunction ||
            b is BallList or BallMap or BallMessage or BallFunction)
        {
            return ReferenceEquals(a, b);
        }

        return BallValue.ValueEquals(a, b);
    }
}
