using Ball.Shared;

namespace Ball.Shared.Tests;

/// <summary>
/// Reference-semantics + insertion-order invariants for <see cref="BallList"/>,
/// <see cref="BallMap"/>, and <see cref="BallMessage"/>. These mirror the Dart
/// reference engine (lists/maps/instances are reference types — an alias's
/// mutation is visible through the original) and <c>rust/shared/src/value.rs</c>'s
/// equivalent tests (issues #39/#298/#300).
/// </summary>
public class BallCollectionsTests
{
    [Fact]
    public void BallMapPreservesInsertionOrder()
    {
        var map = new BallMap();
        map["z"] = BallValue.Int(1);
        map["a"] = BallValue.Int(2);
        map["m"] = BallValue.Int(3);

        Assert.Equal(new[] { "z", "a", "m" }, map.Keys);

        // Overwriting an existing key must NOT move it to the end (Dart
        // LinkedHashMap / JS Map / IndexMap semantics).
        map["z"] = BallValue.Int(99);
        Assert.Equal(new[] { "z", "a", "m" }, map.Keys);
        Assert.Equal(BallValue.Int(99), map.Get("z"));
    }

    [Fact]
    public void BallMapRemovePreservesOrderOfRest()
    {
        var map = new BallMap();
        map["a"] = BallValue.Int(1);
        map["b"] = BallValue.Int(2);
        map["c"] = BallValue.Int(3);

        Assert.Equal(BallValue.Int(2), map.Remove("b"));
        Assert.Equal(new[] { "a", "c" }, map.Keys);
        Assert.Null(map.Remove("missing"));
    }

    [Fact]
    public void ListHasReferenceSemanticsAcrossAliases()
    {
        var a = new BallList(new BallValue[] { BallValue.Int(1) });
        BallList b = a; // alias — same object
        b.Add(BallValue.Int(2));
        Assert.Equal(new BallValue[] { BallValue.Int(1), BallValue.Int(2) }, a.Snapshot());

        a.Add(BallValue.Int(3));
        Assert.Equal(3, b.Count);

        a.Set(0, BallValue.Int(9));
        Assert.Equal(BallValue.Int(9), b.Get(0));

        // A snapshot is a detached copy — mutating it never touches the source.
        var detached = a.Snapshot();
        detached.Add(BallValue.Int(100));
        Assert.Equal(3, a.Count);
    }

    [Fact]
    public void MapHasReferenceSemanticsAcrossAliases()
    {
        var a = new BallMap();
        a["x"] = BallValue.Int(1);
        BallMap b = a;
        b["y"] = BallValue.Int(2);
        Assert.Equal(BallValue.Int(2), a.Get("y"));
        a["z"] = BallValue.Int(3);
        Assert.Equal(BallValue.Int(3), b.Get("z"));
        Assert.Equal(new[] { "x", "y", "z" }, b.Keys);
    }

    [Fact]
    public void MessageHasReferenceSemanticsAcrossAliases()
    {
        var fields = new BallMap();
        fields["_functions"] = BallValue.Null;
        var a = new BallMessage("main:BallEngine", fields);
        BallMessage b = a;

        b.Set("_functions", BallValue.Int(42));
        Assert.Equal(BallValue.Int(42), a.Get("_functions"));
        a.Set("added", BallValue.Str("x"));
        Assert.Equal(BallValue.Str("x"), b.Get("added"));
    }

    [Fact]
    public void MessageSharesFieldMapBacking()
    {
        // Constructing a message from a BallMap shares that map's backing, so a
        // later write through the message is visible on the original map (the
        // property the self-hosted engine's mutable `this` relies on).
        var fields = new BallMap();
        var msg = new BallMessage("Point", fields);
        msg.Set("x", BallValue.Int(7));
        Assert.Equal(BallValue.Int(7), fields.Get("x"));
    }

    [Fact]
    public void ListContainsUsesNumericCrossTypeEquality()
    {
        var list = new BallList(new BallValue[] { BallValue.Double(1.0) });
        Assert.True(list.Contains(BallValue.Int(1)));
        Assert.Equal(0, list.IndexOf(BallValue.Int(1)));
    }

    [Fact]
    public void ListPopInsertRemoveAt()
    {
        var list = new BallList(new BallValue[] { BallValue.Int(1), BallValue.Int(2), BallValue.Int(3) });
        Assert.Equal(BallValue.Int(3), list.RemoveLast());
        list.Insert(0, BallValue.Int(0));
        Assert.Equal(new[] { 0L, 1L, 2L }, list.Snapshot().Select(v => ((BallInt)v).Value));
        Assert.Equal(BallValue.Int(1), list.RemoveAt(1));
        Assert.Equal(new[] { 0L, 2L }, list.Snapshot().Select(v => ((BallInt)v).Value));
    }
}
