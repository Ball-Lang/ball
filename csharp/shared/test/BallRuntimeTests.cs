using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// The runtime base-op helper layer (<see cref="BallRuntime"/>) the Phase-4
/// compiler will emit calls to. Semantics must match the Dart reference engine,
/// not "whatever C# does" — Euclidean modulo, int/double promotion, UTF-16
/// string measures, numeric cross-type comparison. Mirrors the intent of
/// <c>rust/shared/src/runtime.rs</c>'s helper surface.
/// </summary>
public class BallRuntimeTests
{
    // ── Arithmetic with int/double promotion ──────────────────────────────

    [Fact]
    public void AddPromotesIntAndDouble()
    {
        Assert.Equal(BallValue.Int(5), BallRuntime.Add(BallValue.Int(2), BallValue.Int(3)));
        Assert.Equal(BallValue.Double(5.5), BallRuntime.Add(BallValue.Int(2), BallValue.Double(3.5)));
        // String concatenation is also `add` in Dart.
        Assert.Equal(BallValue.Str("ab"), BallRuntime.Add(BallValue.Str("a"), BallValue.Str("b")));
    }

    [Fact]
    public void AddConcatenatesListsWithoutMutatingOperands()
    {
        var left = new BallList(new BallValue[] { BallValue.Int(1) });
        var right = new BallList(new BallValue[] { BallValue.Int(2) });
        var result = (BallList)BallRuntime.Add(left, right);
        Assert.Equal(2, result.Count);
        Assert.Equal(1, left.Count); // operands untouched (Dart list + is non-mutating)
        Assert.Equal(1, right.Count);
    }

    [Fact]
    public void IntArithmeticWrapsLikeDart64BitInt()
    {
        Assert.Equal(BallValue.Int(long.MinValue), BallRuntime.Add(BallValue.Int(long.MaxValue), BallValue.Int(1)));
        Assert.Equal(BallValue.Int(6), BallRuntime.Multiply(BallValue.Int(2), BallValue.Int(3)));
        Assert.Equal(BallValue.Int(-5), BallRuntime.Negate(BallValue.Int(5)));
    }

    [Fact]
    public void DivideTruncatesTowardZeroAndDivideDoubleIsReal()
    {
        Assert.Equal(BallValue.Int(3), BallRuntime.Divide(BallValue.Int(7), BallValue.Int(2)));
        Assert.Equal(BallValue.Int(-3), BallRuntime.Divide(BallValue.Int(-7), BallValue.Int(2)));
        Assert.Equal(BallValue.Double(3.5), BallRuntime.DivideDouble(BallValue.Int(7), BallValue.Int(2)));
    }

    [Fact]
    public void ModuloIsEuclidean()
    {
        // Dart's % has the sign of the divisor (Euclidean), NOT C#'s % (sign of dividend).
        Assert.Equal(BallValue.Int(2), BallRuntime.Modulo(BallValue.Int(-7), BallValue.Int(3)));
        Assert.Equal(BallValue.Int(1), BallRuntime.Modulo(BallValue.Int(7), BallValue.Int(3)));
    }

    [Fact]
    public void DivideByZeroThrows()
    {
        Assert.Throws<BallRuntimeException>(() => BallRuntime.Divide(BallValue.Int(1), BallValue.Int(0)));
        Assert.Throws<BallRuntimeException>(() => BallRuntime.Modulo(BallValue.Int(1), BallValue.Int(0)));
    }

    [Fact]
    public void RemainderIsTruncatedNotEuclidean()
    {
        // Dart's num.remainder keeps the sign of the DIVIDEND (truncated), unlike
        // the Euclidean Modulo above: (-3.75).remainder(2) == -1.75, not 0.25.
        Assert.Equal(BallValue.Double(0.5), BallRuntime.Remainder(BallValue.Double(2.5), BallValue.Int(2)));
        Assert.Equal(BallValue.Double(-1.75), BallRuntime.Remainder(BallValue.Double(-3.75), BallValue.Int(2)));
        Assert.Equal(BallValue.Int(1), BallRuntime.Remainder(BallValue.Int(7), BallValue.Int(3)));
        // Both-int stays int; any double promotes to double.
        Assert.IsType<BallInt>(BallRuntime.Remainder(BallValue.Int(7), BallValue.Int(3)));
        Assert.IsType<BallDouble>(BallRuntime.Remainder(BallValue.Double(2.5), BallValue.Int(2)));
        Assert.Throws<BallRuntimeException>(() => BallRuntime.Remainder(BallValue.Int(1), BallValue.Int(0)));
    }

    [Fact]
    public void NanIsNeverEqualAndSignedZerosAreEqual()
    {
        var nan = BallValue.Double(double.NaN);
        // IEEE-754 / Dart: NaN != NaN (this is exactly how the self-hosted engine
        // computes `isNaN` — as `d != d`).
        Assert.Equal(BallValue.Bool(false), BallRuntime.Equals(nan, nan));
        Assert.Equal(BallValue.Bool(true), BallRuntime.NotEquals(nan, nan));
        // Dart: -0.0 == 0.0 is true, and equal values must hash identically.
        Assert.Equal(BallValue.Bool(true), BallRuntime.Equals(BallValue.Double(-0.0), BallValue.Double(0.0)));
        Assert.Equal(BallValue.Double(0.0).GetHashCode(), BallValue.Double(-0.0).GetHashCode());
    }

    [Fact]
    public void NumericInstanceMethodsDispatchThroughCallMethod()
    {
        // The self-hosted engine routes num.remainder/toInt/toDouble here.
        Assert.Equal(BallValue.Int(1), BallRuntime.CallMethod("remainder", NumMethodInput(BallValue.Int(7), BallValue.Int(3))));
        Assert.Equal(BallValue.Int(3), BallRuntime.CallMethod("toInt", NumMethodInput(BallValue.Double(3.9))));
        Assert.Equal(BallValue.Double(4.0), BallRuntime.CallMethod("toDouble", NumMethodInput(BallValue.Int(4))));
    }

    private static BallValue NumMethodInput(BallValue self, BallValue? arg0 = null)
    {
        var input = new BallMap();
        input.Set("self", self);
        if (arg0 is not null)
        {
            input.Set("arg0", arg0);
        }

        return input;
    }

    // ── Comparison ────────────────────────────────────────────────────────

    [Fact]
    public void ComparisonPromotesAndOrdersStrings()
    {
        Assert.Equal(BallValue.Bool(true), BallRuntime.Equals(BallValue.Int(2), BallValue.Double(2.0)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.LessThan(BallValue.Int(1), BallValue.Double(1.5)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.GreaterThan(BallValue.Double(2.0), BallValue.Int(1)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.Lte(BallValue.Int(2), BallValue.Int(2)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.Gte(BallValue.Int(2), BallValue.Int(2)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.LessThan(BallValue.Str("a"), BallValue.Str("b")));
        Assert.Equal(BallValue.Int(-1), BallRuntime.CompareTo(BallValue.Int(1), BallValue.Int(2)));
    }

    // ── Truthiness ────────────────────────────────────────────────────────

    [Fact]
    public void TruthyUnwrapsBoolAndTreatsNullFalsy()
    {
        Assert.True(BallRuntime.Truthy(BallValue.Bool(true)));
        Assert.False(BallRuntime.Truthy(BallValue.Bool(false)));
        Assert.False(BallRuntime.Truthy(BallValue.Null));
        Assert.Throws<BallRuntimeException>(() => BallRuntime.Truthy(BallValue.Int(1)));
    }

    [Fact]
    public void LogicalNotAndBitwise()
    {
        Assert.Equal(BallValue.Bool(false), BallRuntime.Not(BallValue.Bool(true)));
        Assert.Equal(BallValue.Int(0b1000), BallRuntime.BitwiseAnd(BallValue.Int(0b1100), BallValue.Int(0b1010)));
        Assert.Equal(BallValue.Int(0b1110), BallRuntime.BitwiseOr(BallValue.Int(0b1100), BallValue.Int(0b1010)));
        Assert.Equal(BallValue.Int(0b0110), BallRuntime.BitwiseXor(BallValue.Int(0b1100), BallValue.Int(0b1010)));
        Assert.Equal(BallValue.Int(8), BallRuntime.LeftShift(BallValue.Int(1), BallValue.Int(3)));
        Assert.Equal(BallValue.Int(1), BallRuntime.RightShift(BallValue.Int(8), BallValue.Int(3)));
    }

    // ── Null safety ───────────────────────────────────────────────────────

    [Fact]
    public void NullCoalesceAndNullCheck()
    {
        Assert.Equal(BallValue.Int(1), BallRuntime.NullCoalesce(BallValue.Int(1), BallValue.Int(2)));
        Assert.Equal(BallValue.Int(2), BallRuntime.NullCoalesce(BallValue.Null, BallValue.Int(2)));
        Assert.Equal(BallValue.Int(1), BallRuntime.NullCheck(BallValue.Int(1)));
        Assert.Throws<BallRuntimeException>(() => BallRuntime.NullCheck(BallValue.Null));
    }

    // ── String ops (UTF-16 code-unit semantics, like Dart) ────────────────

    [Fact]
    public void StringOps()
    {
        Assert.Equal(BallValue.Int(5), BallRuntime.Length(BallValue.Str("hello")));
        Assert.Equal(BallValue.Bool(true), BallRuntime.StringContains(BallValue.Str("hello"), BallValue.Str("ell")));
        Assert.Equal(BallValue.Bool(true), BallRuntime.StringStartsWith(BallValue.Str("hello"), BallValue.Str("he")));
        Assert.Equal(BallValue.Str("ell"), BallRuntime.StringSubstring(BallValue.Str("hello"), BallValue.Int(1), BallValue.Int(4)));
        Assert.Equal(BallValue.Str("HELLO"), BallRuntime.StringToUpper(BallValue.Str("hello")));
        Assert.Equal(BallValue.Str("abc"), BallRuntime.StringTrim(BallValue.Str("  abc  ")));
        Assert.Equal(BallValue.Str("h_llo"), BallRuntime.StringReplace(BallValue.Str("hello"), BallValue.Str("e"), BallValue.Str("_")));
        Assert.Equal(BallValue.Str("ababab"), BallRuntime.StringRepeat(BallValue.Str("ab"), BallValue.Int(3)));

        var parts = (BallList)BallRuntime.StringSplit(BallValue.Str("a,b,c"), BallValue.Str(","));
        Assert.Equal(3, parts.Count);
    }

    [Fact]
    public void ToStringAndParsing()
    {
        Assert.Equal(BallValue.Str("42"), BallRuntime.ToStringValue(BallValue.Int(42)));
        Assert.Equal(BallValue.Int(42), BallRuntime.StringToInt(BallValue.Str("42")));
        Assert.Equal(BallValue.Double(3.5), BallRuntime.StringToDouble(BallValue.Str("3.5")));
        Assert.Throws<BallThrow>(() => BallRuntime.StringToInt(BallValue.Str("nope")));
    }

    // ── Collection ops ────────────────────────────────────────────────────

    [Fact]
    public void ListRuntimeOps()
    {
        var list = new BallList(new BallValue[] { BallValue.Int(1), BallValue.Int(2), BallValue.Int(3) });
        Assert.Equal(BallValue.Int(2), BallRuntime.ListGet(list, BallValue.Int(1)));
        Assert.Equal(BallValue.Int(3), BallRuntime.ListLength(list));
        Assert.Equal(BallValue.Int(1), BallRuntime.ListFirst(list));
        Assert.Equal(BallValue.Int(3), BallRuntime.ListLast(list));
        Assert.Equal(BallValue.Bool(true), BallRuntime.ListContains(list, BallValue.Int(2)));

        // list_push mutates the shared backing (reference semantics).
        BallRuntime.ListPush(list, BallValue.Int(4));
        Assert.Equal(4, list.Count);

        var rev = (BallList)BallRuntime.ListReverse(list);
        Assert.Equal(BallValue.Int(4), rev.Get(0));
        Assert.Equal(4, list.Count); // reverse returns a new list, source untouched
    }

    [Fact]
    public void MapRuntimeOps()
    {
        var map = new BallMap();
        BallRuntime.MapSet(map, BallValue.Str("k"), BallValue.Int(1));
        Assert.Equal(BallValue.Int(1), BallRuntime.MapGet(map, BallValue.Str("k")));
        Assert.Equal(BallValue.Bool(true), BallRuntime.MapContainsKey(map, BallValue.Str("k")));
        Assert.Equal(BallValue.Int(1), BallRuntime.MapLength(map));
        var keys = (BallList)BallRuntime.MapKeys(map);
        Assert.Equal(BallValue.Str("k"), keys.Get(0));
    }

    [Fact]
    public void MapNonStringKeysAreStringified()
    {
        // Ball maps are string-keyed, so a non-string key (an int memo key, a
        // bool, a whole double) is coerced to its display form rather than
        // rejected — matches rust/shared's `index_key` (self-host fixtures 95 /
        // 391 memoize with int keys). Every keying path routes through the same
        // coercion: set / get / containsKey / delete and the `map[key]` index form.
        var map = new BallMap();
        BallRuntime.MapSet(map, BallValue.Int(3), BallValue.Str("three"));
        BallRuntime.IndexSet(map, BallValue.Double(2.0), BallValue.Str("two"));
        BallRuntime.MapSet(map, BallValue.Bool(true), BallValue.Str("yes"));

        Assert.Equal(BallValue.Str("three"), BallRuntime.MapGet(map, BallValue.Int(3)));
        Assert.Equal(BallValue.Str("two"), BallRuntime.IndexGet(map, BallValue.Double(2.0)));
        Assert.Equal(BallValue.Bool(true), BallRuntime.MapContainsKey(map, BallValue.Int(3)));
        Assert.Equal(BallValue.Bool(false), BallRuntime.MapContainsKey(map, BallValue.Int(9)));

        // Keys round-trip back as their stringified form.
        var keys = (BallList)BallRuntime.MapKeys(map);
        Assert.Equal(BallValue.Str("3"), keys.Get(0));
        Assert.Equal(BallValue.Str("2.0"), keys.Get(1));
        Assert.Equal(BallValue.Str("true"), keys.Get(2));

        Assert.Equal(BallValue.Str("three"), BallRuntime.MapDelete(map, BallValue.Int(3)));
        Assert.Equal(BallValue.Bool(false), BallRuntime.MapContainsKey(map, BallValue.Int(3)));
    }

    [Fact]
    public void SetRuntimeOpsDedupAsList()
    {
        var set = (BallList)BallRuntime.SetCreate(new BallList(new BallValue[]
        {
            BallValue.Int(1), BallValue.Int(1), BallValue.Int(2),
        }));
        Assert.Equal(2, set.Count); // deduped
        Assert.Equal(BallValue.Bool(true), BallRuntime.SetContains(set, BallValue.Int(2)));
        BallRuntime.SetAdd(set, BallValue.Int(2)); // already present — no-op
        Assert.Equal(2, set.Count);
        BallRuntime.SetAdd(set, BallValue.Int(3));
        Assert.Equal(3, set.Count);
    }

    [Fact]
    public void CallFunctionDispatchesFirstClassValue()
    {
        var doubler = new BallFunction("dbl", v => BallValue.Int(((BallInt)v).Value * 2));
        Assert.Equal(BallValue.Int(10), BallRuntime.CallFunction(doubler, BallValue.Int(5)));
        Assert.Throws<BallRuntimeException>(() => BallRuntime.CallFunction(BallValue.Int(1), BallValue.Int(5)));
    }

    [Fact]
    public void UnsupportedBaseCallFailsLoud()
    {
        var ex = Assert.Throws<BallRuntimeException>(() => BallRuntime.UnsupportedBaseCall("std", "mystery"));
        Assert.Contains("std.mystery", ex.Message);
    }

    // ── Round 13: Dart-catchable runtime errors surface as catchable, matchable throws ──

    [Fact]
    public void MathAbsWrapsAtLongMinValueLikeDart()
    {
        // Dart's two's-complement (-9223372036854775808).abs() wraps back to itself
        // (its magnitude is unrepresentable); .NET Math.Abs(long) throws OverflowException.
        Assert.Equal(BallValue.Int(long.MinValue), BallRuntime.MathAbs(BallValue.Int(long.MinValue)));
        Assert.Equal(BallValue.Int(5), BallRuntime.MathAbs(BallValue.Int(-5)));
        Assert.Equal(BallValue.Int(long.MaxValue), BallRuntime.MathAbs(BallValue.Int(long.MaxValue)));
        Assert.Equal(BallValue.Double(2.5), BallRuntime.MathAbs(BallValue.Double(-2.5)));
    }

    [Fact]
    public void TypedThrowPayloadReportsRuntimeTypeSoOnTypeCatchMatches()
    {
        // The self-hosted engine's compiled try binds `e = throw.Payload` and matches
        // `on FormatException catch` via `e.runtimeType == catchType`. A bare string
        // payload would report runtimeType "String" and never match — the payload must
        // be a message whose type name IS the exception type.
        var thrown = Assert.Throws<BallThrow>(() => BallRuntime.StringToInt(BallValue.Str("not a number")));
        Assert.Equal("FormatException", thrown.TypeName);
        Assert.Equal(BallValue.Str("FormatException"), BallRuntime.FieldGet(thrown.Payload, "runtimeType"));
        // Must NOT be mistaken for an engine-level BallException (a different match path).
        Assert.Equal(BallValue.Bool(false), BallRuntime.IsType(thrown.Payload, "BallException"));
        // The clean message stays on Exception.Message for an uncaught throw's loud report.
        Assert.Contains("not a number", thrown.Message);
    }

    [Fact]
    public void ListGetOutOfRangeThrowsCatchableRangeError()
    {
        var list = new BallList(new BallValue[] { BallValue.Int(10) });
        Assert.Equal(BallValue.Int(10), BallRuntime.ListGet(list, BallValue.Int(0)));

        // Out-of-range surfaces as a catchable BallThrow (RangeError), not a native
        // .NET ArgumentOutOfRangeException the compiled `catch (BallThrow)` never sees.
        var over = Assert.Throws<BallThrow>(() => BallRuntime.ListGet(list, BallValue.Int(1)));
        Assert.Equal("RangeError", over.TypeName);
        Assert.Equal(BallValue.Str("RangeError"), BallRuntime.FieldGet(over.Payload, "runtimeType"));

        var negative = Assert.Throws<BallThrow>(() => BallRuntime.ListGet(list, BallValue.Int(-1)));
        Assert.Equal("RangeError", negative.TypeName);

        var empty = Assert.Throws<BallThrow>(() => BallRuntime.ListGet(new BallList(), BallValue.Int(0)));
        Assert.Equal("RangeError", empty.TypeName);
    }

    // ── bytes viewed as a List<int> (issue #383, conformance 399) ──────────

    [Fact]
    public void BytesBehaveAsAnIntListForListAndIterateOps()
    {
        // A proto `bytes` field is a Dart Uint8List — a List<int> of unsigned
        // byte values — so the engine's list/iterate surface must view it as one.
        var raw = BallValue.Bytes(new byte[] { 0, 1, 127, 255, 65 });

        Assert.Equal(BallValue.Int(5), BallRuntime.ListLength(raw));
        Assert.Equal(BallValue.Int(0), BallRuntime.ListGet(raw, BallValue.Int(0)));
        Assert.Equal(BallValue.Int(255), BallRuntime.ListGet(raw, BallValue.Int(3)));

        // `.toList()` yields a fresh int list; iteration and spread splice the ints.
        var copy = (BallList)BallRuntime.ListToList(raw);
        Assert.Equal(
            new BallValue[] { BallValue.Int(0), BallValue.Int(1), BallValue.Int(127), BallValue.Int(255), BallValue.Int(65) },
            copy.Snapshot());
        Assert.Equal(5, BallRuntime.SpreadIter(raw).Count());
    }

    // ── Map.addAll merges IN PLACE (issue #383, conformance 258) ───────────

    [Fact]
    public void ListConcatMergesMapsInPlaceSoSharedReferenceSeesTheMerge()
    {
        // `map.addAll(other)` is encoded as `map = list_concat(map, other)`, and
        // Dart's Map.addAll mutates — so a caller sharing the map reference must
        // observe the merge. (A fresh-map copy silently dropped pattern bindings.)
        var target = new BallMap();
        target["a"] = BallValue.Int(1);
        BallMap alias = target; // shared reference, like the pattern binder's `bindings`

        var other = new BallMap();
        other["b"] = BallValue.Int(2);
        other["a"] = BallValue.Int(9); // right wins on key clash

        var result = BallRuntime.ListConcat(target, other);

        // The receiver was mutated in place and returned (same object).
        Assert.Same(target, result);
        Assert.Equal(BallValue.Int(9), alias.Get("a"));
        Assert.Equal(BallValue.Int(2), alias.Get("b"));
        Assert.Equal(new[] { "a", "b" }, alias.Keys);
    }

    [Fact]
    public void ListConcatStillConcatenatesListsIntoAFreshList()
    {
        var a = new BallList(new BallValue[] { BallValue.Int(1), BallValue.Int(2) });
        var b = new BallList(new BallValue[] { BallValue.Int(3) });
        var result = (BallList)BallRuntime.ListConcat(a, b);
        Assert.Equal(3, result.Count);
        Assert.Equal(2, a.Count); // a list receiver is not mutated (the reassignment carries same-scope callers)
    }

    // ── two-variable catch binding (issue #383, conformance 300) ───────────

    [Fact]
    public void CaughtStackTraceIsANonEmptyString()
    {
        BallValue trace;
        try
        {
            throw new BallThrow(BallValue.Str("boom"));
        }
        catch (BallThrow ex)
        {
            trace = BallRuntime.CaughtStackTrace(ex);
        }

        var s = Assert.IsType<BallString>(trace);
        Assert.NotEqual(string.Empty, s.Value);
    }
}
