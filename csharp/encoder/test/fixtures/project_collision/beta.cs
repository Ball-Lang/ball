// Collision fixture, file 2 of 2 — see alpha.cs. Same short name, different
// namespace, different fields: a genuine collision, not a `partial` split.
namespace B;

public class Box
{
    public int Height;

    public int Describe()
    {
        return this.Height;
    }
}
