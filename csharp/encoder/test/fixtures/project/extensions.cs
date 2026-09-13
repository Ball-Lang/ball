// Fixture project, file 2 of 3 (issue #492, W12-C slice 1).
//
// A project-declared extension method. At the call site `squared.Doubled()`
// looks like an INSTANCE method on `int`, so name-based dispatch has nothing
// to route it to — `DispatchInstanceOrBuiltinMethod` has no `("Doubled", 0)`
// arm, and the same-file `AnyMethodParams` table only ever holds INSTANCE
// methods, never statics. Only a semantic model can tell that this is really
// the static `NumberExtensions.Doubled(int value)` with the receiver bound to
// its first parameter (`IMethodSymbol.ReducedFrom`).
namespace Demo;

public static class NumberExtensions
{
    public static int Doubled(this int value)
    {
        return value + value;
    }
}
