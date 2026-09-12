// Bucket (i): BCL static guard calls — `ArgumentNullException.ThrowIfNull(x)` and
// `Debug.Assert(...)`. Both are static calls on a BCL type whose semantics is
// "throw unless this holds", which universal `std.assert` already models exactly
// (issue #492, slice 3). `ThrowIfNull` is the highest-count named shape in the
// `unsupported method call` bucket of a Tier A run; `Debug.Assert` is its
// 1-argument/2-argument sibling. Both spellings live in one fixture — as bucket
// (e) put `int.Parse` and `.Count()` in one file — so closing the bucket has to
// close both on this file's UNMODIFIED text.
using System;
using System.Diagnostics;

public class Program
{
    public static void Main()
    {
        string name = "ball";
        ArgumentNullException.ThrowIfNull(name);
        Debug.Assert(name.StartsWith("b"));
        Debug.Assert(name.Length > 0, "name must not be empty");
        Console.WriteLine(name.ToUpper());
    }
}
