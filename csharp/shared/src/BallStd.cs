using System.Globalization;

namespace Ball.Shared;

/// <summary>
/// Additional <c>std</c> / <c>std_collections</c> / <c>std_convert</c> base-op
/// helpers the self-hosted engine calls (issue #383, Round 3) — map/record/
/// invoke construction, type ops, math, higher-order collection ops, and
/// codecs. The C# port of the corresponding <c>ball_shared::runtime</c>
/// functions the Rust engine dispatches to.
/// </summary>
public static partial class BallRuntime
{
    // ════════════════════════════════════════════════════════════
    // Construction: map_create / invoke / type ops
    // ════════════════════════════════════════════════════════════

    /// <summary><c>map_create([[k, v], …])</c> — build a map from <c>[key, value]</c> pair lists.</summary>
    public static BallValue MapCreate(BallValue entries)
    {
        var map = new BallMap();
        foreach (var entry in AsList(entries).Snapshot())
        {
            var pair = AsList(entry);
            if (pair.Count != 2)
            {
                throw new BallRuntimeException("map_create expects [key, value] pairs");
            }

            map.Set(AsStr(pair.Get(0)), pair.Get(1));
        }

        return map;
    }

    /// <summary><c>std.invoke({callee, arg…})</c> — call a first-class function value with the remaining argument(s).</summary>
    public static BallValue Invoke(BallValue input)
    {
        var map = AsMap(input);
        var callee = map.Get("callee")
            ?? throw new BallRuntimeException("std.invoke: no callee");
        var rest = new BallMap();
        foreach (var (key, value) in map.Entries())
        {
            if (key is not "callee" and not "__type__")
            {
                rest.Set(key, value);
            }
        }

        var arg = rest.Count switch
        {
            0 => BallValue.Null,
            1 => rest.Values[0],
            _ => rest,
        };
        return CallFunction(callee, arg);
    }

    /// <summary><c>value is Type</c> — a runtime type test (built-in kinds + a message's own type name; nullable/generic-arg suffixes stripped).</summary>
    public static BallValue IsType(BallValue value, string typeName) => BallValue.Bool(IsOfType(value, typeName));

    /// <summary><c>value is! Type</c>.</summary>
    public static BallValue IsNotType(BallValue value, string typeName) => BallValue.Bool(!IsOfType(value, typeName));

    /// <summary><c>value as Type</c> — a permissive cast (identity in the dynamic value model; <c>null</c> passes a nullable target).</summary>
    public static BallValue AsType(BallValue value, string typeName) => value;

    /// <summary>The unqualified type name (the part after the last <c>:</c> module qualifier), e.g. <c>main:BallObject → BallObject</c>.</summary>
    private static string ShortTypeName(string typeName) =>
        typeName.Contains(':') ? typeName[(typeName.LastIndexOf(':') + 1)..] : typeName;

    private static bool IsOfType(BallValue value, string typeName)
    {
        var t = typeName.Trim();
        if (t.EndsWith('?'))
        {
            if (value is BallNull)
            {
                return true;
            }

            t = t[..^1].Trim();
        }

        var lt = t.IndexOf('<');
        var baseName = lt >= 0 ? t[..lt].Trim() : t;

        return baseName switch
        {
            "int" => value is BallInt,
            "double" => value is BallDouble,
            "num" => value is BallInt or BallDouble,
            "String" or "string" => value is BallString,
            "bool" => value is BallBool,
            "List" or "list" => value is BallList or BallBytes,
            "Map" => value is BallMap,
            "Function" => value is BallFunction,
            "Null" => value is BallNull,
            "Object" or "dynamic" => value is not BallNull,
            // The engine's `BallObject extends BallMap` — the universal object
            // wrapper for a typeDef-backed instance is a `BallMessage("…BallObject")`
            // that IS-A `BallMap` in the reference engine (its `entries` field is the
            // inherited map backing). `is BallMap` must therefore hold for it, so
            // map-shaped engine paths (e.g. `_stdAsMap` → `v.entries`) fire.
            "BallMap" => (value is BallMessage bm && ShortTypeName(bm.TypeName) is "BallMap" or "BallObject"),
            _ => value is BallMessage m
                 && (m.TypeName == baseName
                     || ShortTypeName(m.TypeName) == baseName),
        };
    }

    // ════════════════════════════════════════════════════════════
    // Math
    // ════════════════════════════════════════════════════════════

    /// <summary><c>x.abs()</c> — preserves int/double.</summary>
    public static BallValue MathAbs(BallValue value) => value switch
    {
        BallInt i => BallValue.Int(Math.Abs(i.Value)),
        BallDouble d => BallValue.Double(Math.Abs(d.Value)),
        _ => throw new BallRuntimeException($"abs expects a number, got {TypeName(value)}"),
    };

    /// <summary><c>x.floor()</c> — to int.</summary>
    public static BallValue MathFloor(BallValue value) => BallValue.Int((long)Math.Floor(AsNum(value)));

    /// <summary><c>x.ceil()</c> — to int.</summary>
    public static BallValue MathCeil(BallValue value) => BallValue.Int((long)Math.Ceiling(AsNum(value)));

    /// <summary><c>x.round()</c> — half away from zero, to int (Dart semantics).</summary>
    public static BallValue MathRound(BallValue value) => BallValue.Int((long)Math.Round(AsNum(value), MidpointRounding.AwayFromZero));

    /// <summary><c>x.truncate()</c> — toward zero, to int.</summary>
    public static BallValue MathTrunc(BallValue value) => BallValue.Int((long)Math.Truncate(AsNum(value)));

    /// <summary><c>x.sign</c> — int for an int, double for a double.</summary>
    public static BallValue MathSign(BallValue value) => value switch
    {
        BallInt i => BallValue.Int(Math.Sign(i.Value)),
        BallDouble d => BallValue.Double(double.IsNaN(d.Value) ? double.NaN : Math.Sign(d.Value)),
        _ => throw new BallRuntimeException($"sign expects a number, got {TypeName(value)}"),
    };

    /// <summary><c>a.gcd(b)</c> — non-negative greatest common divisor.</summary>
    public static BallValue MathGcd(BallValue left, BallValue right)
    {
        var a = Math.Abs(AsInt(left));
        var b = Math.Abs(AsInt(right));
        while (b != 0)
        {
            (a, b) = (b, a % b);
        }

        return BallValue.Int(a);
    }

    /// <summary><c>x.clamp(lower, upper)</c>.</summary>
    public static BallValue MathClamp(BallValue value, BallValue lower, BallValue upper)
    {
        var v = AsNum(value);
        var lo = AsNum(lower);
        var hi = AsNum(upper);
        var clamped = v < lo ? lo : v > hi ? hi : v;
        // Preserve int-ness when all operands are ints (Dart's clamp keeps num type).
        return value is BallInt && lower is BallInt && upper is BallInt
            ? BallValue.Int((long)clamped)
            : BallValue.Double(clamped);
    }

    /// <summary><c>x.isFinite</c>.</summary>
    public static BallValue MathIsFinite(BallValue value) => BallValue.Bool(value is BallInt || (value is BallDouble d && double.IsFinite(d.Value)));

    /// <summary><c>x.isInfinite</c>.</summary>
    public static BallValue MathIsInfinite(BallValue value) => BallValue.Bool(value is BallDouble d && double.IsInfinity(d.Value));

    /// <summary><c>x.floorToDouble()</c>.</summary>
    public static BallValue FloorToDouble(BallValue value) => BallValue.Double(Math.Floor(AsNum(value)));

    /// <summary><c>x.ceilToDouble()</c>.</summary>
    public static BallValue CeilToDouble(BallValue value) => BallValue.Double(Math.Ceiling(AsNum(value)));

    /// <summary><c>x.roundToDouble()</c>.</summary>
    public static BallValue RoundToDouble(BallValue value) => BallValue.Double(Math.Round(AsNum(value), MidpointRounding.AwayFromZero));

    /// <summary><c>x.truncateToDouble()</c>.</summary>
    public static BallValue TruncateToDouble(BallValue value) => BallValue.Double(Math.Truncate(AsNum(value)));

    /// <summary>
    /// <c>d.toStringAsFixed(digits)</c> — Dart rounds half <b>away from zero</b>,
    /// where .NET's <c>"F"</c> format uses banker's rounding (ties-to-even), so
    /// <c>(-2.5).toStringAsFixed(0)</c> is <c>-3</c> not <c>-2</c>.
    /// <see cref="Math.Round(double, int, MidpointRounding)"/> supports 0..15
    /// fractional digits; beyond that a double has no exact tie at that place, so
    /// <c>"F"</c> already reproduces Dart's exact decimal expansion.
    /// </summary>
    public static BallValue ToStringAsFixed(BallValue value, BallValue digits)
    {
        var d = AsNum(value);
        var n = (int)AsInt(digits);
        if (double.IsNaN(d))
        {
            return BallValue.Str("NaN");
        }

        if (double.IsInfinity(d))
        {
            return BallValue.Str(d < 0 ? "-Infinity" : "Infinity");
        }

        if (n <= 15)
        {
            d = Math.Round(d, n, MidpointRounding.AwayFromZero);
        }

        return BallValue.Str(d.ToString("F" + n, CultureInfo.InvariantCulture));
    }

    /// <summary>
    /// <c>d.toStringAsExponential([fractionDigits])</c> — byte-exact with Dart
    /// (ECMAScript) formatting, which differs from .NET's <c>"E"</c> format in
    /// three ways: a <em>minimal</em> exponent (<c>1.23e+2</c>, not the fixed
    /// 3-digit <c>1.23e+002</c>), round-half-<b>away-from-zero</b> on an exact tie
    /// (<c>2.5.toStringAsExponential(0)</c> → <c>3e+0</c>, where IEEE ties-to-even
    /// gives <c>2e+0</c>), and — for the no-argument form — the shortest
    /// round-trip mantissa (<c>1.23456e+2</c>, not <c>"E"</c>'s six padded
    /// digits). Ported from <c>cpp/shared/include/ball_emit_runtime.h</c> /
    /// <c>rust/shared/src/runtime.rs</c>: extract the value's exact decimal digits
    /// and round the digit string ourselves.
    /// </summary>
    public static BallValue ToStringAsExponential(BallValue value, BallValue digits)
    {
        var x = AsNum(value);
        if (double.IsNaN(x))
        {
            return BallValue.Str("NaN");
        }

        if (double.IsInfinity(x))
        {
            return BallValue.Str(x < 0 ? "-Infinity" : "Infinity");
        }

        var neg = double.IsNegative(x);
        var ax = Math.Abs(x);
        var d = digits is BallNull ? ShortestSignificantDigits(ax) - 1 : (int)AsInt(digits);
        var body = FormatExponential(ax, d);
        return BallValue.Str(neg ? "-" + body : body);
    }

    /// <summary>
    /// <c>d.toStringAsPrecision(precision)</c> — <c>p</c> significant digits,
    /// choosing fixed vs exponential form by ECMAScript's rule (exponent &lt; -6
    /// or ≥ p ⇒ exponential). Byte-exact with Dart, unlike .NET's <c>"G"</c>
    /// format (which drops the trailing zeros Dart keeps — <c>1.0.toStringAsPrecision(3)</c>
    /// is <c>1.00</c> — uses uppercase <c>E</c>, and rounds ties-to-even).
    /// </summary>
    public static BallValue ToStringAsPrecision(BallValue value, BallValue precision)
    {
        var x = AsNum(value);
        if (double.IsNaN(x))
        {
            return BallValue.Str("NaN");
        }

        if (double.IsInfinity(x))
        {
            return BallValue.Str(x < 0 ? "-Infinity" : "Infinity");
        }

        var p = Math.Max(1, (int)AsInt(precision));
        var neg = double.IsNegative(x);
        var ax = Math.Abs(x);
        string body;
        if (ax == 0.0)
        {
            body = p > 1 ? "0." + new string('0', p - 1) : "0";
        }
        else
        {
            var (m, e) = RoundSigDigits(ax, p);
            if (e < -6 || e >= p)
            {
                body = m[..1];
                if (p > 1)
                {
                    body += "." + m[1..];
                }

                body += DartExponent(e);
            }
            else if (e >= 0)
            {
                var intDigits = e + 1;
                body = m[..intDigits];
                if (p > intDigits)
                {
                    body += "." + m[intDigits..];
                }
            }
            else
            {
                body = "0." + new string('0', -e - 1) + m;
            }
        }

        return BallValue.Str(neg ? "-" + body : body);
    }

    /// <summary>
    /// Format the finite, non-negative <paramref name="ax"/> in exponential form
    /// with <paramref name="fractionDigits"/> mantissa fraction digits (Dart's
    /// minimal-exponent, away-from-zero-tie form).
    /// </summary>
    private static string FormatExponential(double ax, int fractionDigits)
    {
        if (ax == 0.0)
        {
            var zero = fractionDigits > 0 ? "0." + new string('0', fractionDigits) : "0";
            return zero + "e+0";
        }

        var (m, e) = RoundSigDigits(ax, fractionDigits + 1);
        var body = m[..1];
        if (fractionDigits > 0)
        {
            body += "." + m[1..];
        }

        return body + DartExponent(e);
    }

    /// <summary>Dart's minimal exponent suffix (<c>e+2</c> / <c>e-4</c>).</summary>
    private static string DartExponent(int e) =>
        "e" + (e < 0 ? "-" : "+") + Math.Abs(e).ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// The fewest significant digits (1..17) whose <c>"E"</c>-rounded form parses
    /// back to <paramref name="ax"/> exactly — the shortest round-trip mantissa
    /// Dart's argument-less <c>toStringAsExponential()</c> emits.
    /// </summary>
    private static int ShortestSignificantDigits(double ax)
    {
        if (ax == 0.0)
        {
            return 1;
        }

        for (var k = 1; k < 17; k++)
        {
            var s = ax.ToString("E" + (k - 1), CultureInfo.InvariantCulture);
            if (double.Parse(s, CultureInfo.InvariantCulture) == ax)
            {
                return k;
            }
        }

        return 17;
    }

    /// <summary>
    /// Round the exact significant digits of finite <paramref name="ax"/> (&gt; 0)
    /// to <paramref name="k"/> significant digits, half-away-from-zero. Returns the
    /// k-digit string and the decimal exponent of the leading digit
    /// (value = D[0].D[1..] × 10^E; a carry like 9.99 → 10 bumps E). <c>"E1080"</c>
    /// yields 1081 significant digits — more than the 767 a double's exact decimal
    /// expansion ever needs — so the printed digits are EXACT (trailing zeros, not
    /// a rounding artifact), and "away from zero on a tie" reduces to
    /// <c>D[k] &gt;= '5'</c>. Ported from the C++/Rust reference emission.
    /// </summary>
    private static (string Digits, int Exp) RoundSigDigits(double ax, int k)
    {
        var s = ax.ToString("E1080", CultureInfo.InvariantCulture);
        var epos = s.IndexOf('E');
        var exp = int.Parse(s[(epos + 1)..], CultureInfo.InvariantCulture);
        // "D.DDD…E±NNN" → the significant digits without the decimal point.
        var digits = s[0] + s.Substring(2, epos - 2);
        if (digits.Length <= k)
        {
            return (digits + new string('0', k - digits.Length), exp);
        }

        var kept = digits[..k].ToCharArray();
        if (digits[k] >= '5')
        {
            var i = k - 1;
            for (; i >= 0; i--)
            {
                if (kept[i] != '9')
                {
                    kept[i]++;
                    break;
                }

                kept[i] = '0';
            }

            if (i < 0)
            {
                // All nines carried: 9.99 → 10.0 — one more leading digit.
                return ("1" + new string(kept, 0, k - 1), exp + 1);
            }
        }

        return (new string(kept), exp);
    }

    private static double AsNum(BallValue value) => value switch
    {
        BallInt i => i.Value,
        BallDouble d => d.Value,
        _ => throw new BallRuntimeException($"expected a number, got {TypeName(value)}"),
    };

    // ════════════════════════════════════════════════════════════
    // Strings (extra)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>s.codeUnitAt(index)</c> — the UTF-16 code unit.</summary>
    public static BallValue StringCodeUnitAt(BallValue value, BallValue index) => StringCharCodeAt(value, index);

    /// <summary><c>s.runes</c> — the Unicode code points, as a list of ints.</summary>
    public static BallValue StringRunes(BallValue value)
    {
        var list = new BallList();
        var s = AsStr(value);
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext())
        {
            list.Add(BallValue.Int(char.ConvertToUtf32((string)e.Current, 0)));
        }

        return list;
    }

    // ════════════════════════════════════════════════════════════
    // Higher-order collection ops (std_collections)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>list.map(f)</c> — a new list of <c>f(element)</c> (eager, since the engine materializes it).</summary>
    public static BallValue ListMap(BallValue list, BallValue callback)
    {
        var result = new BallList();
        foreach (var item in AsList(list).Snapshot())
        {
            result.Add(CallFunction(callback, item));
        }

        return result;
    }

    /// <summary><c>list.where(pred)</c> — a new list of the elements satisfying <paramref name="predicate"/>.</summary>
    public static BallValue ListFilter(BallValue list, BallValue predicate)
    {
        var result = new BallList();
        foreach (var item in AsList(list).Snapshot())
        {
            if (Truthy(CallFunction(predicate, item)))
            {
                result.Add(item);
            }
        }

        return result;
    }

    /// <summary><c>list.every(pred)</c>.</summary>
    public static BallValue ListAll(BallValue list, BallValue predicate)
    {
        foreach (var item in AsList(list).Snapshot())
        {
            if (!Truthy(CallFunction(predicate, item)))
            {
                return BallValue.Bool(false);
            }
        }

        return BallValue.Bool(true);
    }

    /// <summary><c>list.any(pred)</c>.</summary>
    public static BallValue ListAny(BallValue list, BallValue predicate)
    {
        foreach (var item in AsList(list).Snapshot())
        {
            if (Truthy(CallFunction(predicate, item)))
            {
                return BallValue.Bool(true);
            }
        }

        return BallValue.Bool(false);
    }

    /// <summary><c>list.join(separator)</c>.</summary>
    public static BallValue ListJoin(BallValue list, BallValue separator) =>
        BallValue.Str(string.Join(AsStr(separator), AsList(list).Snapshot().Select(v => v.ToString())));

    /// <summary><c>list.toList()</c> — a fresh copy.</summary>
    public static BallValue ListToList(BallValue list) => new BallList(AsList(list).Snapshot());

    /// <summary>
    /// Iterate a spread operand (<c>...x</c>) for list/set-literal splicing —
    /// yields its ITEMS, not the collection itself. A list yields a snapshot; a
    /// portable ordered set (<c>{'__ball_set__': [...]}</c>) yields its tagged
    /// items; <c>null</c> yields nothing (a null-aware spread guards separately).
    /// The C# analog of <c>ball_shared::runtime::ball_spread_iter</c> — its
    /// absence silently nested the self-hosted engine's own
    /// <c>_ballSetOf([...items, v])</c> as <c>{[...], v}</c>.
    /// </summary>
    public static IEnumerable<BallValue> SpreadIter(BallValue value) => value switch
    {
        BallList list => list.Snapshot(),
        BallMap map when map.Get("__ball_set__") is BallList setItems => setItems.Snapshot(),
        BallMessage msg when msg.Get("__ball_set__") is BallList msgSetItems => msgSetItems.Snapshot(),
        BallNull => Array.Empty<BallValue>(),
        _ => throw new BallRuntimeException($"cannot spread a non-iterable: {TypeName(value)}"),
    };

    /// <summary>
    /// <c>list.sort(compare?)</c> — sorts the shared backing in place and returns
    /// it. With a comparator, calls it (expecting a negative/zero/positive int);
    /// without, compares with the default order.
    /// </summary>
    public static BallValue ListSort(BallValue list, BallValue compare)
    {
        var backing = AsList(list);
        var items = backing.Snapshot();
        Comparison<BallValue> cmp = compare is BallFunction
            ? (a, b) =>
            {
                var input = new BallMap();
                input.Set("arg0", a);
                input.Set("arg1", b);
                return (int)AsInt(CallFunction(compare, input));
            }
        : Compare;
        items.Sort(cmp);
        backing.Clear();
        foreach (var item in items)
        {
            backing.Add(item);
        }

        return backing;
    }

    /// <summary><c>map.containsValue(value)</c>.</summary>
    public static BallValue MapContainsValue(BallValue map, BallValue value) =>
        BallValue.Bool(AsMap(map).Values.Any(v => BallValue.ValueEquals(v, value)));

    /// <summary><c>map.putIfAbsent(key, ifAbsent)</c> — returns the existing or newly-computed value.</summary>
    public static BallValue MapPutIfAbsent(BallValue map, BallValue key, BallValue ifAbsent)
    {
        var m = AsMap(map);
        var k = AsStr(key);
        if (m.Get(k) is { } existing)
        {
            return existing;
        }

        var value = CallFunction(ifAbsent, BallValue.Null);
        m.Set(k, value);
        return value;
    }

    // ════════════════════════════════════════════════════════════
    // Codecs (std_convert)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>utf8.encode(s)</c> — a list of byte ints.</summary>
    public static BallValue Utf8Encode(BallValue value) => BallValue.Bytes(System.Text.Encoding.UTF8.GetBytes(AsStr(value)));

    /// <summary><c>utf8.decode(bytes)</c>.</summary>
    public static BallValue Utf8Decode(BallValue value) => BallValue.Str(System.Text.Encoding.UTF8.GetString(AsBytes(value)));

    /// <summary><c>base64.encode(bytes)</c>.</summary>
    public static BallValue Base64Encode(BallValue value) => BallValue.Str(Convert.ToBase64String(AsBytes(value)));

    /// <summary><c>base64.decode(s)</c> — a bytes value.</summary>
    public static BallValue Base64Decode(BallValue value) => BallValue.Bytes(Convert.FromBase64String(AsStr(value)));

    private static byte[] AsBytes(BallValue value) => value switch
    {
        BallBytes b => b.Value,
        BallList l => l.Snapshot().Select(v => (byte)AsInt(v)).ToArray(),
        _ => throw new BallRuntimeException($"expected bytes, got {TypeName(value)}"),
    };
}
