// The sibling declaration `d_cross_file_caller.cs` calls. It is committed (and
// listed by the sweep) only to make the bucket concrete: no code path in
// `CSharpEncoder.Encode` or `ball encode` can currently reach both files in one
// encode, which is exactly what bucket (d) measures.
public static class MathHelper
{
    public static int Square(int value)
    {
        return value * value;
    }
}
