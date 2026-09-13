// Partial fixture, file 3 of 3 — the entry point, so the merged type is
// exercised end to end (both parts' methods called on one instance). Running
// the encoded program must print exactly 8 / 15.
using System;

namespace Demo;

public static class Program
{
    public static void Main()
    {
        var counter = new Counter { Start = 4, Step = 5 };
        Console.WriteLine(counter.Doubled());
        Console.WriteLine(counter.Tripled());
    }
}
