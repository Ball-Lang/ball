// Bucket (j): the 0-argument LINQ terminals `.Last()` and `.Any()` on a
// `List<T>`/`IEnumerable<T>` receiver — the two remaining shapes in the
// `unsupported method call` bucket whose meaning a DECLARED std function
// already models exactly (issue #492, slice 3b). `.Last()` is `list_last`
// (same throw-on-empty contract as C#'s own `.Last()`), and `.Any()` is
// "not empty", i.e. `not(list_is_empty(...))`.
//
// The fixture prints from BOTH a non-empty and an empty receiver on purpose:
// a route that encoded `.Any()` as bare `list_is_empty` (the inversion this
// pair is easiest to get wrong) still prints two lines, so only asserting
// the actual `true`/`false` values can fail on it.
using System;
using System.Collections.Generic;
using System.Linq;

public class Program
{
    public static void Main()
    {
        List<int> values = new List<int> { 1, 2, 3 };
        List<int> empty = new List<int>();
        Console.WriteLine(values.Last());
        Console.WriteLine(values.Any());
        Console.WriteLine(empty.Any());
    }
}
