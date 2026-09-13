// Partial fixture, file 2 of 3 — the second part of `Demo.Counter`. Its field
// and its method must both survive the merge.
namespace Demo;

public partial class Counter
{
    public int Step;

    public int Tripled()
    {
        return this.Step + this.Step + this.Step;
    }
}
