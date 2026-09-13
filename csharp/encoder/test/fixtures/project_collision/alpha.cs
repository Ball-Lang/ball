// Collision fixture, file 1 of 2 (issue #492, W12-C slice 1).
//
// `A.Box` and `B.Box` (beta.cs) are two DISTINCT types sharing one short
// name. Ball has no namespace concept — `Encoder.QualifiedTypeName` flattens
// every declaration into one `main:` module — so both would encode to
// `main:Box`, producing two `TypeDefinition`s and two `main:Box.Describe`
// functions in one module with no error at all. That silent collision is the
// latent defect W12-C's design record measured (13 occurrences across the four
// Tier A pins); in project mode two distinct `INamedTypeSymbol`s sharing a
// short name is now a loud `EncoderException`.
namespace A;

public class Box
{
    public int Width;

    public int Describe()
    {
        return this.Width;
    }
}
