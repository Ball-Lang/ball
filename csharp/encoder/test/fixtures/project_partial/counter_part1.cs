// Partial fixture, file 1 of 3 (issue #492, W12-C slice 1).
//
// The counterpart to `project_collision/`: two syntax declarations that share
// ONE `INamedTypeSymbol`, because they are `partial` parts of a single type.
// A short-name-keyed declaration table cannot tell this apart from a genuine
// collision — the symbol can, so the parts MERGE into one `main:Counter`
// carrying every field and every method from both, instead of the last part
// silently winning.
namespace Demo;

public partial class Counter
{
    public int Start;

    public int Doubled()
    {
        return this.Start + this.Start;
    }
}
