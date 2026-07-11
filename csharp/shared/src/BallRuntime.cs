using System.Globalization;

namespace Ball.Shared;

/// <summary>
/// The runtime base-op helper layer the compiled C# program (Phase 4, issue
/// #381) dispatches base-function calls into — the C# analog of
/// <c>rust/shared/src/runtime.rs</c> and <c>cpp/shared/include/ball_dyn.h</c>.
/// Rather than re-deriving operator semantics as emitted text, the compiler
/// emits <c>BallRuntime.Add(a, b)</c> / <c>BallRuntime.Modulo(a, b)</c> / … and
/// this shared library supplies the one canonical implementation.
///
/// <para><b>Semantics always match the Dart reference engine</b>, not "whatever
/// C# does": Euclidean modulo (sign of the divisor), truncating integer divide,
/// int/double cross-type promotion for arithmetic and comparison, 64-bit
/// wrapping integer arithmetic, and UTF-16 code-unit string measures (which C#'s
/// native <see cref="string"/> already provides — a Dart <c>String.length</c>
/// equals a C# <c>string.Length</c>).</para>
///
/// <para><b>Scope.</b> This is a substantial but not exhaustive port covering
/// the categories the compiler needs first: arithmetic, comparison, logic/
/// bitwise, null safety, string manipulation, and list/map/set collection ops,
/// plus first-class function dispatch. Deliberately deferred to Phase 4 (falling
/// back to <see cref="UnsupportedBaseCall"/> rather than a silent no-op): the
/// higher-order collection ops that need multi-argument callbacks
/// (<c>list_map</c>/<c>list_reduce</c>/…), <c>regex_*</c>, the <c>math_*</c>
/// transcendental family, <c>std_io</c>, and all of <c>std_memory</c>.</para>
/// </summary>
public static partial class BallRuntime
{
    // ════════════════════════════════════════════════════════════
    // Internal coercion helpers
    // ════════════════════════════════════════════════════════════

    private static double AsDouble(BallValue value) => value switch
    {
        BallInt i => i.Value,
        BallDouble d => d.Value,
        _ => throw new BallRuntimeException($"expected a number, got {TypeName(value)}"),
    };

    private static long AsInt(BallValue value) => value switch
    {
        BallInt i => i.Value,
        BallDouble d => (long)d.Value,
        _ => throw new BallRuntimeException($"expected a number, got {TypeName(value)}"),
    };

    private static string AsStr(BallValue value) => value switch
    {
        BallString s => s.Value,
        _ => throw new BallRuntimeException($"expected a string, got {TypeName(value)}"),
    };

    private static int AsIndex(BallValue value) => value switch
    {
        BallInt i when i.Value >= 0 => (int)i.Value,
        _ => throw new BallRuntimeException($"expected a non-negative int index, got {TypeName(value)}"),
    };

    private static BallList AsList(BallValue value) => value switch
    {
        BallList l => l,
        _ => throw new BallRuntimeException($"expected a list, got {TypeName(value)}"),
    };

    private static BallMap AsMap(BallValue value) => value switch
    {
        BallMap m => m,
        _ => throw new BallRuntimeException($"expected a map, got {TypeName(value)}"),
    };

    private static (long Left, long Right)? BothInt(BallValue left, BallValue right) =>
        left is BallInt a && right is BallInt b ? (a.Value, b.Value) : null;

    private static string TypeName(BallValue value) => value switch
    {
        BallNull => "Null",
        BallBool => "bool",
        BallInt => "int",
        BallDouble => "double",
        BallString => "String",
        BallBytes => "bytes",
        BallList => "List",
        BallMap => "Map",
        BallFunction => "Function",
        BallMessage => "Message",
        _ => value.GetType().Name,
    };

    // ════════════════════════════════════════════════════════════
    // Truthiness / dispatch fallback / function-value dispatch
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Unwrap an <c>if</c>/<c>while</c>/… condition. A non-bool (other than
    /// <c>null</c>, which is falsy, matching proto3 defaults) is a malformed
    /// program — fail loud.
    /// </summary>
    public static bool Truthy(BallValue value) => value switch
    {
        BallBool b => b.Value,
        BallNull => false,
        _ => throw new BallRuntimeException($"expected a bool condition, got {TypeName(value)}"),
    };

    /// <summary>Fallback for a base function the compiler does not special-case — fails loud.</summary>
    public static BallValue UnsupportedBaseCall(string module, string function) =>
        throw new BallRuntimeException(
            $"base function '{module}.{function}' is not implemented by the C# target yet");

    /// <summary>
    /// Fallback for a reference the compiler cannot resolve to any emitted symbol
    /// — an inherited field from a base-type superclass, a stub-module enum
    /// constant, or a second catch binding (documented Round-3 self-host gaps,
    /// issue #383). Fails loud so the gap can never surface as a silently-wrong
    /// value; the base corpus never reaches these paths.
    /// </summary>
    public static BallValue UnresolvedReference(string name) =>
        throw new BallRuntimeException(
            $"reference '{name}' could not be resolved by the C# self-host compiler yet (issue #383)");

    /// <summary>
    /// Invoke a first-class function value with <paramref name="input"/>
    /// (invariant #1). A non-callable value fails loud.
    /// </summary>
    public static BallValue CallFunction(BallValue callee, BallValue input) => callee switch
    {
        BallFunction f => f.Call(input),
        _ => throw new BallRuntimeException($"value is not callable: {TypeName(callee)}"),
    };

    /// <summary>Raise a catchable Ball <c>throw value</c>.</summary>
    public static BallValue Throw(BallValue value) => throw new BallThrow(value);

    // ════════════════════════════════════════════════════════════
    // Arithmetic
    // ════════════════════════════════════════════════════════════

    /// <summary><c>left + right</c> — numeric add, string concat, or list concat (non-mutating).</summary>
    public static BallValue Add(BallValue left, BallValue right)
    {
        switch (left, right)
        {
            case (BallString a, BallString b):
                return BallValue.Str(a.Value + b.Value);
            case (BallList a, BallList b):
                var merged = a.Snapshot();
                merged.AddRange(b.Snapshot());
                return new BallList(merged);
        }

        var pair = BothInt(left, right);
        return pair is { } p
            ? BallValue.Int(unchecked(p.Left + p.Right))
            : BallValue.Double(AsDouble(left) + AsDouble(right));
    }

    /// <summary><c>left - right</c>.</summary>
    public static BallValue Subtract(BallValue left, BallValue right) =>
        BothInt(left, right) is { } p
            ? BallValue.Int(unchecked(p.Left - p.Right))
            : BallValue.Double(AsDouble(left) - AsDouble(right));

    /// <summary><c>left * right</c> — numeric multiply, or string×int repeat (Dart's <c>*</c>).</summary>
    public static BallValue Multiply(BallValue left, BallValue right)
    {
        // Dart's `*` repeats a String when the other operand is an int.
        if (left is BallString ls && right is BallInt ri)
        {
            return BallValue.Str(RepeatString(ls.Value, ri.Value));
        }

        if (left is BallInt li && right is BallString rs)
        {
            return BallValue.Str(RepeatString(rs.Value, li.Value));
        }

        return BothInt(left, right) is { } p
            ? BallValue.Int(unchecked(p.Left * p.Right))
            : BallValue.Double(AsDouble(left) * AsDouble(right));
    }

    /// <summary><c>left ~/ right</c> — truncating integer division (always an int).</summary>
    public static BallValue Divide(BallValue left, BallValue right)
    {
        if (BothInt(left, right) is { } p)
        {
            if (p.Right == 0)
            {
                throw new BallRuntimeException("IntegerDivisionByZeroException");
            }

            return BallValue.Int(p.Left / p.Right);
        }

        var divisor = AsDouble(right);
        if (divisor == 0.0)
        {
            throw new BallRuntimeException("IntegerDivisionByZeroException");
        }

        return BallValue.Int((long)Math.Truncate(AsDouble(left) / divisor));
    }

    /// <summary><c>left / right</c> — real division (always a double).</summary>
    public static BallValue DivideDouble(BallValue left, BallValue right) =>
        BallValue.Double(AsDouble(left) / AsDouble(right));

    /// <summary><c>left % right</c> — Euclidean modulo (sign of the divisor), matching Dart.</summary>
    public static BallValue Modulo(BallValue left, BallValue right)
    {
        if (BothInt(left, right) is { } p)
        {
            if (p.Right == 0)
            {
                throw new BallRuntimeException("modulo by zero");
            }

            var r = p.Left % p.Right;
            return BallValue.Int(r < 0 ? r + Math.Abs(p.Right) : r);
        }

        var (a, b) = (AsDouble(left), AsDouble(right));
        var rem = a % b;
        return BallValue.Double(rem < 0.0 ? rem + Math.Abs(b) : rem);
    }

    /// <summary><c>-value</c>.</summary>
    public static BallValue Negate(BallValue value) => value switch
    {
        BallInt i => BallValue.Int(unchecked(-i.Value)),
        BallDouble d => BallValue.Double(-d.Value),
        _ => throw new BallRuntimeException($"unsupported operand for negate: {TypeName(value)}"),
    };

    private static string RepeatString(string s, long count) =>
        count > 0 ? string.Concat(Enumerable.Repeat(s, (int)count)) : string.Empty;

    // ════════════════════════════════════════════════════════════
    // Comparison (reuses BallValue's numeric-cross-type-aware equality)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>left == right</c>.</summary>
    public static BallValue Equals(BallValue left, BallValue right) =>
        BallValue.Bool(BallValue.ValueEquals(left, right));

    /// <summary><c>left != right</c>.</summary>
    public static BallValue NotEquals(BallValue left, BallValue right) =>
        BallValue.Bool(!BallValue.ValueEquals(left, right));

    private static int Compare(BallValue left, BallValue right)
    {
        if (left is BallString a && right is BallString b)
        {
            // Ordinal (UTF-16 code-unit) comparison — matches Dart's String.compareTo.
            return Math.Sign(string.CompareOrdinal(a.Value, b.Value));
        }

        return AsDouble(left).CompareTo(AsDouble(right));
    }

    /// <summary><c>left &lt; right</c>.</summary>
    public static BallValue LessThan(BallValue left, BallValue right) => BallValue.Bool(Compare(left, right) < 0);

    /// <summary><c>left &gt; right</c>.</summary>
    public static BallValue GreaterThan(BallValue left, BallValue right) => BallValue.Bool(Compare(left, right) > 0);

    /// <summary><c>left &lt;= right</c>.</summary>
    public static BallValue Lte(BallValue left, BallValue right) => BallValue.Bool(Compare(left, right) <= 0);

    /// <summary><c>left &gt;= right</c>.</summary>
    public static BallValue Gte(BallValue left, BallValue right) => BallValue.Bool(Compare(left, right) >= 0);

    /// <summary><c>left.compareTo(right)</c> → -1, 0, or 1.</summary>
    public static BallValue CompareTo(BallValue left, BallValue right) => BallValue.Int(Math.Sign(Compare(left, right)));

    // ════════════════════════════════════════════════════════════
    // Logic / bitwise (and/or short-circuit — emitted inline by the compiler)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>!value</c>.</summary>
    public static BallValue Not(BallValue value) => value switch
    {
        BallBool b => BallValue.Bool(!b.Value),
        _ => throw new BallRuntimeException($"unsupported operand for not: {TypeName(value)}"),
    };

    /// <summary><c>left &amp; right</c>.</summary>
    public static BallValue BitwiseAnd(BallValue left, BallValue right) => BallValue.Int(AsInt(left) & AsInt(right));

    /// <summary><c>left | right</c>.</summary>
    public static BallValue BitwiseOr(BallValue left, BallValue right) => BallValue.Int(AsInt(left) | AsInt(right));

    /// <summary><c>left ^ right</c>.</summary>
    public static BallValue BitwiseXor(BallValue left, BallValue right) => BallValue.Int(AsInt(left) ^ AsInt(right));

    /// <summary><c>~value</c>.</summary>
    public static BallValue BitwiseNot(BallValue value) => BallValue.Int(~AsInt(value));

    /// <summary><c>left &lt;&lt; right</c> (arithmetic shift).</summary>
    public static BallValue LeftShift(BallValue left, BallValue right) =>
        BallValue.Int(AsInt(left) << (int)AsInt(right));

    /// <summary><c>left &gt;&gt; right</c> (arithmetic, sign-extending shift).</summary>
    public static BallValue RightShift(BallValue left, BallValue right) =>
        BallValue.Int(AsInt(left) >> (int)AsInt(right));

    /// <summary><c>left &gt;&gt;&gt; right</c> (logical, zero-filling shift — Dart's <c>&gt;&gt;&gt;</c>).</summary>
    public static BallValue UnsignedRightShift(BallValue left, BallValue right) =>
        BallValue.Int(unchecked((long)((ulong)AsInt(left) >> (int)AsInt(right))));

    // ════════════════════════════════════════════════════════════
    // Null safety
    // ════════════════════════════════════════════════════════════

    /// <summary><c>value!</c> — throws if <paramref name="value"/> is null.</summary>
    public static BallValue NullCheck(BallValue value) =>
        value is BallNull
            ? throw new BallRuntimeException("null check operator used on a null value")
            : value;

    /// <summary><c>left ?? right</c>.</summary>
    public static BallValue NullCoalesce(BallValue left, BallValue right) => left is BallNull ? right : left;

    // ════════════════════════════════════════════════════════════
    // to_string / length / parsing / conversion
    // ════════════════════════════════════════════════════════════

    /// <summary><c>value.toString()</c> — delegates to reference-engine-exact <see cref="object.ToString"/>.</summary>
    public static BallValue ToStringValue(BallValue value) => BallValue.Str(value.ToString()!);

    /// <summary><c>value.length</c> — polymorphic over String (UTF-16 units)/List/Map/Bytes.</summary>
    public static BallValue Length(BallValue value) => value switch
    {
        BallString s => BallValue.Int(s.Value.Length),
        BallList l => BallValue.Int(l.Count),
        BallMap m => BallValue.Int(m.Count),
        BallBytes b => BallValue.Int(b.Value.Length),
        _ => throw new BallRuntimeException($"no length for {TypeName(value)}"),
    };

    /// <summary><c>int.parse(value)</c> — throws a catchable <c>FormatException</c> on failure.</summary>
    public static BallValue StringToInt(BallValue value)
    {
        var s = AsStr(value);
        return long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n)
            ? BallValue.Int(n)
            : throw new BallThrow("FormatException", $"cannot parse '{s}' as int");
    }

    /// <summary><c>double.parse(value)</c> — throws a catchable <c>FormatException</c> on failure.</summary>
    public static BallValue StringToDouble(BallValue value)
    {
        var s = AsStr(value);
        return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n)
            ? BallValue.Double(n)
            : throw new BallThrow("FormatException", $"cannot parse '{s}' as double");
    }

    /// <summary><c>value.toDouble()</c>.</summary>
    public static BallValue ToDouble(BallValue value) => value switch
    {
        BallInt i => BallValue.Double(i.Value),
        BallDouble d => d,
        BallString s => StringToDouble(s),
        _ => throw new BallRuntimeException($"cannot convert {TypeName(value)} to double"),
    };

    /// <summary><c>value.toInt()</c> — truncates a double toward zero.</summary>
    public static BallValue ToInt(BallValue value) => value switch
    {
        BallInt i => i,
        BallDouble d => BallValue.Int((long)Math.Truncate(d.Value)),
        BallString s => StringToInt(s),
        _ => throw new BallRuntimeException($"cannot convert {TypeName(value)} to int"),
    };

    // ════════════════════════════════════════════════════════════
    // String manipulation (Dart UTF-16 semantics == C# native string)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>left + right</c> (strings).</summary>
    public static BallValue Concat(BallValue left, BallValue right) => BallValue.Str(AsStr(left) + AsStr(right));

    /// <summary><c>value.length</c> (string).</summary>
    public static BallValue StringLength(BallValue value) => BallValue.Int(AsStr(value).Length);

    /// <summary><c>value.isEmpty</c>.</summary>
    public static BallValue StringIsEmpty(BallValue value) => BallValue.Bool(AsStr(value).Length == 0);

    /// <summary><c>left.contains(right)</c>.</summary>
    public static BallValue StringContains(BallValue left, BallValue right) =>
        BallValue.Bool(AsStr(left).Contains(AsStr(right), StringComparison.Ordinal));

    /// <summary><c>left.startsWith(right)</c>.</summary>
    public static BallValue StringStartsWith(BallValue left, BallValue right) =>
        BallValue.Bool(AsStr(left).StartsWith(AsStr(right), StringComparison.Ordinal));

    /// <summary><c>left.endsWith(right)</c>.</summary>
    public static BallValue StringEndsWith(BallValue left, BallValue right) =>
        BallValue.Bool(AsStr(left).EndsWith(AsStr(right), StringComparison.Ordinal));

    /// <summary><c>left.indexOf(right)</c>.</summary>
    public static BallValue StringIndexOf(BallValue left, BallValue right) =>
        BallValue.Int(AsStr(left).IndexOf(AsStr(right), StringComparison.Ordinal));

    /// <summary><c>left.lastIndexOf(right)</c>.</summary>
    public static BallValue StringLastIndexOf(BallValue left, BallValue right) =>
        BallValue.Int(AsStr(left).LastIndexOf(AsStr(right), StringComparison.Ordinal));

    /// <summary><c>value.substring(start, end)</c> — <paramref name="end"/> exclusive; null <paramref name="end"/> ⇒ to the end.</summary>
    public static BallValue StringSubstring(BallValue value, BallValue start, BallValue end)
    {
        var s = AsStr(value);
        var from = AsIndex(start);
        var to = end is BallNull ? s.Length : AsIndex(end);
        return BallValue.Str(s.Substring(from, to - from));
    }

    /// <summary><c>value.codeUnitAt(index)</c>.</summary>
    public static BallValue StringCharCodeAt(BallValue value, BallValue index) =>
        BallValue.Int(AsStr(value)[AsIndex(index)]);

    /// <summary><c>String.fromCharCode(value)</c>.</summary>
    public static BallValue StringFromCharCode(BallValue value) =>
        BallValue.Str(char.ConvertFromUtf32((int)AsInt(value)));

    /// <summary><c>value.toUpperCase()</c>.</summary>
    public static BallValue StringToUpper(BallValue value) => BallValue.Str(AsStr(value).ToUpperInvariant());

    /// <summary><c>value.toLowerCase()</c>.</summary>
    public static BallValue StringToLower(BallValue value) => BallValue.Str(AsStr(value).ToLowerInvariant());

    /// <summary><c>value.trim()</c>.</summary>
    public static BallValue StringTrim(BallValue value) => BallValue.Str(AsStr(value).Trim());

    /// <summary><c>value.trimLeft()</c>.</summary>
    public static BallValue StringTrimStart(BallValue value) => BallValue.Str(AsStr(value).TrimStart());

    /// <summary><c>value.trimRight()</c>.</summary>
    public static BallValue StringTrimEnd(BallValue value) => BallValue.Str(AsStr(value).TrimEnd());

    /// <summary><c>value.replaceFirst(from, to)</c>.</summary>
    public static BallValue StringReplace(BallValue value, BallValue from, BallValue to)
    {
        var s = AsStr(value);
        var target = AsStr(from);
        var index = s.IndexOf(target, StringComparison.Ordinal);
        if (index < 0)
        {
            return BallValue.Str(s);
        }

        return BallValue.Str(s[..index] + AsStr(to) + s[(index + target.Length)..]);
    }

    /// <summary><c>value.replaceAll(from, to)</c>.</summary>
    public static BallValue StringReplaceAll(BallValue value, BallValue from, BallValue to) =>
        BallValue.Str(AsStr(value).Replace(AsStr(from), AsStr(to), StringComparison.Ordinal));

    /// <summary><c>left.split(right)</c> — an empty separator splits into characters (Dart).</summary>
    public static BallValue StringSplit(BallValue left, BallValue right)
    {
        var s = AsStr(left);
        var sep = AsStr(right);
        var parts = sep.Length == 0
            ? s.Select(c => c.ToString())
            : s.Split(sep);
        return new BallList(parts.Select(p => BallValue.Str(p)));
    }

    /// <summary><c>value * count</c> (string repeat).</summary>
    public static BallValue StringRepeat(BallValue value, BallValue count) =>
        BallValue.Str(RepeatString(AsStr(value), AsInt(count)));

    /// <summary><c>value.padLeft(width, padding)</c>.</summary>
    public static BallValue StringPadLeft(BallValue value, BallValue width, BallValue padding)
    {
        var s = AsStr(value);
        var delta = AsIndex(width) - s.Length;
        return BallValue.Str(delta <= 0 ? s : RepeatString(AsStr(padding), delta) + s);
    }

    /// <summary><c>value.padRight(width, padding)</c>.</summary>
    public static BallValue StringPadRight(BallValue value, BallValue width, BallValue padding)
    {
        var s = AsStr(value);
        var delta = AsIndex(width) - s.Length;
        return BallValue.Str(delta <= 0 ? s : s + RepeatString(AsStr(padding), delta));
    }

    /// <summary><c>list.join(separator)</c>.</summary>
    public static BallValue StringJoin(BallValue list, BallValue separator) =>
        BallValue.Str(string.Join(AsStr(separator), AsList(list).Snapshot().Select(v => v.ToString())));

    // ════════════════════════════════════════════════════════════
    // List — read
    // ════════════════════════════════════════════════════════════

    /// <summary><c>list[index]</c>.</summary>
    public static BallValue ListGet(BallValue list, BallValue index) => AsList(list).Get(AsIndex(index));

    /// <summary><c>list.length</c>.</summary>
    public static BallValue ListLength(BallValue list) => BallValue.Int(AsList(list).Count);

    /// <summary><c>list.isEmpty</c>.</summary>
    public static BallValue ListIsEmpty(BallValue list) => BallValue.Bool(AsList(list).IsEmpty);

    /// <summary><c>list.first</c>.</summary>
    public static BallValue ListFirst(BallValue list)
    {
        var l = AsList(list);
        return l.IsEmpty ? throw new BallRuntimeException("first on an empty list") : l.Get(0);
    }

    /// <summary><c>list.last</c>.</summary>
    public static BallValue ListLast(BallValue list)
    {
        var l = AsList(list);
        return l.IsEmpty ? throw new BallRuntimeException("last on an empty list") : l.Get(l.Count - 1);
    }

    /// <summary><c>list.contains(value)</c>.</summary>
    public static BallValue ListContains(BallValue list, BallValue value) =>
        BallValue.Bool(AsList(list).Contains(value));

    /// <summary><c>list.indexOf(value)</c>.</summary>
    public static BallValue ListIndexOf(BallValue list, BallValue value) =>
        BallValue.Int(AsList(list).IndexOf(value));

    /// <summary><c>list.reversed.toList()</c> — a new list (source untouched).</summary>
    public static BallValue ListReverse(BallValue list)
    {
        var copy = AsList(list).Snapshot();
        copy.Reverse();
        return new BallList(copy);
    }

    /// <summary><c>list + other</c> — a new list (neither operand mutated).</summary>
    public static BallValue ListConcat(BallValue list, BallValue other)
    {
        var merged = AsList(list).Snapshot();
        merged.AddRange(AsList(other).Snapshot());
        return new BallList(merged);
    }

    /// <summary><c>list.sublist(start, end)</c> — <paramref name="end"/> exclusive; null ⇒ to the end.</summary>
    public static BallValue ListSlice(BallValue list, BallValue start, BallValue end)
    {
        var items = AsList(list).Snapshot();
        var from = AsIndex(start);
        var to = end is BallNull ? items.Count : AsIndex(end);
        return new BallList(items.GetRange(from, to - from));
    }

    /// <summary><c>list.take(n)</c>.</summary>
    public static BallValue ListTake(BallValue list, BallValue count) =>
        new BallList(AsList(list).Snapshot().Take((int)AsInt(count)));

    /// <summary><c>list.skip(n)</c>.</summary>
    public static BallValue ListDrop(BallValue list, BallValue count) =>
        new BallList(AsList(list).Snapshot().Skip((int)AsInt(count)));

    // ════════════════════════════════════════════════════════════
    // List — mutate (reference semantics: the shared backing is updated)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>list.add(value)</c> — mutates the shared list; returns it.</summary>
    public static BallValue ListPush(BallValue list, BallValue value)
    {
        AsList(list).Add(value);
        return list;
    }

    /// <summary><c>list.removeLast()</c>.</summary>
    public static BallValue ListPop(BallValue list) => AsList(list).RemoveLast();

    /// <summary><c>list.insert(index, value)</c> — mutates the shared list; returns it.</summary>
    public static BallValue ListInsert(BallValue list, BallValue index, BallValue value)
    {
        AsList(list).Insert(AsIndex(index), value);
        return list;
    }

    /// <summary><c>list.removeAt(index)</c>.</summary>
    public static BallValue ListRemoveAt(BallValue list, BallValue index) =>
        AsList(list).RemoveAt(AsIndex(index));

    /// <summary><c>list[index] = value</c> — mutates the shared list; returns the value.</summary>
    public static BallValue ListSet(BallValue list, BallValue index, BallValue value)
    {
        AsList(list).Set(AsIndex(index), value);
        return value;
    }

    /// <summary><c>list.clear()</c> — mutates the shared list; returns it.</summary>
    public static BallValue ListClear(BallValue list)
    {
        AsList(list).Clear();
        return list;
    }

    // ════════════════════════════════════════════════════════════
    // Map
    // ════════════════════════════════════════════════════════════

    /// <summary><c>map[key]</c> — an absent key reads as <c>null</c> (Dart).</summary>
    public static BallValue MapGet(BallValue map, BallValue key) =>
        AsMap(map).Get(AsStr(key)) ?? BallValue.Null;

    /// <summary><c>map[key] = value</c> — mutates the shared map; returns it.</summary>
    public static BallValue MapSet(BallValue map, BallValue key, BallValue value)
    {
        AsMap(map).Set(AsStr(key), value);
        return map;
    }

    /// <summary><c>map.remove(key)</c> — returns the removed value or <c>null</c>.</summary>
    public static BallValue MapDelete(BallValue map, BallValue key) =>
        AsMap(map).Remove(AsStr(key)) ?? BallValue.Null;

    /// <summary><c>map.containsKey(key)</c>.</summary>
    public static BallValue MapContainsKey(BallValue map, BallValue key) =>
        BallValue.Bool(AsMap(map).ContainsKey(AsStr(key)));

    /// <summary><c>map.keys.toList()</c>.</summary>
    public static BallValue MapKeys(BallValue map) =>
        new BallList(AsMap(map).Keys.Select(k => BallValue.Str(k)));

    /// <summary><c>map.values.toList()</c>.</summary>
    public static BallValue MapValues(BallValue map) => new BallList(AsMap(map).Values);

    /// <summary><c>map.length</c>.</summary>
    public static BallValue MapLength(BallValue map) => BallValue.Int(AsMap(map).Count);

    /// <summary><c>map.isEmpty</c>.</summary>
    public static BallValue MapIsEmpty(BallValue map) => BallValue.Bool(AsMap(map).IsEmpty);

    /// <summary><c>{...left, ...right}</c> — a new map (neither operand mutated).</summary>
    public static BallValue MapMerge(BallValue left, BallValue right)
    {
        var merged = AsMap(left).Snapshot();
        foreach (var (key, value) in AsMap(right).Entries())
        {
            merged[key] = value;
        }

        return merged;
    }

    // ════════════════════════════════════════════════════════════
    // Set — a duplicate-free list (matching Rust/Dart's LinkedHashSet order)
    // ════════════════════════════════════════════════════════════

    /// <summary><c>Set.from(list)</c> — a new duplicate-free list.</summary>
    public static BallValue SetCreate(BallValue list)
    {
        var result = new BallList();
        foreach (var item in AsList(list).Snapshot())
        {
            if (!result.Contains(item))
            {
                result.Add(item);
            }
        }

        return result;
    }

    /// <summary><c>set.add(value)</c> — mutates the shared set (no-op if present); returns it.</summary>
    public static BallValue SetAdd(BallValue set, BallValue value)
    {
        var s = AsList(set);
        if (!s.Contains(value))
        {
            s.Add(value);
        }

        return set;
    }

    /// <summary><c>set.remove(value)</c> — mutates the shared set; returns it.</summary>
    public static BallValue SetRemove(BallValue set, BallValue value)
    {
        var s = AsList(set);
        var index = s.IndexOf(value);
        if (index >= 0)
        {
            s.RemoveAt(index);
        }

        return set;
    }

    /// <summary><c>set.contains(value)</c>.</summary>
    public static BallValue SetContains(BallValue set, BallValue value) => BallValue.Bool(AsList(set).Contains(value));

    /// <summary><c>set.length</c>.</summary>
    public static BallValue SetLength(BallValue set) => BallValue.Int(AsList(set).Count);

    /// <summary><c>set.isEmpty</c>.</summary>
    public static BallValue SetIsEmpty(BallValue set) => BallValue.Bool(AsList(set).IsEmpty);

    /// <summary><c>set.toList()</c> — a fresh list copy.</summary>
    public static BallValue SetToList(BallValue set) => new BallList(AsList(set).Snapshot());

    /// <summary><c>left.union(right)</c> — a new duplicate-free list.</summary>
    public static BallValue SetUnion(BallValue left, BallValue right)
    {
        var result = new BallList(AsList(left).Snapshot());
        foreach (var item in AsList(right).Snapshot())
        {
            if (!result.Contains(item))
            {
                result.Add(item);
            }
        }

        return result;
    }

    /// <summary><c>left.intersection(right)</c> — a new list.</summary>
    public static BallValue SetIntersection(BallValue left, BallValue right)
    {
        var other = AsList(right);
        var result = new BallList();
        foreach (var item in AsList(left).Snapshot())
        {
            if (other.Contains(item) && !result.Contains(item))
            {
                result.Add(item);
            }
        }

        return result;
    }

    /// <summary><c>left.difference(right)</c> — a new list.</summary>
    public static BallValue SetDifference(BallValue left, BallValue right)
    {
        var other = AsList(right);
        var result = new BallList();
        foreach (var item in AsList(left).Snapshot())
        {
            if (!other.Contains(item) && !result.Contains(item))
            {
                result.Add(item);
            }
        }

        return result;
    }

    // ════════════════════════════════════════════════════════════
    // Field / index access, iteration, and print — the small set of
    // runtime helpers the Phase-4 compiler (#381) emits for the
    // `field_access`/`index` node types, `for_in` iteration, and `print`.
    // Kept here (not inlined into emitted text) for the same reason as the
    // operator helpers above: one canonical implementation the compiler
    // dispatches to, matching `rust/shared/src/runtime.rs`'s
    // `ball_field_get`/`ball_field_set`/`ball_index_*`/`ball_iterate`.
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// <c>object.field</c> — read a field of a <see cref="BallMessage"/> or a
    /// key of a <see cref="BallMap"/>. An absent field/key reads as
    /// <c>null</c> (Dart's auto-vivifying getter / <c>map[key]</c>).
    /// </summary>
    public static BallValue FieldGet(BallValue obj, string field) => obj switch
    {
        BallMessage m => m.Get(field) ?? BallValue.Null,
        BallMap map => map.Get(field) ?? BallValue.Null,
        _ => throw new BallRuntimeException($"no field '{field}' on {TypeName(obj)}"),
    };

    /// <summary>
    /// <c>object.field = value</c> — write a field of a shared (reference-
    /// semantic) <see cref="BallMessage"/> or <see cref="BallMap"/>; returns
    /// the written value.
    /// </summary>
    public static BallValue FieldSet(BallValue obj, string field, BallValue value)
    {
        switch (obj)
        {
            case BallMessage m:
                m.Set(field, value);
                return value;
            case BallMap map:
                map.Set(field, value);
                return value;
            default:
                throw new BallRuntimeException($"cannot set field '{field}' on {TypeName(obj)}");
        }
    }

    /// <summary><c>target[index]</c> — polymorphic over List (int index)/Map (string key)/String (int index).</summary>
    public static BallValue IndexGet(BallValue target, BallValue index) => target switch
    {
        BallList => ListGet(target, index),
        BallMap => MapGet(target, index),
        BallString s => BallValue.Str(s.Value[AsIndex(index)].ToString()),
        _ => throw new BallRuntimeException($"cannot index {TypeName(target)}"),
    };

    /// <summary><c>target[index] = value</c> — mutates the shared List/Map; returns the value.</summary>
    public static BallValue IndexSet(BallValue target, BallValue index, BallValue value)
    {
        switch (target)
        {
            case BallList:
                ListSet(target, index, value);
                return value;
            case BallMap:
                MapSet(target, index, value);
                return value;
            default:
                throw new BallRuntimeException($"cannot index-assign {TypeName(target)}");
        }
    }

    /// <summary>
    /// Iterate a value for a <c>for_in</c> loop: a List yields its elements
    /// (a snapshot, so mutating the source mid-loop doesn't disturb the
    /// iteration), a Map yields each entry as a two-element <c>[key, value]</c>
    /// list (Dart's <c>MapEntry</c>), a String yields its characters.
    /// </summary>
    public static IEnumerable<BallValue> Iterate(BallValue value) => value switch
    {
        BallList l => l.Snapshot(),
        BallMap m => m.Entries().Select(e => (BallValue)new BallList(new[] { BallValue.Str(e.Key), e.Value })),
        BallString s => s.Value.Select(c => BallValue.Str(c.ToString())),
        _ => throw new BallRuntimeException($"value is not iterable: {TypeName(value)}"),
    };

    /// <summary>
    /// The declared <c>type_name</c> of a <see cref="BallMessage"/> instance
    /// (used by a compiled method dispatcher to pick the concrete
    /// implementation at run time), or the empty string for any non-message
    /// value.
    /// </summary>
    public static string MessageTypeName(BallValue value) =>
        value is BallMessage m ? m.TypeName : string.Empty;

    /// <summary>
    /// <c>print(message)</c> — write the value's stdout form followed by a
    /// single <c>\n</c> (never the platform <c>\r\n</c>, so compiled-program
    /// output is byte-identical to the other engines' golden output on every
    /// OS), and return <c>null</c> (invariant #1 — every base op yields a value).
    /// </summary>
    public static BallValue Print(BallValue message)
    {
        Console.Out.Write(message.ToString());
        Console.Out.Write('\n');
        return BallValue.Null;
    }
}
