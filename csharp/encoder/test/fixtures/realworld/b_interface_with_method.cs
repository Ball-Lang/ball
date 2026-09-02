// Bucket (b): an interface declaration. It MUST carry at least one method —
// `InterfaceDeclarationSyntax` derives from `TypeDeclarationSyntax`, so it does
// NOT hit CSharpEncoder.cs's "unsupported type declaration kind" throw (that
// site only catches `enum`); it reaches EncodeTypeDeclaration and only fails on
// a bodyless member. A member-less interface would encode fine and silently
// inflate this sweep's passed count.
public interface IShape
{
    double Area();
}

public class Program
{
    public static void Main()
    {
        System.Console.WriteLine("shapes");
    }
}
