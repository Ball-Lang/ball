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

            // ── Set algebra (a set is a duplicate-free list) ──
            "union" => SetUnion(self, a0),
            "intersection" => SetIntersection(self, a0),
            "difference" => SetDifference(self, a0),

            // ── Static constructors / parsers on a type literal ──
            "tryParse" => MethodParseNumber(self, a0, tryParse: true),
            "parse" => MethodParseNumber(self, a0, tryParse: false),
            "filled" => MethodFilled(self, a0, a1),
            "unmodifiable" => MethodUnmodifiable(self, a0),
            "fromCharCode" => StringFromCharCode(a0),

            // ── Top-level Dart core functions ──
            "identical" => BallValue.Bool(MethodIdentical(a0, a1)),

            // ── DateTime (static) ──
            "now" => MethodDateTimeNow(),

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
                return map.Remove(AsStr(value)) ?? BallValue.Null;
            default:
                return UnsupportedMethod("remove", self);
        }
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
        var fields = new BallMap();
        fields.Set("millisecondsSinceEpoch", BallValue.Int(nowMs));
        fields.Set("microsecondsSinceEpoch", BallValue.Int(nowMs * 1000));
        return new BallMessage("DateTime", fields);
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
