// Fixture project, file 3 of 3 (issue #492, W12-C slice 1) — the entry point.
//
// Four shapes, three of which a syntax-only encode cannot resolve and a
// semantic model answers exactly:
//   * `MathHelper.Square(seed)` — a callee declared in `geometry.cs`.
//   * `squared.Doubled()`       — a project-declared extension method.
//   * `nameof(MathHelper)`      — a compile-time constant string, which Roslyn
//                                 hands over as `GetConstantValue`.
//   * `label.Contains("Math")`  — the positive control for the receiver-typed
//                                 guard: the receiver DOES bind, and it binds
//                                 to `System.String`, so project mode keeps
//                                 routing it to `std.string_contains` exactly
//                                 as the resolution-free path always has.
// Running the encoded program must print exactly 49 / 98 / MathHelper.
using System;

namespace Demo;

public static class Program
{
    public static void Main()
    {
        var seed = 7;
        var squared = MathHelper.Square(seed);
        var doubled = squared.Doubled();
        Console.WriteLine(squared);
        Console.WriteLine(doubled);

        var label = nameof(MathHelper);
        if (label.Contains("Math"))
        {
            Console.WriteLine(label);
        }
    }
}
