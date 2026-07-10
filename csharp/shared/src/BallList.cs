namespace Ball.Shared;

/// <summary>
/// An ordered, <b>reference-semantic</b> list of Ball values — the runtime
/// materialization of every Ball <c>list</c>/<c>set</c> (a set is a
/// duplicate-free list, see <see cref="BallRuntime"/>). Because it is a
/// reference type backed by a shared <see cref="List{T}"/>, <c>var b = a;</c>
/// aliases the same backing, so <c>b.Add(x)</c> is visible through <c>a</c> and
/// passing a list to a function passes the reference — exactly like Dart's
/// <c>List</c> and the Rust <c>BallList</c> (Arc/Mutex-shared) backing.
///
/// <para>Copy points (list literals, <c>toList()</c>, spread, <c>+</c> concat)
/// must build a fresh list from <see cref="Snapshot"/> — never alias — matching
/// the Dart reference engine (issues #39/#300).</para>
/// </summary>
public sealed class BallList : BallValue
{
    private readonly List<BallValue> _items;

    /// <summary>An empty list.</summary>
    public BallList() => _items = new List<BallValue>();

    /// <summary>A list owning a fresh copy of <paramref name="items"/>.</summary>
    public BallList(IEnumerable<BallValue> items) => _items = new List<BallValue>(items);

    /// <summary>Number of elements.</summary>
    public int Count => _items.Count;

    /// <summary>Whether the list has no elements.</summary>
    public bool IsEmpty => _items.Count == 0;

    /// <summary>Append <paramref name="value"/> (Dart's <c>list.add</c>).</summary>
    public void Add(BallValue value) => _items.Add(value);

    /// <summary>Append every element of <paramref name="values"/> (Dart's <c>addAll</c>).</summary>
    public void AddAll(IEnumerable<BallValue> values) => _items.AddRange(values);

    /// <summary>Remove and return the last element (Dart's <c>removeLast</c>).</summary>
    public BallValue RemoveLast()
    {
        if (_items.Count == 0)
        {
            throw new BallRuntimeException("removeLast on an empty list");
        }

        var last = _items[^1];
        _items.RemoveAt(_items.Count - 1);
        return last;
    }

    /// <summary>Insert <paramref name="value"/> at <paramref name="index"/> (Dart's <c>insert</c>).</summary>
    public void Insert(int index, BallValue value) => _items.Insert(index, value);

    /// <summary>Remove and return the element at <paramref name="index"/> (Dart's <c>removeAt</c>).</summary>
    public BallValue RemoveAt(int index)
    {
        var removed = _items[index];
        _items.RemoveAt(index);
        return removed;
    }

    /// <summary>Read the element at <paramref name="index"/>.</summary>
    public BallValue Get(int index) => _items[index];

    /// <summary>Overwrite the element at <paramref name="index"/> (<c>list[index] = value</c>).</summary>
    public void Set(int index, BallValue value) => _items[index] = value;

    /// <summary>Empty the list in place (Dart's <c>clear</c>).</summary>
    public void Clear() => _items.Clear();

    /// <summary>
    /// Whether <paramref name="value"/> is present (structural equality via
    /// <see cref="BallValue.ValueEquals"/> — so <c>1</c> matches <c>1.0</c>).
    /// </summary>
    public bool Contains(BallValue value) => IndexOf(value) >= 0;

    /// <summary>First index of <paramref name="value"/>, or <c>-1</c> if absent.</summary>
    public int IndexOf(BallValue value)
    {
        for (var i = 0; i < _items.Count; i++)
        {
            if (ValueEquals(_items[i], value))
            {
                return i;
            }
        }

        return -1;
    }

    /// <summary>A detached snapshot copy of the elements (the value-semantic copy point).</summary>
    public List<BallValue> Snapshot() => new(_items);

    /// <inheritdoc />
    // A constant hash: Ball lists are mutable and never used as hash keys (maps
    // are string-keyed, sets are linear-scan lists), so a per-type constant keeps
    // the Equals/GetHashCode contract (structurally-equal lists hash equal)
    // without a mutation-sensitive structural hash.
    public override int GetHashCode() => 0x115700;

    /// <inheritdoc />
    public override string ToString() => "[" + string.Join(", ", _items) + "]";
}
