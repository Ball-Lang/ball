// Bucket (a): a namespaced class library with no entry point — the single
// largest bucket in issue #492's 200-file study (38/200).
namespace Ball.Sample.Library;

public class Greeter
{
    public string Greet(string name)
    {
        return "Hello, " + name;
    }
}
