// Unbound-receiver fixture (issue #492, W12-C slice 1) — the guard against
// project mode being SILENTLY wrong.
//
// `Missing.Bag` is not declared anywhere and is not referenced, so `bag` has
// an error type and `GetTypeInfo` cannot say what it is. `.Contains(x)` is one
// of the receiver-discriminated names `Methods.cs`'s module doc comment names:
// the resolution-free path routes it unconditionally to `std.string_contains`,
// which is a documented coin flip that path never promised to win.
//
// `EncodeProject` DOES promise a symbol-grade answer, so the same coin flip
// inside it would be a silent fail-soft in the mode advertised as resolved.
// Project mode therefore fails LOUD here, naming the file, the call and the
// binding failure — while `Encode(string)` on this very text keeps returning
// today's `string_contains` answer, unchanged.
using System;

public static class Unbound
{
    public static void Check(Missing.Bag bag)
    {
        Console.WriteLine(bag.Contains("needle"));
    }
}
