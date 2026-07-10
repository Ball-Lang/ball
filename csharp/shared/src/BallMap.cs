using System.Collections.Generic;

namespace Ball.Shared;

/// <summary>
/// A string-keyed, <b>insertion-ordered</b>, <b>reference-semantic</b> map of
/// Ball values — the runtime materialization of every Ball <c>map</c>. Backed
/// by <see cref="OrderedDictionary{TKey, TValue}"/> (.NET 9+), which preserves
/// first-insertion order even after further mutation (Dart's
/// <c>LinkedHashMap</c> / JS <c>Map</c> / Rust <c>IndexMap</c> semantics).
///
/// <para>Like <see cref="BallList"/>, it is a reference type: <c>var b = a;</c>
/// aliases the same backing, so <c>b["k"] = v</c> is visible through <c>a</c>.
/// Overwriting an existing key preserves its position; removing a key preserves
/// the order of the rest.</para>
/// </summary>
public sealed class BallMap : BallValue
{
    private readonly OrderedDictionary<string, BallValue> _entries;

    /// <summary>An empty map.</summary>
    public BallMap() => _entries = new OrderedDictionary<string, BallValue>();

    /// <summary>An empty map with capacity pre-reserved (a hint only).</summary>
    public BallMap(int capacity) => _entries = new OrderedDictionary<string, BallValue>(capacity);

    /// <summary>Number of entries.</summary>
    public int Count => _entries.Count;

    /// <summary>Whether the map has no entries.</summary>
    public bool IsEmpty => _entries.Count == 0;

    /// <summary>
    /// Set entry <paramref name="key"/> (reference semantics). Overwriting an
    /// existing key preserves its insertion position.
    /// </summary>
    public BallValue this[string key]
    {
        set => _entries[key] = value;
    }

    /// <summary>
    /// Read entry <paramref name="key"/>, or C# <c>null</c> if the key is
    /// <b>absent</b> (a present entry whose value is <see cref="BallValue.Null"/>
    /// returns that null value, not C# <c>null</c> — matching Dart's
    /// <c>map[key]</c>).
    /// </summary>
    public BallValue? Get(string key) => _entries.TryGetValue(key, out var value) ? value : null;

    /// <summary>Set entry <paramref name="key"/> (Dart's <c>map[key] = value</c>).</summary>
    public void Set(string key, BallValue value) => _entries[key] = value;

    /// <summary>Whether entry <paramref name="key"/> is present.</summary>
    public bool ContainsKey(string key) => _entries.ContainsKey(key);

    /// <summary>
    /// Remove entry <paramref name="key"/>, preserving the insertion order of
    /// the rest (Dart's <c>Map.remove</c>). Returns the removed value, or C#
    /// <c>null</c> if the key was absent.
    /// </summary>
    public BallValue? Remove(string key)
    {
        if (!_entries.TryGetValue(key, out var value))
        {
            return null;
        }

        _entries.Remove(key);
        return value;
    }

    /// <summary>Empty the map in place (Dart's <c>Map.clear</c>).</summary>
    public void Clear() => _entries.Clear();

    /// <summary>The keys, in insertion order.</summary>
    public IReadOnlyList<string> Keys => _entries.Select(e => e.Key).ToList();

    /// <summary>The values, in insertion order.</summary>
    public IReadOnlyList<BallValue> Values => _entries.Select(e => e.Value).ToList();

    /// <summary>The entries, in insertion order.</summary>
    public IEnumerable<KeyValuePair<string, BallValue>> Entries() => _entries;

    /// <summary>A detached copy with a fresh backing (the value-semantic copy point).</summary>
    public BallMap Snapshot()
    {
        var copy = new BallMap(_entries.Count);
        foreach (var (key, value) in _entries)
        {
            copy._entries[key] = value;
        }

        return copy;
    }

    /// <inheritdoc />
    // Constant hash: mutable, never used as a hash key. See BallList.GetHashCode.
    public override int GetHashCode() => 0x11A900;

    /// <inheritdoc />
    public override string ToString() => FormatEntries(_entries);
}
