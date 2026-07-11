using Ball.Shared;
using Ball.V1;
using Google.Protobuf.WellKnownTypes;
using BallV1Program = Ball.V1.Program;

namespace Ball.Compiler.Tests;

/// <summary>
/// Terse factory helpers for hand-building Ball <see cref="Expression"/> /
/// <see cref="Statement"/> / <see cref="BallV1Program"/> trees in tests — the
/// C# analog of <c>rust/compiler</c>'s in-test <c>int_lit</c>/<c>reference</c>
/// builders — so a dispatch/lazy-evaluation test can assert on the exact
/// construct it targets without shipping a <c>.ball.json</c> fixture.
/// </summary>
internal static class Ast
{
    public static Expression Int(long value) => new() { Literal = new Literal { IntValue = value } };

    public static Expression Double(double value) => new() { Literal = new Literal { DoubleValue = value } };

    public static Expression Str(string value) => new() { Literal = new Literal { StringValue = value } };

    public static Expression Bool(bool value) => new() { Literal = new Literal { BoolValue = value } };

    public static Expression Ref(string name) => new() { Reference = new Reference { Name = name } };

    public static Expression Msg(params (string Name, Expression Value)[] fields)
    {
        var mc = new MessageCreation();
        foreach (var (name, value) in fields)
        {
            mc.Fields.Add(new FieldValuePair { Name = name, Value = value });
        }

        return new Expression { MessageCreation = mc };
    }

    public static Expression Call(string module, string function, Expression? input = null)
    {
        var call = new FunctionCall { Module = module, Function = function };
        if (input is not null)
        {
            call.Input = input;
        }

        return new Expression { Call = call };
    }

    public static Expression Bin(string function, Expression left, Expression right) =>
        Call("std", function, Msg(("left", left), ("right", right)));

    public static Expression Print(Expression message) =>
        Call("std", "print", Msg(("message", message)));

    public static Statement Expr(Expression expression) => new() { Expression = expression };

    public static Statement Let(string name, Expression value) =>
        new() { Let = new LetBinding { Name = name, Value = value } };

    public static Expression Block(IEnumerable<Statement> statements, Expression? result = null)
    {
        var block = new Block();
        block.Statements.AddRange(statements);
        if (result is not null)
        {
            block.Result = result;
        }

        return new Expression { Block = block };
    }

    /// <summary>An anonymous lambda whose single parameter is addressed as <c>input</c>.</summary>
    public static Expression Lambda(Expression body) =>
        new() { Lambda = new FunctionDefinition { Body = body } };

    public static Expression ListLit(params Expression[] elements)
    {
        var list = new ListLiteral();
        list.Elements.AddRange(elements);
        return new Expression { Literal = new Literal { ListValue = list } };
    }

    /// <summary>Build a runnable program whose <c>main</c> function has <paramref name="mainBody"/>.</summary>
    public static BallV1Program Program(Expression mainBody, params FunctionDefinition[] extraFunctions)
    {
        var main = new Module { Name = "main" };
        foreach (var func in extraFunctions)
        {
            main.Functions.Add(func);
        }

        main.Functions.Add(new FunctionDefinition
        {
            Name = "main",
            OutputType = "void",
            Body = mainBody,
            Metadata = new Struct { Fields = { ["kind"] = Value.ForString("function") } },
        });

        var program = new BallV1Program
        {
            Name = "test",
            Version = "1.0.0",
            EntryModule = "main",
            EntryFunction = "main",
        };
        program.Modules.Add(StdModuleBuilders.BuildStdModule());
        program.Modules.Add(StdModuleBuilders.BuildStdCollectionsModule());
        program.Modules.Add(main);
        return program;
    }

    /// <summary>A user function with one named parameter (<paramref name="paramName"/>) and body <paramref name="body"/>.</summary>
    public static FunctionDefinition Func(string name, string paramName, Expression body)
    {
        var meta = new Struct { Fields = { ["kind"] = Value.ForString("function") } };
        var paramStruct = new Struct
        {
            Fields =
            {
                ["name"] = Value.ForString(paramName),
                ["type"] = Value.ForString("int"),
            },
        };
        meta.Fields["params"] = Value.ForList(Value.ForStruct(paramStruct));
        return new FunctionDefinition
        {
            Name = name,
            InputType = "int",
            OutputType = "int",
            Body = body,
            Metadata = meta,
        };
    }
}
