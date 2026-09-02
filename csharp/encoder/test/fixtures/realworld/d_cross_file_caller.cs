// Bucket (d): a call whose callee type is declared in a SIBLING file
// (d_cross_file_callee.cs). `ball encode` reads exactly one file and the
// encoder's symbol table (Encoder.ClassNames/ClassFields/MethodParams) is
// rebuilt per Encode() call from that file's own declarations, so `MathHelper`
// is simply unknown here.
public class Program
{
    public static void Main()
    {
        var result = MathHelper.Square(7);
        System.Console.WriteLine(result);
    }
}
