// Bucket (k): the 2-argument `string.Join(separator, values)` static call on the
// PREDEFINED type `string` — the single largest routable shape left in the
// `unsupported static call` bucket of the Tier A corpus (issue #492, slice 4:
// 12 of that bucket's 19 first-error files, every one of them this exact
// `string.Join(" ", parts)` spelling in Humanizer's
// `Localisation/NumberToWords/*NumberToWordsConverter.cs` and
// `StringHumanizeExtensions.cs`).
//
// `string` parses as a Roslyn `PredefinedTypeSyntax`, so the call reaches
// `EncodePredefinedTypeStaticCall`, which modelled only `Parse` and threw on
// everything else. It routes to the already-declared, already-compiled
// `std_collections.string_join`.
//
// The two calls below join the SAME list with two DIFFERENT separators, and a
// third joins an empty list. C#'s argument order is (separator, values) while
// `StringJoinInput`'s field order is (list = 1, separator = 2) — inverted — so a
// positional construction would swap them; joining twice with different
// separators is what makes that swap show up in the printed output rather than
// merely in a tree assertion.
using System;
using System.Collections.Generic;

public class Program
{
    public static void Main()
    {
        List<string> parts = new List<string> { "one", "hundred", "twenty" };
        List<string> none = new List<string>();
        Console.WriteLine(string.Join(" ", parts));
        Console.WriteLine(string.Join(", ", parts));
        Console.WriteLine(string.Join(" ", none));
    }
}
